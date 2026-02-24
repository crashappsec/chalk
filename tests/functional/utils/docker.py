# Copyright (c) 2023-2024, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import re
from contextlib import contextmanager
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Optional, TypeVar

from more_itertools import windowed

from .dict import ContainsDict, Either, MISSING, Repr
from .log import get_logger
from .os import Program, run


logger = get_logger()

ProgramType = TypeVar("ProgramType", bound=Program)


@lru_cache()
def is_overlayfs() -> bool:
    return "overlayfs" in run(["docker", "info"]).text


@dataclass
class DockerDigests:
    config: str
    digest: str
    index: str
    registry_digest: str
    registry_index: str

    @property
    def registry(self) -> str:
        return (
            self.registry_index  #
            or self.registry_digest  #
            or self.index  #
            or self.digest  #
        )

    @property
    def id(self) -> str:
        if is_overlayfs():
            return self.index or self.digest
        else:
            return self.config

    @property
    def either_ids(self) -> Either | Repr:
        ids: list[str] = []
        if is_overlayfs():
            if self.index:
                ids.append(self.index)
            if self.digest:
                ids.append(self.digest)
        elif self.config:
            ids.append(self.config)
        if not ids:
            return MISSING
        return Either(*ids)

    @property
    def either_registry_ids(self) -> Either | Repr:
        ids: list[str] = []
        if is_overlayfs():
            if self.registry_index:
                ids.append(self.registry_index)
            if self.registry_digest:
                ids.append(self.registry_digest)
            if self.index:
                ids.append(self.index)
            if self.digest:
                ids.append(self.digest)
        elif self.config:
            ids.append(self.config)
        if not ids:
            return MISSING
        return Either(*ids)

    def __bool__(self) -> bool:
        return bool(self.config) or bool(self.digest) or bool(self.index)


class Docker:
    @staticmethod
    def dockerfile(d: str) -> str:
        return "\n".join(i.strip() for i in d.splitlines()).strip()

    @contextmanager
    @staticmethod
    def build_cmd(
        *,
        tag: Optional[str],
        tags: Optional[list[str]] = None,
        context: Optional[Path | str] = None,
        dockerfile: Optional[Path | str] = None,
        content: Optional[str] = None,
        args: Optional[dict[str, str]] = None,
        push: bool = False,
        load: bool = True,
        platforms: Optional[list[str]] = None,
        buildx: bool = False,
        secrets: Optional[dict[str, Path]] = None,
        buildkit: bool = True,
        builder: Optional[str] = None,
        provenance: bool = False,
        sbom: bool = False,
        labels: Optional[dict[str, str]] = None,
        annotations: Optional[dict[str, str]] = None,
    ):
        stdin = b""
        tags = tags or []
        if tag:
            tags = [tag] + tags
        cmd = ["docker"]
        if platforms or buildx:
            cmd += ["buildx"]
            buildx = True
        cmd += ["build"]
        if buildx and not platforms and not provenance and not sbom and load:
            cmd += ["--load"]
        for t in tags:
            cmd += ["-t", t]
        if content:
            stdin = Docker.dockerfile(content).encode()
            cmd += ["-f", "-"]
        elif dockerfile:
            cmd += ["-f", str(dockerfile)]
        for name, value in (args or {}).items():
            cmd += [f"--build-arg={name}={value}"]
        if platforms:
            cmd += [f"--platform={','.join(platforms)}"]
        if push:
            cmd += ["--push"]
        if secrets and buildkit:
            cmd += [f"--secret=id={k},src={v}" for k, v in secrets.items()]
        if provenance:
            cmd += ["--provenance=true"]
        elif buildx:
            # its on by default now
            cmd += ["--provenance=false"]
        if sbom:
            cmd += ["--sbom=true"]
        if labels:
            for k, v in labels.items():
                cmd += [f"--label={k}={v}"]
        if annotations:
            if not buildx:
                raise ValueError("--annotation only works with buildx")
            for k, v in annotations.items():
                cmd += [f"--annotation={k}={v}"]
        if builder and buildx:
            cmd += [f"--builder={builder}"]
        cmd += [str(context or ".")]
        yield cmd, stdin

    @staticmethod
    def build(
        *,
        tag: Optional[str] = None,
        tags: Optional[list[str]] = None,
        context: Optional[Path | str] = None,
        dockerfile: Optional[Path | str] = None,
        content: Optional[str] = None,
        args: Optional[dict[str, str]] = None,
        cwd: Optional[Path] = None,
        push: bool = False,
        load: bool = True,
        platforms: Optional[list[str]] = None,
        buildx: bool = False,
        builder: Optional[str] = None,
        expected_success: bool = True,
        buildkit: bool = True,
        secrets: Optional[dict[str, Path]] = None,
        provenance: bool = False,
        sbom: bool = False,
        env: Optional[dict[str, str]] = None,
        labels: Optional[dict[str, str]] = None,
        annotations: Optional[dict[str, str]] = None,
    ) -> tuple[DockerDigests, Program]:
        """
        run docker build with parameters
        """
        with Docker.build_cmd(
            tag=tag,
            tags=tags,
            context=context,
            dockerfile=dockerfile,
            content=content,
            args=args,
            push=push,
            load=load,
            platforms=platforms,
            buildx=buildx,
            builder=builder,
            secrets=secrets,
            buildkit=buildkit,
            provenance=provenance,
            sbom=sbom,
            labels=labels,
            annotations=annotations,
        ) as (params, stdin):
            return Docker.with_digests(
                run(
                    params,
                    stdin=stdin,
                    expected_exit_code=int(not expected_success),
                    env={**Docker.build_env(buildkit=buildkit), **(env or {})},
                    cwd=cwd,
                ),
                push=push,
                tag=tag,
            )

    @staticmethod
    def build_env(
        *,
        buildkit: bool = True,
    ) -> dict[str, str]:
        return {"DOCKER_BUILDKIT": str(int(buildkit))}

    @staticmethod
    def with_digests(
        build: ProgramType, push: bool, tag: Optional[str] = None
    ) -> tuple[DockerDigests, ProgramType]:
        config_digest = ""
        image_digest = ""
        list_digest = ""
        registry_list_digest = ""
        registry_image_digest = ""

        if build.exit_code == 0:
            if build.env.get("DOCKER_BUILDKIT", "1") == "1" or (
                "docker",
                "buildx",
            ) in list(windowed(build.cmd, 2)):

                def get_sha256(
                    needle: re.Pattern,
                    ignore_in_between: Optional[list[tuple[str, str]]] = None,
                ) -> str:
                    ignore_in_between = ignore_in_between or []
                    return build.find(
                        needle,
                        text=build.logs,
                        words=1,  # there is "done" after hash
                        default="",
                        log_level=None,
                        ignore_in_between=(
                            [
                                (
                                    "docker: probing for build platforms",
                                    "docker: done probing for build platforms",
                                )
                            ]
                            + (ignore_in_between if is_overlayfs() else [])
                        ),
                    )

                oci = [("exporting to oci image format", "DONE")]
                docker = [("exporting to image", "DONE")]
                registry_list_digest = get_sha256(
                    re.compile("exporting manifest list sha256:"),
                    oci,
                )
                registry_image_digest = get_sha256(
                    re.compile("exporting manifest sha256:"),
                    oci,
                )
                list_digest = get_sha256(
                    re.compile("exporting manifest list sha256:"),
                    docker,
                )
                image_digest = get_sha256(
                    re.compile("exporting manifest sha256:"),
                    docker,
                )

                config_digest = get_sha256(
                    re.compile("exporting config sha256:"),
                ) or get_sha256(
                    re.compile("writing image sha256:"),
                )
                if not config_digest and (
                    # this is a multi-platform build so image_id is expected to be missing
                    list_digest
                    # --load wasnt used so no image id is provided
                    or "Build result will only remain in the build cache" in build.logs
                ):
                    pass
                elif not config_digest:
                    raise ValueError("No buildx image found during docker build")

            else:
                short_id = build.find(
                    "Successfully built",
                    words=1,
                    reverse=True,
                    log_level=None,
                )
                # legacy builder returns short id so we figure out longer id
                long_id = run(
                    ["docker", "inspect", short_id, "--format", "{{ .ID }}"],
                    log_level="debug",
                ).text.rsplit(":", maxsplit=1)[1]
                if is_overlayfs():
                    image_digest = long_id
                else:
                    config_digest = long_id

        digests = DockerDigests(
            config=config_digest,
            digest=image_digest or registry_image_digest,
            index=list_digest or registry_list_digest,
            registry_digest=registry_image_digest,
            registry_index=registry_list_digest,
        )

        if tag and push and not digests.registry:
            digests = Docker.crane_digests(tag, digests)

        return (digests, build)

    @staticmethod
    def run(
        image: str,
        params: Optional[list[str]] = None,
        name: Optional[str] = None,
        entrypoint: Optional[str] = None,
        expected_success: bool = True,
        timeout: Optional[int] = None,
        tty: bool = True,
        check: bool = True,
        attach: bool = True,
        user: Optional[str] = None,
        volumes: Optional[dict[Path, Path | str]] = None,
        cwd: Optional[Path] = None,
        env: Optional[dict[str, str]] = None,
    ):
        cmd = ["docker", "create"]
        if name:
            cmd += ["--name", name]
        else:
            cmd += ["--rm"]
        if entrypoint:
            cmd += ["--entrypoint", entrypoint]
        if tty:
            cmd += ["-t"]
        if user:
            cmd += ["-u", user]
        for host, container in (volumes or {}).items():
            cmd += ["-v", f"{host}:{container}"]
        if cwd:
            cmd += ["-w", str(cwd)]
        for k, v in (env or {}).items():
            cmd += ["-e", f"{k}={v}"]
        cmd += [image]
        cmd += params or []
        container_id = run(cmd).text
        assert container_id

        cmd = ["docker", "start", container_id]
        if attach:
            cmd += ["-a"]
        return container_id, run(
            cmd,
            check=check,
            expected_exit_code=int(not expected_success),
            timeout=timeout,
        )

    @staticmethod
    def version() -> Program:
        return run(["docker", "--version"])

    @staticmethod
    def pull(tag: str, platform: Optional[str] = None) -> Program:
        p = []
        if platform:
            p = ["--platform", platform]
        return run(["docker", "pull", tag] + p)

    @staticmethod
    def push(
        tag: str, digests: Optional[DockerDigests] = None
    ) -> tuple[DockerDigests, Program]:
        push = run(["docker", "push", tag])
        return (
            Docker.crane_digests(tag, digests),
            push,
        )

    @staticmethod
    def tag(tag: str, new_tag: str) -> Program:
        return run(["docker", "tag", tag, new_tag])

    @staticmethod
    def manifest_create(
        list_manifest: str, *manifests: str, insecure: bool = True
    ) -> Program:
        insec = []
        if insecure:
            insec = ["--insecure"]
        run(["docker", "manifest", "create", list_manifest, *manifests] + insec)
        return run(["docker", "manifest", "push", list_manifest] + insec)

    @staticmethod
    def imagetools_inspect(tag: str) -> Program:
        return run(["docker", "buildx", "imagetools", "inspect", "--raw", tag])

    @staticmethod
    def crane_inspect(tag: str) -> Program:
        return run(["crane", "manifest", "--insecure", tag])

    @staticmethod
    def crane_digests(
        tag: str,
        digests: Optional[DockerDigests] = None,
        architecture: Optional[str] = None,
    ) -> DockerDigests:
        list_digest = ""
        image_digest = ""
        config_digest = ""

        output = Docker.crane_inspect(tag)
        if "manifests" in output.json():
            list_digest = output.digest
            image_digest = [
                i["digest"].split(":")[1]
                for i in output.json()["manifests"]
                if i.get("platform", {}).get("os", "unknown") != "unknown"
                and (
                    i.get("platform", {}).get("architecture", "unknown")
                    == (
                        architecture
                        or i.get("platform", {}).get("architecture", "unknown")
                    )
                )
            ][0].split(":")[0]
            tag = tag.split("@")[0]
            output = Docker.crane_inspect(f"{tag}@sha256:{image_digest}")

        image_digest = output.digest
        config_digest = output.json()["config"]["digest"].split(":")[1]

        return DockerDigests(
            config=config_digest,
            digest=digests.digest if digests else "",
            index=digests.index if digests else "",
            registry_digest=image_digest,
            registry_index=list_digest,
        )

    @staticmethod
    def inspect(name: str) -> ContainsDict:
        data = run(["docker", "inspect", name]).json()
        if len(data) != 1:
            raise IndexError(f"only single inspect output expected. got: {len(data)}")
        return ContainsDict(data[0])

    @staticmethod
    def all_images(only_id=True) -> list[str]:
        return run(
            ["docker", "image", "ls", "-a"]
            + (["--format", "{{ .ID }}"] if only_id else []),
            log_level="debug",
        ).text.splitlines()

    @staticmethod
    def all_containers() -> list[str]:
        return run(["docker", "ps", "-a", "-q"], log_level="debug").text.splitlines()

    @staticmethod
    def remove_images(images: list[str]) -> Program:
        assert images
        return run(
            ["docker", "image", "rm", "-f"] + images,
            check=False,
            log_level="debug",
        )

    @staticmethod
    def remove_containers(containers: list[str]) -> Program:
        assert containers
        return run(
            ["docker", "rm", "-f"] + containers,
            check=False,
            log_level="debug",
        )

    @staticmethod
    def stop_containers(containers: list[str]) -> Program:
        assert containers
        return run(
            ["docker", "kill"] + containers,
            check=False,
            log_level="debug",
        )

    @staticmethod
    def is_overlayfs() -> bool:
        return is_overlayfs()

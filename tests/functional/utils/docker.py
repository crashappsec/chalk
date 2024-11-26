# Copyright (c) 2023-2024, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from contextlib import contextmanager
from pathlib import Path
from subprocess import CalledProcessError
from typing import Optional, TypeVar

from more_itertools import windowed

from .dict import ContainsMixin
from .log import get_logger
from .os import Program, run


logger = get_logger()

ProgramType = TypeVar("ProgramType", bound=Program)


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
        platforms: Optional[list[str]] = None,
        buildx: bool = False,
        secrets: Optional[dict[str, Path]] = None,
        buildkit: bool = True,
        provenance: bool = False,
        sbom: bool = False,
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
        if buildx and not platforms:
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
        platforms: Optional[list[str]] = None,
        buildx: bool = False,
        expected_success: bool = True,
        buildkit: bool = True,
        secrets: Optional[dict[str, Path]] = None,
        provenance: bool = False,
        sbom: bool = False,
        env: Optional[dict[str, str]] = None,
    ) -> tuple[str, Program]:
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
            platforms=platforms,
            buildx=buildx,
            secrets=secrets,
            buildkit=buildkit,
            provenance=provenance,
            sbom=sbom,
        ) as (params, stdin):
            return Docker.with_image_id(
                run(
                    params,
                    stdin=stdin,
                    expected_exit_code=int(not expected_success),
                    env={**Docker.build_env(buildkit=buildkit), **(env or {})},
                    cwd=cwd,
                )
            )

    @staticmethod
    def build_env(
        *,
        buildkit: bool = True,
    ) -> dict[str, str]:
        return {"DOCKER_BUILDKIT": str(int(buildkit))}

    @staticmethod
    def with_image(
        build: ProgramType,
        buildkit="writing image",
        buildx="exporting config",
        legacy="{{ .ID }}",
    ) -> tuple[str, ProgramType]:
        image_id = ""

        if build.exit_code == 0:
            if build.env.get("DOCKER_BUILDKIT", "1") == "1" or (
                "docker",
                "buildx",
            ) in list(windowed(build.cmd, 2)):

                def get_sha256(needle: str) -> str:
                    if needle == "":
                        return ""
                    return build.find(
                        needle,
                        text=build.logs,
                        words=1,  # there is "done" after hash
                        reverse=True,
                        default="",
                        log_level=None,
                    ).split(":")[-1]

                image_id = get_sha256(buildkit) or get_sha256(buildx)
                if not image_id and (
                    # this is a multi-platform build so image_id is expected to be missing
                    get_sha256("exporting_manifest_list")
                    # --load wasnt used so no image id is provided
                    or "Build result will only remain in the build cache" in build.logs
                ):
                    pass
                elif not image_id:
                    raise ValueError("No buildx image found during docker build")

            else:
                image_id = build.find(
                    "Successfully built",
                    words=1,
                    reverse=True,
                    log_level=None,
                )
                # legacy builder returns short id so we figure out longer id
                image_id = run(
                    ["docker", "inspect", image_id, "--format", legacy],
                    log_level="debug",
                ).text.rsplit(":", maxsplit=1)[1]

        return image_id, build

    @staticmethod
    def with_image_id(build: ProgramType) -> tuple[str, ProgramType]:
        return Docker.with_image(build)

    @staticmethod
    def with_image_digest(build: ProgramType) -> tuple[str, ProgramType]:
        image_id, _ = Docker.with_image_id(build)
        format = "{{ (index .RepoDigests 0) }}"
        try:
            image_digest = run(
                ["docker", "inspect", image_id, "--format", format],
                log_level="debug",
            ).text.rsplit(":", maxsplit=1)[1]
            return image_digest, build
        except (IndexError, CalledProcessError):
            return Docker.with_image(
                build,
                buildkit="",
                buildx="exporting manifest",
                legacy=format,
            )

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
    def push(tag: str) -> Program:
        return run(["docker", "push", tag])

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
    def inspect(name: str) -> list[ContainsMixin]:
        return [ContainsMixin(i) for i in run(["docker", "inspect", name]).json()]

    @staticmethod
    def all_images() -> list[str]:
        return run(
            ["docker", "image", "ls", "-a", "--format", "{{ .ID }}"],
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

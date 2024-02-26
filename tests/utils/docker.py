# Copyright (c) 2023-2024, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from pathlib import Path
from typing import Any, Optional, TypeVar

from .log import get_logger
from .os import Program, run


logger = get_logger()

ProgramType = TypeVar("ProgramType", bound=Program)


class Docker:
    @staticmethod
    def build_cmd(
        *,
        tag: Optional[str],
        tags: Optional[list[str]] = None,
        context: Optional[Path | str] = None,
        dockerfile: Optional[Path | str] = None,
        args: Optional[dict[str, str]] = None,
        push: bool = False,
        platforms: Optional[list[str]] = None,
        buildx: bool = False,
        secrets: Optional[dict[str, Path]] = None,
        buildkit: bool = True,
    ):
        tags = tags or []
        if tag:
            tags = [tag] + tags
        cmd = ["docker"]
        if platforms or buildx:
            cmd += ["buildx"]
        cmd += ["build"]
        for t in tags:
            cmd += ["-t", t]
        if dockerfile:
            cmd += ["-f", str(dockerfile)]
        for name, value in (args or {}).items():
            cmd += [f"--build-arg={name}={value}"]
        if platforms:
            cmd += [f"--platform={','.join(platforms)}"]
        if push:
            cmd += ["--push"]
        if secrets and buildkit:
            cmd += [f"--secret=id={k},src={v}" for k, v in secrets.items()]
        cmd += [str(context or ".")]
        return cmd

    @staticmethod
    def build(
        *,
        tag: Optional[str] = None,
        tags: Optional[list[str]] = None,
        context: Optional[Path | str] = None,
        dockerfile: Optional[Path | str] = None,
        args: Optional[dict[str, str]] = None,
        cwd: Optional[Path] = None,
        push: bool = False,
        platforms: Optional[list[str]] = None,
        buildx: bool = False,
        expected_success: bool = True,
        buildkit: bool = True,
        secrets: Optional[dict[str, Path]] = None,
    ) -> tuple[str, Program]:
        """
        run docker build with parameters
        """
        return Docker.with_image_id(
            run(
                Docker.build_cmd(
                    tag=tag,
                    tags=tags,
                    context=context,
                    dockerfile=dockerfile,
                    args=args,
                    push=push,
                    platforms=platforms,
                    buildx=buildx,
                    secrets=secrets,
                    buildkit=buildkit,
                ),
                expected_exit_code=int(not expected_success),
                env=Docker.build_env(buildkit=buildkit),
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
    def with_image_id(build: ProgramType) -> tuple[str, ProgramType]:
        image_id = ""

        if build.exit_code == 0:  # and not any(
            if build.env.get("DOCKER_BUILDKIT", "1") == "1":

                def get_sha256(needle: str) -> str:
                    return build.find(
                        needle,
                        text=build.logs,
                        words=1,  # there is "done" after hash
                        reverse=True,
                        default="",
                        log_level=None,
                    ).split(":")[-1]

                image_id = get_sha256("writing image") or get_sha256("exporting config")
                if not image_id and (
                    # this is a multi-platform build so image_id is expected to be missing
                    get_sha256("exporting_manifest_list")
                    # --load wasnt used so no image id is provided
                    or "Build result will only remain in the build cache" in build.logs
                ):
                    pass
                elif not image_id:
                    raise ValueError("No buildx image_id found during docker build")

            else:
                image_id = build.find(
                    "Successfully built",
                    words=1,
                    reverse=True,
                    log_level=None,
                )
                # legacy builder returns short id so we figure out longer id
                image_id = run(
                    ["docker", "inspect", image_id, "--format", "{{ .ID }}"],
                    log_level="debug",
                ).text.split(":")[1]

        return image_id, build

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
    def pull(tag: str) -> Program:
        return run(["docker", "pull", tag])

    @staticmethod
    def imagetools_inspect(tag: str) -> Program:
        return run(["docker", "buildx", "imagetools", "inspect", tag])

    @staticmethod
    def inspect(name: str) -> list[dict[str, Any]]:
        return run(["docker", "inspect", name]).json()

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

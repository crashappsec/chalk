# Copyright (c) 2023, Crash Override, Inc.
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
        context: Optional[Path] = None,
        dockerfile: Optional[Path] = None,
        args: Optional[dict[str, str]] = None,
        push: bool = False,
    ):
        cmd = ["docker", "build"]
        if tag:
            cmd += ["-t", tag]
        if dockerfile:
            cmd += ["-f", str(dockerfile)]
        for name, value in (args or {}).items():
            cmd += [f"--build-arg={name}={value}"]
        if push:
            cmd += ["--push"]
        cmd += [str(context or ".")]
        return cmd

    @staticmethod
    def build(
        *,
        tag: Optional[str] = None,
        context: Optional[Path] = None,
        dockerfile: Optional[Path] = None,
        args: Optional[dict[str, str]] = None,
        cwd: Optional[Path] = None,
        push: bool = False,
        expected_success: bool = True,
        buildkit: bool = True,
    ) -> tuple[str, Program]:
        """
        run docker build with parameters
        """
        return Docker.with_image_id(
            run(
                Docker.build_cmd(
                    tag=tag,
                    context=context,
                    dockerfile=dockerfile,
                    args=args,
                    push=push,
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
        if build.exit_code == 0:
            try:
                # buildx
                image_id = build.find(
                    "writing image",
                    text=build.logs,
                    words=1,  # there is "done" after hash
                    reverse=True,
                ).split(":")[1]
            except ValueError:
                image_id = build.find(
                    "Successfully built",
                    words=1,
                    reverse=True,
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

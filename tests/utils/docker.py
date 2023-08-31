from pathlib import Path
from typing import Any, Optional

from .log import get_logger
from .os import Program, run


logger = get_logger()


class Docker:
    @staticmethod
    def build_cmd(
        tag: str,
        context: Optional[Path] = None,
        dockerfile: Optional[Path] = None,
    ):
        cmd = ["docker", "build", "-t", tag]
        if dockerfile:
            cmd += ["-f", str(dockerfile)]
        cmd += [str(context or ".")]
        return cmd

    @staticmethod
    def build(
        tag: str,
        context: Optional[Path] = None,
        dockerfile: Optional[Path] = None,
        cwd: Optional[Path] = None,
        expected_success: bool = True,
    ) -> Program:
        """
        run docker build with parameters
        """
        return run(
            Docker.build_cmd(tag=tag, context=context, dockerfile=dockerfile),
            expected_exit_code=int(not expected_success),
            cwd=cwd,
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

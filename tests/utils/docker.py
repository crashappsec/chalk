import os
from contextlib import chdir
from pathlib import Path
from subprocess import DEVNULL, CalledProcessError, CompletedProcess, run
from typing import List, Optional

from .log import get_logger

logger = get_logger()


def remove_img(img: str) -> None:
    try:
        run(
            ["docker", "image", "rm", img],
            check=False,
            stdout=DEVNULL,
            stderr=DEVNULL,
        )
    except CalledProcessError as e:
        logger.warning("[WARN] docker image removal failed: %s", str(e))


def docker_build(dir: Path, params: Optional[List[str]] = None) -> CompletedProcess:
    with chdir(dir):
        cmd = ["docker", "build"]
        if params:
            cmd.extend(params)

        _build = run(cmd, capture_output=True)
        if _build.returncode != 0:
            # if docker build fails, it might be because docker is down
            # or throttling us, so print error in case we want to check
            logger.error("Docker build failed", error=_build.stderr.decode())
        return _build

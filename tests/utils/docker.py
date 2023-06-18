import json
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


def stop_container(id: str) -> None:
    try:
        run(
            ["docker", "stop", id],
            check=True,
            stdout=DEVNULL,
            stderr=DEVNULL,
        )
    except CalledProcessError as e:
        logger.error("docker image removal failed: %s", str(e))


def compose_run_local_server(*, https: bool = False) -> str:
    """Spins up the server and returns the container id"""
    root_dir = Path(__file__).parent.parent.parent
    try:
        cmd = [
            "docker",
            "run",
            "--rm",
            "-d",
            "--publish",
            "8585:8585",
            "-v",
            f"{root_dir}:{root_dir}",
            "--network",
            "chalk-internal-network",
            "--network-alias",
            "chalk.crashoverride.local",
            "--workdir",
            f"{root_dir}/server/app",
            "chalk_local_api_server",
        ]
        if https:
            cmd.extend(
                [
                    "sh",
                    "-c",
                    "python main.py --keyfile keys/self-signed.key --certfile keys/self-signed.cert",
                ]
            )
        out = run(
            cmd,
            capture_output=True,
            cwd=root_dir,
        )
        return out.stdout.decode().strip()
    except CalledProcessError as e:
        logger.warning(
            "docker execution of server failed. Is the container built? %s", str(e)
        )
        logger.error(e)
        raise


# run docker build with parameters
def docker_build(
    dir: Path, params: Optional[List[str]] = None, expected_success: bool = True
) -> CompletedProcess:
    with chdir(dir):
        cmd = ["docker", "build"]
        if params:
            cmd.extend(params)

        _build = run(cmd, capture_output=True)
        if _build.returncode != 0 and expected_success:
            # if docker build fails, it might be because docker is down
            # or throttling us, so print error in case we want to check
            logger.error(
                "Docker build failed unexpectedly", error=_build.stderr.decode()
            )
        if _build.returncode == 0 and not expected_success:
            # if docker build fails, it might be because docker is down
            # or throttling us, so print error in case we want to check
            logger.error(
                "Docker build should have failed but did not",
                error=_build.stderr.decode(),
            )
        return _build


# look up docker image hash from docker tag
# returns a list of all hashes from the docker inspect
def docker_inspect_image_hashes(tag: str) -> List[str]:
    images: List[str] = []
    try:
        docker_inspect = run(
            ["docker", "inspect", tag],
            capture_output=True,
            check=True,
        )
    except CalledProcessError as e:
        logger.error("docker inspect failed", error=e)
        return images

    try:
        inspect_json = json.loads(docker_inspect.stdout.decode())
    except json.JSONDecodeError as e:
        logger.error("docker inspect json could not be decoded", error=e)
        return images

    for i in inspect_json:
        try:
            hash = i["Id"].split("sha256:")[1]
            images.append(hash)
        except KeyError:
            logger.warn("docker inspect json missing Id field")

    return images


def docker_image_cleanup(images: List[str]):
    for image in images:
        info_img_hash = image
        logger.debug("removing image %s", info_img_hash)
        try:
            run(
                ["docker", "image", "rm", info_img_hash],
                check=False,
                stdout=DEVNULL,
                stderr=DEVNULL,
            )
        except CalledProcessError as e:
            logger.warning("[WARN] docker image removal failed", error=str(e))

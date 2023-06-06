import json
import os
import shutil
import subprocess
import uuid
from contextlib import chdir
from pathlib import Path
from tempfile import TemporaryDirectory

import pytest

from .chalk.runner import Chalk
from .utils.docker import docker_build
from .utils.log import get_logger

logger = get_logger()

chalk = Chalk(binary=(Path(__file__).parent.parent / "chalk").resolve())
DOCKERFILES = Path(__file__).parent / "data" / "dockerfiles"


def test_virtual_valid_sample_1():
    assert chalk.binary is None or chalk.binary.is_file()
    with TemporaryDirectory() as _tmp_dir:
        tmp_dir = Path(_tmp_dir)
        shutil.copy(DOCKERFILES / "valid" / "sample_1" / "Dockerfile", tmp_dir)
        shutil.copy(DOCKERFILES / "valid" / "sample_1" / "helloworld.sh", tmp_dir)
        tag = str(uuid.uuid4())
        docker_build_params = ["-t", tag, "."]
        images = []
        # FIXME add everything below this point in a try/finally
        with chdir(tmp_dir):
            try:
                docker_run = docker_build(tmp_dir, params=docker_build_params)
                chalk_run = chalk.run(
                    params=[
                        "--debug",
                        "--log-level=warn",
                        "--virtual",
                        "docker",
                        "build",
                    ]
                    + docker_build_params,
                )
                try:
                    docker_inspect = subprocess.run(
                        ["docker", "inspect", tag],
                        capture_output=True,
                        check=True,
                    )
                except subprocess.CalledProcessError as e:
                    logger.error("docker inspect failed", error=e)
                    raise

                inspect_json = json.loads(docker_inspect.stdout.decode())
                for i in inspect_json:
                    hash = i["Id"].split("sha256:")[1]
                    images.append(hash)

                vjsonf = tmp_dir / "virtual-chalk.json"
                assert vjsonf.is_file(), "virtual-chalk.json not found"
                vjson = json.loads(vjsonf.read_bytes())
                assert "CHALK_ID" in vjson

            finally:
                for image in images:
                    info_img_hash = image
                    logger.debug("removing image %s", info_img_hash)
                    try:
                        subprocess.run(
                            ["docker", "image", "rm", info_img_hash],
                            check=False,
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                        )
                    except subprocess.CalledProcessError as e:
                        logger.warning(
                            "[WARN] docker image removal failed", error=str(e)
                        )

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


# DOCKER_BUILDKIT=0 /Users/nettrino/projects/crashappsec/chalk-internal/chalk --debug --log-level=warn --virtual docker build .
# manually run
@pytest.mark.skipif(
    os.getenv("CONTAINERIZED") is not None,
    reason="Not chalking a container from within a container",
)
def test_virtual_valid_sample_1():
    assert chalk.binary is None or chalk.binary.is_file()
    logger.error("PWD", pwd=subprocess.check_output(["pwd"]).decode())
    logger.error("ls", ls=subprocess.check_output(["ls"]).decode())
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
                logger.error("PWD2", pwd=subprocess.check_output(["pwd"]).decode())
                logger.error("ls2", pwd=subprocess.check_output(["ls"]).decode())
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

                # single report in here
                chalk_report = tmp_dir / "chalk-reports.jsonl"
                assert chalk_report.is_file(), "chalk-reports.jsonl not found"
                chalk_reports = json.loads(chalk_report.read_bytes())
                len(chalk_reports["_CHALKS"]) == 1
                assert chalk_reports["_CHALKS"][0]["CHALK_ID"] == vjson["CHALK_ID"]
                assert chalk_reports["_CHALKS"][0]["_CURRENT_HASH"] in images
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

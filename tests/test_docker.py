import os
import shutil
import uuid
from pathlib import Path

import pytest

from .chalk.runner import Chalk
from .utils.docker import (
    docker_build,
    docker_image_cleanup,
    docker_inspect_image_hashes,
)
from .utils.log import get_logger
from .utils.validate import ArtifactInfo, validate_virtual_chalk

logger = get_logger()

DOCKERFILES = Path(__file__).parent / "data" / "dockerfiles"


def _build_and_chalk_dockerfile(chalk: Chalk, tmp_data_dir: Path, valid: bool):
    try:
        tag = str(uuid.uuid4())
        docker_build_params = ["-t", tag, "."]

        docker_run = docker_build(
            dir=tmp_data_dir, params=docker_build_params, expected_success=valid
        )
        chalk_run = chalk.run(
            params=[
                "--debug",
                "--log-level=warn",
                "--virtual",
                "docker",
                "build",
            ]
            + docker_build_params,
            expected_success=valid,
        )

        if valid:
            assert chalk_run and (
                docker_run.returncode == chalk_run.returncode
            ), "docker build and chalk docker build results should be the same"
        else:
            assert chalk_run is None, "chalk run should be unsuccessful on invalid test"
    except Exception as e:
        logger.error("docker build / chalk build failed unexpectedly", error=e)
        raise
    finally:
        if docker_run.returncode == 0:
            images = docker_inspect_image_hashes(tag=tag)
            docker_image_cleanup(images=images)


@pytest.mark.parametrize(
    "test_file", ["valid/sample_1", "valid/sample_2", "valid/sample_3"]
)
def test_virtual_valid(tmp_data_dir: Path, chalk: Chalk, test_file: str):
    files = os.listdir(DOCKERFILES / test_file)
    for file in files:
        shutil.copy(DOCKERFILES / test_file / file, tmp_data_dir)

    artifact_info = {tmp_data_dir: ArtifactInfo(type="docker", hash="")}
    _build_and_chalk_dockerfile(chalk, tmp_data_dir, True)
    validate_virtual_chalk(tmp_data_dir, artifact_map=artifact_info, virtual=True)


@pytest.mark.parametrize("test_file", ["invalid/sample_1", "invalid/sample_2"])
def test_virtual_invalid(tmp_data_dir: Path, chalk: Chalk, test_file: str):
    files = os.listdir(DOCKERFILES / test_file)
    for file in files:
        shutil.copy(DOCKERFILES / test_file / file, tmp_data_dir)

    artifact_info = {tmp_data_dir: ArtifactInfo(type="docker", hash="")}
    _build_and_chalk_dockerfile(chalk, tmp_data_dir, False)
    validate_virtual_chalk(tmp_data_dir, artifact_map=artifact_info, virtual=False)

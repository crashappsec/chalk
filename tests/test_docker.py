import json
import os
import shutil
import uuid
from contextlib import chdir
from pathlib import Path
from typing import List

import pytest

from .chalk.runner import Chalk
from .utils.docker import (
    docker_build,
    docker_image_cleanup,
    docker_inspect_image_hashes,
)
from .utils.log import get_logger

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
            assert (
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


def _validate_virtual_chalk(tmp_data_dir: Path):
    try:
        vjsonf = tmp_data_dir / "virtual-chalk.json"
        assert vjsonf.is_file(), "virtual-chalk.json not found"
        vjson = json.loads(vjsonf.read_bytes())
        assert "CHALK_ID" in vjson
        assert (
            vjson["MAGIC"] == "dadfedabbadabbed"
        ), "virtual chalk magic value incorrect"
    except json.JSONDecodeError as e:
        logger.error("unable to decode json", error=e)
        raise
    except AssertionError as e:
        logger.error("virtual-chalk validation failed", error=e)
        raise


def test_virtual_valid_sample_1(tmp_data_dir: Path, chalk: Chalk):
    files = os.listdir(DOCKERFILES / "valid" / "sample_1")
    for file in files:
        shutil.copy(DOCKERFILES / "valid" / "sample_1" / file, tmp_data_dir)

    _build_and_chalk_dockerfile(chalk, tmp_data_dir, True)
    _validate_virtual_chalk(tmp_data_dir)


def test_virtual_valid_sample_2(tmp_data_dir: Path, chalk: Chalk):
    files = os.listdir(DOCKERFILES / "valid" / "sample_2")
    for file in files:
        shutil.copy(DOCKERFILES / "valid" / "sample_2" / file, tmp_data_dir)

    _build_and_chalk_dockerfile(chalk, tmp_data_dir, True)
    _validate_virtual_chalk(tmp_data_dir)


def test_virtual_valid_sample_3(tmp_data_dir: Path, chalk: Chalk):
    files = os.listdir(DOCKERFILES / "valid" / "sample_3")
    for file in files:
        shutil.copy(DOCKERFILES / "valid" / "sample_3" / file, tmp_data_dir)

    _build_and_chalk_dockerfile(chalk, tmp_data_dir, True)
    _validate_virtual_chalk(tmp_data_dir)


def test_virtual_invalid_sample_1(tmp_data_dir: Path, chalk: Chalk):
    files = os.listdir(DOCKERFILES / "invalid" / "sample_1")
    for file in files:
        shutil.copy(DOCKERFILES / "invalid" / "sample_1" / file, tmp_data_dir)

    _build_and_chalk_dockerfile(chalk, tmp_data_dir, False)


def test_virtual_invalid_sample_2(tmp_data_dir: Path, chalk: Chalk):
    files = os.listdir(DOCKERFILES / "invalid" / "sample_2")
    for file in files:
        shutil.copy(DOCKERFILES / "invalid" / "sample_2" / file, tmp_data_dir)

    _build_and_chalk_dockerfile(chalk, tmp_data_dir, False)

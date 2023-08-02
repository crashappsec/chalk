import json
import os
import platform
import shutil
import subprocess
from pathlib import Path
from subprocess import CompletedProcess
from typing import Any, Dict, Optional
from unittest import mock

import pytest

from .chalk.runner import Chalk
from .utils.docker import (
    docker_build,
    docker_image_cleanup,
    docker_inspect_image_hashes,
)
from .utils.log import get_logger
from .utils.validate import (
    MAGIC,
    ArtifactInfo,
    validate_docker_chalk_report,
    validate_virtual_chalk,
)

logger = get_logger()

DOCKERFILES = Path(__file__).parent / "data" / "dockerfiles"
# pushing to a registry is orchestrated over the docker socket which means that the push comes from the host
# therefore this is sufficient for the docker push command
# FIXME: once we have buildx support we'll need to enable insecure registry https://docs.docker.com/registry/insecure/
REGISTRY = "localhost:5044"


def _build_and_chalk_dockerfile(
    chalk: Chalk, test_file: str, tmp_data_dir: Path, valid: bool, virtual: bool
) -> Optional[CompletedProcess]:
    try:
        files = os.listdir(DOCKERFILES / test_file)
        for file in files:
            shutil.copy(DOCKERFILES / test_file / file, tmp_data_dir)

        tag = test_file
        docker_build_params = ["-t", tag, "."]

        docker_run = docker_build(
            dir=tmp_data_dir, params=docker_build_params, expected_success=valid
        )
        chalk_params = [
            "--debug",
            "--log-level=none",
        ]
        if virtual:
            chalk_params += [
                "--virtual",
            ]

        chalk_params += [
            "docker",
            "build",
        ]
        chalk_run = chalk.run(
            params=chalk_params + docker_build_params,
            expected_success=valid,
        )

        if valid:
            assert chalk_run and (
                docker_run.returncode == chalk_run.returncode
            ), "docker build and chalk docker build results should be the same"
        else:
            assert chalk_run is None, "chalk run should be unsuccessful on invalid test"
        return chalk_run
    except Exception as e:
        logger.error("docker build / chalk build failed unexpectedly", error=e)
        raise


def _get_chalk_report_from_docker_output(proc: CompletedProcess) -> Dict[str, Any]:
    # # FIXME: hacky json read of report that has to stop before we reach logs
    json_string = ""
    in_json = False
    for line in proc.stdout.decode().splitlines():
        if line == ("["):
            in_json = True
        if in_json:
            json_string = json_string + line
        if line == ("]"):
            break
    chalk_reports = json.loads(json_string)
    assert len(chalk_reports) == 1
    chalk_report = chalk_reports[0]
    return chalk_report


@mock.patch.dict(os.environ, {"SINK_TEST_OUTPUT_FILE": "/tmp/sink_file.json"})
@pytest.mark.parametrize("test_file", ["valid/sample_1", "valid/sample_2"])
def test_virtual_valid(tmp_data_dir: Path, chalk: Chalk, test_file: str):
    try:
        artifact_info = {str(tmp_data_dir): ArtifactInfo(type="Docker Image", hash="")}
        insert_output = _build_and_chalk_dockerfile(
            chalk, test_file, tmp_data_dir, valid=True, virtual=True
        )
        assert insert_output is not None
        assert insert_output.returncode == 0, "chalking dockerfile failed"

        chalk_report = _get_chalk_report_from_docker_output(insert_output)

        validate_docker_chalk_report(
            chalk_report=chalk_report, artifact_map=artifact_info, virtual=True
        )

        validate_virtual_chalk(tmp_data_dir, artifact_map=artifact_info, virtual=True)

        # chalk extraction is not checked as extract will only say
        # No chalk marks extracted
    finally:
        images = docker_inspect_image_hashes(tag=test_file)
        docker_image_cleanup(images=images)


@pytest.mark.parametrize("test_file", ["invalid/sample_1", "invalid/sample_2"])
def test_virtual_invalid(tmp_data_dir: Path, chalk: Chalk, test_file: str):
    _build_and_chalk_dockerfile(
        chalk, test_file, tmp_data_dir, valid=False, virtual=True
    )
    # invalid dockerfile should not create any chalk output
    assert not (
        tmp_data_dir / "virtual-chalk.json"
    ).is_file(), "virtual-chalk.json should not have been created!"


@pytest.mark.parametrize("test_file", ["valid/sample_1", "valid/sample_2"])
def test_nonvirtual_valid(tmp_data_dir: Path, chalk: Chalk, test_file: str):
    try:
        artifact_info = {str(tmp_data_dir): ArtifactInfo(type="Docker Image", hash="")}
        insert_output = _build_and_chalk_dockerfile(
            chalk, test_file, tmp_data_dir, valid=True, virtual=False
        )
        assert insert_output is not None
        chalk_report = _get_chalk_report_from_docker_output(insert_output)

        validate_docker_chalk_report(
            chalk_report=chalk_report, artifact_map=artifact_info, virtual=False
        )
        # docker tags should be set to tag above
        assert chalk_report["_CHALKS"][0]["DOCKER_TAGS"] == [test_file]
        # current hash is the image hash
        assert "_CURRENT_HASH" in chalk_report["_CHALKS"][0]
        image_hash = chalk_report["_CHALKS"][0]["_CURRENT_HASH"]

        container_proc = subprocess.run(
            args=[
                "docker",
                "run",
                "--name",
                "test_container",
                "--entrypoint",
                "cat",
                image_hash,
                "chalk.json",
            ],
            check=True,
            capture_output=True,
        )

        container_chalk = container_proc.stdout.decode()
        chalk_json = json.loads(container_chalk)
        assert "CHALK_ID" in chalk_json
        assert chalk_json["MAGIC"] == MAGIC, "chalk magic value incorrect"
    except subprocess.CalledProcessError as e:
        logger.info(e.stderr)
    finally:
        images = docker_inspect_image_hashes(tag=test_file)
        docker_image_cleanup(images)
        try:
            subprocess.run(args=["docker", "rm", "-f", "test_container"])
        except Exception as e:
            logger.warning("Could not remove test_container %s", e)


@pytest.mark.parametrize("test_file", ["invalid/sample_1", "invalid/sample_2"])
def test_nonvirtual_invalid(tmp_data_dir: Path, chalk: Chalk, test_file: str):
    _build_and_chalk_dockerfile(
        chalk, test_file, tmp_data_dir, valid=False, virtual=False
    )
    # invalid dockerfile should not create any chalk output
    assert not (
        tmp_data_dir / "virtual-chalk.json"
    ).is_file(), "virtual-chalk.json should not have been created!"


@pytest.mark.parametrize(
    "test_file",
    [
        "valid/sample_1",
    ],
)
@pytest.mark.skipif(
    platform.system() == "Darwin",
    reason="Skipping local docker push on mac due to issues https://github.com/docker/for-mac/issues/6704",
)
def test_build_and_push(tmp_data_dir: Path, chalk: Chalk, test_file: str):
    try:
        files = os.listdir(DOCKERFILES / test_file)
        for file in files:
            shutil.copy(DOCKERFILES / test_file / file, tmp_data_dir)

        tag = f"{REGISTRY}/{test_file}:latest"

        # build docker wrapped
        chalk_docker_build_proc = chalk.run(
            params=[
                "--log-level=none",
                "docker",
                "build",
                "-t",
                tag,
                ".",
            ],
        )
        assert chalk_docker_build_proc is not None
        assert chalk_docker_build_proc.returncode == 0, "chalk docker build failed"
        # grab current_hash for comparison later
        chalk_docker_build_report = _get_chalk_report_from_docker_output(
            chalk_docker_build_proc
        )
        current_hash_build = chalk_docker_build_report["_CHALKS"][0]["_CURRENT_HASH"]

        # push docker wrapped
        chalk_docker_push_proc = chalk.run(
            params=[
                "--log-level=none",
                "docker",
                "push",
                tag,
            ],
        )
        assert chalk_docker_push_proc is not None
        assert chalk_docker_push_proc.returncode == 0, "chalk docker push failed"
        chalk_docker_push_report = _get_chalk_report_from_docker_output(
            chalk_docker_push_proc
        )
        current_hash_push = chalk_docker_push_report["_CHALKS"][0]["_CURRENT_HASH"]
        repo_digest_push = chalk_docker_push_report["_CHALKS"][0]["_REPO_DIGESTS"][0]

        assert current_hash_build == current_hash_push

        # docker pull and check hash
        docker_pull_proc = chalk.run(params=["docker", "pull", tag])
        assert docker_pull_proc is not None
        assert docker_pull_proc.returncode == 0
        found = False
        for line in docker_pull_proc.stdout.decode().splitlines():
            if "Digest" in line:
                found = True
                assert repo_digest_push in line
        assert found
    finally:
        images = docker_inspect_image_hashes(tag=tag)
        docker_image_cleanup(images)

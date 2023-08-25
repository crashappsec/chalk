import json
import platform
import shutil
import subprocess
import time
from pathlib import Path
from subprocess import CompletedProcess
from typing import Any, Dict, Optional
from unittest import mock

import os
import pytest

from .chalk.runner import Chalk
from .utils.chalk_report import get_chalk_report_from_output
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
CONFIGFILES = Path(__file__).parent / "data" / "configs"
# pushing to a registry is orchestrated over the docker socket which means that the push comes from the host
# therefore this is sufficient for the docker push command
# FIXME: once we have buildx support we'll need to enable insecure registry https://docs.docker.com/registry/insecure/
REGISTRY = "localhost:5044"

TEST_LABEL = "CRASH_OVERRIDE_TEST_LABEL"


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
            # chalk run should not return empty process
            # if it was a valid dockerfile
            assert chalk_run is not None, "chalk process should not be empty"
            assert (
                docker_run.returncode == 0
            ), "docker build should have succeeded on valid dockerfile"
            assert (
                chalk_run.returncode == 0
            ), "chalk docker build should have succeeded on valid dockerfile"
        else:
            assert (
                docker_run.returncode == 1
            ), "docker build should not have succeeded on invalid dockerfile"
            assert (
                chalk_run.returncode == 1
            ), "chalk docker build should not have succeeded on invalid dockerfile"
        return chalk_run
    except Exception as e:
        logger.error("docker build / chalk build failed unexpectedly", error=e)
        raise


@mock.patch.dict(os.environ, {"SINK_TEST_OUTPUT_FILE": "/tmp/sink_file.json"})
@pytest.mark.parametrize(
    "test_file",
    [
        "valid/sample_1",
        "valid/sample_2",
    ],
)
def test_virtual_valid(tmp_data_dir: Path, chalk: Chalk, test_file: str):
    try:
        insert_output = _build_and_chalk_dockerfile(
            chalk, test_file, tmp_data_dir, valid=True, virtual=True
        )
        assert insert_output is not None
        assert insert_output.returncode == 0, "chalking dockerfile failed"

        chalk_report = get_chalk_report_from_output(insert_output)

        _chalk = chalk_report["_CHALKS"][0]
        # current hash is the image hash
        assert "_CURRENT_HASH" in _chalk
        image_hash = _chalk["_CURRENT_HASH"]

        # artifact is the docker image
        artifact_info = ArtifactInfo(type="Docker Image", hash=image_hash)
        # keys to check
        artifact_info.chalk_info = {
            "_CURRENT_HASH": image_hash,
            "_IMAGE_ID": image_hash,
            "_REPO_TAGS": [test_file + ":latest"],
            "DOCKERFILE_PATH": str(tmp_data_dir / "Dockerfile"),
            # docker tags should be set to tag above
            "DOCKER_TAGS": [test_file],
        }
        artifact_info.host_info = {}
        validate_docker_chalk_report(
            chalk_report=chalk_report, artifact=artifact_info, virtual=True
        )

        metadata_hash = _chalk["METADATA_HASH"]
        metadata_id = _chalk["METADATA_ID"]

        vchalk = validate_virtual_chalk(
            tmp_data_dir, artifact_map={artifact_info}, virtual=True
        )
        assert "CHALK_ID" in vchalk
        assert vchalk["MAGIC"] == MAGIC, "chalk magic value incorrect"
        assert vchalk["METADATA_HASH"] == metadata_hash
        assert vchalk["METADATA_ID"] == metadata_id

        container_proc = subprocess.run(
            args=[
                "docker",
                "run",
                "--rm",
                "--name",
                "test_container",
                "--entrypoint",
                "cat",
                image_hash,
                "chalk.json",
            ],
            # check=True,
            capture_output=True,
        )

        # expecting error since chalk.json doesn't exist
        chalk_err = container_proc.stderr.decode()
        assert "No such file or directory" in chalk_err
    except subprocess.CalledProcessError as e:
        logger.info(e.stderr)
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
        insert_output = _build_and_chalk_dockerfile(
            chalk, test_file, tmp_data_dir, valid=True, virtual=False
        )
        assert insert_output is not None
        assert insert_output.returncode == 0, "chalking dockerfile failed"

        chalk_report = get_chalk_report_from_output(insert_output)

        _chalk = chalk_report["_CHALKS"][0]
        # current hash is the image hash
        assert "_CURRENT_HASH" in _chalk
        image_hash = _chalk["_CURRENT_HASH"]

        # artifact is the docker image
        artifact_info = ArtifactInfo(type="Docker Image", hash=image_hash)
        # keys to check
        artifact_info.chalk_info = {
            "_CURRENT_HASH": image_hash,
            "_IMAGE_ID": image_hash,
            "_REPO_TAGS": [test_file + ":latest"],
            "DOCKERFILE_PATH": str(tmp_data_dir / "Dockerfile"),
            # docker tags should be set to tag above
            "DOCKER_TAGS": [test_file],
        }
        artifact_info.host_info = {}
        validate_docker_chalk_report(
            chalk_report=chalk_report, artifact=artifact_info, virtual=False
        )

        metadata_hash = _chalk["METADATA_HASH"]
        metadata_id = _chalk["METADATA_ID"]

        container_proc = subprocess.run(
            args=[
                "docker",
                "run",
                "--rm",
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
        assert chalk_json["METADATA_HASH"] == metadata_hash
        assert chalk_json["METADATA_ID"] == metadata_id
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


# exec heartbeat from inside docker
@pytest.mark.slow()
def test_docker_heartbeat(tmp_data_dir: Path, chalk_copy: Chalk):
    test_image = "test_image"
    test_container = "test_container"
    try:
        files = os.listdir(DOCKERFILES / "valid" / "sleep")
        for file in files:
            shutil.copy(DOCKERFILES / "valid" / "sleep" / file, tmp_data_dir)

        load_output = chalk_copy.load(str(CONFIGFILES / "docker_heartbeat.conf"), False)
        assert load_output.returncode == 0

        # build dockerfile with chalk docker entrypoint wrapping
        chalk_build = subprocess.run(
            args=[
                chalk_copy.binary,
                "docker",
                "build",
                "--platform=linux/amd64",
                "-t",
                test_image,
                # TODO switch to . context
                # If docker build context has "chalk", it is not copied
                # to the image and therefore the container will fail to run.
                # For now using /tmp as context and explicitly building
                # Dockerfile via -f
                "-f",
                tmp_data_dir / "Dockerfile",
                "/tmp",
            ],
            capture_output=True,
        )
        assert chalk_build.returncode == 0

        with open(tmp_data_dir / "log.tmp", "w") as file:
            # run with docker and we should get output
            subprocess.Popen(
                args=[
                    "docker",
                    "run",
                    "--name",
                    test_container,
                    "-t",
                    test_image,
                ],
                stdin=None,
                stdout=file,
                stderr=file,
                close_fds=True,
            )
        time.sleep(10)

        with open(tmp_data_dir / "log.tmp") as file:
            _stdout = file.read()
            # FIXME: stdoutput is multiple jsons split over multiple lines, figure out how to parse that into a list of json objects
            # validate exec
            assert '"_OPERATION": "exec"' in _stdout
            # at least two heartbeats in output
            assert _stdout.count('"_OPERATION": "heartbeat"') > 2

    except Exception:
        raise
    finally:
        docker_image_cleanup([test_image])
        try:
            subprocess.run(args=["docker", "rm", "-f", test_container])
        except Exception as e:
            logger.warning("Could not remove test_container %s", e)


def test_docker_labels(tmp_data_dir: Path, chalk: Chalk):
    files = os.listdir(DOCKERFILES / "valid" / "sample_1")
    for file in files:
        shutil.copy(DOCKERFILES / "valid" / "sample_1" / file, tmp_data_dir)

    container_name = "test_container"
    try:
        # build container with env vars
        chalk_run = chalk.run(
            params=[
                f"--config-file={CONFIGFILES / 'docker_heartbeat.conf'}",
                "--log-level=none",
                "docker",
                "build",
                "-t",
                container_name,
                ".",
            ],
        )
        assert chalk_run.returncode == 0

        _docker_inspect_proc = subprocess.run(
            ["docker", "inspect", container_name],
            capture_output=True,
        )
        assert _docker_inspect_proc.returncode == 0
        # expecting json array with 1 element
        _docker_inspect_info = _docker_inspect_proc.stdout.decode()
        docker_inspect = json.loads(_docker_inspect_info)

        assert len(docker_inspect) == 1
        docker_configs = docker_inspect[0]["Config"]
        assert "Labels" in docker_configs
        labels = docker_configs["Labels"]
        label_found = False
        for label in labels:
            if labels[label] == TEST_LABEL:
                label_found = True
                break
        assert label_found
    except Exception:
        raise
    finally:
        docker_image_cleanup([container_name])


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

        tag_base = f"{REGISTRY}/{test_file}"
        tag = f"{tag_base}:latest"

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
        chalk_docker_build_report = get_chalk_report_from_output(
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
        chalk_docker_push_report = get_chalk_report_from_output(chalk_docker_push_proc)
        current_hash_push = chalk_docker_push_report["_CHALKS"][0]["_CURRENT_HASH"]
        repo_digest_push = chalk_docker_push_report["_CHALKS"][0]["_REPO_DIGESTS"][
            tag_base
        ]

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


# extract on image id, and image name, running container id + container name, exited container id + container name
def test_extract(tmp_data_dir: Path, chalk: Chalk):
    try:
        dockerfile = "valid/sample_1"
        files = os.listdir(DOCKERFILES / dockerfile)
        for file in files:
            shutil.copy(DOCKERFILES / dockerfile / file, tmp_data_dir)

        # build test image
        image_name = "test_image"
        chalk_params = ["--log-level=none", "docker", "build", "-t", image_name, "."]
        chalk_run = chalk.run(
            params=chalk_params,
            expected_success=True,
        )

        chalk_report = get_chalk_report_from_output(chalk_run)
        assert "_CURRENT_HASH" in chalk_report["_CHALKS"][0]
        image_id = chalk_report["_CHALKS"][0]["_CURRENT_HASH"]

        # artifact info should be consistent
        artifact = ArtifactInfo(type="Docker Image", hash=image_id)
        artifact.host_info = {
            "_OPERATION": "extract",
            "_OP_EXE_NAME": "chalk",
            "_OP_UNMARKED_COUNT": 0,
            "_OP_CHALK_COUNT": 1,
        }
        artifact.chalk_info = {
            "_OP_ARTIFACT_TYPE": "Docker Image",
            "_IMAGE_ID": image_id,
            "_CURRENT_HASH": image_id,
            "_REPO_TAGS": [image_name + ":latest"],
        }

        # extract chalk from image id and image name
        _extract_image_name = chalk.extract(image_name)[0]

        validate_docker_chalk_report(
            chalk_report=_extract_image_name,
            artifact=artifact,
            virtual=False,
            chalk_action="extract",
        )

        _extract_image_id = chalk.extract(image_id[:12])[0]
        validate_docker_chalk_report(
            chalk_report=_extract_image_id,
            artifact=artifact,
            virtual=False,
            chalk_action="extract",
        )

        # run container and keep alive via shell
        container_name = "test_container"
        subprocess.Popen(
            args=[
                "docker",
                "run",
                "--name",
                container_name,
                "-t",
                "--entrypoint",
                "sh",
                image_id,
            ],
            shell=False,
            stdin=None,
            stdout=None,
            stderr=None,
            close_fds=True,
        )

        # let container start
        time.sleep(2)
        # get running container id
        _proc = subprocess.run(
            args=["docker", "ps", "-qf", f"name={container_name}", "--no-trunc"],
            capture_output=True,
        )
        container_id = _proc.stdout.decode().strip()
        assert container_id != ""

        # new artifact for running container
        artifact_container = ArtifactInfo(type="Docker Container", hash=image_id)
        artifact_container.host_info = {
            "_OPERATION": "extract",
            "_OP_EXE_NAME": "chalk",
            "_OP_UNMARKED_COUNT": 0,
            "_OP_CHALK_COUNT": 1,
        }
        artifact_container.chalk_info = {
            "_OP_ARTIFACT_TYPE": "Docker Container",
            "_IMAGE_ID": image_id,
            "_CURRENT_HASH": image_id,
            "_INSTANCE_CONTAINER_ID": container_id,
            "_INSTANCE_NAME": container_name,
            "_INSTANCE_STATUS": "running",
        }

        # extract on container name and validate
        _extract_container_name_running = chalk.extract(container_name)[0]
        validate_docker_chalk_report(
            chalk_report=_extract_container_name_running,
            artifact=artifact_container,
            virtual=False,
            chalk_action="extract",
        )

        # extract on container id and validate
        _extract_container_id_running = chalk.extract(container_id)[0]
        validate_docker_chalk_report(
            chalk_report=_extract_container_id_running,
            artifact=artifact_container,
            virtual=False,
            chalk_action="extract",
        )

        # shut down container
        _proc = subprocess.run(
            args=["docker", "stop", container_name], capture_output=True
        )
        assert container_name in _proc.stdout.decode(), "container not stopped properly"

        # update artifact info
        artifact_container.chalk_info["_INSTANCE_STATUS"] = "exited"

        # extract on container name and container id now that container is stopped
        _extract_container_name_dead = chalk.extract(container_name)[0]
        validate_docker_chalk_report(
            chalk_report=_extract_container_name_dead,
            artifact=artifact_container,
            virtual=False,
            chalk_action="extract",
        )

        _extract_container_id_dead = chalk.extract(container_id)[0]
        validate_docker_chalk_report(
            chalk_report=_extract_container_id_dead,
            artifact=artifact_container,
            virtual=False,
            chalk_action="extract",
        )
    except Exception as e:
        logger.error(e)
        raise
    finally:
        images = docker_inspect_image_hashes(tag="test_image")
        docker_image_cleanup(images)
        try:
            subprocess.run(args=["docker", "rm", "-f", "test_container"])
        except Exception as e:
            logger.warning("Could not remove test_container %s", e)

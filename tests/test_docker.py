import platform
import shutil
import time
from contextlib import ExitStack
from pathlib import Path
from unittest import mock

import os
import pytest

from .chalk.runner import Chalk
from .chalk.validate import (
    MAGIC,
    ArtifactInfo,
    validate_docker_chalk_report,
    validate_virtual_chalk,
)
from .conf import CONFIGS, DOCKERFILES, REGISTRY
from .utils.docker import Docker
from .utils.log import get_logger


logger = get_logger()

TEST_LABEL = "CRASH_OVERRIDE_TEST_LABEL"


@pytest.fixture(scope="session", autouse=True)
def do_docker_cleanup():
    # record all tags/containers being created during tests
    # and automatically delete them at the end of the test suite
    tags: set[str] = set()
    containers: set[str] = set()

    _docker_build = Chalk.docker_build
    _run_container = Docker.run

    def docker_build(self, *args, **kwargs):
        tags.add(kwargs["tag"])
        return _docker_build(self, *args, **kwargs)

    def run_container(*args, **kwargs):
        container_id, result = _run_container(*args, **kwargs)
        containers.add(container_id)
        return container_id, result

    with ExitStack() as stack:
        stack.enter_context(mock.patch.object(Chalk, "docker_build", docker_build))
        stack.enter_context(mock.patch.object(Docker, "run", run_container))
        try:
            yield
        finally:
            if containers:
                Docker.remove_containers(list(containers))
            if tags:
                Docker.remove_images(list(tags))


@mock.patch.dict(os.environ, {"SINK_TEST_OUTPUT_FILE": "/tmp/sink_file.json"})
@pytest.mark.parametrize(
    "test_file",
    [
        "valid/sample_1",
        "valid/sample_2",
    ],
)
def test_virtual_valid(
    tmp_data_dir: Path, chalk: Chalk, test_file: str, random_hex: str
):
    # TODO virtual chalk only works in /tmp
    shutil.copytree(DOCKERFILES / test_file, tmp_data_dir, dirs_exist_ok=True)

    tag = f"{test_file}_{random_hex}"
    build = chalk.docker_build(
        dockerfile=tmp_data_dir / "Dockerfile",
        tag=tag,
        virtual=True,
        cwd=tmp_data_dir,
    )
    image_hash = build.mark["_CURRENT_HASH"]

    # artifact is the docker image
    # keys to check
    artifact_info = ArtifactInfo(
        type="Docker Image",
        hash=image_hash,
        chalk_info={
            "_CURRENT_HASH": image_hash,
            "_IMAGE_ID": image_hash,
            "_REPO_TAGS": [tag + ":latest"],
            "DOCKERFILE_PATH": str(tmp_data_dir / "Dockerfile"),
            # docker tags should be set to tag above
            "DOCKER_TAGS": [tag],
        },
    )
    validate_docker_chalk_report(
        chalk_report=build.report, artifact=artifact_info, virtual=True
    )

    metadata_hash = build.mark["METADATA_HASH"]
    metadata_id = build.mark["METADATA_ID"]

    vchalk = validate_virtual_chalk(
        tmp_data_dir, artifact_map={image_hash: artifact_info}, virtual=True
    )
    assert "CHALK_ID" in vchalk
    assert vchalk["MAGIC"] == MAGIC
    assert vchalk["METADATA_HASH"] == metadata_hash
    assert vchalk["METADATA_ID"] == metadata_id

    _, result = Docker.run(
        image=image_hash,
        entrypoint="cat",
        params=["chalk.json"],
        expected_success=False,
    )
    # expecting error since chalk.json doesn't exist
    assert "No such file or directory" in result.text


@pytest.mark.parametrize("test_file", ["invalid/sample_1", "invalid/sample_2"])
def test_virtual_invalid(
    tmp_data_dir: Path, chalk: Chalk, test_file: str, random_hex: str
):
    # TODO virtual chalk only works in /tmp
    shutil.copytree(DOCKERFILES / test_file, tmp_data_dir, dirs_exist_ok=True)

    tag = f"{test_file}_{random_hex}"
    chalk.docker_build(
        dockerfile=tmp_data_dir / "Dockerfile",
        tag=tag,
        virtual=True,
        cwd=tmp_data_dir,
        expected_success=False,
    )

    # invalid dockerfile should not create any chalk output
    assert not (
        tmp_data_dir / "virtual-chalk.json"
    ).is_file(), "virtual-chalk.json should not have been created!"


@pytest.mark.parametrize("test_file", ["valid/sample_1", "valid/sample_2"])
def test_nonvirtual_valid(chalk: Chalk, test_file: str, random_hex: str):
    tag = f"{test_file}_{random_hex}"
    build = chalk.docker_build(
        dockerfile=DOCKERFILES / test_file / "Dockerfile",
        tag=tag,
    )
    image_hash = build.mark["_CURRENT_HASH"]

    # artifact is the docker image
    artifact_info = ArtifactInfo(
        type="Docker Image",
        hash=image_hash,
        # keys to check
        chalk_info={
            "_CURRENT_HASH": image_hash,
            "_IMAGE_ID": image_hash,
            "_REPO_TAGS": [tag + ":latest"],
            "DOCKERFILE_PATH": str(DOCKERFILES / test_file / "Dockerfile"),
            # docker tags should be set to tag above
            "DOCKER_TAGS": [tag],
        },
    )
    validate_docker_chalk_report(
        chalk_report=build.report, artifact=artifact_info, virtual=False
    )

    metadata_hash = build.mark["METADATA_HASH"]
    metadata_id = build.mark["METADATA_ID"]

    _, result = Docker.run(
        image=image_hash,
        entrypoint="cat",
        params=["chalk.json"],
    )
    chalk_json = result.json()

    assert "CHALK_ID" in chalk_json
    assert chalk_json["MAGIC"] == MAGIC, "chalk magic value incorrect"
    assert chalk_json["METADATA_HASH"] == metadata_hash
    assert chalk_json["METADATA_ID"] == metadata_id


@pytest.mark.parametrize("test_file", ["invalid/sample_1", "invalid/sample_2"])
def test_nonvirtual_invalid(chalk: Chalk, test_file: str, random_hex: str):
    tag = f"{test_file}_{random_hex}"
    chalk.docker_build(
        dockerfile=DOCKERFILES / test_file / "Dockerfile",
        tag=tag,
        expected_success=False,
    )


# exec heartbeat from inside docker
@pytest.mark.slow()
def test_docker_heartbeat(chalk_copy: Chalk, random_hex: str):
    tag = f"test_image_{random_hex}"
    chalk_copy.load(CONFIGS / "docker_heartbeat.conf", False)

    # build dockerfile with chalk docker entrypoint wrapping
    chalk_copy.docker_build(
        DOCKERFILES / "valid" / "sleep" / "Dockerfile",
        tag=tag,
        # TODO remove
        # If docker build context has "chalk", it is not copied
        # to the image and therefore the container will fail to run.
        # For now using /tmp as context and explicitly building
        context=Path("/tmp"),
    )

    _, result = Docker.run(
        image=tag,
        check=False,
    )

    # FIXME: stdoutput is multiple jsons split over multiple lines,
    # figure out how to parse that into a list of json objects
    # validate exec
    assert '"_OPERATION": "exec"' in result.text
    # at least two heartbeats in output
    assert result.text.count('"_OPERATION": "heartbeat"') > 2


def test_docker_labels(chalk: Chalk, random_hex: str):
    tag = f"test_image_{random_hex}"

    # build container with env vars
    chalk.docker_build(
        dockerfile=DOCKERFILES / "valid" / "sample_1" / "Dockerfile",
        tag=tag,
        params=[
            f"--config-file={CONFIGS / 'docker_heartbeat.conf'}",
        ],
    )

    inspected = Docker.inspect(tag)
    assert len(inspected) == 1

    docker_configs = inspected[0]["Config"]
    assert "Labels" in docker_configs
    labels = docker_configs["Labels"]
    assert TEST_LABEL in labels.values()


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
def test_build_and_push(chalk: Chalk, test_file: str):
    tag_base = f"{REGISTRY}/{test_file}"
    tag = f"{tag_base}:latest"

    build = chalk.docker_build(
        DOCKERFILES / test_file / "Dockerfile",
        tag=tag,
    )
    # grab current_hash for comparison later
    current_hash_build = build.mark["_CURRENT_HASH"]

    # push docker wrapped
    push = chalk.docker_push(tag)
    current_hash_push = push.mark["_CURRENT_HASH"]
    repo_digest_push = push.mark["_REPO_DIGESTS"][tag_base]

    assert current_hash_build == current_hash_push

    pull = chalk.docker_pull(tag)
    assert pull.find("Digest:") == f"sha256:{repo_digest_push}"


# extract on image id, and image name, running container id + container name, exited container id + container name
def test_extract(tmp_data_dir: Path, chalk: Chalk, random_hex: str):
    tag = f"test_image_{random_hex}"
    container_name = f"test_container_{random_hex}"

    # build test image
    build = chalk.docker_build(
        DOCKERFILES / "valid" / "sample_1" / "Dockerfile",
        tag=tag,
    )
    image_id = build.mark["_CURRENT_HASH"]

    # artifact info should be consistent
    image_artifact = ArtifactInfo(
        type="Docker Image",
        hash=image_id,
        host_info={
            "_OPERATION": "extract",
            "_OP_EXE_NAME": "chalk",
            "_OP_UNMARKED_COUNT": 0,
            "_OP_CHALK_COUNT": 1,
        },
        chalk_info={
            "_OP_ARTIFACT_TYPE": "Docker Image",
            "_IMAGE_ID": image_id,
            "_CURRENT_HASH": image_id,
            "_REPO_TAGS": [tag + ":latest"],
        },
    )

    # extract chalk from image id and image name
    extract_by_name = chalk.extract(tag)
    validate_docker_chalk_report(
        chalk_report=extract_by_name.report,
        artifact=image_artifact,
        virtual=False,
        chalk_action="extract",
    )

    extract_by_id = chalk.extract(image_id[:12])
    validate_docker_chalk_report(
        chalk_report=extract_by_id.report,
        artifact=image_artifact,
        virtual=False,
        chalk_action="extract",
    )

    # run container and keep alive via tail
    container_id, _ = Docker.run(
        image_id,
        name=container_name,
        entrypoint="tail",
        params=["-f", "/dev/null"],
        attach=False,
    )

    # let container start
    time.sleep(2)

    # new artifact for running container
    artifact_container = ArtifactInfo(
        type="Docker Container",
        hash=image_id,
        host_info={
            "_OPERATION": "extract",
            "_OP_EXE_NAME": "chalk",
            "_OP_UNMARKED_COUNT": 0,
            "_OP_CHALK_COUNT": 1,
        },
        chalk_info={
            "_OP_ARTIFACT_TYPE": "Docker Container",
            "_IMAGE_ID": image_id,
            "_CURRENT_HASH": image_id,
            "_INSTANCE_CONTAINER_ID": container_id,
            "_INSTANCE_NAME": container_name,
            "_INSTANCE_STATUS": "running",
        },
    )

    # extract on container name and validate
    extract_container_name = chalk.extract(container_name)
    validate_docker_chalk_report(
        chalk_report=extract_container_name.report,
        artifact=artifact_container,
        virtual=False,
        chalk_action="extract",
    )

    # extract on container id and validate
    extract_container_id = chalk.extract(container_id)
    validate_docker_chalk_report(
        chalk_report=extract_container_id.report,
        artifact=artifact_container,
        virtual=False,
        chalk_action="extract",
    )

    # shut down container
    Docker.stop_containers([container_name])

    # update artifact info
    artifact_container.chalk_info["_INSTANCE_STATUS"] = "exited"

    # extract on container name and container id now that container is stopped
    extract_container_name_stopped = chalk.extract(container_name)
    validate_docker_chalk_report(
        chalk_report=extract_container_name_stopped.report,
        artifact=artifact_container,
        virtual=False,
        chalk_action="extract",
    )

    extract_container_id_stopped = chalk.extract(container_id)
    validate_docker_chalk_report(
        chalk_report=extract_container_id_stopped.report,
        artifact=artifact_container,
        virtual=False,
        chalk_action="extract",
    )

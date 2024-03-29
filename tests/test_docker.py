# Copyright (c) 2023-2024, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import itertools
import platform
import shutil
import time
from contextlib import ExitStack
from pathlib import Path
from typing import Iterator, Optional
from unittest import mock

import os
import pytest

from .chalk.runner import Chalk, ChalkProgram
from .chalk.validate import (
    MAGIC,
    ArtifactInfo,
    validate_docker_chalk_report,
    validate_virtual_chalk,
)
from .conf import (
    CONFIGS,
    DOCKERFILES,
    DOCKER_SSH_REPO,
    DOCKER_TOKEN_REPO,
    MARKS,
    REGISTRY,
)
from .utils.docker import Docker
from .utils.log import get_logger
from .utils.os import run


logger = get_logger()

TEST_LABEL = "CRASH_OVERRIDE_TEST_LABEL"


@pytest.fixture(scope="session", autouse=True)
def do_docker_cleanup() -> Iterator[None]:
    # record all tags/containers being created during tests
    # and automatically delete them at the end of the test suite
    images: set[str] = set()
    containers: set[str] = set()

    _docker_build = Chalk.docker_build
    _run_container = Docker.run

    def docker_build(self, *args, **kwargs):
        image_hash, result = _docker_build(self, *args, **kwargs)
        images.add(image_hash)
        return image_hash, result

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
            if images:
                Docker.remove_images(list(images))


def test_no_docker(chalk: Chalk):
    _, build = chalk.docker_build(
        context=DOCKERFILES / "valid" / "sample_1",
        env={"PATH": ""},
        expected_success=False,
        # dont run sanity docker subcommand
        run_docker=False,
    )
    assert build.exit_code > 0


@pytest.mark.parametrize("buildkit", [True, False])
@pytest.mark.parametrize(
    "cwd, dockerfile, tag",
    [
        # PWD=foo && docker build .
        (DOCKERFILES / "valid" / "sample_1", None, False),
        # PWD=foo && docker build -t test .
        (DOCKERFILES / "valid" / "sample_1", None, True),
        # PWD=foo && docker build .
        (DOCKERFILES / "valid" / "sample_3", None, False),
        # PWD=foo && docker build -t test .
        (DOCKERFILES / "valid" / "sample_3", None, True),
        # docker build -f foo/Dockerfile foo
        (None, DOCKERFILES / "valid" / "sample_1" / "Dockerfile", False),
        # docker build -f foo/Dockerfile -t test foo
        (None, DOCKERFILES / "valid" / "sample_1" / "Dockerfile", True),
    ],
)
def test_build(
    chalk: Chalk,
    dockerfile: Optional[Path],
    cwd: Optional[Path],
    tag: Optional[bool],
    buildkit: bool,
    random_hex: str,
):
    """
    Test various variants of docker build command
    """
    image_id, _ = chalk.docker_build(
        dockerfile=dockerfile,
        cwd=cwd,
        tag=random_hex if tag else None,
        buildkit=buildkit,
        config=CONFIGS / "docker_wrap.c4m",
    )
    assert image_id


def test_docker_context(chalk: Chalk, tmp_data_dir: Path):
    """
    Test docker can build when a context is "docker"
    """
    shutil.copy(chalk.binary, tmp_data_dir / "docker")
    cwd = tmp_data_dir / "cwd"
    context = cwd / "docker"
    context.mkdir(parents=True)
    path = os.environ["PATH"]

    _, build = Docker.build(
        cwd=cwd,
        dockerfile=DOCKERFILES / "valid" / "sample_2" / "Dockerfile",
        context="docker",
        env={"PATH": f"{tmp_data_dir}:{path}"},
    )
    assert ChalkProgram.from_program(build)


@pytest.mark.parametrize("dockerfile", [DOCKERFILES / "valid" / "sample_1"])
def test_multiple_tags(
    chalk: Chalk,
    dockerfile: Path,
    random_hex: str,
):
    tags = [
        f"{REGISTRY}/{random_hex}-1",
        f"{REGISTRY}/{random_hex}-2",
    ]
    image_id, build = chalk.docker_build(
        dockerfile=dockerfile / "Dockerfile",
        tags=tags,
        config=CONFIGS / "docker_wrap.c4m",
        push=True,
        # docker sanity check will push to registry
        # whereas we want to ensure chalk does the pushing
        run_docker=False,
    )
    assert image_id
    assert len(build.mark["_REPO_TAGS"]) == 2

    # ensure all tags are pushed
    for tag in tags:
        assert Docker.pull(tag)


@pytest.mark.parametrize("buildkit", [True, False])
@pytest.mark.parametrize(
    "base, test",
    [
        (
            DOCKERFILES / "valid" / "split_dockerfiles" / "base.Dockerfile",
            DOCKERFILES / "valid" / "split_dockerfiles" / "test.Dockerfile",
        ),
    ],
)
def test_composite_build(
    chalk: Chalk,
    base: Path,
    test: Path,
    buildkit: bool,
    random_hex: str,
):
    image_id, _ = Docker.build(
        dockerfile=base,
        buildkit=buildkit,
        tag=random_hex,
    )
    assert image_id

    # TODO this is a known limitation for the moment
    # we EXPECT this case to fail without buildkit enabled,
    # as base image adjusts USER and child Dockerfile
    # does not have any indication that USER was adjusted
    # and so we cannot detect USER from base image.
    # In this case chalk falls back to standard docker build
    # which means there is no chalk report in the output
    second_image_id, result = chalk.docker_build(
        dockerfile=test,
        buildkit=buildkit,
        args={"BASE": random_hex},
        config=CONFIGS / "docker_wrap.c4m",
        expecting_report=buildkit,
    )
    assert second_image_id


def test_base_ecr(chalk: Chalk):
    """
    ecr some manifest endpoints require additional auth even for public registries
    """
    _, build = chalk.docker_build(
        dockerfile=DOCKERFILES / "valid" / "ecr" / "Dockerfile",
        config=CONFIGS / "docker_wrap.c4m",
    )
    assert build
    assert build.mark.has(
        _IMAGE_ENTRYPOINT=[
            "/chalk",
            "exec",
            "--exec-command-name",
            "/lambda-entrypoint.sh",
            "--",
        ],
    )


def test_base_image(chalk: Chalk, random_hex: str):
    base_id, _ = Docker.build(
        dockerfile=DOCKERFILES / "valid" / "base" / "Dockerfile.base",
        context=DOCKERFILES / "valid" / "base",
        tag=random_hex,
    )
    assert base_id

    image_id, result = chalk.docker_build(
        dockerfile=DOCKERFILES / "valid" / "base" / "Dockerfile",
        context=DOCKERFILES / "valid" / "base",
        args={"BASE": random_hex},
        config=CONFIGS / "docker_wrap.c4m",
    )
    assert Docker.run(image_id)


@pytest.mark.parametrize("cmd", ["cmd", "entrypoint"])
@pytest.mark.parametrize(
    "test_file",
    [
        "string.Dockerfile",
        "json.Dockerfile",
    ],
)
def test_wrap(chalk: Chalk, random_hex: str, test_file: str, cmd: str):
    image_id, result = chalk.docker_build(
        dockerfile=DOCKERFILES / "valid" / cmd / test_file,
        context=DOCKERFILES / "valid" / cmd,
        config=CONFIGS / "docker_wrap.c4m",
    )
    _, output = Docker.run(image_id)
    assert "hello" in output.text


@pytest.mark.parametrize(
    "test_file",
    [
        "valid/sample_1",
        "valid/sample_2",
        "valid/sample_3",
    ],
)
def test_virtual_valid(
    tmp_data_dir: Path, chalk: Chalk, test_file: str, random_hex: str
):
    tag = f"{test_file}_{random_hex}"
    dockerfile = DOCKERFILES / test_file / "Dockerfile"
    image_hash, build = chalk.docker_build(
        dockerfile=dockerfile,
        tag=tag,
        virtual=True,
        env={"SINK_TEST_OUTPUT_FILE": "/tmp/sink_file.json"},
    )

    # artifact is the docker image
    # keys to check
    artifact_info = ArtifactInfo(
        type="Docker Image",
        chalk_info={
            "_CURRENT_HASH": image_hash,
            "_IMAGE_ID": image_hash,
            "_REPO_TAGS": [tag + ":latest"],
            "DOCKERFILE_PATH": str(dockerfile),
            # docker tags should be set to tag above
            "DOCKER_TAGS": [tag],
        },
    )
    validate_docker_chalk_report(
        chalk_report=build.report,
        artifact=artifact_info,
        virtual=True,
    )

    chalk_version = build.mark["CHALK_VERSION"]
    metadata_id = build.mark["METADATA_ID"]

    vchalk = validate_virtual_chalk(
        tmp_data_dir, artifact_map={image_hash: artifact_info}, virtual=True
    )

    # required keys in min chalk mark
    assert "CHALK_ID" in vchalk
    assert vchalk["MAGIC"] == MAGIC
    assert vchalk["CHALK_VERSION"] == chalk_version
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
    tag = f"{test_file}_{random_hex}"
    dockerfile = DOCKERFILES / test_file / "Dockerfile"
    chalk.docker_build(
        dockerfile=dockerfile,
        tag=tag,
        virtual=True,
        expected_success=False,
    )

    # invalid dockerfile should not create any chalk output
    assert not (
        tmp_data_dir / "virtual-chalk.json"
    ).is_file(), "virtual-chalk.json should not have been created!"


@pytest.mark.parametrize(
    "test_file", ["valid/sample_1", "valid/sample_2", "valid/sample_3"]
)
def test_nonvirtual_valid(chalk: Chalk, test_file: str, random_hex: str):
    tag = f"{test_file}_{random_hex}"
    image_hash, build = chalk.docker_build(
        dockerfile=DOCKERFILES / test_file / "Dockerfile",
        tag=tag,
        config=CONFIGS / "docker_wrap.c4m",
    )

    # artifact is the docker image
    artifact_info = ArtifactInfo(
        type="Docker Image",
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

    chalk_version = build.mark["CHALK_VERSION"]
    metadata_id = build.mark["METADATA_ID"]

    _, result = Docker.run(
        image=image_hash,
        entrypoint="cat",
        params=["chalk.json"],
    )
    chalk_json = result.json()

    assert "CHALK_ID" in chalk_json
    assert chalk_json["MAGIC"] == MAGIC, "chalk magic value incorrect"
    assert chalk_json["CHALK_VERSION"] == chalk_version
    assert chalk_json["METADATA_ID"] == metadata_id


@pytest.mark.parametrize("test_file", ["invalid/sample_1", "invalid/sample_2"])
def test_nonvirtual_invalid(chalk: Chalk, test_file: str, random_hex: str):
    tag = f"{test_file}_{random_hex}"
    chalk.docker_build(
        dockerfile=DOCKERFILES / test_file / "Dockerfile",
        tag=tag,
        expected_success=False,
    )


def test_docker_heartbeat(chalk_copy: Chalk, random_hex: str):
    """
    exec heartbeat from inside docker
    """
    tag = f"test_image_{random_hex}"
    chalk_copy.load(CONFIGS / "docker_heartbeat.c4m", use_embedded=False)

    # build dockerfile with chalk docker entrypoint wrapping
    chalk_copy.docker_build(
        dockerfile=DOCKERFILES / "valid" / "sleep" / "Dockerfile",
        tag=tag,
    )

    _, result = Docker.run(
        image=tag,
        check=False,
    )
    chalk_result = ChalkProgram.from_program(result)

    exec_report = chalk_result.reports[0]
    assert exec_report["_OPERATION"] == "exec"

    # there should be a few heartbeats
    assert len(chalk_result.reports) > 1
    for heartbeat_report in chalk_result.reports[1:]:
        assert heartbeat_report["_OPERATION"] == "heartbeat"
        assert heartbeat_report.mark == exec_report.mark


def test_docker_labels(chalk: Chalk, random_hex: str):
    tag = f"test_image_{random_hex}"

    # build container with env vars
    chalk.docker_build(
        dockerfile=DOCKERFILES / "valid" / "sample_1" / "Dockerfile",
        tag=tag,
        config=CONFIGS / "docker_heartbeat.c4m",
    )

    inspected = Docker.inspect(tag)
    assert len(inspected) == 1

    docker_configs = inspected[0]["Config"]
    assert "Labels" in docker_configs
    labels = docker_configs["Labels"]
    assert TEST_LABEL in labels.values()


@pytest.mark.parametrize("push", [True, False])
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
def test_build_and_push(chalk: Chalk, test_file: str, random_hex: str, push: bool):
    tag_base = f"{REGISTRY}/{test_file}_{random_hex}"
    tag = f"{tag_base}:latest"

    current_hash_build, push_result = chalk.docker_build(
        dockerfile=DOCKERFILES / test_file / "Dockerfile",
        tag=tag,
        push=push,
    )

    # if without --push at build time, explicitly push to registry
    if not push:
        push_result = chalk.docker_push(tag)

    current_hash_push = push_result.mark["_CURRENT_HASH"]
    repo_digest_push = push_result.mark["_REPO_DIGESTS"][tag_base]
    assert "CHALK_ID" in push_result.mark
    # primary key needed to associate build+push
    assert "METADATA_ID" in push_result.mark

    assert current_hash_build == current_hash_push

    pull = chalk.docker_pull(tag)
    assert pull.find("Digest:") == f"sha256:{repo_digest_push}"


@pytest.mark.parametrize("push", [True, False])
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
def test_multiplatform_build(chalk: Chalk, test_file: str, random_hex: str, push: bool):
    tag_base = f"{REGISTRY}/{test_file}_{random_hex}"
    tag = f"{tag_base}:latest"
    platforms = {"linux/amd64", "linux/arm64"}

    image_id, build = chalk.docker_build(
        dockerfile=DOCKERFILES / test_file / "Dockerfile",
        tag=tag,
        push=push,
        platforms=list(platforms),
    )

    assert len(build.marks) == len(platforms)
    assert {i["DOCKER_PLATFORM"] for i in build.marks} == platforms

    if not push:
        return

    chalk_ids = {i["CHALK_ID"] for i in build.marks}
    metadata_ids = {i["METADATA_ID"] for i in build.marks}
    hashes = {i["_CURRENT_HASH"] for i in build.marks}
    digests = {i["_REPO_DIGESTS"][tag_base] for i in build.marks}
    tags = set(itertools.chain(*[i["DOCKER_TAGS"] for i in build.marks]))

    assert len(chalk_ids) == 1
    assert len(metadata_ids) == len(platforms)
    assert image_id in hashes
    assert len(hashes) == len(platforms)
    assert len(digests) == len(platforms)
    assert len(tags) == len(platforms)
    for t in tags:
        assert t != tag
        assert t.startswith(tag)
        assert any(t.endswith(i.replace("/", "-")) for i in platforms)


@pytest.mark.slow()
@pytest.mark.parametrize(
    "context, dockerfile, private, buildkit",
    [
        # without buildkit
        # note legacy builder defaults to "master" branch so needs to be overwritten
        (
            "https://github.com/crashappsec/chalk-docker-git-context.git#main",
            None,
            False,
            False,
        ),
        # git scheme
        pytest.param(
            f"git@github.com:{DOCKER_SSH_REPO}.git",
            None,
            False,
            True,
            marks=pytest.mark.skipif(
                not os.environ.get("SSH_KEY"), reason="SSH_KEY is required"
            ),
        ),
        # ssh with port number
        pytest.param(
            f"ssh://git@github.com:22/{DOCKER_SSH_REPO}.git",
            None,
            False,
            True,
            marks=pytest.mark.skipif(
                not os.environ.get("SSH_KEY"), reason="SSH_KEY is required"
            ),
        ),
        # https
        (
            "https://github.com/crashappsec/chalk-docker-git-context.git",
            None,
            False,
            True,
        ),
        # with dockerfile path within context
        (
            "https://github.com/crashappsec/chalk-docker-git-context.git",
            "./Dockerfile",
            False,
            True,
        ),
        # with commit
        (
            "https://github.com/crashappsec/chalk-docker-git-context.git#e488e0f9eaad7eb08c05334454787a7966c39f84",
            None,
            False,
            True,
        ),
        # with branch
        (
            "https://github.com/crashappsec/chalk-docker-git-context.git#main",
            None,
            False,
            True,
        ),
        # with branch and nested folder for context
        (
            "https://github.com/crashappsec/chalk-docker-git-context.git#main:nested",
            None,
            False,
            True,
        ),
        # private repo
        (
            f"https://github.com/{DOCKER_TOKEN_REPO}.git",
            None,
            True,
            True,
        ),
    ],
)
@pytest.mark.skipif(
    not os.environ.get("GITHUB_TOKEN"), reason="GITHUB_TOKEN is required"
)
def test_git_context(
    chalk: Chalk,
    context: str,
    dockerfile: Optional[str],
    private: bool,
    buildkit: bool,
    tmp_file: Path,
    random_hex: str,
):
    tmp_file.write_text(os.environ["GITHUB_TOKEN"])

    image_id, build = chalk.docker_build(
        context=context,
        dockerfile=dockerfile,
        tag=random_hex,
        secrets={"GIT_AUTH_TOKEN": tmp_file} if private else {},
        buildkit=buildkit,
    )
    assert build.mark


# extract on image id, and image name, running container id + container name, exited container id + container name
def test_extract(chalk: Chalk, random_hex: str):
    tag = f"test_image_{random_hex}"
    container_name = f"test_container_{random_hex}"

    # build test image
    image_id, _ = chalk.docker_build(
        dockerfile=DOCKERFILES / "valid" / "sample_1" / "Dockerfile",
        tag=tag,
    )

    # artifact info should be consistent
    image_artifact = ArtifactInfo(
        type="Docker Image",
        host_info={
            "_OPERATION": "extract",
            "_OP_EXE_NAME": chalk.binary.name,
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
        host_info={
            "_OPERATION": "extract",
            "_OP_EXE_NAME": chalk.binary.name,
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


def test_docker_diff_user(chalk_default: Chalk):
    _, program = Docker.run(
        "alpine",
        entrypoint="/chalk",
        params=["exec", "--trace", "--exec-command-name=sleep", "1"],
        volumes={
            chalk_default.binary: "/chalk",
            MARKS / "object.json": "/chalk.json",
        },
        cwd=chalk_default.binary.parent,
        user="1000:1000",
    )
    result = ChalkProgram.from_program(program)
    assert result


def test_docker_default_command(chalk_copy: Chalk, tmp_data_dir: Path):
    assert chalk_copy.load(CONFIGS / "docker_cmd.c4m")
    expected = Docker.version()
    docker = tmp_data_dir / "docker"
    shutil.copy(chalk_copy.binary, docker)
    actual = run([str(docker), "--version"])
    assert actual
    assert actual.text == expected.text

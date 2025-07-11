# Copyright (c) 2023-2025, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import itertools
import operator
import os
import platform
import re
import shutil
import time
from contextlib import ExitStack
from pathlib import Path
from typing import Iterator, Optional
from unittest import mock

import pytest

from .chalk.runner import Chalk, ChalkMark, ChalkProgram
from .conf import (
    CONFIGS,
    DOCKERFILES,
    DOCKER_SSH_REPO,
    DOCKER_TOKEN_REPO,
    MAGIC,
    MARKS,
    REGISTRY,
    REGISTRY_PROXY,
    REGISTRY_TLS,
    REGISTRY_TLS_INSECURE,
    TESTS,
)
from .utils.dict import (
    ANY,
    MISSING,
    Contains,
    IfExists,
    Iso8601,
    Length,
    Values,
)
from .utils.docker import Docker
from .utils.git import Git
from .utils.log import get_logger
from .utils.os import run


logger = get_logger()


@pytest.fixture(scope="session", autouse=True)
def do_docker_cleanup() -> Iterator[None]:
    # record all tags/containers being created during tests
    # and automatically delete them at the end of the test suite
    images: set[str] = set()
    containers: set[str] = set()

    _chalk_docker_build = Chalk.docker_build
    _docker_build = Docker.build
    _docker_tag = Docker.tag
    _docker_run = Docker.run

    def chalk_docker_build(self, *args, **kwargs):
        image_hash, result = _chalk_docker_build(self, *args, **kwargs)
        images.add(image_hash)
        return image_hash, result

    def docker_build(*args, **kwargs):
        image_hash, result = _docker_build(*args, **kwargs)
        images.add(image_hash)
        return image_hash, result

    def docker_tag(tag, new_tag):
        images.add(new_tag)
        return _docker_tag(tag, new_tag)

    def docker_run(*args, **kwargs):
        container_id, result = _docker_run(*args, **kwargs)
        containers.add(container_id)
        return container_id, result

    with ExitStack() as stack:
        stack.enter_context(
            mock.patch.object(Chalk, "docker_build", chalk_docker_build)
        )
        stack.enter_context(mock.patch.object(Docker, "build", docker_build))
        stack.enter_context(mock.patch.object(Docker, "tag", docker_tag))
        stack.enter_context(mock.patch.object(Docker, "run", docker_run))
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


@pytest.mark.parametrize(
    "buildkit, buildx, builder",
    [
        (True, True, "empty_builder"),
        (True, True, None),
        (True, False, None),
        (False, False, None),
    ],
)
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
    chalk_copy: Chalk,
    dockerfile: Optional[Path],
    cwd: Optional[Path],
    tag: Optional[bool],
    buildkit: bool,
    buildx: bool,
    builder: Optional[str],
    random_hex: str,
):
    """
    Test various variants of docker build command
    """
    chalk_copy.binary.rename("chalk")
    image_id, build = chalk_copy.docker_build(
        dockerfile=dockerfile,
        cwd=cwd,
        tag=random_hex if tag else None,
        buildkit=buildkit,
        buildx=buildx,
        builder=builder,
        config=CONFIGS / "docker_wrap.c4m",
    )
    assert image_id
    assert build.mark.has(_IMAGE_ENTRYPOINT=["/chalk", "exec", "--"])
    assert build.report.has(
        _OP_EXIT_CODE=build.exit_code,
        _DOCKER_CLIENT_VERSION=str,
        _DOCKER_SERVER_VERSION=str,
        _DOCKER_BUILDX_VERSION=str if buildx or buildkit else MISSING,
        _DOCKER_BUILDER_BUILDKIT_VERSION=str if buildx or buildkit else MISSING,
        _DOCKER_INFO=str,
        _DOCKER_USED_REGISTRIES={
            REGISTRY_PROXY: (
                {
                    "auth": False,
                    "www_auth": False,
                    "http": True,
                    "insecure": True,
                    "mirroring": "registry-1.docker.io",
                    "scheme": "http",
                    "secure": False,
                    "source": "buildx" if buildx else "daemon",
                    "url": f"http://{REGISTRY_PROXY}/v2/",
                }
                if not builder
                else MISSING
            ),
            "registry-1.docker.io": (
                {
                    "url": "https://registry-1.docker.io/v2/",
                    "source": "buildx",
                    "scheme": "https",
                    "http": False,
                    "secure": True,
                    "insecure": False,
                    "auth": False,
                    "www_auth": True,
                }
                # without empty builder, docker hub should be used as there is no proxy config anymore
                if builder
                else MISSING
            ),
        },
        _DOCKER_BUILDER_INFO=str if buildx or buildkit else MISSING,
        _DOCKER_BUILDER_NODES_INFO=Length(0, operator.gt) if buildx else MISSING,
        _DOCKER_BUILDER_NODES_CONFIG=(
            Values(
                Contains(
                    [
                        (
                            {
                                "debug": True,
                                "registry": {
                                    REGISTRY: {"http": True},
                                    REGISTRY_PROXY: {"http": True},
                                    REGISTRY_TLS_INSECURE: {"insecure": True},
                                    REGISTRY_TLS: {"ca": [str]},
                                    "docker.io": {
                                        "mirrors": Contains([REGISTRY_PROXY]),
                                    },
                                },
                            }
                            if not builder
                            # empty builder doesnt have any configs
                            else Length(0)
                        )
                    ]
                )
            )
            if buildx
            else MISSING
        ),
    )


@pytest.mark.parametrize("buildkit", [True, False])
def test_scratch(chalk: Chalk, buildkit: bool):
    _, build = chalk.docker_build(
        dockerfile=DOCKERFILES / "valid" / "empty" / "Dockerfile",
        buildkit=buildkit,
        run_docker=buildkit,  # non-buildx doesnt allow empty image
        config=CONFIGS / "docker_wrap.c4m",
    )
    if buildkit:
        assert "_IMAGE_ENTRYPOINT" not in build.mark


def test_distroless(chalk: Chalk):
    image_id, build = chalk.docker_build(
        dockerfile=DOCKERFILES / "valid" / "distroless" / "Dockerfile",
        config=CONFIGS / "docker_wrap.c4m",
    )
    # distroless image has user marked as "0" vs usual "root" or missing user
    assert "ONBUILD USER" not in build.mark["DOCKER_FILE_CHALKED"]

    _, output = Docker.run(image=image_id)
    assert "hello" in output.text


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


@pytest.mark.parametrize("buildx", [True, False])
@pytest.mark.parametrize("dockerfile", [DOCKERFILES / "valid" / "sample_1"])
def test_multiple_tags(
    chalk: Chalk,
    dockerfile: Path,
    random_hex: str,
    buildx: bool,
):
    tags = [
        f"{REGISTRY}/{random_hex}-1",
        f"{REGISTRY}/{random_hex}-1:foo",
        f"{REGISTRY}/{random_hex}-2",
    ]
    image_id, build = chalk.docker_build(
        dockerfile=dockerfile / "Dockerfile",
        tags=tags,
        config=CONFIGS / "docker_wrap.c4m",
        push=True,
        load=not buildx,
        buildx=buildx,
        # docker sanity check will push to registry
        # whereas we want to ensure chalk does the pushing
        run_docker=False,
    )
    assert image_id
    assert build.mark.has(
        _REPO_TAGS={
            REGISTRY: {
                f"{random_hex}-1": {
                    "latest": ANY,
                    "foo": ANY,
                },
                f"{random_hex}-2": {
                    "latest": ANY,
                },
            },
        }
    )

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

    second_image_id, _ = chalk.docker_build(
        dockerfile=test,
        buildkit=buildkit,
        args={"BASE": random_hex},
        config=CONFIGS / "docker_wrap.c4m",
    )
    assert second_image_id


@pytest.mark.parametrize(
    "base, test",
    [
        (
            DOCKERFILES / "valid" / "split_dockerfiles" / "base.Dockerfile",
            DOCKERFILES / "valid" / "split_dockerfiles" / "test.Dockerfile",
        ),
    ],
)
def test_onbuild(chalk: Chalk, base: Path, test: Path, random_hex: str):
    """
    check onbuild correctly mutates /chalk.json

    when using chalked image as base image, all child builds, when not wrapped
    should reflect that in /chalk.json
    """
    image_id, build = chalk.docker_build(
        dockerfile=base,
        tag=random_hex,
        config=CONFIGS / "docker_wrap.c4m",
    )
    assert image_id
    assert build.mark.has(_IMAGE_ENTRYPOINT=["/chalk", "exec", "--"])

    second_image_id, _ = Docker.build(
        dockerfile=test,
        args={"BASE": random_hex},
    )
    assert second_image_id
    assert (
        Docker.inspect(second_image_id)[0]["Config"]["User"]
        == build.mark["_IMAGE_USER"]
    )

    _, result = Docker.run(
        image=second_image_id,
        entrypoint="cat",
        params=["/chalk.json"],
        expected_success=True,
    )
    mark = ChalkMark.from_json(result.text)
    assert mark.has(
        METADATA_ID=MISSING,
        METADATA_HASH=MISSING,
        CHALK_ID=MISSING,
        OLD_CHALK_METADATA_ID=build.mark["METADATA_ID"],
        EMBEDDED_CHALK=[
            {
                "METADATA_ID": build.mark["METADATA_ID"],
            },
        ],
    )


@pytest.mark.parametrize("buildx", [True, False])
@pytest.mark.parametrize(
    "image, entrypoint",
    [
        ("public.ecr.aws/lambda/python:3.11", "/lambda-entrypoint.sh"),
        ("quay.io/cilium/alpine-curl", "/usr/bin/curl"),
        ("registry.k8s.io/pause:3.9", "/pause"),
        ("k8s.gcr.io/pause", "/pause"),
        ("ghcr.io/crashappsec/pgcli:3.5.0", "pgcli"),
        ("nginx:1.27", "/docker-entrypoint.sh"),
        (f"{REGISTRY_PROXY}/library/nginx:1.27", "/docker-entrypoint.sh"),
    ],
)
def test_base_registry(chalk: Chalk, image: str, entrypoint: str, buildx: bool):
    """
    ecr some manifest endpoints require additional auth even for public registries
    """
    _, build = chalk.docker_build(
        content=f"FROM {image}",
        config=CONFIGS / "docker_wrap.c4m",
        buildx=buildx,
    )
    assert build
    assert build.mark.has(
        _IMAGE_ENTRYPOINT=[
            "/chalk",
            "exec",
            "--exec-command-name",
            entrypoint,
            "--",
        ],
    )


@pytest.mark.parametrize("push", [True, False])
def test_base_image(chalk: Chalk, random_hex: str, push: bool):
    base = f"{REGISTRY}/base/{random_hex}:{random_hex}"
    base_id, _ = Docker.build(
        buildx=push,
        push=push,
        load=not push,
        dockerfile=DOCKERFILES / "valid" / "base" / "Dockerfile.base",
        context=DOCKERFILES / "valid" / "base",
        tag=base,
    )
    assert base_id

    image_id, _ = chalk.docker_build(
        dockerfile=DOCKERFILES / "valid" / "base" / "Dockerfile",
        context=DOCKERFILES / "valid" / "base",
        args={"BASE": base},
        config=CONFIGS / "docker_wrap.c4m",
    )
    _, run = Docker.run(image_id)
    assert run


def test_recursion_wrapping(chalk: Chalk, random_hex: str):
    base_id, _ = chalk.docker_build(
        dockerfile=DOCKERFILES / "valid" / "base" / "Dockerfile.base",
        context=DOCKERFILES / "valid" / "base",
        tag=random_hex,
        config=CONFIGS / "docker_wrap.c4m",
    )
    assert base_id

    image_id, _ = chalk.docker_build(
        dockerfile=DOCKERFILES / "valid" / "base" / "Dockerfile",
        context=DOCKERFILES / "valid" / "base",
        args={"BASE": random_hex},
        config=CONFIGS / "docker_wrap.c4m",
    )
    _, run = Docker.run(image_id)
    assert run


def test_subscan(chalk: Chalk, server_cert: Path, random_hex: str):
    _, build = chalk.docker_build(
        config=CONFIGS / "docker_wrap.c4m",
        tag=random_hex,
        context=server_cert.parent,
        content=Docker.dockerfile(
            """
            FROM alpine
            """
        ),
    )
    assert build.artifacts_by_path.contains(
        {
            str(server_cert): {
                "_X509_SUBJECT": {
                    "commonName": "tls.chalk.local",
                },
                "_OP_ARTIFACT_PATH_WITHIN_VCTL": str(
                    server_cert.relative_to(TESTS.parent.parent)
                ),
            }
        }
    )


def test_base_images(chalk: Chalk, random_hex: str, tmp_data_dir: Path):
    (
        Git(tmp_data_dir)
        .init(remote="git@github.com:crashappsec/foo.git", branch="main")
        .add()
        .commit("init")
    )

    # most of the images below are manifest lists
    # so we create a dummy one which is guaranteed to be regular image manifest
    name = f"{random_hex}_image"
    image = f"{REGISTRY}/{name}"
    _, base = chalk.docker_build(
        config=CONFIGS / "docker_wrap.c4m",
        tag=image,
        content=Docker.dockerfile(
            """
            FROM alpine
            CMD /true
            """
        ),
        push=True,
        buildx=True,
    )
    assert base.artifact.has(
        METADATA_ID=MISSING,
        COMMIT_ID=ANY,
        ORIGIN_URI="https://github.com/alpinelinux/docker-alpine.git",
        _OP_ARTIFACT_CONTEXT="base",
    )
    assert base.mark.has(
        COMMIT_ID=ANY,
        ORIGIN_URI="git@github.com:crashappsec/foo.git",
        DOCKER_BASE_IMAGE_METADATA_ID=MISSING,
        DOCKER_BASE_IMAGE_ID=ANY,
        _OP_ARTIFACT_CONTEXT="build",
    )

    _, result = chalk.docker_build(
        content=Docker.dockerfile(
            f"""
            ARG BASE=seven

            FROM alpine as one
            FROM alpine as oneduplicate

            FROM alpine
            FROM ubuntu:24.04 as two
            COPY --from=docker /usr/local/bin/docker /docker
            COPY --from=busybox:latest /bin/busybox /busybox

            FROM --platform=linux/arm64 busybox@sha256:9ae97d36d26566ff84e8893c64a6dc4fe8ca6d1144bf5b87b2b85a32def253c7 as three

            FROM --platform=linux/amd64 nginx:1.27.0@sha256:97b83c73d3165f2deb95e02459a6e905f092260cd991f4c4eae2f192ddb99cbe as four

            FROM one as five
            COPY --from=nginx:1.27.0@sha256:97b83c73d3165f2deb95e02459a6e905f092260cd991f4c4eae2f192ddb99cbe /usr/sbin/nginx /nginx
            COPY --from=one /bin/sh /sh
            COPY --from=0 /bin/ls /ls

            FROM scratch as six

            FROM {image}:latest as seven

            FROM crashappsec/chalk as chalk

            FROM $BASE
            COPY --from=four /usr/sbin/nginx /nginx
            """
        ),
    )
    assert result.report.has(
        _OP_CHALK_COUNT=1,
        # all base images should be set as unmarked
        _UNMARKED=Length(len({"alpine", "ubuntu", "busybox", "nginx"}), operator.ge),
        _COLLECTED_ARTIFACTS=Contains(
            [
                {
                    **{
                        k: IfExists(v)
                        for k, v in base.mark.items()
                        if not k.startswith("_")
                    },
                    **{
                        "_OP_ARTIFACT_CONTEXT": "base",
                        "_IMAGE_ID": base.mark["_IMAGE_ID"],
                        "METADATA_ID": base.mark["METADATA_ID"],
                        "COMMIT_ID": base.mark["COMMIT_ID"],
                        "ORIGIN_URI": base.mark["ORIGIN_URI"],
                    },
                },
                {
                    "_IMAGE_ID": ANY,
                    "METADATA_ID": MISSING,
                    "COMMIT_ID": ANY,
                    "_IMAGE_CREATION_DATETIME": Iso8601(),
                    "ORIGIN_URI": "https://git.launchpad.net/cloud-images/+oci/ubuntu-base",
                    "_REPO_DIGESTS": {
                        "registry-1.docker.io": {
                            "library/ubuntu": ANY,
                        }
                    },
                    "_REPO_TAGS": {
                        "registry-1.docker.io": {
                            "library/ubuntu": {
                                "24.04": ANY,
                            }
                        }
                    },
                    "_REPO_URLS": {
                        "registry-1.docker.io": {
                            "library/ubuntu": "https://hub.docker.com/_/ubuntu"
                        }
                    },
                },
                {
                    "_IMAGE_ID": ANY,
                    "METADATA_ID": MISSING,
                    "COMMIT_ID": ANY,
                    "_IMAGE_CREATION_DATETIME": Iso8601(),
                    "ORIGIN_URI": "https://github.com/nginxinc/docker-nginx.git",
                    "DOCKER_PLATFORM": "linux/amd64",
                    "_REPO_DIGESTS": {
                        "registry-1.docker.io": {
                            "library/nginx": ANY,
                        }
                    },
                    # even though tag is specified in dockerfile, its pinning to digest
                    # and tag is outdated after new release
                    "_REPO_TAGS": IfExists(
                        {
                            "registry-1.docker.io": MISSING,
                        }
                    ),
                    "_REPO_URLS": {
                        "registry-1.docker.io": {
                            "library/nginx": "https://hub.docker.com/_/nginx"
                        }
                    },
                },
                {
                    "_IMAGE_ID": ANY,
                    "METADATA_ID": MISSING,
                    "COMMIT_ID": ANY,
                    "_IMAGE_CREATION_DATETIME": Iso8601(),
                    "ORIGIN_URI": "https://github.com/docker-library/busybox.git",
                    "DOCKER_PLATFORM": re.compile(r"^linux/arm64"),
                    "_REPO_DIGESTS": {
                        "registry-1.docker.io": {
                            "library/busybox": ANY,
                        }
                    },
                    # even though tag is specified in dockerfile, its pinning to digest
                    # and tag is outdated after new release
                    "_REPO_TAGS": IfExists(
                        {
                            "registry-1.docker.io": MISSING,
                        }
                    ),
                    "_REPO_URLS": {
                        "registry-1.docker.io": {
                            "library/busybox": "https://github.com/docker-library/busybox"
                        }
                    },
                },
                {
                    "_IMAGE_ID": ANY,
                    "METADATA_ID": ANY,
                    "COMMIT_ID": ANY,
                    "_IMAGE_CREATION_DATETIME": Iso8601(),
                    "ORIGIN_URI": "https://github.com/crashappsec/chalk",
                    "_REPO_DIGESTS": {
                        "registry-1.docker.io": {
                            "crashappsec/chalk": ANY,
                        }
                    },
                    "_REPO_URLS": {
                        "registry-1.docker.io": {
                            "crashappsec/chalk": "https://hub.docker.com/r/crashappsec/chalk"
                        }
                    },
                },
            ]
        ),
    )
    assert result.mark.has(
        DOCKER_TARGET="",
        _OP_ARTIFACT_CONTEXT="build",
        DOCKER_BASE_IMAGE_METADATA_ID=base.mark["METADATA_ID"],
        DOCKER_BASE_IMAGE_CHALK={k: IfExists(v) for k, v in base.mark.items()},
        DOCKER_BASE_IMAGE_ID=base.mark["_IMAGE_ID"],
        DOCKER_BASE_IMAGE=re.compile(rf"{image}:latest@sha256:"),
        DOCKER_BASE_IMAGE_REPO=image,
        DOCKER_BASE_IMAGE_REGISTRY=REGISTRY,
        DOCKER_BASE_IMAGE_NAME=name,
        DOCKER_BASE_IMAGE_TAG="latest",
        DOCKER_BASE_IMAGE_DIGEST=ANY,
        DOCKER_BASE_IMAGES={
            "one": {
                "from": re.compile("alpine@sha256:"),
                "uri": re.compile("alpine@sha256:"),
                "repo": "alpine",
                "registry": "registry-1.docker.io",
                "name": "library/alpine",
                "tag": MISSING,
                "digest": ANY,
            },
            "two": {
                "from": re.compile("ubuntu:24.04@sha256:"),
                "uri": re.compile("ubuntu:24.04@sha256:"),
                "repo": "ubuntu",
                "registry": "registry-1.docker.io",
                "name": "library/ubuntu",
                "tag": "24.04",
                "digest": ANY,
            },
            "three": {
                "from": "busybox@sha256:9ae97d36d26566ff84e8893c64a6dc4fe8ca6d1144bf5b87b2b85a32def253c7",
                "uri": "busybox@sha256:9ae97d36d26566ff84e8893c64a6dc4fe8ca6d1144bf5b87b2b85a32def253c7",
                "repo": "busybox",
                "registry": "registry-1.docker.io",
                "name": "library/busybox",
                "tag": MISSING,
                "digest": "9ae97d36d26566ff84e8893c64a6dc4fe8ca6d1144bf5b87b2b85a32def253c7",
            },
            "four": {
                "from": "nginx:1.27.0@sha256:97b83c73d3165f2deb95e02459a6e905f092260cd991f4c4eae2f192ddb99cbe",
                "uri": "nginx:1.27.0@sha256:97b83c73d3165f2deb95e02459a6e905f092260cd991f4c4eae2f192ddb99cbe",
                "repo": "nginx",
                "registry": "registry-1.docker.io",
                "name": "library/nginx",
                "tag": "1.27.0",
                "digest": "97b83c73d3165f2deb95e02459a6e905f092260cd991f4c4eae2f192ddb99cbe",
            },
            "five": {
                "from": "one",
                "uri": re.compile("alpine@sha256:"),
                "repo": "alpine",
                "registry": "registry-1.docker.io",
                "name": "library/alpine",
                "tag": MISSING,
                "digest": ANY,
            },
            "six": {
                "from": "scratch",
                "uri": "scratch",
                "repo": "scratch",
                "registry": MISSING,
                "name": "scratch",
                "tag": MISSING,
                "digest": MISSING,
            },
            "seven": {
                "from": re.compile(f"{image}:latest@sha256:"),
                "uri": re.compile(f"{image}:latest@sha256:"),
                "repo": image,
                "registry": REGISTRY,
                "name": name,
                "tag": "latest",
                "digest": ANY,
            },
            "": {
                "from": "seven",
                "uri": re.compile(f"{image}:latest@sha256:"),
                "repo": image,
                "registry": REGISTRY,
                "name": name,
                "tag": "latest",
                "digest": ANY,
            },
        },
        DOCKER_COPY_IMAGES={
            "two": [
                {
                    "from": "docker",
                    "uri": "docker",
                    "repo": "docker",
                    "registry": "registry-1.docker.io",
                    "name": "library/docker",
                    "tag": MISSING,
                    "digest": MISSING,
                    "src": ["/usr/local/bin/docker"],
                    "dest": "/docker",
                },
                {
                    "from": "busybox:latest",
                    "uri": "busybox:latest",
                    "repo": "busybox",
                    "registry": "registry-1.docker.io",
                    "name": "library/busybox",
                    "tag": "latest",
                    "digest": MISSING,
                    "src": ["/bin/busybox"],
                    "dest": "/busybox",
                },
            ],
            "five": [
                {
                    "from": "nginx:1.27.0@sha256:97b83c73d3165f2deb95e02459a6e905f092260cd991f4c4eae2f192ddb99cbe",
                    "uri": "nginx:1.27.0@sha256:97b83c73d3165f2deb95e02459a6e905f092260cd991f4c4eae2f192ddb99cbe",
                    "repo": "nginx",
                    "registry": "registry-1.docker.io",
                    "name": "library/nginx",
                    "tag": "1.27.0",
                    "digest": "97b83c73d3165f2deb95e02459a6e905f092260cd991f4c4eae2f192ddb99cbe",
                    "src": ["/usr/sbin/nginx"],
                    "dest": "/nginx",
                },
                {
                    "from": "one",
                    "uri": re.compile("alpine@sha256:"),
                    "repo": "alpine",
                    "registry": "registry-1.docker.io",
                    "name": "library/alpine",
                    "tag": MISSING,
                    "digest": ANY,
                    "src": ["/bin/sh"],
                    "dest": "/sh",
                },
                {
                    "from": "0",
                    "uri": re.compile("alpine@sha256:"),
                    "repo": "alpine",
                    "registry": "registry-1.docker.io",
                    "name": "library/alpine",
                    "tag": MISSING,
                    "digest": ANY,
                    "src": ["/bin/ls"],
                    "dest": "/ls",
                },
            ],
            "": [
                {
                    "from": "four",
                    "uri": "nginx:1.27.0@sha256:97b83c73d3165f2deb95e02459a6e905f092260cd991f4c4eae2f192ddb99cbe",
                    "repo": "nginx",
                    "registry": "registry-1.docker.io",
                    "name": "library/nginx",
                    "tag": "1.27.0",
                    "digest": "97b83c73d3165f2deb95e02459a6e905f092260cd991f4c4eae2f192ddb99cbe",
                    "src": ["/usr/sbin/nginx"],
                    "dest": "/nginx",
                }
            ],
        },
        DOCKERFILE_PATH_WITHIN_VCTL=MISSING,
    )


@pytest.mark.parametrize(
    "test_file, docker_entrypoint, chalk_entrypoint, cmd, buildkit, buildx, runnable",
    [
        (
            Docker.dockerfile(
                """
                FROM alpine
                ENTRYPOINT echo hello
                CMD echo world
                """
            ),
            ["/bin/sh", "-c", "echo hello"],
            [
                "/chalk",
                "exec",
                "--exec-command-name",
                "/bin/sh",
                "--",
                "-c",
                "echo hello",
            ],
            ["/bin/sh", "-c", "echo world"],
            True,  # buildkit
            False,  # buildx
            True,  # runnable
        ),
        (
            Docker.dockerfile(
                """
                FROM alpine
                ENTRYPOINT ["echo"]
                CMD ["hello"]
                """
            ),
            ["echo"],
            ["/chalk", "exec", "--exec-command-name", "echo", "--"],
            ["hello"],
            True,  # buildkit
            False,  # buildx
            True,  # runnable
        ),
        (
            Docker.dockerfile(
                """
                FROM alpine as base
                ENTRYPOINT ["/bin/sh", "-c"]
                FROM base
                ENTRYPOINT []
                CMD ["echo", "hello"]
                """
            ),
            None,
            ["/chalk", "exec", "--"],
            ["echo", "hello"],
            True,  # buildkit
            False,  # buildx
            True,  # runnable
        ),
        (
            Docker.dockerfile(
                """
                FROM alpine
                ENTRYPOINT
                CMD ["echo", "hello"]
            """
            ),
            ["/bin/sh", "-c", ""],
            ["/chalk", "exec", "--exec-command-name", "/bin/sh", "--", "-c", ""],
            ["echo", "hello"],
            True,  # buildkit
            False,  # buildx
            True,  # runnable
        ),
        (
            Docker.dockerfile(
                """
                FROM alpine
                ENTRYPOINT
                CMD ["echo", "hello"]
                """
            ),
            None,
            ["/chalk", "exec", "--"],
            ["echo", "hello"],
            False,  # buildkit
            False,  # buildx
            True,  # runnable
        ),
        (
            Docker.dockerfile(
                """
                FROM alpine
                ENTRYPOINT
                CMD ["echo", "hello"]
                """
            ),
            ["/bin/sh", "-c", ""],
            ["/chalk", "exec", "--exec-command-name", "/bin/sh", "--", "-c", ""],
            ["echo", "hello"],
            False,  # buildkit
            True,  # buildx
            True,  # runnable
        ),
        (
            Docker.dockerfile(
                """
                FROM alpine
                ENTRYPOINT [""]
                CMD ["echo", "hello"]
                """
            ),
            [""],
            ["/chalk", "exec", "--"],
            ["echo", "hello"],
            True,  # buildkit
            False,  # buildx
            True,  # runnable
        ),
        (
            Docker.dockerfile(
                """
                FROM alpine
                ENTRYPOINT [" "]
                CMD ["echo", "hello"]
                """
            ),
            [" "],
            [" "],  # chalk should bail out wrapping known invalid entrypoint
            ["echo", "hello"],
            True,  # buildkit
            False,  # buildx
            False,  # runnable
        ),
        (
            Docker.dockerfile(
                """
                FROM alpine
                ENTRYPOINT ["", ""]
                CMD ["echo", "hello"]
                """
            ),
            ["", ""],
            ["", ""],  # same thing. chalk should bail out
            ["echo", "hello"],
            True,  # buildkit
            False,  # buildx
            False,  # runnable
        ),
    ],
)
def test_wrap_entrypoint(
    chalk: Chalk,
    test_file: str,
    docker_entrypoint: list[str],
    chalk_entrypoint: list[str],
    cmd: list[str],
    buildkit: bool,
    buildx: bool,
    runnable: bool,
):
    docker_id, _ = Docker.build(
        content=test_file,
        buildkit=buildkit,
        buildx=buildx,
    )
    assert Docker.inspect(docker_id)[0].has(
        Config={
            "Entrypoint": docker_entrypoint,
            "Cmd": cmd,
        }
    )
    _, docker_output = Docker.run(docker_id, expected_success=runnable)

    image_id, result = chalk.docker_build(
        content=test_file,
        config=CONFIGS / "docker_wrap.c4m",
        buildkit=buildkit,
        buildx=buildx,
        run_docker=False,  # explicitly running above
    )
    assert result.mark.has(
        _IMAGE_ENTRYPOINT=chalk_entrypoint,
        _IMAGE_CMD=cmd,
    )
    _, chalk_output = Docker.run(image_id, expected_success=runnable)
    assert docker_output == chalk_output


@pytest.mark.parametrize(
    "test_file, entrypoint, cmd",
    [
        (
            # shold lookup entypoint/cmd from base image
            "base.Dockerfile",
            ["/chalk", "exec", "--exec-command-name", "/docker-entrypoint.sh", "--"],
            ["/bin/sh", "-c", "nginx"],
        ),
        (
            # if ENTRYPOINT is set, it resets CMD
            "override.Dockerfile",
            ["/chalk", "exec", "--exec-command-name", "two", "--", "entrypoint"],
            MISSING,
        ),
        (
            # CMD honors higher section ENTRYPOINTs
            "cmd.Dockerfile",
            ["/chalk", "exec", "--exec-command-name", "one", "--", "entrypoint"],
            ["/bin/sh", "-c", "two cmd"],
        ),
    ],
)
def test_wrap_base_entrypoint(
    chalk: Chalk, test_file: str, entrypoint: list[str], cmd: list[str]
):
    _, result = chalk.docker_build(
        dockerfile=DOCKERFILES / "valid" / "entrypoint" / test_file,
        context=DOCKERFILES / "valid" / "entrypoint",
        config=CONFIGS / "docker_wrap.c4m",
    )
    assert result.mark.has(
        _IMAGE_ENTRYPOINT=entrypoint,
        _IMAGE_CMD=cmd,
    )


@pytest.mark.parametrize(
    "test_file, entrypoint, cmd",
    [
        (
            "string.Dockerfile",
            ["/chalk", "exec", "--"],
            ["/bin/sh", "-c", "echo hello"],
        ),
        (
            "json.Dockerfile",
            ["/chalk", "exec", "--"],
            ["echo", "hello"],
        ),
    ],
)
def test_wrap_cmd(chalk: Chalk, test_file: str, entrypoint: list[str], cmd: list[str]):
    image_id, result = chalk.docker_build(
        dockerfile=DOCKERFILES / "valid" / "cmd" / test_file,
        context=DOCKERFILES / "valid" / "cmd",
        config=CONFIGS / "docker_wrap.c4m",
    )
    _, output = Docker.run(image_id)
    assert "hello" in output.text
    assert result.mark.has(_IMAGE_ENTRYPOINT=entrypoint, _IMAGE_CMD=cmd)


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
    assert build.mark.contains(
        {
            "_CURRENT_HASH": image_hash,
            "_IMAGE_ID": image_hash,
            "_REPO_TAGS": MISSING,  # not pushed
            "DOCKERFILE_PATH": str(dockerfile),
            "DOCKERFILE_PATH_WITHIN_VCTL": str(
                dockerfile.relative_to(TESTS.parent.parent)
            ),
            # docker tags should be set to tag above
            "DOCKER_TAGS": Contains({f"{tag}:latest"}),
        },
    )

    assert build.vmark.contains({k: IfExists(v) for k, v in build.mark.items()})

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
    _, result = chalk.docker_build(
        dockerfile=dockerfile,
        tag=tag,
        virtual=True,
        expected_success=False,
    )

    assert result.report.has(_OP_EXIT_CODE=result.exit_code)

    # invalid dockerfile should not create any chalk output
    assert not (
        tmp_data_dir / "virtual-chalk.json"
    ).is_file(), "virtual-chalk.json should not have been created!"


@pytest.mark.parametrize(
    "test_file", ["valid/sample_1", "valid/sample_2", "valid/sample_3"]
)
def test_nonvirtual_valid(chalk: Chalk, test_file: str, random_hex: str):
    tag = f"{test_file}_{random_hex}"
    dockerfile = DOCKERFILES / test_file / "Dockerfile"
    image_hash, build = chalk.docker_build(
        dockerfile=dockerfile,
        tag=tag,
        config=CONFIGS / "docker_wrap.c4m",
    )
    assert build.mark.contains(
        {
            "_CURRENT_HASH": image_hash,
            "_IMAGE_ID": image_hash,
            "_REPO_TAGS": MISSING,  # not pushed
            "DOCKERFILE_PATH": str(DOCKERFILES / test_file / "Dockerfile"),
            "DOCKERFILE_PATH_WITHIN_VCTL": str(
                dockerfile.relative_to(TESTS.parent.parent)
            ),
            # docker tags should be set to tag above
            "DOCKER_TAGS": Contains({f"{tag}:latest"}),
        },
    )

    _, result = Docker.run(
        image=image_hash,
        entrypoint="cat",
        params=["chalk.json"],
    )
    chalk_json = ChalkMark(result.json())
    # ensure required keys are present
    assert chalk_json.has(MAGIC=MAGIC, CHALK_VERSION=ANY, CHALK_ID=ANY, METADATA_ID=ANY)
    # ensure all values match with build report
    assert build.mark.contains({k: IfExists(v) for k, v in chalk_json.items()})


@pytest.mark.parametrize("test_file", ["invalid/sample_1", "invalid/sample_2"])
def test_nonvirtual_invalid(chalk: Chalk, test_file: str, random_hex: str):
    tag = f"{test_file}_{random_hex}"
    _, result = chalk.docker_build(
        dockerfile=DOCKERFILES / test_file / "Dockerfile",
        tag=tag,
        expected_success=False,
    )

    assert result.report.has(_OP_EXIT_CODE=result.exit_code, _CHALKS=MISSING)


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
        assert exec_report.mark.contains(heartbeat_report.mark)


def test_postexec(chalk_copy: Chalk):
    chalk_copy.load(CONFIGS / "docker_postexec.c4m", use_embedded=True, replace=False)

    # build dockerfile with chalk docker entrypoint wrapping
    image_id, _ = chalk_copy.docker_build(
        dockerfile=DOCKERFILES / "valid" / "cert" / "Dockerfile",
    )

    _, result = Docker.run(
        image=image_id,
        check=False,
    )
    chalk_result = ChalkProgram.from_program(result)

    postexec_report = chalk_result.reports[-1]
    assert postexec_report["_OPERATION"] == "postexec"
    assert postexec_report.artifacts_by_path.contains(
        {
            "/etc/cert.pem": {
                "_OP_ARTIFACT_TYPE": "x509 Cert",
                "_OP_ARTIFACT_ACCESSED": True,
                "_X509_SUBJECT": {"commonName": "tls.chalk.local"},
            },
            "/etc/ssl/certs/ca-certificates.crt": {
                "_OP_ARTIFACT_TYPE": "x509 Cert",
                "_OP_ARTIFACT_ACCESSED": False,
            },
        }
    )


def test_docker_labels(chalk: Chalk, random_hex: str):
    tag = f"{REGISTRY}/test_image_{random_hex}"

    # build container with env vars
    _, build = chalk.docker_build(
        buildx=True,
        dockerfile=DOCKERFILES / "valid" / "sample_1" / "Dockerfile",
        tag=tag,
        config=CONFIGS / "docker_heartbeat.c4m",
        labels={"foo": "bar"},
        annotations={"hello": "there"},
        push=True,
    )

    assert build.mark.has(
        DOCKER_LABELS={
            "foo": "bar",
            "run.crashoverride.hello": MISSING,  # only known on host-keys
        },
        _IMAGE_LABELS={
            "foo": "bar",
            "run.crashoverride.hello": "CRASH_OVERRIDE_TEST_LABEL",
        },
        DOCKER_ANNOTATIONS={"hello": "there"},
        _IMAGE_ANNOTATIONS={"hello": "there"},
    )

    inspected = Docker.inspect(tag)
    assert len(inspected) == 1

    docker_configs = inspected[0]["Config"]
    assert "Labels" in docker_configs
    labels = docker_configs["Labels"]
    assert "CRASH_OVERRIDE_TEST_LABEL" in labels.values()


@pytest.mark.parametrize(
    "registry, push, buildkit, buildx",
    [
        (REGISTRY, True, True, False),  # non-buildx does not support --push
        (REGISTRY, False, True, False),
        (REGISTRY, False, False, False),
        (REGISTRY_TLS, True, True, False),
        (REGISTRY_TLS_INSECURE, True, True, False),
        (REGISTRY_TLS, True, True, True),
        (REGISTRY_TLS_INSECURE, True, True, True),
    ],
)
@pytest.mark.parametrize(
    "test_file",
    [
        "valid/empty",
    ],
)
@pytest.mark.skipif(
    platform.system() == "Darwin",
    reason="Skipping local docker push on mac due to issues https://github.com/docker/for-mac/issues/6704",
)
def test_build_and_push(
    chalk: Chalk,
    registry: str,
    test_file: str,
    random_hex: str,
    push: bool,
    buildkit: bool,
    buildx: bool,
):
    name = f"{test_file}_{random_hex}"
    tag_base = f"{registry}/{name}"
    tag = f"{tag_base}:latest"
    env = {
        "CI": "true",
        "GITHUB_SHA": "abc",
        # generates BUILD_CONTACT which is a list
        # which can break METADATA_ID computation between build/push
        "GITHUB_ACTOR": "octocat",
    }

    image_id, build_result = chalk.docker_build(
        dockerfile=DOCKERFILES / test_file / "Dockerfile",
        buildkit=buildkit,
        buildx=buildx,
        tag=tag,
        push=push,
        run_docker=buildkit,  # legacy builder doesnt allow to build empty image
        env=env,
    )

    push_result = build_result
    # if without --push at build time, explicitly push to registry
    if not push:
        assert build_result.mark.has(
            _IMAGE_LAYERS=MISSING,
        )
        push_result = chalk.docker_push(tag, buildkit=buildkit, env=env)

    image_digest, _ = Docker.with_image_digest(build_result)

    assert build_result.mark.has(
        CHALK_ID=ANY,
        # primary key needed to associate build+push
        METADATA_ID=ANY,
        METADATA_HASH=ANY,
        _CURRENT_HASH=image_id,
        _IMAGE_ID=image_id,
        DOCKER_TAGS=[tag],
        _REPO_TAGS=(
            {
                registry: {
                    name: {
                        "latest": image_digest,
                    }
                }
            }
            if push
            else MISSING
        ),
        _REPO_DIGESTS=(
            {
                registry: {
                    name: [image_digest],
                }
            }
            if push
            else MISSING
        ),
    )

    assert push_result.mark.has(
        CHALK_ID=build_result.mark["CHALK_ID"],
        METADATA_ID=build_result.mark["METADATA_ID"],
        METADATA_HASH=build_result.mark["METADATA_HASH"],
        _CURRENT_HASH=image_id,
        _IMAGE_ID=image_id,
        _REPO_DIGESTS={
            registry: {
                name: [image_digest],
            }
        },
        _IMAGE_LAYERS=Length(1, operator.ge),
    )

    pull = chalk.docker_pull(tag)
    assert pull.find("Digest:") == f"sha256:{image_digest}"


def test_push_nonchalked(chalk: Chalk, random_hex: str):
    tag_base = f"{REGISTRY}/nonchalked_{random_hex}"
    tag = f"{tag_base}:latest"
    Docker.build(content="FROM alpine", tag=tag)
    push = chalk.docker_push(tag)
    assert push.report.has(
        _OP_EXIT_CODE=0,
        _CHALK_RUN_TIME=ANY,
    )


def test_retagging(chalk: Chalk, random_hex: str):
    name = f"retagged_{random_hex}"
    tag_base = f"{REGISTRY}/{name}"
    tag = f"{tag_base}:foo"
    # this pulls only a single platform
    Docker.pull("alpine")
    Docker.tag("alpine", tag)
    # this pushes only a single platform
    Docker.push(tag)
    local_alpine = Docker.inspect("alpine")[0]["Id"].split(":")[1]
    registry_image = Docker.imagetools_inspect(tag).digest
    hub_alpine = Docker.imagetools_inspect("alpine")
    hub_alpine_list = hub_alpine.digest
    hub_alpine_image = next(
        i["digest"].split(":")[1]
        for i in hub_alpine.json()["manifests"]
        if i["platform"]["architecture"] == "amd64"
    )
    extract = chalk.extract(tag)
    assert hub_alpine_image != registry_image
    assert extract.mark.has(
        _IMAGE_ID=local_alpine,
        _REPO_TAGS={
            "registry-1.docker.io": {
                "library/alpine": {"latest": hub_alpine_list},
            },
            REGISTRY: {
                name: {"foo": registry_image},
            },
        },
        _REPO_DIGESTS={
            "registry-1.docker.io": {
                "library/alpine": [hub_alpine_image],
            },
            REGISTRY: {
                name: [registry_image],
            },
        },
        _REPO_LIST_DIGESTS={
            "registry-1.docker.io": {
                "library/alpine": [hub_alpine_list],
            },
            REGISTRY: IfExists(
                {
                    name: MISSING,
                }
            ),
        },
    )


def test_remanifest(chalk: Chalk, random_hex: str):
    name = f"remanifest_{random_hex}"
    tag_base = f"{REGISTRY}/{name}"
    tag_list1 = "list1"
    tag_list2 = "list2"
    tag_amd64 = "amd64"
    tag_arm64 = "arm64"
    id_amd64, _ = Docker.build(
        content="FROM alpine",
        tag=f"{tag_base}:{tag_amd64}",
        push=True,
        platforms=["linux/amd64"],
    )
    Docker.build(
        content="FROM alpine",
        tag=f"{tag_base}:{tag_arm64}",
        push=True,
        platforms=["linux/arm64"],
    )
    amd64_image = Docker.imagetools_inspect(f"{tag_base}:{tag_amd64}").digest
    arm64_image = Docker.imagetools_inspect(f"{tag_base}:{tag_arm64}").digest
    Docker.manifest_create(
        f"{tag_base}:{tag_list1}",
        f"{tag_base}@sha256:{amd64_image}",
        f"{tag_base}@sha256:{arm64_image}",
    )
    Docker.manifest_create(
        f"{tag_base}:{tag_list2}",
        f"{tag_base}@sha256:{amd64_image}",
    )
    amd64_list1 = Docker.imagetools_inspect(f"{tag_base}:{tag_list1}").digest
    amd64_list2 = Docker.imagetools_inspect(f"{tag_base}:{tag_list2}").digest
    Docker.pull(f"{tag_base}:{tag_list1}", platform="linux/amd64")
    Docker.pull(f"{tag_base}:{tag_list2}", platform="linux/amd64")
    Docker.pull(f"{tag_base}:{tag_amd64}", platform="linux/amd64")
    Docker.inspect(f"{tag_base}:{tag_amd64}")
    extract = chalk.extract(f"{tag_base}:{tag_list1}")
    assert extract.mark.has(
        _IMAGE_ID=id_amd64,
        _REPO_DIGESTS={
            REGISTRY: {
                name: {
                    amd64_image,
                }
            }
        },
        _REPO_LIST_DIGESTS={
            REGISTRY: {
                name: {
                    amd64_list1,
                    amd64_list2,
                }
            }
        },
        _REPO_TAGS={
            REGISTRY: {
                name: {
                    tag_list1: amd64_list1,
                    tag_list2: amd64_list2,
                    tag_amd64: amd64_image,
                }
            }
        },
    )


@pytest.mark.parametrize("test_file", ["valid/sample_1"])
def test_push_without_buildx(
    chalk: Chalk,
    test_file: str,
    random_hex: str,
):
    name = f"{test_file}_{random_hex}"
    tag_base = f"{REGISTRY}/{name}"
    tag = f"{tag_base}:latest"

    image_id, build = chalk.docker_build(
        dockerfile=DOCKERFILES / test_file / "Dockerfile",
        buildkit=False,
        tag=tag,
    )

    # passing `buildkit=False` is not enough since
    # that still allows the use of buildx commands
    # whereas running in isolcated container without
    # buildx being installed we can test push flow
    # without any buildx support
    _, program = Docker.run(
        # this image doesnt have buildx installed
        "docker:19",
        entrypoint="/chalk",
        params=["docker", "push", tag],
        volumes={
            Path("/var/run/docker.sock"): "/var/run/docker.sock",
            chalk.binary: "/chalk",
        },
    )
    push = ChalkProgram.from_program(program)
    image_digest = Docker.inspect(tag_base)[0]["RepoDigests"][0].rsplit(
        ":", maxsplit=1
    )[-1]
    assert push.mark.has(
        CHALK_ID=build.mark["CHALK_ID"],
        # primary key needed to associate build+push
        METADATA_ID=build.mark["METADATA_ID"],
        METADATA_HASH=build.mark["METADATA_HASH"],
        _CURRENT_HASH=image_id,
        _IMAGE_ID=image_id,
        _REPO_DIGESTS={
            REGISTRY: {
                name: [image_digest],
            },
        },
    )


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
def test_multiplatform_build(
    chalk: Chalk,
    test_file: str,
    random_hex: str,
    push: bool,
    server_http: str,
):
    name = f"{test_file}_{random_hex}"
    tag_base = f"{REGISTRY}/{name}"
    tag = f"{tag_base}:latest"
    platforms = {"linux/amd64/v1", "linux/arm64/v8", "linux/arm/v7"}
    target_platforms = {"linux/amd64", "linux/arm64", "linux/arm/v7"}

    image_id, build = chalk.docker_build(
        dockerfile=DOCKERFILES / test_file / "Dockerfile",
        tag=tag_base,
        push=push,
        platforms=list(platforms),
        config=CONFIGS / "docker_wrap.c4m",
        provenance=True,
        sbom=True,
        env={
            # for downloading arm chalk binary
            "CHALK_SERVER": server_http,
            # to isolate downloaded binaries
            "CHALK_TMP": f"/tmp/{random_hex}",
        },
    )

    if not push:
        # as no image is loaded without --push,
        # we cant inspect anything
        for mark in build.marks:
            assert mark.has(_CURRENT_HASH=MISSING, _IMAGE_ID=MISSING)
        return

    assert len(build.marks) == len(platforms)
    assert {i["DOCKER_PLATFORM"] for i in build.marks} == target_platforms

    chalk_ids = {i["CHALK_ID"] for i in build.marks}
    metadata_ids = {i["METADATA_ID"] for i in build.marks}
    hashes = {i["_CURRENT_HASH"] for i in build.marks}
    ids = {i["_IMAGE_ID"] for i in build.marks}
    list_digests = set(
        itertools.chain(*[i["_REPO_LIST_DIGESTS"][REGISTRY][name] for i in build.marks])
    )
    repo_digests = set(
        itertools.chain(*[i["_REPO_DIGESTS"][REGISTRY][name] for i in build.marks])
    )

    assert len(chalk_ids) == 1
    assert len(metadata_ids) == len(platforms)
    assert image_id in hashes
    assert len(ids) == len(platforms)
    assert hashes == ids
    assert len(hashes) == len(platforms)
    assert len(repo_digests) == len(platforms)
    assert len(list_digests) == 1

    for mark in build.marks:
        assert mark.has(
            DOCKER_TAGS=[tag],
            DOCKER_PLATFORMS=target_platforms,
            DOCKER_FILE_CHALKED=Contains(
                {
                    "/$TARGETPLATFORM load /config.json",
                    "/$TARGETPLATFORM version",
                }
            ),
            _IMAGE_ENTRYPOINT=["/chalk", "exec", "--"],
            _IMAGE_SBOM={
                "SPDXID": "SPDXRef-DOCUMENT",
            },
            _IMAGE_PROVENANCE={
                "buildConfig": ANY,
                "invocation": ANY,
                "materials": ANY,
            },
        )


@pytest.mark.slow()
@pytest.mark.parametrize(
    "context, dockerfile, content, private, buildkit",
    [
        # without buildkit
        # note legacy builder defaults to "master" branch so needs to be overwritten
        (
            "https://github.com/crashappsec/chalk-docker-git-context.git#main",
            None,
            None,
            False,
            False,
        ),
        # git scheme
        pytest.param(
            f"git@github.com:{DOCKER_SSH_REPO}.git",
            None,
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
            None,
            False,
            True,
        ),
        # https but dockerfile from stdin
        (
            "https://github.com/crashappsec/chalk-docker-git-context.git",
            None,
            "FROM alpine",
            False,
            True,
        ),
        # with dockerfile path within context
        (
            "https://github.com/crashappsec/chalk-docker-git-context.git",
            "./Dockerfile",
            None,
            False,
            True,
        ),
        # with commit
        (
            "https://github.com/crashappsec/chalk-docker-git-context.git#e488e0f9eaad7eb08c05334454787a7966c39f84",
            None,
            None,
            False,
            True,
        ),
        # with branch
        (
            "https://github.com/crashappsec/chalk-docker-git-context.git#main",
            None,
            None,
            False,
            True,
        ),
        # with tag
        (
            "https://github.com/crashappsec/chalk-docker-git-context.git#1-annotated",
            None,
            None,
            False,
            True,
        ),
        # with branch and nested folder for context
        (
            "https://github.com/crashappsec/chalk-docker-git-context.git#main:nested",
            None,
            None,
            False,
            True,
        ),
        # with PR ref
        (
            "https://github.com/crashappsec/chalk-docker-git-context.git#refs/pull/1/merge",
            None,
            None,
            False,
            True,
        ),
        # with tag ref
        (
            "https://github.com/crashappsec/chalk-docker-git-context.git#refs/tags/1-annotated",
            None,
            None,
            False,
            True,
        ),
        # private repo
        (
            f"https://github.com/{DOCKER_TOKEN_REPO}.git",
            None,
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
    content: Optional[str],
    private: bool,
    buildkit: bool,
    tmp_file: Path,
    random_hex: str,
):
    tmp_file.write_text(os.environ["GITHUB_TOKEN"])
    remote = context.split("#")[0]

    _, build = chalk.docker_build(
        context=context,
        dockerfile=dockerfile,
        content=content,
        tag=random_hex,
        secrets={"GIT_AUTH_TOKEN": tmp_file} if private else {},
        buildkit=buildkit,
    )
    assert build.mark.has(
        ORIGIN_URI=remote,
        DOCKERFILE_PATH=":stdin:" if content else MISSING,
        DOCKERFILE_PATH_WITHIN_VCTL=(
            (dockerfile or "Dockerfile") if not content else MISSING
        ),
        COMMIT_ID=ANY,
    )


# extract on image id, and image name, running container id + container name, exited container id + container name
def test_extract(chalk: Chalk, random_hex: str):
    tag = f"test_image_{random_hex}"
    container_name = f"test_container_{random_hex}"

    # build test image
    image_id, _ = chalk.docker_build(
        dockerfile=DOCKERFILES / "valid" / "sample_1" / "Dockerfile",
        tag=tag,
    )

    # extract chalk from image id and image name
    extract_by_name = chalk.extract(tag)
    assert extract_by_name.report.contains(
        {
            "_OPERATION": "extract",
            "_OP_EXE_NAME": chalk.binary.name,
            "_OP_UNMARKED_COUNT": 0,
            "_OP_CHALK_COUNT": 1,
        }
    )
    assert extract_by_name.mark.contains(
        {
            "_OP_ARTIFACT_TYPE": "Docker Image",
            "_IMAGE_ID": image_id,
            "_CURRENT_HASH": image_id,
            "_REPO_TAGS": MISSING,
        }
    )

    extract_by_id = chalk.extract(image_id[:12])
    assert extract_by_id.report.contains(extract_by_name.report.deterministic())

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

    # extract on container name and validate
    extract_container_name = chalk.extract(container_name)
    assert extract_container_name.report.contains(
        {
            "_OPERATION": "extract",
            "_OP_EXE_NAME": chalk.binary.name,
            "_OP_UNMARKED_COUNT": 0,
            "_OP_CHALK_COUNT": 1,
        }
    )
    assert extract_container_name.mark.contains(
        {
            "_OP_ARTIFACT_TYPE": "Docker Container",
            "_IMAGE_ID": image_id,
            "_CURRENT_HASH": container_id,
            "_INSTANCE_CONTAINER_ID": container_id,
            "_INSTANCE_NAME": container_name,
            "_INSTANCE_STATUS": "running",
        }
    )

    # extract on container id and validate
    extract_container_id = chalk.extract(container_id)
    assert extract_container_id.report.contains(
        extract_container_name.report.deterministic()
    )

    # shut down container
    Docker.stop_containers([container_name])

    # extract on container name and container id now that container is stopped
    extract_container_name_stopped = chalk.extract(container_name)
    assert extract_container_name_stopped.report.contains(
        {
            "_OPERATION": "extract",
            "_OP_EXE_NAME": chalk.binary.name,
            "_OP_UNMARKED_COUNT": 0,
            "_OP_CHALK_COUNT": 1,
        }
    )
    assert extract_container_name_stopped.mark.contains(
        {
            "_OP_ARTIFACT_TYPE": "Docker Container",
            "_IMAGE_ID": image_id,
            "_CURRENT_HASH": container_id,
            "_INSTANCE_CONTAINER_ID": container_id,
            "_INSTANCE_NAME": container_name,
            "_INSTANCE_STATUS": "exited",
        }
    )

    extract_container_id_stopped = chalk.extract(container_id)
    assert extract_container_id_stopped.report.contains(
        extract_container_name_stopped.report.deterministic()
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


def test_version_bare(chalk_default: Chalk):
    """
    Runs in empty container which tests chalk has no external startup deps
    """
    image_id, build = Docker.build(
        dockerfile=DOCKERFILES / "valid" / "empty" / "Dockerfile",
    )
    assert build
    _, run = Docker.run(
        image_id,
        volumes={chalk_default.binary: "/chalk"},
        entrypoint="/chalk",
        params=["version"],
    )
    assert run

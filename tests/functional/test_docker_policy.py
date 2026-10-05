# Copyright (c) 2026, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import json
import subprocess
from pathlib import Path

import pytest
import requests

from .chalk.runner import Chalk
from .conf import CONFIGS, REGISTRY
from .utils.docker import Docker
from .utils.dict import ANY, MISSING, Contains, ContainsDict


def report_file(random_hex: str) -> Path:
    return Path(f"/tmp/policy-{random_hex}.jsonl")


def policy_reports(random_hex: str) -> list[ContainsDict]:
    path = report_file(random_hex)
    if not path.exists():
        return []
    reports = []
    for line in path.read_text().splitlines():
        if line.strip():
            reports += [ContainsDict(i) for i in json.loads(line)]
    return reports


def image_exists(tag: str) -> bool:
    return (
        subprocess.run(
            ["docker", "image", "inspect", tag], capture_output=True
        ).returncode
        == 0
    )


def registry_tags(name: str) -> list[str]:
    response = requests.get(f"http://{REGISTRY}/v2/{name}/tags/list")
    if response.status_code == 404:
        return []
    response.raise_for_status()
    return response.json().get("tags") or []


def policy_env(mode: str, random_hex: str) -> dict[str, str]:
    return {"POLICY_MODE": mode, "POLICY_REPORT_FILE": str(report_file(random_hex))}


def build(chalk: Chalk, content: str, mode: str, random_hex: str, **kwargs):
    return chalk.docker_build(
        content=Docker.dockerfile(content),
        config=CONFIGS / "policy.c4m",
        env={**policy_env(mode, random_hex), **kwargs.pop("env", {})},
        # vanilla docker would succeed where chalk is expected to block
        run_docker=False,
        **kwargs,
    )


def test_enforce_blocks_base_image(chalk: Chalk, random_hex: str):
    _, result = build(
        chalk,
        "FROM busybox\nCMD true\n",
        "enforce",
        random_hex,
        tag=random_hex,
        expected_success=False,
    )
    assert result.exit_code == 1
    assert not image_exists(random_hex)
    (report,) = policy_reports(random_hex)
    assert len(report["_POLICY_FINDINGS"]) == 1
    assert report.contains(
        {
            "_POLICY_MODE": "enforce",
            "_POLICY_RESULT": "blocked",
            "_OP_EXIT_CODE": 1,
            "_POLICY_BUILD": {"command": "build", "tags": [f"{random_hex}:latest"]},
            "_POLICY_FINDINGS": Contains(
                [
                    {
                        "rule": "golden_images",
                        "kind": "violation",
                        "image": "busybox",
                        "digest": ANY,
                        "source": "from",
                        "reason": "image is not in the list of allowed golden images. Use an approved golden image",
                    }
                ]
            ),
        }
    )


def test_enforce_allows_golden_image(chalk: Chalk, random_hex: str):
    _, result = build(
        chalk, "FROM alpine\nCMD true\n", "enforce", random_hex, tag=random_hex
    )
    assert result.exit_code == 0
    assert image_exists(random_hex)
    assert policy_reports(random_hex) == []


def test_audit_reports_without_blocking(chalk: Chalk, random_hex: str):
    _, result = build(
        chalk, "FROM busybox\nCMD true\n", "audit", random_hex, tag=random_hex
    )
    assert result.exit_code == 0
    assert image_exists(random_hex)
    (report,) = policy_reports(random_hex)
    assert report.has(_POLICY_MODE="audit", _POLICY_RESULT="violation", _OP_EXIT_CODE=0)


def test_mode_off(chalk: Chalk, random_hex: str):
    _, result = build(
        chalk, "FROM busybox\nCMD true\n", "off", random_hex, tag=random_hex
    )
    assert result.exit_code == 0
    assert policy_reports(random_hex) == []


def test_disabled_by_default(chalk: Chalk, random_hex: str):
    # default test config has no policy section at all
    _, result = chalk.docker_build(
        content=Docker.dockerfile("FROM busybox\nCMD true\n"),
        tag=random_hex,
        run_docker=False,
    )
    assert result.exit_code == 0
    assert image_exists(random_hex)
    assert result.report.has(
        _POLICY_MODE=MISSING,
        _POLICY_RESULT=MISSING,
        _POLICY_FINDINGS=MISSING,
        _POLICY_BUILD=MISSING,
    )
    assert not any("policy" in e for e in result.errors)


def test_partial_config_uses_defaults(chalk: Chalk, random_hex: str):
    _, result = chalk.docker_build(
        content=Docker.dockerfile("FROM alpine:latest\nCMD true\n"),
        tag=random_hex,
        config=CONFIGS / "policy_custom_only.c4m",
        env=policy_env("enforce", random_hex),
        run_docker=False,
        expected_success=False,
    )
    assert result.exit_code == 1
    (report,) = policy_reports(random_hex)
    # golden_images is not configured so only the custom check runs
    assert len(report["_POLICY_FINDINGS"]) == 1
    assert report.has(
        _POLICY_RESULT="blocked",
        _POLICY_FINDINGS=Contains(
            [{"rule": "custom_check", "kind": "violation", "image": "alpine:latest"}]
        ),
    )


def test_enforce_multi_stage_and_copy_from(chalk: Chalk, random_hex: str):
    _, result = build(
        chalk,
        """
        FROM alpine AS base
        FROM base
        COPY --from=busybox /bin/busybox /busybox
        COPY --from=base /etc/os-release /os-release
        """,
        "enforce",
        random_hex,
        tag=random_hex,
        expected_success=False,
    )
    assert result.exit_code == 1
    (report,) = policy_reports(random_hex)
    assert len(report["_POLICY_FINDINGS"]) == 1
    assert report.has(
        _POLICY_FINDINGS=Contains(
            [{"image": "busybox", "source": "copy_from", "kind": "violation"}]
        )
    )


def test_enforce_custom_check(chalk: Chalk, random_hex: str):
    _, result = build(
        chalk,
        "FROM alpine\nCMD true\n",
        "enforce",
        random_hex,
        tag=random_hex,
        expected_success=False,
        env={"POLICY_CUSTOM_DENY": "alpine"},
    )
    assert result.exit_code == 1
    (report,) = policy_reports(random_hex)
    assert len(report["_POLICY_FINDINGS"]) == 1
    assert report.has(
        _POLICY_FINDINGS=Contains(
            [
                {
                    "rule": "custom_check",
                    "kind": "violation",
                    "reason": "denied by custom check",
                }
            ]
        )
    )


def test_enforce_blocks_build_push(chalk: Chalk, random_hex: str, tmp_data_dir):
    tag = f"{REGISTRY}/{random_hex}"
    # run chalk directly as docker_build inspects the pushed image afterwards
    result = chalk.run(
        params=[
            "docker",
            "buildx",
            "build",
            "--push",
            "-t",
            tag,
            "-f",
            "-",
            str(tmp_data_dir),
        ],
        stdin=b"FROM busybox\nCMD true\n",
        config=CONFIGS / "policy.c4m",
        env=policy_env("enforce", random_hex),
        expected_success=False,
    )
    assert result.exit_code == 1
    assert registry_tags(random_hex) == []


@pytest.mark.parametrize(
    "base, expected_exit, pushed",
    [
        ("busybox", 1, False),
        ("alpine", 0, True),
    ],
)
def test_enforce_docker_push(
    chalk: Chalk, random_hex: str, base: str, expected_exit: int, pushed: bool
):
    tag = f"{REGISTRY}/{random_hex}"
    # build in mode off so the image is chalked with its base images
    build(chalk, f"FROM {base}\nCMD true\n", "off", random_hex, tag=tag)
    _, result = chalk.docker_push(
        tag,
        config=CONFIGS / "policy.c4m",
        env=policy_env("enforce", random_hex),
        ignore_errors=True,
        expected_success=expected_exit == 0,
    )
    assert result.exit_code == expected_exit
    assert (registry_tags(random_hex) != []) == pushed

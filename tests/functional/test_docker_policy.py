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
    # a report of its own: fresh _ACTION_ID, correlated with the build report
    # via BUILD_URI/_POLICY_BUILD rather than by sharing the id
    assert report["_ACTION_ID"] != result.report["_ACTION_ID"]
    assert report.has(_POLICY_BUILD=Contains({"tags": [f"{random_hex}:latest"]}))


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


@pytest.mark.parametrize("source", ["from", "copy_from"])
def test_enforce_blocks_named_image_context(chalk: Chalk, random_hex: str, source: str):
    content = (
        "FROM external\nCMD true\n"
        if source == "from"
        else "FROM scratch\nCOPY --from=external /bin/busybox /busybox\n"
    )
    _, result = build(
        chalk,
        content,
        "enforce",
        random_hex,
        tag=random_hex,
        named_contexts={"external": "docker-image://busybox:latest"},
        buildx=True,
        expected_success=False,
    )
    assert result.exit_code == 1
    assert not image_exists(random_hex)
    (report,) = policy_reports(random_hex)
    assert report.has(
        _POLICY_RESULT="blocked",
        _POLICY_FINDINGS=Contains(
            [{"image": "busybox:latest", "source": source, "kind": "violation"}]
        ),
    )


@pytest.mark.parametrize("reference", ["alpine:latest", "docker.io/library/alpine"])
def test_enforce_blocks_context_by_familiar_name(
    chalk: Chalk, random_hex: str, reference: str
):
    # BuildKit resolves both spellings to the "alpine" context, not to alpine
    _, result = build(
        chalk,
        f"FROM scratch\nCOPY --from={reference} /bin/busybox /busybox\n",
        "enforce",
        random_hex,
        tag=random_hex,
        named_contexts={"alpine": "docker-image://busybox:latest"},
        buildx=True,
        expected_success=False,
    )
    assert result.exit_code == 1
    assert not image_exists(random_hex)
    (report,) = policy_reports(random_hex)
    assert report.has(
        _POLICY_FINDINGS=Contains(
            [{"image": "busybox:latest", "source": "copy_from", "kind": "violation"}]
        )
    )


def test_enforce_blocks_forward_stage_name(chalk: Chalk, random_hex: str):
    # FROM only resolves earlier stages, so the target builds on the busybox image
    _, result = build(
        chalk,
        "FROM busybox AS first\nFROM alpine AS busybox\nFROM first\nCMD true\n",
        "enforce",
        random_hex,
        tag=random_hex,
        expected_success=False,
    )
    assert result.exit_code == 1
    (report,) = policy_reports(random_hex)
    assert report.has(
        _POLICY_FINDINGS=Contains(
            [{"image": "busybox", "source": "from", "kind": "violation"}]
        )
    )


def test_unbuilt_stage_is_not_checked(chalk: Chalk, random_hex: str):
    # BuildKit never pulls a stage the target does not depend on
    _, result = build(
        chalk,
        "FROM busybox AS debug\nFROM alpine\nCMD true\n",
        "enforce",
        random_hex,
        tag=random_hex,
    )
    assert result.exit_code == 0
    assert image_exists(random_hex)
    assert policy_reports(random_hex) == []


def test_enforce_blocks_stage_used_by_run_mount(chalk: Chalk, random_hex: str):
    _, result = build(
        chalk,
        "FROM busybox AS tools\nFROM alpine\n"
        "RUN --mount=type=bind,from=tools,target=/tools true\n",
        "enforce",
        random_hex,
        tag=random_hex,
        expected_success=False,
    )
    assert result.exit_code == 1
    (report,) = policy_reports(random_hex)
    assert report.has(
        _POLICY_FINDINGS=Contains(
            [{"image": "busybox", "source": "from", "kind": "violation"}]
        )
    )


def test_enforce_blocks_image_used_by_run_mount(chalk: Chalk, random_hex: str):
    _, result = build(
        chalk,
        "FROM alpine\nRUN --mount=type=bind,from=busybox,target=/tools true\n",
        "enforce",
        random_hex,
        tag=random_hex,
        expected_success=False,
    )
    assert result.exit_code == 1
    assert not image_exists(random_hex)
    (report,) = policy_reports(random_hex)
    assert report.has(
        _POLICY_FINDINGS=Contains(
            [{"image": "busybox", "source": "mount_from", "kind": "violation"}]
        )
    )


def test_mounted_image_is_checked_again_on_push(chalk: Chalk, random_hex: str):
    tag = f"{REGISTRY}/{random_hex}"
    build(
        chalk,
        "FROM alpine\nRUN --mount=from=busybox:latest,target=/tools true\n",
        "audit",
        random_hex,
        tag=random_hex,
    )
    subprocess.run(["docker", "tag", random_hex, tag], check=True)
    # Keep only the push report for this assertion.
    report_file(random_hex).write_text("")
    result = chalk.run(
        params=["docker", "push", tag],
        config=CONFIGS / "policy.c4m",
        env=policy_env("enforce", random_hex),
        expected_success=False,
    )
    assert result.exit_code == 1
    assert registry_tags(random_hex) == []
    (report,) = policy_reports(random_hex)
    assert report.has(
        _POLICY_FINDINGS=Contains(
            [{"image": "busybox:latest", "source": "mount_from", "kind": "violation"}]
        ),
    )


@pytest.mark.parametrize(
    "mode,on_error,result_kind",
    [
        ("enforce", "block", "blocked"),
        ("enforce", "allow", "error"),
        ("audit", "block", "error"),
    ],
)
def test_failure_before_evaluation_honors_on_error(
    chalk: Chalk, random_hex: str, mode: str, on_error: str, result_kind: str
):
    # chalk cannot evaluate FROM, which used to rerun docker unchecked
    _, result = build(
        chalk,
        "ARG BASE\nFROM ${BASE}\nCMD true\n",
        mode,
        random_hex,
        tag=random_hex,
        env={"POLICY_ON_ERROR": on_error},
        expected_success=False,
    )
    assert result.exit_code != 0
    if result_kind == "blocked":
        assert result.exit_code == 1
        assert "retrying without chalk" not in result.logs
    else:
        assert "retrying without chalk" in result.logs
    (report,) = policy_reports(random_hex)
    assert report.has(
        _POLICY_RESULT=result_kind,
        _POLICY_FINDINGS=Contains(
            [{"rule": "golden_images", "kind": "error", "reason": ANY}]
        ),
    )


def test_blocked_build_does_not_chalk_context(
    chalk: Chalk, random_hex: str, tmp_data_dir: Path
):
    # policies run before chalk_contained_items marks the context
    (tmp_data_dir / "Dockerfile").write_text("FROM busybox\nCMD true\n")
    script = tmp_data_dir / "script.sh"
    script.write_text("#!/bin/sh\necho hello\n")
    config = tmp_data_dir / "subchalk.c4m"
    config.write_text(
        (CONFIGS / "policy.c4m").read_text() + "\nchalk_contained_items = true\n"
    )
    _, result = chalk.docker_build(
        dockerfile=tmp_data_dir / "Dockerfile",
        context=tmp_data_dir,
        tag=random_hex,
        config=config,
        env=policy_env("enforce", random_hex),
        run_docker=False,
        expected_success=False,
    )
    assert result.exit_code == 1
    assert "CHALK_ID" not in script.read_text()


def test_large_numeric_copy_reference_is_checked(chalk: Chalk, random_hex: str):
    image = "999999999999999999999999999999"
    _, result = build(
        chalk,
        f"FROM scratch\nCOPY --from={image} /bin/x /x\n",
        "enforce",
        random_hex,
        tag=random_hex,
        expected_success=False,
    )
    assert result.exit_code == 1
    assert "retrying without chalk" not in result.logs
    (report,) = policy_reports(random_hex)
    assert report.has(
        _POLICY_FINDINGS=Contains(
            [{"image": image, "kind": "violation", "source": "copy_from"}]
        )
    )


def test_enforce_push_checks_all_tags(chalk: Chalk, random_hex: str):
    repo = f"{REGISTRY}/{random_hex}"
    for base, tag in [("alpine", "latest"), ("busybox", "other")]:
        local = f"{random_hex}-{tag}"
        build(chalk, f"FROM {base}\nCMD true\n", "off", random_hex, tag=local)
        subprocess.run(["docker", "tag", local, f"{repo}:{tag}"], check=True)
    result = chalk.run(
        params=["docker", "push", "--all-tags", repo],
        config=CONFIGS / "policy.c4m",
        env=policy_env("enforce", random_hex),
        expected_success=False,
    )
    assert result.exit_code == 1
    assert registry_tags(random_hex) == []
    (report,) = policy_reports(random_hex)
    assert report.has(
        _POLICY_RESULT="blocked",
        _POLICY_BUILD={
            "command": "push",
            "tags": Contains([f"{repo}:latest", f"{repo}:other"]),
        },
        _POLICY_FINDINGS=Contains([{"image": ANY, "kind": "violation"}]),
    )


def test_named_image_context_is_checked_again_on_push(chalk: Chalk, random_hex: str):
    tag = f"{REGISTRY}/{random_hex}"
    build(
        chalk,
        "FROM scratch\nCOPY --from=external /bin/busybox /busybox\n",
        "audit",
        random_hex,
        tag=random_hex,
        named_contexts={"external": "docker-image://busybox:latest"},
        buildx=True,
    )
    subprocess.run(["docker", "tag", random_hex, tag], check=True)
    # Keep only the push report for this assertion.
    report_file(random_hex).write_text("")
    result = chalk.run(
        params=["docker", "push", tag],
        config=CONFIGS / "policy.c4m",
        env=policy_env("enforce", random_hex),
        expected_success=False,
    )
    assert result.exit_code == 1
    assert registry_tags(random_hex) == []
    (report,) = policy_reports(random_hex)
    assert report.has(
        _POLICY_RESULT="blocked",
        _POLICY_FINDINGS=Contains(
            [{"image": "busybox:latest", "source": "copy_from", "kind": "violation"}]
        ),
    )


@pytest.mark.parametrize(
    "mode,on_error,result_kind",
    [
        ("enforce", "block", "blocked"),
        ("enforce", "allow", "error"),
        ("audit", "block", "error"),
    ],
)
def test_subject_collection_errors_honor_configuration(
    chalk: Chalk, random_hex: str, mode: str, on_error: str, result_kind: str
):
    _, result = build(
        chalk,
        "FROM scratch\nCOPY --from=external /x /x\n",
        mode,
        random_hex,
        tag=random_hex,
        named_contexts={"external": "docker-image://"},
        buildx=True,
        env={"POLICY_ON_ERROR": on_error},
        expected_success=False,
    )
    assert result.exit_code != 0
    if result_kind == "blocked":
        assert result.exit_code == 1
        assert "retrying without chalk" not in result.logs
    (report,) = policy_reports(random_hex)
    assert report.has(
        _POLICY_RESULT=result_kind,
        _POLICY_FINDINGS=Contains(
            [{"rule": "golden_images", "kind": "error", "reason": ANY}]
        ),
    )


@pytest.mark.parametrize("source", ["from", "copy_from"])
def test_enforce_allows_named_image_context(chalk: Chalk, random_hex: str, source: str):
    content = (
        "FROM external\nCMD true\n"
        if source == "from"
        else "FROM scratch\nCOPY --from=external /etc/os-release /os-release\n"
    )
    _, result = build(
        chalk,
        content,
        "enforce",
        random_hex,
        tag=random_hex,
        buildx=True,
        named_contexts={"external": "docker-image://alpine:latest"},
    )
    assert result.exit_code == 0
    assert image_exists(random_hex)
    assert policy_reports(random_hex) == []


# same document an external policy authoring system produces (shared with unit tests)
POLICY_CONFIG = Path(__file__).parents[1] / "unit" / "fixtures" / "policy_config.json"
# enforced golden-images@3 plus audited chainguard-only@1
POLICY_CONFIG_MULTI = POLICY_CONFIG.with_name("policy_config_multi.json")


def build_json(chalk: Chalk, content: str, config_json: str, random_hex: str, **kwargs):
    return chalk.docker_build(
        content=Docker.dockerfile(content),
        config=CONFIGS / "policy_json.c4m",
        env={
            "POLICY_CONFIG_JSON": config_json,
            "POLICY_REPORT_FILE": str(report_file(random_hex)),
        },
        run_docker=False,
        **kwargs,
    )


def test_config_json_enforces(chalk: Chalk, random_hex: str):
    _, result = build_json(
        chalk,
        "FROM busybox\nCMD true\n",
        POLICY_CONFIG.read_text(),
        random_hex,
        tag=random_hex,
        expected_success=False,
    )
    assert result.exit_code == 1
    assert not image_exists(random_hex)
    (report,) = policy_reports(random_hex)
    assert report.has(
        _POLICY_ID="golden-images@3",
        _POLICY_MODE="enforce",
        _POLICY_RESULT="blocked",
    )
    assert report["_POLICY_RESULTS"] == [
        {
            "id": "golden-images@3",
            "mode": "enforce",
            "on_error": "allow",
            "result": "blocked",
        }
    ]
    assert report["_POLICY_FINDINGS"][0]["policy_id"] == "golden-images@3"


def test_config_json_allows_golden_image(chalk: Chalk, random_hex: str):
    _, result = build_json(
        chalk,
        "FROM alpine\nCMD true\n",
        POLICY_CONFIG.read_text(),
        random_hex,
        tag=random_hex,
    )
    assert result.exit_code == 0
    assert image_exists(random_hex)
    assert policy_reports(random_hex) == []


def test_config_json_invalid_never_blocks(chalk: Chalk, random_hex: str):
    config = json.loads(POLICY_CONFIG.read_text())
    config["on_error"] = "block"
    config["golden_images"]["enabled"] = "yes"
    _, result = build_json(
        chalk,
        "FROM busybox\nCMD true\n",
        json.dumps(config),
        random_hex,
        tag=random_hex,
        # the broken configuration is logged as an error
        ignore_errors=True,
    )
    assert result.exit_code == 0
    assert image_exists(random_hex)
    (report,) = policy_reports(random_hex)
    assert report.has(_POLICY_RESULT="error", _POLICY_ID=MISSING)
    assert report.contains(
        {
            "_POLICY_FINDINGS": [
                {
                    "rule": "config",
                    "kind": "error",
                    "reason": ANY,
                }
            ]
        }
    )
    assert "policy.golden_images.enabled" in report["_POLICY_FINDINGS"][0]["reason"]


def test_config_json_multi_audit_violation_does_not_block(
    chalk: Chalk, random_hex: str
):
    _, result = build_json(
        chalk,
        "FROM alpine\nCMD true\n",
        POLICY_CONFIG_MULTI.read_text(),
        random_hex,
        tag=random_hex,
    )
    assert result.exit_code == 0
    assert image_exists(random_hex)
    (report,) = policy_reports(random_hex)
    assert report.has(
        _POLICY_ID=MISSING,
        _POLICY_MODE="enforce",
        _POLICY_RESULT="violation",
    )
    assert report["_POLICY_RESULTS"] == [
        {
            "id": "golden-images@3",
            "mode": "enforce",
            "on_error": "allow",
            "result": "pass",
        },
        {
            "id": "chainguard-only@1",
            "mode": "audit",
            "on_error": "block",
            "result": "violation",
        },
    ]
    assert report.contains(
        {
            "_POLICY_FINDINGS": [
                {
                    "policy_id": "chainguard-only@1",
                    "rule": "golden_images",
                    "kind": "violation",
                    "image": "alpine",
                }
            ]
        }
    )


def test_config_json_multi_enforced_violation_blocks(chalk: Chalk, random_hex: str):
    _, result = build_json(
        chalk,
        "FROM busybox\nCMD true\n",
        POLICY_CONFIG_MULTI.read_text(),
        random_hex,
        tag=random_hex,
        expected_success=False,
    )
    assert result.exit_code == 1
    assert not image_exists(random_hex)
    (report,) = policy_reports(random_hex)
    assert report.has(_POLICY_ID=MISSING, _POLICY_RESULT="blocked")
    assert [(r["id"], r["result"]) for r in report["_POLICY_RESULTS"]] == [
        ("golden-images@3", "blocked"),
        ("chainguard-only@1", "violation"),
    ]
    assert [(f["policy_id"], f["kind"]) for f in report["_POLICY_FINDINGS"]] == [
        ("golden-images@3", "violation"),
        ("chainguard-only@1", "violation"),
    ]


def test_config_json_multi_invalid_entry_is_isolated(chalk: Chalk, random_hex: str):
    config = json.loads(POLICY_CONFIG_MULTI.read_text())
    config["policies"][1]["golden_images"]["enabled"] = "yes"
    _, result = build_json(
        chalk,
        "FROM busybox\nCMD true\n",
        json.dumps(config),
        random_hex,
        tag=random_hex,
        expected_success=False,
    )
    # the valid policy still blocks
    assert result.exit_code == 1
    (report,) = policy_reports(random_hex)
    assert [(r["id"], r["result"]) for r in report["_POLICY_RESULTS"]] == [
        ("golden-images@3", "blocked"),
        ("chainguard-only@1", "error"),
    ]
    assert report.contains(
        {
            "_POLICY_FINDINGS": [
                {"policy_id": "golden-images@3", "kind": "violation"},
                {"policy_id": "chainguard-only@1", "rule": "config", "kind": "error"},
            ]
        }
    )

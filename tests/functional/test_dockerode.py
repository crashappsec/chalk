# Copyright (c) 2026, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)

import json
import os
import sys
from pathlib import Path

import pytest

from .chalk.runner import Chalk
from .utils.os import run


@pytest.mark.parametrize(
    "configured_timeout,expected_timeout",
    [(None, "300000"), ("1234", "1234")],
)
def test_dockerode_public_command_lifecycle(
    chalk_default: Chalk,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    configured_timeout: str | None,
    expected_timeout: str,
):
    state = tmp_path / "child-state"
    monkeypatch.setenv("NODE_OPTIONS", "--trace-warnings")
    monkeypatch.setenv("CHALK_DOCKERODE_CHALK", "prior-chalk")
    monkeypatch.setenv("CHALK_DOCKERODE_NO_EXTERNAL_CONFIG", "prior-config")
    if configured_timeout is None:
        monkeypatch.delenv("CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS", raising=False)
    else:
        monkeypatch.setenv("CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS", configured_timeout)

    script = r"""
import json
import os
from pathlib import Path
import re
import stat
import sys

match = re.search(r'--require="([^"]+)"', os.environ['NODE_OPTIONS'])
assert match
register = Path(match.group(1))
loader = register.parent
state = {
    'timeout': os.environ['CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS'],
    'chalk': os.environ['CHALK_DOCKERODE_CHALK'],
    'node_options': os.environ['NODE_OPTIONS'],
    'loader': str(loader),
    'dir_mode': stat.S_IMODE(loader.stat().st_mode),
    'register_mode': stat.S_IMODE(register.stat().st_mode),
    'file_count': len(list(loader.iterdir())),
    'forwarded': sys.argv[1],
}
Path(sys.argv[2]).write_text(json.dumps(state))
raise SystemExit(7)
"""
    result = run(
        [
            str(chalk_default.binary),
            "--no-use-external-config",
            "dockerode",
            "--",
            sys.executable,
            "-c",
            script,
            "argument with spaces",
            str(state),
        ],
        expected_exit_code=7,
    )

    values = json.loads(state.read_text())
    loader = Path(values["loader"])
    assert result.exit_code == 7
    assert values["timeout"] == expected_timeout
    assert values["chalk"] == str(chalk_default.binary)
    assert values["node_options"].startswith("--trace-warnings --require=")
    assert values["dir_mode"] == 0o700
    assert values["register_mode"] == 0o600
    assert values["file_count"] == 4
    assert values["forwarded"] == "argument with spaces"
    assert not loader.exists()

    assert os.environ["NODE_OPTIONS"] == "--trace-warnings"
    assert os.environ["CHALK_DOCKERODE_CHALK"] == "prior-chalk"
    assert os.environ["CHALK_DOCKERODE_NO_EXTERNAL_CONFIG"] == "prior-config"
    if configured_timeout is None:
        assert "CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS" not in os.environ
    else:
        assert os.environ["CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS"] == configured_timeout


def test_dockerode_is_public_and_handoff_remains_private(chalk_default: Chalk):
    help_result = run(
        [
            str(chalk_default.binary),
            "--no-use-external-config",
            "help",
            "commands",
        ],
    )
    assert "dockerode" in help_result.text

    malformed = run(
        [
            str(chalk_default.binary),
            "--no-use-external-config",
            "__",
            "docker_post_push",
        ],
        stdin=b"not-json",
        expected_exit_code=2,
    )
    assert "chalk-docker-post-push-result" not in malformed.text

    unsupported_auth = run(
        [
            str(chalk_default.binary),
            "--no-use-external-config",
            "__",
            "docker_post_push",
        ],
        stdin=json.dumps(
            {
                "schema": "chalk-docker-post-push/v1",
                "operationId": "operation-1",
                "repository": "example.invalid/team/app",
                "tag": "latest",
                "digest": "sha256:" + "a" * 64,
                "socketPath": "/var/run/docker.sock",
                "authconfig": {"username": "user"},
            }
        ).encode(),
        expected_exit_code=2,
    )
    assert json.loads(unsupported_auth.text) == {
        "schema": "chalk-docker-post-push-result/v1",
        "status": "unsupported_auth",
        "operationId": "operation-1",
    }

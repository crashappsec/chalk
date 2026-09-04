# Copyright (c) 2026, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)

import json
import os
import shutil
import sys
from pathlib import Path

import pytest

from .chalk.runner import Chalk
from .utils.os import run


@pytest.mark.parametrize(
    "configured_timeout,expected_timeout",
    [(None, None), ("1234", "1234")],
)
def test_dockerode_public_command_lifecycle(
    chalk_default: Chalk,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    configured_timeout: str | None,
    expected_timeout: str | None,
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
requires = sorted({
    specifier
    for loader_file in loader.iterdir()
    for specifier in re.findall(
        r'''require\s*\(\s*["']([^"']+)["']\s*\)''',
        loader_file.read_text(),
    )
})
state = {
    'timeout': os.environ.get('CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS'),
    'chalk': os.environ['CHALK_DOCKERODE_CHALK'],
    'no_external_config': os.environ.get('CHALK_DOCKERODE_NO_EXTERNAL_CONFIG'),
    'node_options': os.environ['NODE_OPTIONS'],
    'loader': str(loader),
    'dir_mode': stat.S_IMODE(loader.stat().st_mode),
    'register_mode': stat.S_IMODE(register.stat().st_mode),
    'file_count': len(list(loader.iterdir())),
    'requires': requires,
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
    assert values["no_external_config"] == "1"
    assert values["node_options"].startswith("--trace-warnings --require=")
    assert values["dir_mode"] == 0o700
    assert values["register_mode"] == 0o600
    assert values["file_count"] == 4
    assert values["requires"] == [
        "./node_support.cjs",
        "./register_impl.cjs",
        "./runtime.cjs",
        "node:child_process",
        "node:crypto",
        "node:fs",
        "node:module",
        "node:path",
        "node:stream",
        "node:url",
    ]
    assert values["forwarded"] == "argument with spaces"
    assert not loader.exists()

    assert os.environ["NODE_OPTIONS"] == "--trace-warnings"
    assert os.environ["CHALK_DOCKERODE_CHALK"] == "prior-chalk"
    assert os.environ["CHALK_DOCKERODE_NO_EXTERNAL_CONFIG"] == "prior-config"
    if configured_timeout is None:
        assert "CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS" not in os.environ
    else:
        assert os.environ["CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS"] == configured_timeout


def _write_npm_dockerode_fixture(root: Path) -> None:
    dockerode = root / "node_modules" / "dockerode"
    dockerode.mkdir(parents=True)
    (root / "package.json").write_text(
        json.dumps(
            {
                "private": True,
                "scripts": {"publish": "node publish.cjs"},
            }
        )
    )
    (dockerode / "package.json").write_text(
        json.dumps({"name": "dockerode", "version": "3.3.5"})
    )
    (dockerode / "lib").mkdir()
    (dockerode / "lib" / "image.js").write_text("""
const fs = require('node:fs');
function Image() {}
Image.prototype.push = function originalPush() {
  fs.appendFileSync(process.env.ENGINE_PUSH_LOG, 'push\\n');
  return 'original-result';
};
module.exports = Image;
""".lstrip())
    (root / "publish.cjs").write_text("""
const fs = require('node:fs');
const Image = require('./node_modules/dockerode/lib/image.js');
const patched = Object.getOwnPropertySymbols(Image.prototype.push)
  .some((symbol) => String(symbol).includes('chalk.dockerode.postPush.patched.v1'));
let result = null;
if (process.env.CALL_PUSH === '1') result = new Image().push();
fs.writeFileSync(process.env.STATE_PATH, JSON.stringify({
  patched,
  result,
  nodeOptions: process.env.NODE_OPTIONS || null,
  timeout: process.env.CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS || null,
  chalk: process.env.CHALK_DOCKERODE_CHALK || null,
}));
""".lstrip())


def test_unwrapped_dockerode_remains_unobserved(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
):
    npm = shutil.which("npm")
    if npm is None:
        pytest.skip("npm is required")
    consumer = tmp_path / "consumer"
    consumer.mkdir()
    _write_npm_dockerode_fixture(consumer)
    state = tmp_path / "state.json"
    engine_pushes = tmp_path / "engine-pushes.log"
    diagnostic = tmp_path / "dockerode-diagnostic.jsonl"
    for variable in [
        "NODE_OPTIONS",
        "CHALK_DOCKERODE_CHALK",
        "CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS",
    ]:
        monkeypatch.delenv(variable, raising=False)

    run(
        [npm, "run", "--silent", "publish"],
        cwd=consumer,
        env={
            "CALL_PUSH": "1",
            "STATE_PATH": str(state),
            "ENGINE_PUSH_LOG": str(engine_pushes),
            "CHALK_DOCKERODE_LOG": str(diagnostic),
        },
    )

    values = json.loads(state.read_text())
    assert values == {
        "patched": False,
        "result": "original-result",
        "nodeOptions": None,
        "timeout": None,
        "chalk": None,
    }
    assert engine_pushes.read_text().splitlines() == ["push"]
    assert not diagnostic.exists()


def test_dockerode_wrapper_reaches_npm_child(
    chalk_default: Chalk,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
):
    npm = shutil.which("npm")
    node = shutil.which("node")
    if npm is None or node is None:
        pytest.skip("Node and npm are required")
    node_version = run([node, "-p", "process.versions.node"]).text.strip()
    major, minor, _ = (int(part) for part in node_version.split(".", maxsplit=2))
    if major not in {20, 22, 24, 26} or (major == 22 and minor < 15):
        pytest.skip(f"Node {node_version} is outside the V1 support boundary")

    consumer = tmp_path / "consumer"
    jenkins_owned = tmp_path / "jenkins-owned"
    consumer.mkdir()
    jenkins_owned.mkdir()
    _write_npm_dockerode_fixture(consumer)
    state = jenkins_owned / "state.json"
    diagnostic = jenkins_owned / "dockerode-diagnostic.jsonl"
    monkeypatch.delenv("NODE_OPTIONS", raising=False)

    run(
        [
            str(chalk_default.binary),
            "--no-use-external-config",
            "dockerode",
            "--",
            npm,
            "run",
            "--silent",
            "publish",
        ],
        cwd=consumer,
        env={
            "CALL_PUSH": "0",
            "STATE_PATH": str(state),
            "ENGINE_PUSH_LOG": str(jenkins_owned / "engine-pushes.log"),
            "CHALK_DOCKERODE_LOG": str(diagnostic),
            "CHALK_DOCKERODE_POST_PUSH_TIMEOUT_MS": "1234",
        },
    )

    values = json.loads(state.read_text())
    assert values["patched"] is True
    assert values["result"] is None
    assert values["timeout"] == "1234"
    assert values["chalk"] == str(chalk_default.binary)
    assert "chalk-dockerode-" in values["nodeOptions"]
    assert not (jenkins_owned / "engine-pushes.log").exists()
    assert not diagnostic.exists()


def test_legacy_docker_scan_retains_manifest_fallback():
    scan = Path(__file__).parents[2] / "src" / "docker" / "scan.nim"
    source = scan.read_text()
    start = source.index("proc scanImage*(name:")
    end = source.index("\nproc scanImage*(name: string", start)
    legacy_overload = source[start:end]
    assert "return chalk.scanImage(name, image)" in legacy_overload
    assert "fromManifest = fromManifest" not in legacy_overload


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

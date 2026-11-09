#!/usr/bin/env python3
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SELECTOR_PATH = (
    Path(__file__).resolve().parent / "customer_selector" / "stage05-bootstrap.py"
)
INSTALLER = Path(__file__).resolve().parent / "customer_selector" / "install-podman.sh"
BINARY = Path(os.environ["CHALK_BINARY"])
SOURCE_SHA = os.environ["SOURCE_SHA"]
POLICY = "829d1787a78a699d3c7708a616844c9728c53a1a"


def load_selector():
    spec = importlib.util.spec_from_file_location("selector", SELECTOR_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run_cases(selector, env, files, binary, select):
    for enabled in ("", "false", "0", "no", "off"):
        case = select(dict(env, CHALK_PODMAN_ENABLED=enabled), files)
        assert (
            case["status"] == 0
            and not case["downloads"]
            and not case["output"]
            and case["receipt"]["status"] == "disabled"
        ), case
    for current, selected in (
        ("86098193", selector.ALLOWED_PROJECT_ID),
        (selector.ALLOWED_PROJECT_ID, "86098193"),
    ):
        case = select(
            dict(env, CI_PROJECT_ID=current, CHALK_PODMAN_PROJECT_ID=selected), files
        )
        assert (
            case["status"] == 1
            and not case["downloads"]
            and case["receipt"]["reason"] == "wrong_project"
        ), case
    for name in ("manifest.json", "install.sh", "chalk"):
        case = select(env, files, corrupt=name)
        assert case["status"] == 1 and not case["output"], case
    case = select(env, files, fail_setup=True)
    assert (
        case["status"] == 1
        and not case["output"]
        and case["receipt"]["reason"] == "installer_failed"
    ), case
    installed = select(env, files)
    assert (
        installed["status"] == 0 and installed["receipt"]["status"] == "installed"
    ), installed
    bindir = Path(installed["output"].strip())
    dest = bindir / "podman"
    assert sha(dest.read_bytes()) == sha(binary)
    selected_env = selector.scrub_env(
        dict(env, PATH=str(bindir) + os.pathsep + os.environ["PATH"])
    )
    assert shutil.which("podman", path=selected_env["PATH"]) == str(dest)
    assert selected_env["HOME"] == os.environ["HOME"]
    delegated = subprocess.run(
        [str(dest), "--version"],
        env=selected_env,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert delegated.returncode == 0, delegated.stderr
    assert delegated.stdout.strip() == "podman version 6.1.4", delegated.stdout
    os.link(dest, bindir / "chalk")
    reported = subprocess.run(
        [str(bindir / "chalk"), "--no-use-external-config", "version"],
        env=selected_env,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert reported.returncode == 0, reported.stderr
    assert re.search(
        r"Commit ID[^\n]*?" + re.escape(SOURCE_SHA) + r"\b", reported.stdout
    ), reported.stdout
    assert "synthetic-stage05-token" not in reported.stdout + reported.stderr


def main():
    selector = load_selector()
    owned = []
    real = shutil.which("podman")
    assert real, "podman is not on PATH"
    version = subprocess.run(
        [real, "--version"], check=False, capture_output=True, text=True, timeout=60
    )
    assert (
        version.returncode == 0 and version.stdout.strip() == "podman version 6.1.4"
    ), version.stdout
    info = subprocess.run(
        [real, "info", "--format", "json"],
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert info.returncode == 0, info.stderr
    assert json.loads(info.stdout)["host"]["security"]["rootless"]
    binary = BINARY.read_bytes()
    installer = INSTALLER.read_bytes()
    assert re.fullmatch(r"[0-9a-f]{40}", SOURCE_SHA)

    def bundle(data, source):
        payload = {
            "schema_version": 1,
            "source_sha": source,
            "policy_sha": POLICY,
            "release_id": source + "-" + sha(data),
            "components": [
                {
                    "name": "binary",
                    "filename": "chalk",
                    "size": len(data),
                    "sha256": sha(data),
                },
                {
                    "name": "installer",
                    "filename": "install.sh",
                    "size": len(installer),
                    "sha256": sha(installer),
                },
            ],
        }
        raw = (json.dumps(payload, indent=2) + "\n").encode()
        env = dict(
            os.environ,
            CHALK_PODMAN_ENABLED="true",
            CI_PROJECT_ID=selector.ALLOWED_PROJECT_ID,
            CHALK_PODMAN_PROJECT_ID=selector.ALLOWED_PROJECT_ID,
            CHALK_PODMAN_POLICY_SHA=POLICY,
            CHALK_PODMAN_RELEASE_ID=payload["release_id"],
            CHALK_PODMAN_MANIFEST_SHA256=sha(raw),
            CHALK_PODMAN_INSTALLER_SHA256=sha(installer),
            CI_API_V4_URL="https://internal.invalid/api/v4",
            CI_JOB_TOKEN="synthetic-stage05-token",
            CHALK_OIDC="synthetic-stage05-token",
            CI_PROJECT_DIR=str(ROOT),
        )
        return raw, env, {"manifest.json": raw, "chalk": data, "install.sh": installer}

    def select(env, files, *, corrupt=None, fail_setup=False):
        downloads = []

        def download(url, token):
            assert token == "synthetic-stage05-token"
            name = url.rsplit("/", 1)[-1]
            downloads.append(name)
            return b"corrupt" if name == corrupt else files[name]

        def execute(args, **kwargs):
            assert all(key not in kwargs["env"] for key in selector.SECRET_ENV)
            if fail_setup:
                return subprocess.CompletedProcess(
                    args, 9, "", "synthetic setup failure"
                )
            return subprocess.run(args, **kwargs)

        stdout, stderr = io.StringIO(), io.StringIO()
        before = set(Path("/tmp").glob("chalk-podman-*"))
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = selector.main(env, download, execute)
        owned.extend(set(Path("/tmp").glob("chalk-podman-*")) - before)
        captured = stdout.getvalue() + stderr.getvalue()
        assert "synthetic-stage05-token" not in captured
        receipt = json.loads(stderr.getvalue())
        return {
            "status": status,
            "output": stdout.getvalue(),
            "receipt": receipt,
            "downloads": downloads,
        }

    raw, env, files = bundle(binary, SOURCE_SHA)
    try:
        run_cases(selector, env, files, binary, select)
    finally:
        for directory in owned:
            shutil.rmtree(directory, ignore_errors=True)


if __name__ == "__main__":
    main()

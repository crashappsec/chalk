#!/usr/bin/env python3
import hashlib
import json
import os
import re
import ssl
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

ALLOWED_PROJECT_ID = "86225665"
ORCHESTRATION_PROJECT_ID = "86098193"
PACKAGE_NAME = "chalk-podman-86101615"
MANIFEST_NAME = "manifest.json"
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_COMPONENT_BYTES = 256 * 1024 * 1024
GIT_SHA = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
RELEASE_ID = re.compile(r"^[0-9a-f]{40}-[0-9a-f]{64}$")
COMPONENT_NAMES = (
    "binary",
    "installer",
    "connection_artifact",
    "official_connection_installer",
)
REQUIRED_COMPONENTS = ("binary", "installer")
SECRET_ENV = (
    "CI_JOB_TOKEN",
    "CI_JOB_JWT",
    "CI_JOB_JWT_V1",
    "CI_JOB_JWT_V2",
    "CHALK_OIDC",
)
TRUE_VALUES = ("1", "true", "yes", "on")


class SetupError(Exception):
    def __init__(self, reason):
        self.reason = reason
        Exception.__init__(self, reason)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SetupError("download_failed")


def emit_receipt(status, release_id="", checksums=None, installed_path="", reason=None):
    payload = {
        "status": status,
        "release_id": release_id or "",
        "checksums": checksums or {},
        "installed_path": installed_path or "",
    }
    if reason:
        payload["reason"] = reason
    sys.stderr.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stderr.flush()


def env_get(env, name):
    value = env.get(name)
    if value is None:
        return ""
    return str(value).strip()


def is_enabled(env):
    return env_get(env, "CHALK_PODMAN_ENABLED").lower() in TRUE_VALUES


def https_ok(url):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https":
        return False
    if parts.username is not None or parts.password is not None:
        return False
    if not parts.hostname:
        return False
    return True


def quote_segment(value):
    return urllib.parse.quote(str(value), safe="-._")


def package_url(api, filename, release_id):
    return "%s/projects/%s/packages/generic/%s/%s/%s" % (
        api.rstrip("/"),
        quote_segment(ORCHESTRATION_PROJECT_ID),
        quote_segment(PACKAGE_NAME),
        quote_segment(release_id),
        quote_segment(filename),
    )


def digest(data):
    return hashlib.sha256(data).hexdigest()


def is_within(path, parent):
    real_path = os.path.realpath(path)
    real_parent = os.path.realpath(parent)
    if real_path == real_parent:
        return True
    prefix = real_parent
    if not prefix.endswith(os.sep):
        prefix += os.sep
    return real_path.startswith(prefix)


def safe_basename(name):
    if not isinstance(name, str):
        return False
    if not 1 <= len(name) <= 255:
        return False
    if name in (".", "..") or ".." in name:
        return False
    if os.path.basename(name) != name:
        return False
    if "/" in name or "\\" in name or "\0" in name:
        return False
    return bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", name))


def safe_release_id(env):
    release_id = env_get(env, "CHALK_PODMAN_RELEASE_ID").lower()
    if RELEASE_ID.fullmatch(release_id):
        return release_id
    return ""


def decide(env):
    if not is_enabled(env):
        return "skip", "disabled"
    current = env_get(env, "CI_PROJECT_ID")
    selected = env_get(env, "CHALK_PODMAN_PROJECT_ID")
    if current != ALLOWED_PROJECT_ID or selected != ALLOWED_PROJECT_ID:
        return "reject", "wrong_project"
    policy_sha = env_get(env, "CHALK_PODMAN_POLICY_SHA").lower()
    release_id = env_get(env, "CHALK_PODMAN_RELEASE_ID").lower()
    manifest_sha = env_get(env, "CHALK_PODMAN_MANIFEST_SHA256").lower()
    installer_sha = env_get(env, "CHALK_PODMAN_INSTALLER_SHA256").lower()
    api = env_get(env, "CI_API_V4_URL")
    token = env.get("CI_JOB_TOKEN") or ""
    source = env_get(env, "CI_PROJECT_DIR")
    if not GIT_SHA.fullmatch(policy_sha):
        return "reject", "invalid_selection"
    if not RELEASE_ID.fullmatch(release_id):
        return "reject", "invalid_selection"
    if not SHA256.fullmatch(manifest_sha):
        return "reject", "invalid_selection"
    if not SHA256.fullmatch(installer_sha):
        return "reject", "invalid_selection"
    if not source or not token or any(ch.isspace() for ch in str(token)):
        return "reject", "invalid_selection"
    if not https_ok(api):
        return "reject", "invalid_selection"
    return "run", "enabled"


def download_https(url, token):
    if not https_ok(url):
        raise SetupError("download_failed")
    if not token or any(ch.isspace() for ch in str(token)):
        raise SetupError("download_failed")
    request = urllib.request.Request(url)
    request.add_header("JOB-TOKEN", token)
    opener = urllib.request.build_opener(
        NoRedirect(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()),
    )
    try:
        with opener.open(request, timeout=120) as response:
            if not https_ok(response.geturl()):
                raise SetupError("download_failed")
            length = response.headers.get("Content-Length")
            if length is not None:
                try:
                    announced = int(length)
                except ValueError:
                    raise SetupError("download_failed")
                if announced < 1 or announced > MAX_COMPONENT_BYTES:
                    raise SetupError("download_failed")
            chunks = []
            size = 0
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_COMPONENT_BYTES:
                    raise SetupError("download_failed")
                chunks.append(chunk)
            data = b"".join(chunks)
            if not data:
                raise SetupError("download_failed")
            return data
    except SetupError:
        raise
    except urllib.error.HTTPError as error:
        try:
            error.close()
        except Exception:
            pass
        raise SetupError("download_failed") from None
    except Exception:
        raise SetupError("download_failed") from None


def fetch(download, url, token, max_bytes):
    data = download(url, token)
    if not isinstance(data, (bytes, bytearray)):
        raise SetupError("download_failed")
    data = bytes(data)
    if not data or len(data) > max_bytes:
        raise SetupError("download_failed")
    return data


def write_private(path, data, workdir):
    parent = os.path.dirname(path)
    if not is_within(parent, workdir):
        raise SetupError("source_conflict")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)


def parse_manifest(raw, release_id, policy_sha, installer_pin):
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
        raise SetupError("invalid_manifest")
    if not isinstance(payload, dict):
        raise SetupError("invalid_manifest")
    if payload.get("schema_version") != 1:
        raise SetupError("invalid_manifest")
    source_sha = payload.get("source_sha")
    if not isinstance(source_sha, str) or not GIT_SHA.fullmatch(source_sha):
        raise SetupError("invalid_manifest")
    got_policy = payload.get("policy_sha")
    if not isinstance(got_policy, str) or not GIT_SHA.fullmatch(got_policy):
        raise SetupError("invalid_manifest")
    if got_policy != policy_sha:
        raise SetupError("wrong_policy_sha")
    got_release = payload.get("release_id")
    if not isinstance(got_release, str) or got_release != release_id:
        raise SetupError("invalid_manifest")
    items = payload.get("components")
    if not isinstance(items, list) or not items:
        raise SetupError("invalid_manifest")
    by_name = {}
    for item in items:
        if not isinstance(item, dict):
            raise SetupError("invalid_manifest")
        name = item.get("name")
        if name not in COMPONENT_NAMES or name in by_name:
            raise SetupError("invalid_manifest")
        filename = item.get("filename")
        size = item.get("size")
        sha256 = item.get("sha256")
        if not safe_basename(filename):
            raise SetupError("unsafe_filename")
        if not isinstance(size, int) or isinstance(size, bool) or size < 1:
            raise SetupError("invalid_manifest")
        if size > MAX_COMPONENT_BYTES:
            raise SetupError("invalid_manifest")
        if not isinstance(sha256, str):
            raise SetupError("invalid_manifest")
        sha256 = sha256.lower()
        if not SHA256.fullmatch(sha256):
            raise SetupError("invalid_manifest")
        by_name[name] = {
            "name": name,
            "filename": filename,
            "size": size,
            "sha256": sha256,
        }
    for name in REQUIRED_COMPONENTS:
        if name not in by_name:
            raise SetupError("invalid_manifest")
    binary = by_name["binary"]
    installer = by_name["installer"]
    expected_id = "%s-%s" % (source_sha, binary["sha256"])
    if expected_id != release_id:
        raise SetupError("invalid_manifest")
    if installer["sha256"] != installer_pin:
        raise SetupError("component_mismatch")
    if binary["filename"] == installer["filename"]:
        raise SetupError("invalid_manifest")
    return binary, installer


def scrub_env(env):
    cleaned = {}
    for key, value in env.items():
        if key in SECRET_ENV:
            continue
        cleaned[key] = value
    return cleaned


def install_release(env, download, run_command):
    policy_sha = env_get(env, "CHALK_PODMAN_POLICY_SHA").lower()
    release_id = env_get(env, "CHALK_PODMAN_RELEASE_ID").lower()
    manifest_sha = env_get(env, "CHALK_PODMAN_MANIFEST_SHA256").lower()
    installer_pin = env_get(env, "CHALK_PODMAN_INSTALLER_SHA256").lower()
    api = env_get(env, "CI_API_V4_URL")
    token = env.get("CI_JOB_TOKEN")
    source = env_get(env, "CI_PROJECT_DIR")
    if not os.path.isdir(source):
        raise SetupError("invalid_selection")
    if is_within("/tmp", source):
        raise SetupError("source_conflict")
    workdir = tempfile.mkdtemp(prefix="chalk-podman-", dir="/tmp")
    if is_within(workdir, source) or not is_within(workdir, "/tmp"):
        raise SetupError("source_conflict")
    token_value = str(token)
    raw = fetch(
        download,
        package_url(api, MANIFEST_NAME, release_id),
        token_value,
        MAX_MANIFEST_BYTES,
    )
    if digest(raw) != manifest_sha:
        raise SetupError("manifest_mismatch")
    binary, installer = parse_manifest(raw, release_id, policy_sha, installer_pin)
    write_private(os.path.join(workdir, MANIFEST_NAME), raw, workdir)
    os.mkdir(os.path.join(workdir, "binary"), 0o700)
    os.mkdir(os.path.join(workdir, "installer"), 0o700)
    installer_bytes = fetch(
        download,
        package_url(api, installer["filename"], release_id),
        token_value,
        installer["size"],
    )
    if (
        len(installer_bytes) != installer["size"]
        or digest(installer_bytes) != installer["sha256"]
    ):
        raise SetupError("component_mismatch")
    installer_path = os.path.join(workdir, "installer", installer["filename"])
    write_private(installer_path, installer_bytes, workdir)
    binary_bytes = fetch(
        download,
        package_url(api, binary["filename"], release_id),
        token_value,
        binary["size"],
    )
    if len(binary_bytes) != binary["size"] or digest(binary_bytes) != binary["sha256"]:
        raise SetupError("component_mismatch")
    binary_path = os.path.join(workdir, "binary", binary["filename"])
    write_private(binary_path, binary_bytes, workdir)
    install_dir = os.path.join(workdir, "install")
    os.mkdir(install_dir, 0o700)
    os.chmod(install_dir, 0o700)
    if os.path.islink(install_dir) or not os.path.isdir(install_dir):
        raise SetupError("installer_failed")
    if stat.S_IMODE(os.lstat(install_dir).st_mode) & 0o077:
        raise SetupError("installer_failed")
    expected_bin = os.path.join(install_dir, "bin")
    try:
        proc = run_command(
            ["sh", installer_path, binary_path, binary["sha256"], install_dir],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=workdir,
            env=scrub_env(env),
            text=True,
        )
    except SetupError:
        raise
    except Exception:
        raise SetupError("installer_failed") from None
    if proc.returncode != 0 or proc.stdout != expected_bin + "\n":
        raise SetupError("installer_failed")
    podman_path = os.path.join(expected_bin, "podman")
    if not os.path.isfile(podman_path) or os.path.islink(podman_path):
        raise SetupError("installer_failed")
    checksums = {
        "manifest": manifest_sha,
        "installer": installer["sha256"],
        "binary": binary["sha256"],
    }
    emit_receipt(
        "installed",
        release_id=release_id,
        checksums=checksums,
        installed_path=expected_bin,
    )
    sys.stdout.write(expected_bin + "\n")
    sys.stdout.flush()
    return 0


def main(env=None, download=download_https, run_command=subprocess.run):
    if env is None:
        env = os.environ
    action, reason = decide(env)
    release_id = safe_release_id(env)
    if action == "skip":
        emit_receipt("disabled", release_id=release_id)
        return 0
    if action == "reject":
        emit_receipt("failed", release_id=release_id, reason=reason)
        return 1
    try:
        return install_release(env, download, run_command)
    except SetupError as error:
        emit_receipt("failed", release_id=release_id, reason=error.reason)
        return 1
    except Exception:
        emit_receipt("failed", release_id=release_id, reason="internal_error")
        return 1


if __name__ == "__main__":
    sys.exit(main())

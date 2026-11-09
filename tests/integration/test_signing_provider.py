#!/usr/bin/env python3
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading

SOURCE_SHA = os.environ["SOURCE_SHA"]
BINARY = Path(os.environ["CHALK_BINARY"])
DIAGNOSTIC = Path(os.environ["SIGNING_PROVIDER"])


def host_cpu():
    machine = os.uname().machine
    if machine in ("x86_64", "amd64"):
        return "amd64"
    if machine in ("aarch64", "arm64"):
        return "arm64"
    raise AssertionError("unsupported machine " + machine)


def commit_of(binary):
    result = subprocess.run(
        [str(binary), "--no-use-external-config", "version"],
        check=False,
        capture_output=True,
        text=True,
        timeout=90,
    )
    assert result.returncode == 0, result.stderr
    match = re.search(r"Commit ID[^\n]*?([0-9a-f]{40})", result.stdout)
    assert match, result.stdout
    assert re.search(r"Build OS[^\n]*?\blinux\b", result.stdout), result.stdout
    assert re.search(
        r"Build CPU[^\n]*?\b" + host_cpu() + r"\b", result.stdout
    ), result.stdout
    return match.group(1), result.stdout


def assert_elf(path):
    data = path.read_bytes()
    assert len(data) >= 20 and data[:4] == b"\x7fELF", path
    assert data[4] == 2 and data[5] == 1, path
    machine = int.from_bytes(data[18:20], "little")
    expected = 62 if os.uname().machine in ("x86_64", "amd64") else 183
    assert machine == expected, (path, machine)


def main():
    assert re.fullmatch(r"[0-9a-f]{40}", SOURCE_SHA)
    assert_elf(BINARY)
    assert_elf(DIAGNOSTIC)
    binary_commit, _ = commit_of(BINARY)
    assert binary_commit == SOURCE_SHA
    evidence = {"commands": [], "requests": [], "cases": []}

    def run(argv, env, cwd):
        result = subprocess.run(
            list(map(str, argv)),
            env=env,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=90,
        )
        evidence["commands"].append(
            {
                "argv": list(map(str, argv)),
                "status": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            }
        )
        return result

    class Service(http.server.BaseHTTPRequestHandler):
        body = b""
        status = 200

        def do_GET(self):
            evidence["requests"].append(
                {
                    "path": self.path,
                    "status": self.status,
                    "body_sha256": hashlib.sha256(self.body).hexdigest(),
                }
            )
            self.send_response(self.status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(self.body)))
            self.end_headers()
            self.wfile.write(self.body)

        def log_message(self, *args):
            pass

    server = None
    try:
        with tempfile.TemporaryDirectory(prefix="stage02-") as directory:
            temp = Path(directory)
            env = dict(
                os.environ,
                STAGE02_OPERATION="mint",
                STAGE02_KEY_PATH=str(temp / "key"),
                STAGE02_FIXTURE=str(temp / "fixture.json"),
            )
            minted = run(
                [DIAGNOSTIC, "--no-use-external-config", "--log-level=none", "version"],
                env,
                temp,
            )
            assert minted.returncode == 0, minted.stderr
            assert "STAGE02_SOURCE " + SOURCE_SHA in minted.stdout
            assert re.search(r"Build OS[^\n]*?\blinux\b", minted.stdout), minted.stdout
            assert re.search(
                r"Build CPU[^\n]*?\b" + host_cpu() + r"\b", minted.stdout
            ), minted.stdout
            keys = json.loads((temp / "fixture.json").read_text())
            assert commit_of(BINARY)[0] == SOURCE_SHA
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Service)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            config = temp / "provider.c4m"
            config.write_text("""auth_config synthetic {
  auth: "jwt"
  token: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
}
attestation {
  key_provider: "get"
  attestation_key_get {
    uri: "http://127.0.0.1:%s/provider"
    auth: "synthetic"
  }
}
""" % server.server_port)
            marker = "S2_SECRET"
            valid = json.dumps({marker: "synthetic", **keys}).encode()
            password = json.dumps(
                {marker: "synthetic", "password": keys["password"]}
            ).encode()
            cases = [
                ("valid-key", "key", 200, valid, True),
                ("valid-password", "password", 200, password, True),
                (
                    "invalid-json",
                    "key",
                    200,
                    (marker + "_INVALID_JSON").encode(),
                    False,
                ),
                (
                    "invalid-password-json",
                    "password",
                    200,
                    (marker + "_INVALID_JSON").encode(),
                    False,
                ),
                (
                    "missing-fields",
                    "key",
                    200,
                    json.dumps({marker: "synthetic"}).encode(),
                    False,
                ),
                ("unauthorized", "key", 401, (marker + "_DENIED").encode(), False),
                (
                    "service-error",
                    "key",
                    503,
                    (marker + "_SERVICE_ERROR").encode(),
                    False,
                ),
                (
                    "password-service-error",
                    "password",
                    503,
                    (marker + "_PASSWORD_ERROR").encode(),
                    False,
                ),
            ]
            for level in ("info", "trace"):
                for name, operation, status, body, success in cases:
                    Service.status, Service.body = status, body
                    start = len(evidence["requests"])
                    env.update(
                        STAGE02_OPERATION=operation,
                        STAGE02_EXPECT_PASSWORD=keys["password"],
                    )
                    result = run(
                        [
                            DIAGNOSTIC,
                            "--no-use-embedded-config",
                            "--config-file=" + str(config),
                            "--no-color",
                            "--log-level=" + level,
                            "version",
                        ],
                        env,
                        temp,
                    )
                    output = result.stdout + result.stderr
                    assert "STAGE02_SOURCE " + SOURCE_SHA in result.stdout
                    decoded = []
                    for line in output.splitlines():
                        try:
                            item = json.loads(line)
                        except ValueError:
                            continue
                        if isinstance(item, dict) and isinstance(item.get("msg"), str):
                            decoded.append(item["msg"])
                    output += "\n" + "\n".join(decoded)
                    leaked = [
                        label
                        for label, value in [
                            ("body", body.decode()),
                            ("response-prefix", body[:15].decode()),
                            ("marker", marker),
                            ("password", keys["password"]),
                            ("private-key", keys["privateKey"][40:100]),
                        ]
                        if value and value in output
                    ]
                    requests = evidence["requests"][start:]
                    expected_path = (
                        "/provider?only=password"
                        if operation == "password"
                        else "/provider"
                    )
                    record = {
                        "name": name,
                        "level": level,
                        "operation": operation,
                        "status": result.returncode,
                        "leaks": leaked,
                        "request_paths": [request["path"] for request in requests],
                    }
                    evidence["cases"].append(record)
                    assert requests and all(
                        request["path"] == expected_path for request in requests
                    ), record
                    assert (result.returncode == 0) == success, record
                    if success:
                        expected_marker = (
                            "STAGE02_PASSWORD_VERIFIED"
                            if operation == "password"
                            else "STAGE02_SIGNING_VERIFIED"
                        )
                        assert expected_marker in output
                    assert not leaked, record
                    if level == "trace" and success:
                        assert "Signing Key Provider Service status code: 200" in output
                    if status != 200:
                        assert str(status) in output, record
    finally:
        if server:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()

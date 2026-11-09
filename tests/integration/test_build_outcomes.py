#!/usr/bin/env python3
import hashlib
import http.server
import json
import os
import re
from pathlib import Path
import shutil
import signal
import socket
import sys
import subprocess
import tempfile
import threading
import time
import uuid

BASE = (
    "docker.io/library/alpine@sha256:"
    + {
        "x86_64": "eafc1edb577d2e9b458664a15f23ea1c370214193226069eb22921169fc7e43f",
        "aarch64": "4562b419adf48c5f3c763995d6014c123b3ce1d2e0ef2613b189779caa787192",
    }[os.uname().machine]
)
ROOT = Path(os.environ["CHALK_BINARY"]).parent
OUT = ROOT / ".developer-diagnostics/evidence" / ("build-outcomes-" + sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)
ENGINE = sys.argv[1]
evidence = dict(
    engine=ENGINE,
    phase="candidate",
    test_commit=os.environ.get("GITHUB_SHA"),
    pipeline=os.environ.get("GITHUB_RUN_ID"),
    job=os.environ.get("GITHUB_JOB"),
    fixture=os.environ.get("ImageOS"),
    uid=os.getuid(),
    commands=[],
    cases=[],
    passed=False,
)
events = []
images = []
server = None


def redact(text, env):
    for key, value in env.items():
        if len(value) >= 8 and any(
            (
                word in key.upper()
                for word in ("TOKEN", "PASSWORD", "PRIVATE_KEY", "SSH_KEY")
            )
        ):
            text = text.replace(value, "[redacted]")
    return text


def save():
    (OUT / "result.json").write_text(json.dumps(evidence, indent=2) + "\n")
    (OUT / "ledger.json").write_text(json.dumps(events, indent=2) + "\n")


def run(argv, *, cwd=None, env=None, required=True, timeout=180):
    record = dict(argv=list(map(str, argv)), cwd=str(cwd or ROOT))
    evidence["commands"].append(record)
    save()
    result = subprocess.run(
        record["argv"],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    record.update(
        status=result.returncode,
        stdout=redact(result.stdout, os.environ),
        stderr=redact(result.stderr, os.environ),
    )
    save()
    if required:
        assert result.returncode == 0, record
    return result


class Ledger(http.server.BaseHTTPRequestHandler):

    def do_GET(self):
        event = dict(path=self.path, monotonic=time.monotonic())
        events.append(event)
        with (OUT / "ledger-events.jsonl").open("a") as stream:
            stream.write(json.dumps(event) + "\n")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"recorded\n")

    def log_message(self, *args):
        pass


PROXY = r"""#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
any_build = args[:1] == ['build'] or args[:2] == ['buildx', 'build']
is_build = any_build and os.environ['STAGE_CONTEXT'] in args
injected = any(a == '--build-context' or a.startswith('--build-context=') for a in args) or any(a.startswith('--iidfile=') and '/tmp/' in a for a in args)
with open(os.environ['STAGE_CALLS'], 'a') as f:
    f.write(json.dumps(dict(args=args, build=is_build, injected=injected, ancillary_build=any_build and not is_build, event='launch')) + '\n')
if args == ['build', 'stage01-original-must-not-run']:
    sys.exit(int(os.environ['STAGE_NATIVE_STATUS']))
mode = os.environ.get('STAGE_FAULT')
if mode == 'preparation' and args[:1] == ['info']:
    sys.exit(19)
if is_build and injected and mode == 'injected':
    sys.exit(27)
if is_build and injected and mode == 'cancel':
    Path(os.environ['STAGE_READY']).write_text(str(os.getpid()))
    while True:
        time.sleep(.05)
if is_build:
    with open(os.environ['STAGE_CALLS'], 'a') as f:
        f.write(json.dumps(dict(args=args, event='engine-build')) + '\n')
os.execv(os.environ['STAGE_REAL'], [os.environ['STAGE_REAL'], *args])
"""
try:
    real = shutil.which(ENGINE)
    assert real
    evidence["versions"] = run([real, "version"]).stdout
    if ENGINE == "podman":
        evidence["buildah"] = json.loads(
            run([real, "info", "--format", "json"]).stdout
        )["host"]["buildahVersion"]
        assert evidence["buildah"] == "1.45.2"
        assert run([real, "--version"]).stdout.strip() == "podman version 6.1.4"
        assert json.loads(run([real, "info", "--format", "json"]).stdout)["host"][
            "security"
        ]["rootless"]
        assert os.getuid() != 0
    else:
        run([real, "buildx", "use", "default"])
        assert (
            run([real, "version", "--format", "{{.Client.Version}}"]).stdout.strip()
            == "29.2.1"
        )
        assert (
            run([real, "version", "--format", "{{.Server.Version}}"]).stdout.strip()
            == "29.2.1"
        )
        for _ in range(30):
            if run([real, "info"], required=False).returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError("Docker service did not start")
    binary = Path(os.environ["CHALK_BINARY"])
    manifest = json.loads(
        (ROOT / ".developer-diagnostics/evidence/build-identity.json").read_text()
    )
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    assert digest == manifest["sha256"]
    assert binary.read_bytes()[:4] == b"\x7fELF" and int.from_bytes(
        binary.read_bytes()[18:20], "little"
    ) == (62 if os.uname().machine == "x86_64" else 183)
    assert (
        re.search(
            "Commit ID[^\\n]*?([0-9a-f]{40})",
            run([binary, "--no-use-external-config", "version"]).stdout,
        )[1]
        == manifest["source"]
    )
    evidence["identity"] = manifest
    evidence["binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Ledger)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    address = (
        "127.0.0.1"
        if ENGINE == "podman"
        else socket.gethostbyname(socket.gethostname())
    )
    url = f"http://{address}:{server.server_port}"
    import urllib.request

    assert urllib.request.urlopen(url + "/health", timeout=5).read() == b"recorded\n"
    run([real, "pull", BASE])
    with tempfile.TemporaryDirectory(prefix="stage01-") as temporary:
        root = Path(temporary)
        proxy = root / ENGINE
        proxy.write_text(PROXY)
        proxy.chmod(493)
        calls = root / "calls.jsonl"
        ready = root / "ready"
        env = dict(
            os.environ,
            PATH=str(root) + ":" + os.environ["PATH"],
            STAGE_REAL=real,
            STAGE_CALLS=str(calls),
            STAGE_READY=str(ready),
            STAGE_CONTEXT=str(root),
        )
        prefix = [
            str(binary),
            "--no-use-external-config",
            "--no-color",
            "--no-run-sbom-tools",
            "--no-run-sast-tools",
            "--skip-command-report",
            "--skip-custom-reports",
        ]
        if ENGINE == "docker":
            prefix += ["--wrap"]
        prefix += [ENGINE]

        def case(
            name,
            *,
            native=False,
            fault="",
            fail=False,
            warm=False,
            buildx=False,
            collision=False,
        ):
            calls.write_text("")
            env["STAGE_FAULT"] = fault
            nonce = uuid.uuid4().hex
            tag = "localhost/stage01-" + nonce
            images.append(tag)
            (root / "nonce").write_text(nonce)
            recipe = (
                "FROM "
                + BASE
                + "\nRUN true\nCOPY nonce /nonce\n"
                + f"RUN wget -qO- {url}/effect/{nonce}"
                + ("; exit 17" if fail else "")
                + ("\nRUN printf customer-content > /chalk.json" if collision else "")
                + '\nENTRYPOINT ["/bin/true"]\n'
            )
            (root / "Dockerfile").write_text(recipe)
            args = ["buildx", "build", "--load"] if buildx else ["build"]
            args += ["--network=host", "--tag", tag, "--file", str(root / "Dockerfile")]
            if ENGINE == "podman":
                args += ["--layers"]
            if not warm:
                args += ["--no-cache"]
            args += [str(root)]
            result = run(
                ([str(proxy)] if native else prefix) + args,
                cwd=root,
                env=env,
                required=False,
            )
            records = [json.loads(line) for line in calls.read_text().splitlines()]
            launches = [r for r in records if r.get("build")]
            builds = [r for r in records if r["event"] == "engine-build"]
            effects = [e for e in events if e["path"] == "/effect/" + nonce]
            record = dict(
                name=name,
                native=native,
                nonce=nonce,
                status=result.returncode,
                launches=launches,
                engine_builds=builds,
                effects=effects,
            )
            evidence["cases"].append(record)
            if warm:
                record["cache_hit"] = (
                    "Using cache" in result.stdout
                    if ENGINE == "podman"
                    else "CACHED" in result.stderr
                )
            save()
            if warm:
                assert record["cache_hit"], record
            if native:
                assert len(launches) == len(builds) == len(effects) == 1, record
            else:
                assert len(launches) == 1, record
                assert len(builds) == (0 if fault == "injected" else 1), record
                assert len(effects) == (0 if fault == "injected" else 1), record
                if not fault:
                    assert launches[0]["injected"], record
            return (result.returncode, tag)

        for warm in (False, True):
            control, _ = case(
                "native-workload-failure-" + str(warm),
                native=True,
                fail=True,
                warm=warm,
            )
            observed, _ = case(
                "wrapped-workload-failure-" + str(warm), fail=True, warm=warm
            )
            assert observed == control, (observed, control)
        status, tag = case("instrumented-success")
        assert status == 0
        config = json.loads(run([real, "image", "inspect", tag]).stdout)[0]["Config"]
        assert config["Entrypoint"][:2] == ["/chalk", "exec"], config
        evidence["instrumentation"] = config
        status, _ = case("injected-launch-failure", fault="injected")
        assert status == 27
        if ENGINE == "podman":
            control, _ = case("native-reserved-path", native=True, collision=True)
            observed, collision_tag = case(
                "injected-reserved-path-guard", collision=True
            )
            assert control == 0
            assert observed != 0
            absent = run([real, "image", "inspect", collision_tag], required=False)
            assert absent.returncode != 0
            report_log = Path.home() / ".local/chalk/chalk.log"
            report_log.parent.mkdir(parents=True, exist_ok=True)
            report_log.touch(exist_ok=True)
            file_mode = report_log.stat().st_mode & 511
            dir_mode = report_log.parent.stat().st_mode & 511
            before = report_log.read_bytes()
            original_prefix = prefix
            prefix = [
                arg
                for arg in prefix
                if arg not in ("--skip-command-report", "--skip-custom-reports")
            ]
            report_log.chmod(292)
            report_log.parent.chmod(365)
            try:
                status, _ = case("reporting-permission-failure")
                assert status == 0 and report_log.read_bytes() == before
            finally:
                report_log.parent.chmod(dir_mode)
                report_log.chmod(file_mode)
                prefix = original_prefix
            status, _ = case("preparation-fallback", fault="preparation")
            assert status == 0
            diagnostic = Path(os.environ["CHALK_DIAGNOSTIC"])
            for fault in ("spawn", "unknown"):
                calls.write_text("")
                launches_file = root / "adapter-launches"
                launches_file.write_text("")
                env.update(
                    STAGE_FAULT="",
                    STAGE_LAUNCH_FAULT=fault,
                    STAGE_LAUNCH_LEDGER=str(launches_file),
                )
                nonce = uuid.uuid4().hex
                (root / "Dockerfile").write_text(
                    "FROM "
                    + BASE
                    + "\n"
                    + f'RUN wget -qO- {url}/effect/{nonce}\nENTRYPOINT ["/bin/true"]\n'
                )
                tag = "localhost/stage01-" + nonce
                images.append(tag)
                result = run(
                    [
                        str(diagnostic),
                        *prefix[1:],
                        "build",
                        "--no-cache",
                        "--network=host",
                        "--tag",
                        tag,
                        str(root),
                    ],
                    env=env,
                    cwd=root,
                    required=False,
                )
                attempts = launches_file.read_text().splitlines()
                records = [json.loads(line) for line in calls.read_text().splitlines()]
                effects = [e for e in events if e["path"] == "/effect/" + nonce]
                record = dict(
                    name="adapter-" + fault,
                    status=result.returncode,
                    adapter_calls=attempts,
                    engine_records=records,
                    effects=effects,
                )
                evidence["cases"].append(record)
                save()
                assert result.returncode == 127 and attempts == ["injected"], record
                assert len([r for r in records if r["event"] == "engine-build"]) == (
                    fault == "unknown"
                ), record
                assert len(effects) == (fault == "unknown"), record
            env.pop("STAGE_LAUNCH_FAULT")
            env.pop("STAGE_LAUNCH_LEDGER")
        else:
            control, _ = case(
                "native-buildx-failure", native=True, fail=True, buildx=True
            )
            observed, _ = case("wrapped-buildx-failure", fail=True, buildx=True)
            assert observed == control
            helper = Path(os.environ["DOCKER_BUILD_STATUS"])
            for status in ("unknown", "0", "17", "143"):
                calls.write_text("")
                env["STAGE_TERMINAL_STATUS"] = status
                result = run(
                    [helper, "--no-use-external-config", "--no-color", "version"],
                    env=env,
                    cwd=root,
                    required=False,
                )
                record = dict(
                    name="post-launch-exception-" + status,
                    status=result.returncode,
                    calls=calls.read_text(),
                )
                evidence["cases"].append(record)
                assert result.returncode == (
                    1 if status == "unknown" else int(status)
                ), record
                assert not calls.read_text(), record
            env["STAGE_PRELAUNCH"] = "true"
            for status in ("0", "17", "143"):
                calls.write_text("")
                env["STAGE_NATIVE_STATUS"] = status
                result = run(
                    [helper, "--no-use-external-config", "--no-color", "version"],
                    env=env,
                    cwd=root,
                    required=False,
                )
                records = [json.loads(line) for line in calls.read_text().splitlines()]
                record = dict(
                    name="pre-launch-native-status-" + status,
                    status=result.returncode,
                    calls=records,
                )
                evidence["cases"].append(record)
                assert result.returncode == int(status), record
                builds = [item for item in records if item["args"][:1] == ["build"]]
                assert len(builds) == 1 and builds[0]["args"] == [
                    "build",
                    "stage01-original-must-not-run",
                ], record
            env.pop("STAGE_PRELAUNCH")
        original_prefix = prefix
        failure_config = root / "failure-report.c4m"
        failure_config.write_text('subscribe("fail", "json_console_out")\n')
        prefix = [
            arg
            for arg in prefix
            if arg not in ("--no-use-external-config", "--skip-command-report")
        ]
        prefix[-1:-1] = [
            "--no-use-embedded-config",
            "--config-file=" + str(failure_config),
        ]
        try:
            status, _ = case("failed-build-report", fail=True)
            stdout = evidence["commands"][-1]["stdout"]
            reports = []
            for match in re.finditer("\\[\\s*\\{", stdout):
                try:
                    value, _ = json.JSONDecoder().raw_decode(stdout, match.start())
                except json.JSONDecodeError:
                    continue
                if isinstance(value, list) and any(
                    (
                        isinstance(row, dict) and row.get("_OPERATION") == "build"
                        for row in value
                    )
                ):
                    reports.extend(value)
            evidence["failed_build_reports"] = reports
            save()
            assert (
                len(reports) == 1
            ), "failed engine build must emit one subscribed failure report"
            assert status == next(
                (
                    c["status"]
                    for c in evidence["cases"]
                    if c["name"] == "native-workload-failure-False"
                )
            )
        finally:
            prefix = original_prefix
        env["STAGE_FAULT"] = "cancel"
        calls.write_text("")
        process = subprocess.Popen(
            prefix + ["build", "--tag", "localhost/stage01-cancel", str(root)],
            cwd=root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            deadline = time.monotonic() + 30
            while not ready.exists():
                assert process.poll() is None and time.monotonic() < deadline
                time.sleep(0.05)
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=15)
            records = [json.loads(line) for line in calls.read_text().splitlines()]
            evidence["cancellation"] = dict(
                status=process.returncode,
                calls=records,
                stdout=stdout.decode(errors="replace"),
                stderr=stderr.decode(errors="replace"),
            )
            assert process.returncode in (143, -signal.SIGTERM), evidence[
                "cancellation"
            ]
            assert len([r for r in records if r.get("build")]) == 1
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            if ready.exists():
                try:
                    os.kill(int(ready.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
    evidence["passed"] = True
except BaseException as error:
    evidence["failure"] = str(error)
    raise
finally:
    if server:
        server.shutdown()
        server.server_close()
    evidence["cleanup"] = []
    for image in images:
        result = subprocess.run(
            [real, "rmi", "--force", image], capture_output=True, text=True
        )
        evidence["cleanup"].append(
            dict(
                image=image,
                status=result.returncode,
                stderr=redact(result.stderr, os.environ),
            )
        )
    save()

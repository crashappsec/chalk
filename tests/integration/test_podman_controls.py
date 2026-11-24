#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
launch_diagnostic = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None
output = Path("artifacts/podman/controls.json")
output.parent.mkdir(parents=True, exist_ok=True)


def elf_architecture(path):
    header = path.read_bytes()[:20]
    if header[:4] != b"\x7fELF" or len(header) < 20:
        raise AssertionError(f"expected a Linux ELF Chalk binary: {path}")
    machine = int.from_bytes(header[18:20], "little")
    return {62: "amd64", 183: "arm64"}[machine]


binary_arch = elf_architecture(binary)


FAKE_PODMAN = r"""#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import signal
import sys

argv = sys.argv[1:]
record = {"argv": argv}
if argv and argv[0] == "build" and "--build-context" in argv:
    containerfile = Path(argv[argv.index("--file") + 1])
    assets = Path(argv[argv.index("--build-context") + 1].split("=", 1)[1])
    record["derived_containerfile"] = containerfile.read_text()
    record["assets"] = {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in assets.iterdir()
        if path.is_file()
    }
with open(os.environ["PODMAN_CONTROL_CALLS"], "a") as stream:
    stream.write(json.dumps(record) + "\n")

native_argv = json.loads(os.environ.get("PODMAN_CONTROL_NATIVE_ARGV", "null"))
if argv == native_argv:
    print("native podman stdout")
    if os.environ.get("PODMAN_CONTROL_BUILD_EXIT"):
        print("native podman stderr", file=sys.stderr)
    sys.exit(int(os.environ["PODMAN_CONTROL_NATIVE_EXIT"]))

if argv == ["info", "--format", "json"]:
    print(json.dumps({
        "host": {
            "os": "linux",
            "arch": os.environ["PODMAN_CONTROL_ARCH"],
            "serviceIsRemote": False,
            "buildahVersion": "1.45.2",
        },
        "version": {"Version": "6.1.4"},
    }))
    sys.exit(0)

if argv and argv[0] == "build":
    if "--iidfile" in argv:
        Path(argv[argv.index("--iidfile") + 1]).write_text("sha256:" + "a" * 64 + "\n")
    status = os.environ.get("PODMAN_CONTROL_BUILD_EXIT")
    if status:
        print("instrumented podman stdout", flush=True)
        print("instrumented podman stderr", file=sys.stderr, flush=True)
        if status == "signal":
            os.kill(os.getpid(), signal.SIGKILL)
        sys.exit(int(status))
    sys.exit(0)

if argv[:2] == ["image", "inspect"]:
    print(json.dumps([{
        "Id": "sha256:" + "a" * 64,
        "Digest": "sha256:" + "b" * 64,
        "RepoTags": [],
        "RepoDigests": [],
        "Os": "linux",
        "Architecture": os.environ["PODMAN_CONTROL_ARCH"],
        "Config": {
            "User": "",
            "Entrypoint": ["/chalk", "exec", "--heartbeat", "--", "/bin/true"],
            "Cmd": [],
        },
    }]))
    sys.exit(0)

if argv and argv[0] == "create":
    print("control-scan-container")
    sys.exit(0)
if argv[:2] == ["cp", "control-scan-container:/chalk.json"]:
    sys.exit(1)  # The existing image has no mark.
if argv == ["rm", "--force", "control-scan-container"]:
    sys.exit(0)

sys.stderr.write("unexpected fake Podman invocation: " + repr(argv) + "\n")
sys.exit(99)
"""


def records(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def workspaces():
    result = set()
    for parent in (Path("/tmp"), Path("/var/tmp")):
        if parent.is_dir():
            result.update(str(path) for path in parent.glob("chalk-podman-*"))
    return result


def invoke(
    root,
    fake_dir,
    calls,
    name,
    source,
    config_text="",
    extra_flags=(),
    build_argv=None,
    wrapper=None,
    native_status=None,
    instrumented_status=None,
    launch_fault=None,
):
    case_root = root / name
    home = case_root / "home"
    context = case_root / "context"
    home.mkdir(parents=True)
    context.mkdir()
    (context / "Containerfile").write_text(source)
    config = (home if wrapper else case_root) / "chalk.c4m"
    report = case_root / "report.json"
    config.write_text(
        'log_format = "plain"\n'
        "custom_report.terminal_chalk_time.enabled = false\n"
        "custom_report.terminal_other_op.enabled = false\n"
        "skip_custom_reports = true\n"
        'podman_log_level = "error"\n'
        "sink_config controls_file {\n"
        "  enabled: true\n"
        '  sink: "file"\n'
        '  filename: env("PODMAN_CONTROL_REPORT")\n'
        "  use_search_path: false\n"
        "}\n"
        'subscribe("report", "controls_file")\n'
        'subscribe("fail", "controls_file")\n'
        'subscribe("virtual", "controls_file")\n' + config_text
    )
    calls.write_text("")
    before = workspaces()
    argv = (
        build_argv
        if build_argv is not None
        else [
            "build",
            "--tag",
            "localhost/control:test",
            "--label",
            "control=exact argv",
            ".",
        ]
    )
    env = dict(
        os.environ,
        HOME=str(home),
        PATH=str(fake_dir) + os.pathsep + os.environ["PATH"],
        PODMAN_CONTROL_CALLS=str(calls),
        PODMAN_CONTROL_ARCH=binary_arch,
        PODMAN_CONTROL_REPORT=str(report),
    )
    if native_status is not None:
        env["PODMAN_CONTROL_NATIVE_ARGV"] = json.dumps(argv)
        env["PODMAN_CONTROL_NATIVE_EXIT"] = str(native_status)
    if instrumented_status is not None:
        env["PODMAN_CONTROL_BUILD_EXIT"] = str(instrumented_status)
    launch_ledger = case_root / "launches"
    if launch_fault:
        env["STAGE_LAUNCH_FAULT"] = launch_fault
        env["STAGE_LAUNCH_LEDGER"] = str(launch_ledger)
    if wrapper:
        env["PATH"] = str(wrapper.parent) + os.pathsep + env["PATH"]
        command = [str(wrapper)]
    else:
        command = [
            str(launch_diagnostic if launch_fault else binary),
            f"--config-file={config}",
            "--use-embedded-config",
            "--skip-custom-reports",
            "--no-color",
            "--log-level=error",
            *extra_flags,
            "podman",
        ]
    result = subprocess.run(
        [*command, *argv],
        cwd=context,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return {
        "name": name,
        "result": result,
        "argv": argv,
        "calls": records(calls),
        "new_workspaces": sorted(workspaces() - before),
        "context_files": sorted(path.name for path in context.iterdir()),
        "report": report.read_text() if report.exists() else "",
        "launches": launch_ledger.read_text().splitlines() if launch_fault else [],
    }


def assert_instrumented(case):
    assert case["result"].returncode == 0, (case["name"], case)
    assert case["calls"][0]["argv"] == ["info", "--format", "json"], case
    builds = [
        call for call in case["calls"] if call["argv"] and call["argv"][0] == "build"
    ]
    assert len(builds) == 1 and "--build-context" in builds[0]["argv"], case
    assert set(builds[0]["assets"]) == {"chalk", "chalk.json"}, builds[0]
    assert case["context_files"] == ["Containerfile"], case
    return builds[0]["derived_containerfile"]


def check_build_retries(root, fake_dir, calls):
    source = 'FROM scratch\nENTRYPOINT ["/bin/true"]\n'
    confidential = "PASSWORD=retry secret"
    argv = ["build", "--build-arg", confidential, "--label", "test=exact argv", "."]
    retry_notice = (
        "chalk: Instrumented Podman build exited with status 17; "
        "retrying the original build without instrumentation."
    )
    for status, notice in (
        (0, "chalk: Build succeeded; Chalk did not instrument this build."),
        (
            23,
            "chalk: the native Podman retry exited with status 23; "
            "Chalk did not instrument this build.",
        ),
    ):
        case = invoke(
            root,
            fake_dir,
            calls,
            f"retry-exit-{status}",
            source,
            build_argv=argv,
            instrumented_status=17,
            native_status=status,
        )
        engine_calls = [call["argv"] for call in case["calls"]]
        assert len(engine_calls) == 3, case
        assert engine_calls[0] == ["info", "--format", "json"], case
        assert "--build-context" in engine_calls[1] and engine_calls[2] == argv, case
        result = case["result"]
        assert result.returncode == status, case
        assert result.stdout.splitlines()[:2] == [
            "instrumented podman stdout",
            "native podman stdout",
        ], case
        stderr = result.stderr.splitlines()
        assert [
            line
            for line in stderr
            if line
            in {
                retry_notice,
                notice,
                "instrumented podman stderr",
                "native podman stderr",
            }
        ] == [
            "instrumented podman stderr",
            retry_notice,
            "native podman stderr",
            notice,
        ], case
        report = case["report"]
        assert confidential not in report and "<<redact>>" in report, report
        reports = json.loads(report)
        assert len(reports) == 1 and not reports[0].get("_CHALKS"), reports
        evidence.append(
            {
                "case": case["name"],
                "build_count": 2,
                "native_argv_preserved": True,
                "status": status,
                "fallback_report_redacted": True,
            }
        )

    outcomes = [
        ("exit-130", 130, None, 130, 1),
        ("exit-143", 143, None, 143, 1),
        ("signal", "signal", None, 137, 1),
    ]
    if launch_diagnostic:
        outcomes += [
            ("forwarded", 17, "forwarded", 143, 1),
            ("timeout", 17, "timeout", 17, 1),
            ("spawn", 17, "spawn", 127, 0),
            ("unknown", 17, "unknown", 127, 1),
        ]
    for name, first_status, fault, status, recorded_builds in outcomes:
        case = invoke(
            root,
            fake_dir,
            calls,
            name,
            source,
            build_argv=argv,
            instrumented_status=first_status,
            native_status=0,
            launch_fault=fault,
        )
        builds = [
            call["argv"] for call in case["calls"] if call["argv"][:1] == ["build"]
        ]
        assert len(builds) == recorded_builds, case
        assert all("--build-context" in build for build in builds), case
        if fault:
            assert case["launches"] == ["injected"], case
        assert case["result"].returncode == status, case
        assert "retrying the original build" not in case["result"].stderr, case
        evidence.append({"case": name, "launch_attempts": 1, "status": status})


evidence = []
with tempfile.TemporaryDirectory(prefix="podman-controls-") as temp:
    root = Path(temp)
    fake_dir = root / "fake"
    fake_dir.mkdir()
    fake = fake_dir / "podman"
    fake.write_text(FAKE_PODMAN)
    fake.chmod(0o755)
    calls = root / "calls.jsonl"
    check_build_retries(root, fake_dir, calls)

    default_case = invoke(
        root,
        fake_dir,
        calls,
        "default-entrypoint",
        'FROM scratch\nENTRYPOINT ["/bin/true"]\n',
    )
    default_derived = assert_instrumented(default_case)
    assert 'ENTRYPOINT ["/chalk","exec","--heartbeat"' in default_derived
    evidence.append({"case": default_case["name"], "instrumented": True})

    nonroot_case = invoke(
        root,
        fake_dir,
        calls,
        "explicit-on-nonroot",
        'FROM scratch\nUSER 10001:10001\nENTRYPOINT ["/bin/true"]\n',
        "podman.wrap_entrypoint = true\n",
    )
    nonroot_derived = assert_instrumented(nonroot_case)
    assert "USER 10001:10001\n" in nonroot_derived
    assert "ONBUILD" not in nonroot_derived
    evidence.append({"case": nonroot_case["name"], "instrumented": True})

    cmd_case = invoke(
        root,
        fake_dir,
        calls,
        "docker-off-cmd-only",
        'FROM scratch\nCMD ["/bin/true"]\n',
        "docker.wrap_entrypoint = false\n",
    )
    cmd_derived = assert_instrumented(cmd_case)
    assert 'ENTRYPOINT ["/chalk","exec","--heartbeat","--"]' in cmd_derived
    assert cmd_derived.count('CMD ["/bin/true"]') == 1
    evidence.append(
        {
            "case": cmd_case["name"],
            "instrumented": True,
            "docker_setting_did_not_control_podman": True,
        }
    )

    wrapped_case = invoke(
        root,
        fake_dir,
        calls,
        "already-wrapped",
        'FROM scratch\nENTRYPOINT ["/chalk", "exec", "--", "/bin/true"]\n',
    )
    wrapped_derived = assert_instrumented(wrapped_case)
    assert wrapped_derived.count("ENTRYPOINT") == 1
    evidence.append(
        {"case": wrapped_case["name"], "instrumented": True, "wrapped_once": True}
    )

    off_case = invoke(
        root,
        fake_dir,
        calls,
        "podman-off-docker-on",
        'FROM scratch\nENTRYPOINT ["/bin/true"]\n',
        "podman.wrap_entrypoint = false\ndocker.wrap_entrypoint = true\n",
    )
    assert off_case["result"].returncode == 0, off_case["result"]
    assert [call["argv"] for call in off_case["calls"]] == [off_case["argv"]], off_case
    assert "--build-context" not in off_case["calls"][0]["argv"]
    assert off_case["new_workspaces"] == []
    assert off_case["context_files"] == ["Containerfile"]
    assert "derived_containerfile" not in off_case["calls"][0]
    evidence.append(
        {
            "case": off_case["name"],
            "native_argv": off_case["calls"][0]["argv"],
            "native_executions": 1,
            "engine_probes": 0,
            "workspace_created": False,
            "docker_setting_independent": True,
        }
    )

    wrapper = root / "wrapper" / "podman"
    wrapper.parent.mkdir()
    shutil.copy2(binary, wrapper)
    virtual_notice = (
        "chalk: Running the native Podman build. "
        "Chalk did not produce a virtual mark.\n"
    )

    for entry in ("cli", "wrapper"):
        for spelling, args, builds, status in [
            ("build", ["build", "--label", "control=exact argv", "."], True, 0),
            ("failed-build", ["build", "--tag", "control:failure", "."], True, 23),
            ("unsupported-build-option", ["build", "--from", "base", "."], True, 0),
            ("image-build", ["image", "build", "."], True, 0),
            ("buildx-build", ["buildx", "build", "."], True, 0),
            (
                "global-option",
                ["--root", "engine root", "image", "build", "."],
                True,
                0,
            ),
            ("build-help", ["build", "--help"], False, 0),
            ("ordinary", ["ps", "--all"], False, 0),
            ("unknown", ["unknown", "build", "."], False, 125),
            ("unknown-option", ["--unknown", "build", "."], False, 125),
            ("pull", ["pull", "localhost/control:test"], False, 0),
            ("push", ["push", "localhost/control:test", "dir:output"], False, 0),
        ]:
            name = f"virtual-{entry}-{spelling}"
            case = invoke(
                root,
                fake_dir,
                calls,
                name,
                'FROM scratch\nENTRYPOINT ["/bin/true"]\n',
                config_text="virtual_chalk = true\n" if entry == "wrapper" else "",
                extra_flags=("--virtual",) if entry == "cli" else (),
                build_argv=args,
                wrapper=wrapper if entry == "wrapper" else None,
                native_status=status,
            )
            proc = case["result"]
            assert proc.returncode == status, case
            assert proc.stdout == "native podman stdout\n", case
            assert proc.stderr == (virtual_notice if builds else ""), case
            engine_argv = [call["argv"] for call in case["calls"]]
            assert case["context_files"] == ["Containerfile"], case
            assert case["new_workspaces"] == [], case
            if spelling in ("pull", "push"):
                launches = [argv for argv in engine_argv if argv[0] == spelling]
                assert launches == [args], case
                reports = json.loads(case["report"])
                assert [report["_OPERATION"] for report in reports] == [spelling], case
            else:
                assert engine_argv == [args], case
                assert not case["report"], case
            evidence.append(
                {
                    "case": name,
                    "native_argv": args,
                    "exit_code": proc.returncode,
                    "engine_calls": len(engine_argv),
                    "notice": proc.stderr.strip(),
                    "reported": bool(case["report"]),
                }
            )

result = {
    "schema_version": 1,
    "source_sha": os.environ.get("CI_COMMIT_SHA"),
    "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "cases": evidence,
    "passed": True,
}
output.write_text(json.dumps(result, indent=2) + "\n")
print("Podman control validation passed")

#!/usr/bin/env python3
"""Compare Docker fallback observations with the pre-Podman contract."""

import argparse
import base64
from dataclasses import dataclass
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ORIGINAL_ARGS = [
    "build",
    "--diagnostic-original=kept",
    "context with spaces",
]
ORIGINAL_STDIN = b"FROM scratch\nRUN printf 'original stdin'\n"
WRAPPED_ARGS = [
    "build",
    "--diagnostic-wrapped=changed",
    "wrapped context",
]
WRAPPED_STDIN = b"FROM scratch\nRUN printf 'wrapped stdin'\n"

FAKE_DOCKER = r'''#!/usr/bin/env python3
import base64
import json
import os
import subprocess
import sys

args = sys.argv[1:]
original = json.loads(os.environ["FAKE_DOCKER_ORIGINAL_ARGS"])
diagnostic_wrapped = json.loads(os.environ["FAKE_DOCKER_WRAPPED_ARGS"])
target_context = os.environ.get("FAKE_DOCKER_TARGET_CONTEXT")
is_build = args[:1] == ["build"] or args[:2] == ["buildx", "build"]

if args == original:
    kind = "native"
elif args == diagnostic_wrapped or (
    is_build and target_context and target_context in args
):
    kind = "wrapped"
elif is_build:
    kind = "ancillary"
else:
    kind = "probe"
stdin = sys.stdin.buffer.read() if kind != "probe" else b""

with open(os.environ["FAKE_DOCKER_CALLS"], "a", encoding="utf-8") as stream:
    stream.write(json.dumps({
        "args": args,
        "kind": kind,
        "stdin": base64.b64encode(stdin).decode("ascii"),
    }) + "\n")

if kind in ("native", "wrapped"):
    prefix = "FAKE_DOCKER_" + kind.upper()
    sys.stdout.write(os.environ[prefix + "_STDOUT"])
    sys.stdout.flush()
    sys.stderr.write(os.environ[prefix + "_STDERR"])
    sys.stderr.flush()
    sys.exit(int(os.environ[prefix + "_STATUS"]))

real = os.environ.get("FAKE_DOCKER_REAL")
if real:
    result = subprocess.run([real, *args], input=stdin, capture_output=True)
    sys.stdout.buffer.write(result.stdout)
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(result.stderr)
    sys.stderr.buffer.flush()
    sys.exit(result.returncode)

if args == ["--version"]:
    print("Docker version 27.0.0, build diagnostic")
    sys.exit(0)
if args == ["version"]:
    print("Client:\n Version: 27.0.0\nServer:\n Engine:\n  Version: 27.0.0")
    sys.exit(0)
if args == ["info"]:
    print("Storage Driver: overlay2")
    sys.exit(0)
if args[:2] == ["context", "inspect"]:
    print('{"Name":"default"}')
    sys.exit(0)
sys.exit(1)
'''


@dataclass
class Observation:
    calls: list[dict]
    native_stderr: str
    native_stdout: str
    result: subprocess.CompletedProcess
    wrapped_stderr: str
    wrapped_stdout: str


def decode_stdin(call):
    return base64.b64decode(call["stdin"])


def read_calls(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines()]


def invoke(
    executable,
    arguments,
    *,
    root,
    ledger_name,
    control_scenario,
    original_args,
    stdin=b"",
    wrapped_status=17,
    native_status=0,
    real_docker=None,
    target_context=None,
):
    calls = root / f"{ledger_name}.jsonl"
    native_stdout = f"{ledger_name}: native stdout\n"
    native_stderr = f"{ledger_name}: native stderr\n"
    wrapped_stdout = f"{ledger_name}: wrapped stdout\n"
    wrapped_stderr = f"{ledger_name}: wrapped stderr\n"
    env = dict(
        os.environ,
        PATH=str(root) + os.pathsep + os.environ["PATH"],
        DOCKER_FALLBACK_SCENARIO=control_scenario,
        FAKE_DOCKER_CALLS=str(calls),
        FAKE_DOCKER_ORIGINAL_ARGS=json.dumps(original_args),
        FAKE_DOCKER_WRAPPED_ARGS=json.dumps(WRAPPED_ARGS),
        FAKE_DOCKER_NATIVE_STATUS=str(native_status),
        FAKE_DOCKER_NATIVE_STDOUT=native_stdout,
        FAKE_DOCKER_NATIVE_STDERR=native_stderr,
        FAKE_DOCKER_WRAPPED_STATUS=str(wrapped_status),
        FAKE_DOCKER_WRAPPED_STDOUT=wrapped_stdout,
        FAKE_DOCKER_WRAPPED_STDERR=wrapped_stderr,
    )
    if real_docker:
        env["FAKE_DOCKER_REAL"] = str(real_docker)
    if target_context:
        env["FAKE_DOCKER_TARGET_CONTEXT"] = str(target_context)
    result = subprocess.run(
        [str(executable), *arguments],
        cwd=root,
        env=env,
        input=stdin,
        capture_output=True,
        timeout=120,
    )
    return Observation(
        calls=read_calls(calls),
        native_stderr=native_stderr,
        native_stdout=native_stdout,
        result=result,
        wrapped_stderr=wrapped_stderr,
        wrapped_stdout=wrapped_stdout,
    )


def assert_streams(observation, *, native, wrapped):
    stdout = observation.result.stdout.decode(errors="replace")
    stderr = observation.result.stderr.decode(errors="replace")
    assert (observation.native_stdout in stdout) is native, observation
    assert (observation.native_stderr in stderr) is native, observation
    assert (observation.wrapped_stdout in stdout) is wrapped, observation
    assert (observation.wrapped_stderr in stderr) is wrapped, observation


def assert_diagnostic_call(call, *, kind):
    assert call["kind"] == kind, call
    if kind == "native":
        assert call["args"] == ORIGINAL_ARGS, call
        assert decode_stdin(call) == ORIGINAL_STDIN, call
    else:
        assert call["args"] == WRAPPED_ARGS, call
        assert decode_stdin(call) == WRAPPED_STDIN, call


def check_diagnostic_cases(binary, root):
    arguments = [
        "--no-use-external-config",
        "--no-color",
        "--skip-command-report",
        "--skip-custom-reports",
        "version",
    ]
    cases = [
        ("preparation-success", "preparation", 0, 0, ["native"]),
        ("preparation-failure", "preparation", 0, 23, ["native"]),
        (
            "wrapped-nonzero-success",
            "wrapped-nonzero",
            17,
            0,
            ["wrapped", "native"],
        ),
        (
            "wrapped-nonzero-failure",
            "wrapped-nonzero",
            17,
            23,
            ["wrapped", "native"],
        ),
        ("post-launch-success", "post-launch", 0, 0, ["wrapped", "native"]),
        ("post-launch-failure", "post-launch", 0, 23, ["wrapped", "native"]),
    ]
    for ledger, scenario, wrapped_status, native_status, expected in cases:
        observation = invoke(
            binary,
            arguments,
            root=root,
            ledger_name=ledger,
            control_scenario=scenario,
            original_args=ORIGINAL_ARGS,
            wrapped_status=wrapped_status,
            native_status=native_status,
        )
        assert observation.result.returncode == native_status, observation
        assert [call["kind"] for call in observation.calls] == expected, observation
        for call, kind in zip(observation.calls, expected):
            assert_diagnostic_call(call, kind=kind)
        assert_streams(
            observation,
            native=True,
            wrapped="wrapped" in expected,
        )

    policy = invoke(
        binary,
        arguments,
        root=root,
        ledger_name="policy-zero-native",
        control_scenario="policy",
        original_args=ORIGINAL_ARGS,
        wrapped_status=0,
        native_status=0,
    )
    assert policy.result.returncode == 1, policy
    assert policy.calls == [], policy
    assert b"diagnostic policy refusal" in policy.result.stderr, policy
    assert_streams(policy, native=False, wrapped=False)
    return len(cases) + 1


def check_functional_cases(binary, root, real_docker):
    context = root / "context"
    context.mkdir()
    original_stdin = b"FROM scratch\n"
    original_args = [
        "build",
        "--no-cache",
        "--tag",
        "chalk-fallback-regression:latest",
        "--file",
        "-",
        str(context),
    ]
    arguments = [
        "--no-use-external-config",
        "--no-color",
        "--no-run-sbom-tools",
        "--no-run-sast-tools",
        "--skip-command-report",
        "--skip-custom-reports",
        "--wrap",
        "docker",
        *original_args,
    ]
    for name, native_status in [
        ("functional-fallback-success", 0),
        ("functional-fallback-failure", 23),
    ]:
        observation = invoke(
            binary,
            arguments,
            root=root,
            ledger_name=name,
            control_scenario=name,
            original_args=original_args,
            stdin=original_stdin,
            wrapped_status=17,
            native_status=native_status,
            real_docker=real_docker,
            target_context=context,
        )
        builds = [
            call
            for call in observation.calls
            if call["kind"] in ("wrapped", "native")
        ]
        assert [call["kind"] for call in builds] == ["wrapped", "native"], observation
        wrapped, native = builds
        assert wrapped["args"] != original_args, wrapped
        assert "--iidfile" in wrapped["args"], wrapped
        wrapped_stdin = decode_stdin(wrapped)
        assert wrapped_stdin != original_stdin, wrapped
        assert b"/chalk.json" in wrapped_stdin, wrapped
        assert native["args"] == original_args, native
        assert decode_stdin(native) == original_stdin, native
        assert observation.result.returncode == native_status, observation
        assert_streams(observation, native=True, wrapped=True)
        assert b"retrying without chalk" in observation.result.stderr, observation
    return 2


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("diagnostic", type=Path)
    parser.add_argument("--chalk", type=Path)
    parser.add_argument("--docker", type=Path)
    args = parser.parse_args()
    diagnostic = args.diagnostic.resolve()
    chalk = args.chalk.resolve() if args.chalk else None
    real_docker = args.docker.resolve() if args.docker else shutil.which("docker")

    with tempfile.TemporaryDirectory(prefix="chalk-docker-fallback-") as temporary:
        root = Path(temporary)
        fake = root / "docker"
        fake.write_text(FAKE_DOCKER)
        fake.chmod(0o755)
        count = check_diagnostic_cases(diagnostic, root)
        if chalk:
            if real_docker:
                available = subprocess.run(
                    [str(real_docker), "info"], capture_output=True, timeout=30
                )
                assert available.returncode == 0, available.stderr.decode(
                    errors="replace"
                )
            count += check_functional_cases(chalk, root, real_docker)

    print(f"{count} Docker fallback regression cases passed")


if __name__ == "__main__":
    main()

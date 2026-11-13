#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
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
    sys.exit(int(os.environ.get("PODMAN_CONTROL_BUILD_EXIT", "0")))

if argv[:2] == ["image", "inspect"]:
    print(json.dumps([{
        "Id": "sha256:" + "a" * 64,
        "Digest": "sha256:" + "b" * 64,
        "RepoTags": ["localhost/control:test"],
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
):
    case_root = root / name
    home = case_root / "home"
    context = case_root / "context"
    home.mkdir(parents=True)
    context.mkdir()
    (context / "Containerfile").write_text(source)
    config = case_root / "chalk.c4m"
    config.write_text(
        'log_format = "plain"\n'
        "custom_report.terminal_chalk_time.enabled = false\n"
        "custom_report.terminal_other_op.enabled = false\n" + config_text
    )
    calls.write_text("")
    before = workspaces()
    argv = build_argv or [
        "build",
        "--tag",
        "localhost/control:test",
        "--label",
        "control=exact argv",
        ".",
    ]
    env = dict(
        os.environ,
        HOME=str(home),
        PATH=str(fake_dir) + os.pathsep + os.environ["PATH"],
        PODMAN_CONTROL_CALLS=str(calls),
        PODMAN_CONTROL_ARCH=binary_arch,
    )
    result = subprocess.run(
        [
            str(binary),
            f"--config-file={config}",
            "--use-embedded-config",
            "--skip-custom-reports",
            "--no-color",
            "--log-level=error",
            *extra_flags,
            "podman",
            *argv,
        ],
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


evidence = []
with tempfile.TemporaryDirectory(prefix="podman-controls-") as temp:
    root = Path(temp)
    fake_dir = root / "fake"
    fake_dir.mkdir()
    fake = fake_dir / "podman"
    fake.write_text(FAKE_PODMAN)
    fake.chmod(0o755)
    calls = root / "calls.jsonl"

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
    assert "ONBUILD USER 0:0\n" in nonroot_derived
    assert "ONBUILD USER 10001:10001\n" in nonroot_derived
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

    virtual_case = invoke(
        root,
        fake_dir,
        calls,
        "virtual-refused",
        'FROM scratch\nENTRYPOINT ["/bin/true"]\n',
        extra_flags=("--virtual",),
    )
    assert virtual_case["result"].returncode == 2, virtual_case["result"]
    assert virtual_case["calls"] == [], virtual_case
    assert virtual_case["new_workspaces"] == []
    assert virtual_case["context_files"] == ["Containerfile"]
    assert (
        virtual_case["result"].stderr
        == "chalk: virtual_chalk is not supported for Podman commands.\n"
    ), virtual_case["result"].stderr
    evidence.append(
        {
            "case": virtual_case["name"],
            "exit_code": 2,
            "engine_calls": 0,
            "workspace_created": False,
            "image_created": False,
        }
    )

    for spelling, build_args in [
        ("global-option", ["--root", str(root / "unused-engine-root"), "build", "."]),
        ("image-build-alias", ["image", "build", "."]),
    ]:
        virtual_form = invoke(
            root,
            fake_dir,
            calls,
            "virtual-" + spelling,
            'FROM scratch\nENTRYPOINT ["/bin/true"]\n',
            extra_flags=("--virtual",),
            build_argv=build_args,
        )
        assert virtual_form["result"].returncode == 2, spelling
        assert virtual_form["calls"] == [], spelling
        assert virtual_form["new_workspaces"] == [], spelling
        evidence.append(
            {"case": "virtual-" + spelling, "exit_code": 2, "engine_calls": 0}
        )

    virtual_unsupported_case = invoke(
        root,
        fake_dir,
        calls,
        "virtual-unsupported-build",
        'FROM scratch\nENTRYPOINT ["/bin/true"]\n',
        extra_flags=("--virtual",),
        build_argv=["build", "--from", "must-not-run", "."],
    )
    assert virtual_unsupported_case["result"].returncode == 2, virtual_unsupported_case[
        "result"
    ]
    assert virtual_unsupported_case["calls"] == [], virtual_unsupported_case
    assert virtual_unsupported_case["new_workspaces"] == []
    assert virtual_unsupported_case["context_files"] == ["Containerfile"]
    assert (
        virtual_unsupported_case["result"].stderr
        == "chalk: virtual_chalk is not supported for Podman commands.\n"
    ), virtual_unsupported_case["result"].stderr
    evidence.append(
        {
            "case": virtual_unsupported_case["name"],
            "exit_code": 2,
            "engine_calls": 0,
            "workspace_created": False,
            "image_created": False,
            "unsupported_build_flag": "--from",
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

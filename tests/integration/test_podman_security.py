#!/usr/bin/env python3
"""Exercise Podman credential reporting and forged-mark projection end to end."""

import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile


binary = Path(sys.argv[1]).resolve()
machine = {"aarch64": "arm64", "x86_64": "amd64"}.get(
    platform.machine(), platform.machine()
)
image_id = "sha256:" + "a" * 64
lineage_id = "ABCDEF-GHJK-MNPQ-RSTUVW"
historical_base = "registry.example/history/base:valid"
attacker_values = [
    "attacker/os",
    "sha256:attacker-image",
    "attacker-config",
    "attacker-user",
    "attacker-operation-name",
    "attacker-operation",
    "attacker-process",
    "attacker-repository",
    "attacker-wrong-type",
]

fake_podman = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import sys

argv = sys.argv[1:]
with Path(os.environ["PODMAN_SECURITY_LEDGER"]).open("a") as stream:
    stream.write(json.dumps(argv) + "\n")

image_id = os.environ["PODMAN_SECURITY_IMAGE_ID"]
if argv and argv[0] in ("push", "pull"):
    sys.exit(int(os.environ["PODMAN_SECURITY_NATIVE_STATUS"]))
if argv[:2] == ["image", "inspect"]:
    print(json.dumps([{
        "Id": image_id,
        "RepoTags": [],
        "Os": "linux",
        "Architecture": os.environ["PODMAN_SECURITY_ARCH"],
        "Config": {
            "Entrypoint": ["/engine-entrypoint"],
            "Cmd": ["engine-command"],
        },
    }]))
    sys.exit(0)
if argv and argv[0] == "create":
    if len(argv) < 2 or argv[1] != image_id:
        sys.stderr.write("mark extraction did not use the immutable image id\n")
        sys.exit(98)
    print("security-scan-container")
    sys.exit(0)
if argv and argv[0] == "cp":
    shutil.copyfile(os.environ["PODMAN_SECURITY_MARK"], argv[2])
    sys.exit(0)
if argv[:2] == ["rm", "--force"]:
    sys.exit(0)
sys.stderr.write("unexpected fake Podman operation\n")
sys.exit(99)
'''


def json_values(text):
    decoder = json.JSONDecoder()
    values = []
    while text.strip():
        text = text.lstrip()
        value, end = decoder.raw_decode(text)
        values.append(value)
        text = text[end:]
    return values


def reports_from_values(values):
    reports = []
    for value in values:
        reports.extend(value if isinstance(value, list) else [value])
    return reports


def reports_from_file(path):
    if not path.exists():
        return []
    return reports_from_values(json_values(path.read_text()))


def cached_reports(path):
    reports = []
    if not path.exists():
        return reports
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        entry = json.loads(line)
        reports.extend(reports_from_values(json_values(entry["$message"])))
    return reports


def operation_report(reports, operation, case_name, sink_name):
    matches = [report for report in reports if report.get("_OPERATION") == operation]
    assert len(matches) == 1, (
        f"{case_name}: {sink_name} operation report count"
    )
    return matches[0]


def assert_projected_artifact(report, expected_platform, case_name, sink_name):
    artifacts = report.get("_CHALKS", [])
    assert len(artifacts) == 1, f"{case_name}: {sink_name} artifact count"
    artifact = artifacts[0]
    assert artifact.get("CHALK_ID") == lineage_id, (
        f"{case_name}: {sink_name} CHALK_ID"
    )
    assert artifact.get("DOCKER_BASE_IMAGE") == historical_base, (
        f"{case_name}: {sink_name} DOCKER_BASE_IMAGE"
    )
    if "DOCKER_PLATFORM" in artifact:
        assert artifact["DOCKER_PLATFORM"] == expected_platform, (
            f"{case_name}: {sink_name} DOCKER_PLATFORM"
        )
    assert artifact.get("PODMAN_IMAGE_ID") == image_id, (
        f"{case_name}: {sink_name} PODMAN_IMAGE_ID"
    )
    for key in ("DOCKER_TAGS", "_IMAGE_USER"):
        assert key not in artifact, f"{case_name}: {sink_name} forged {key}"
    serialized = json.dumps(report, sort_keys=True)
    for attacker_value in attacker_values:
        assert attacker_value not in serialized, (
            f"{case_name}: {sink_name} forged mark value"
        )


forms = [
    ("push-creds-separated", "push", lambda secret, root: [
        "push", "--creds", "user:" + secret, "security-image",
        "dir:" + str(root / "pushed"),
    ]),
    ("push-creds-equals", "push", lambda secret, root: [
        "push", "--creds=user:" + secret, "security-image",
        "dir:" + str(root / "pushed"),
    ]),
    ("pull-creds-separated", "pull", lambda secret, root: [
        "pull", "--creds", "user:" + secret, "security-image",
    ]),
    ("pull-creds-equals", "pull", lambda secret, root: [
        "pull", "--creds=user:" + secret, "security-image",
    ]),
    ("pull-decryption-separated", "pull", lambda secret, root: [
        "pull", "--decryption-key", "/tmp/key:" + secret, "security-image",
    ]),
    ("pull-decryption-equals", "pull", lambda secret, root: [
        "pull", "--decryption-key=/tmp/key:" + secret, "security-image",
    ]),
]


results = []
with tempfile.TemporaryDirectory(prefix="podman-security-") as temp:
    root = Path(temp)
    real_dir = root / "real"
    real_dir.mkdir()
    real = real_dir / "podman"
    real.write_text(fake_podman)
    real.chmod(0o755)

    mark = root / "chalk.json"
    mark.write_text(json.dumps({
        "MAGIC": "dadfedabbadabbed",
        "CHALK_ID": lineage_id,
        "DOCKER_BASE_IMAGE": historical_base,
        "DOCKER_TAGS": "attacker-wrong-type",
        "DOCKER_PLATFORM": "attacker/os",
        "PODMAN_IMAGE_ID": "sha256:attacker-image",
        "_IMAGE_CONFIG_DIGEST": "attacker-config",
        "_IMAGE_USER": "attacker-user",
        "_OPERATION": "attacker-operation-name",
        "_OP_ARGV": ["attacker-operation"],
        "_PROCESS_ARGV": ["attacker-process"],
        "_REPO_TAGS": {"attacker-repository": {}},
    }))

    for form_name, operation, build_args in forms:
        for outcome, native_status in (("success", 0), ("failure", 23)):
            case = root / (form_name + "-" + outcome)
            case_name = case.name
            home = case / "home"
            default_sink = home / ".local" / "chalk" / "chalk.log"
            secondary_sink = case / "secondary.jsonl"
            custom_report_sink = case / "custom-report.jsonl"
            report_cache = case / "report-cache.jsonl"
            ledger = case / "engine-ledger.jsonl"
            case.mkdir()
            default_sink.parent.mkdir(parents=True)
            ledger.write_text("")
            config = case / "security.c4m"
            config.write_text(
                'log_format = "plain"\n'
                'sink_config security_file {\n'
                '  enabled: true\n'
                '  sink: "file"\n'
                '  filename: env("PODMAN_SECURITY_SECONDARY_SINK")\n'
                '  use_search_path: false\n'
                '}\n'
                'sink_config security_failure {\n'
                '  enabled: true\n'
                '  sink: "post"\n'
                '  uri: "http://127.0.0.1:1/podman-security"\n'
                '}\n'
                'subscribe("report", "security_file")\n'
                'subscribe("report", "security_failure")\n'
                'report_template security_retained {\n'
                '  key._OPERATION.use = true\n'
                '  key._ARGV.use = true\n'
                '  key._OP_ARGV.use = true\n'
                '  key._OP_ANCESTOR_ARGVS.use = true\n'
                '  key._OP_ALL_PS_INFO.use = true\n'
                '  key._OP_ERRORS.use = true\n'
                '  key._CHALKS.use = true\n'
                '  key.CHALK_ID.use = true\n'
                '  key.DOCKER_BASE_IMAGE.use = true\n'
                '  key.DOCKER_PLATFORM.use = true\n'
                '  key.PODMAN_IMAGE_ID.use = true\n'
                '  key.DOCKER_TAGS.use = true\n'
                '  key._IMAGE_USER.use = true\n'
                '  key._PROCESS_ARGV.use = true\n'
                '  key.ERR_INFO.use = true\n'
                '}\n'
                'sink_config security_custom_file {\n'
                '  enabled: true\n'
                '  sink: "file"\n'
                '  filename: env("PODMAN_SECURITY_CUSTOM_REPORT_SINK")\n'
                '  use_search_path: false\n'
                '}\n'
                'custom_report security_retained {\n'
                '  enabled: true\n'
                '  report_template: "security_retained"\n'
                '  sink_configs: ["security_custom_file"]\n'
                '  use_when: ["push", "pull"]\n'
                '}\n'
                'custom_report.terminal_chalk_time.enabled = false\n'
                'custom_report.terminal_other_op.enabled = false\n'
                'use_report_cache = true\n'
                'report_cache_location = env("PODMAN_SECURITY_CACHE")\n'
            )
            canary = "podman-" + form_name + "-" + outcome + "-canary"
            secret = canary + '\"line\npassphrase'
            args = build_args(secret, case)
            env = dict(
                os.environ,
                HOME=str(home),
                PATH=str(real_dir) + os.pathsep + os.environ["PATH"],
                PODMAN_SECURITY_ARCH=machine,
                PODMAN_SECURITY_CACHE=str(report_cache),
                PODMAN_SECURITY_IMAGE_ID=image_id,
                PODMAN_SECURITY_LEDGER=str(ledger),
                PODMAN_SECURITY_MARK=str(mark),
                PODMAN_SECURITY_NATIVE_STATUS=str(native_status),
                PODMAN_SECURITY_SECONDARY_SINK=str(secondary_sink),
                PODMAN_SECURITY_CUSTOM_REPORT_SINK=str(custom_report_sink),
            )
            try:
                result = subprocess.run(
                    [
                        str(binary),
                        "--config-file=" + str(config),
                        "--use-embedded-config",
                        "--no-color",
                        "--log-level=none",
                        "podman",
                        *args,
                    ],
                    cwd=case,
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
            except (OSError, subprocess.SubprocessError):
                raise AssertionError(f"{case_name}: Chalk execution") from None
            assert result.returncode == native_status, (
                f"{case_name}: native exit status"
            )

            calls = [json.loads(line) for line in ledger.read_text().splitlines()]
            launches = [call for call in calls if call and call[0] == operation]
            assert launches == [args], f"{case_name}: exact native argv"
            assert canary in ledger.read_text(), f"{case_name}: engine ledger"

            retained_bytes = result.stdout.encode() + result.stderr.encode()
            for path in case.rglob("*"):
                if path.is_file() and path != ledger:
                    retained_bytes += path.read_bytes()
            for representation in (canary, secret, repr(secret)):
                assert representation.encode() not in retained_bytes, (
                    f"{case_name}: retained credential bytes"
                )

            reporting_expected = operation == "push" or native_status == 0
            if reporting_expected:
                assert any(
                    call[:2] == ["create", image_id] for call in calls
                ), f"{case_name}: immutable-id mark extraction"
                default_reports = reports_from_file(default_sink)
                secondary_reports = reports_from_file(secondary_sink)
                custom_reports = reports_from_file(custom_report_sink)
                cache_reports = cached_reports(report_cache)
                for sink_name, reports in (
                    ("default", default_reports),
                    ("secondary", secondary_reports),
                    ("cache", cache_reports),
                ):
                    report = operation_report(
                        reports, operation, case_name, sink_name
                    )
                    assert "<<redact>>" in json.dumps(report), (
                        f"{case_name}: {sink_name} redaction marker"
                    )
                    assert_projected_artifact(
                        report, "linux/" + machine, case_name, sink_name
                    )
                custom_report = operation_report(
                    custom_reports, operation, case_name, "custom report"
                )
                assert "<<redact>>" in json.dumps(custom_report), (
                    f"{case_name}: custom report redaction marker"
                )
                for field in ("_ARGV", "_OP_ARGV", "_OP_ALL_PS_INFO"):
                    assert field in custom_report, (
                        f"{case_name}: custom report {field}"
                    )
                    assert "<<redact>>" in json.dumps(custom_report[field]), (
                        f"{case_name}: custom report redacted {field}"
                    )
            else:
                assert reports_from_file(default_sink) == []
                assert reports_from_file(secondary_sink) == []
                assert reports_from_file(custom_report_sink) == []
                assert cached_reports(report_cache) == []

            results.append({
                "form": form_name,
                "outcome": outcome,
                "native_status": native_status,
                "reported": reporting_expected,
            })

assert len(results) == len(forms) * 2
print("Podman security boundary validation passed")

#!/usr/bin/env python3
"""Verify Podman credential confinement and image-fact authority on a real engine."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

# Keep this identical to podman_compatibility_probe.DEFAULT_BASE_IMAGE. The
# digest is the Alpine 3.22.1 multi-platform index used on AMD64 and ARM64.
DEFAULT_BASE_IMAGE = (
    "docker.io/library/alpine:3.22.1@"
    "sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1"
)

# Official Distribution registry 2.8.3 multi-platform index.
REGISTRY_IMAGE = (
    "docker.io/library/registry:2@"
    "sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"
)

# This credential is intentionally public and fixed. Its complete value is a
# recognizable canary, not a secret. Runtime evidence must still confine it to
# the original Podman invocation and the private engine ledger.
PUBLIC_USERNAME = "chalk-native-security"
PUBLIC_PASSWORD = "podman-public-test-credential-canary"
PUBLIC_CREDENTIAL = PUBLIC_USERNAME + ":" + PUBLIC_PASSWORD
PUBLIC_HTPASSWD = (
    "chalk-native-security:"
    "$2y$05$dhhxXa.hrH.E0cND8iZF3uZTo0.VJa5QCk6Afb1MPKIGCUbuoRDgq"
)

HISTORICAL_CHALK_ID = "X6VRPZ-C828-KDNS-QDXRT0"
ENGINE_USER = "1042:1043"
ENGINE_ENTRYPOINT = ["/bin/sh", "-c"]
ENGINE_COMMAND = ["printf 'engine-startup-truth\\n'"]
ENGINE_STARTUP_OUTPUT = b"engine-startup-truth\n"
FORGED_DIGEST = "f" * 64
FORGED_VALUES = (
    "forged/architecture",
    "forged-architecture",
    "forged-command",
    "forged-context",
    "forged-entrypoint",
    "forged-missing-inspection",
    "forged-operation",
    "forged-operation-argv",
    "forged-os",
    "forged-user",
    "forged-variant",
    "forged.invalid",
    "X_FORGED_UNDECLARED_FIELD",
)

ENGINE_RECORDER = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

ledger = Path(os.environ["CHALK_NATIVE_SECURITY_LEDGER"])
fd = os.open(ledger, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
with os.fdopen(fd, "a") as stream:
    stream.write(json.dumps(sys.argv[1:], separators=(",", ":")) + "\n")

real_home = os.environ.get("CHALK_NATIVE_SECURITY_REAL_HOME")
if real_home:
    os.environ["HOME"] = real_home
real = os.environ["CHALK_NATIVE_SECURITY_REAL_PODMAN"]
os.execv(real, [real, *sys.argv[1:]])
"""


class NativeSecurityFailure(RuntimeError):
    def __init__(self, case, field):
        self.case = case
        self.field = field
        super().__init__(f"{case}: {field}")


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("chalk", type=Path, help="Chalk binary to exercise")
    parser.add_argument("--podman", default="podman", help="Podman executable")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("artifacts/podman/native-security.json"),
    )
    return parser.parse_args()


def resolve_executable(value):
    if isinstance(value, Path) or os.sep in str(value):
        candidate = Path(value).expanduser().resolve()
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
        return None
    return shutil.which(str(value))


def json_values(raw):
    text = raw.decode("utf-8")
    decoder = json.JSONDecoder()
    values = []
    while text.strip():
        text = text.lstrip()
        value, end = decoder.raw_decode(text)
        values.append(value)
        text = text[end:]
    return values


def flatten_reports(values):
    reports = []
    for value in values:
        reports.extend(value if isinstance(value, list) else [value])
    return reports


def normalize_digest(value):
    if not isinstance(value, str):
        return ""
    return value.removeprefix("sha256:")


class NativeSecurityRunner:
    def __init__(self, chalk, podman, output):
        self.chalk = chalk
        self.podman = podman
        self.output = output
        self.registry_name = None
        self.image_references = []
        self.ledger = None
        self.receipt = {
            "schema_version": 1,
            "test": "podman-native-security",
            "binary_sha256": "",
            "base_image": DEFAULT_BASE_IMAGE,
            "registry_image": REGISTRY_IMAGE,
            "engine": {},
            "cases": [],
            "passed": False,
        }

    def require(self, case, field, condition):
        if not condition:
            raise NativeSecurityFailure(case, field)

    def command(
        self,
        case,
        field,
        argv,
        *,
        cwd=None,
        env=None,
        expected=0,
        timeout=300,
    ):
        try:
            result = subprocess.run(
                [str(value) for value in argv],
                cwd=cwd,
                env=env,
                capture_output=True,
                timeout=timeout,
            )
        except (OSError, subprocess.SubprocessError):
            raise NativeSecurityFailure(case, field) from None
        if expected is not None and result.returncode != expected:
            raise NativeSecurityFailure(case, field)
        return result

    def inspect_image(self, case, reference):
        result = self.command(
            case,
            "image inspection",
            [self.podman, "image", "inspect", reference, "--format", "json"],
        )
        try:
            values = json.loads(result.stdout)
            image = values[0]
        except (
            IndexError,
            KeyError,
            TypeError,
            UnicodeDecodeError,
            json.JSONDecodeError,
        ):
            raise NativeSecurityFailure(case, "image inspection document") from None
        self.require(case, "image inspection document", isinstance(image, dict))
        return image

    def engine_info(self):
        case = "prerequisites"
        result = self.command(
            case,
            "Podman availability",
            [self.podman, "info", "--format", "json"],
        )
        try:
            info = json.loads(result.stdout)
            host = info["host"]
            version = info["version"]["Version"]
            buildah = host["buildahVersion"]
            rootless = host["security"]["rootless"]
            remote = host.get("serviceIsRemote", False)
            os_name = host["os"]
            architecture = host["arch"]
        except (KeyError, TypeError, UnicodeDecodeError, json.JSONDecodeError):
            raise NativeSecurityFailure(case, "Podman information document") from None
        self.require(case, "local Podman engine", remote is False)
        self.require(case, "Linux Podman engine", os_name == "linux")
        self.require(case, "rootless Podman engine", rootless is True)
        self.receipt["engine"] = {
            "podman": version,
            "buildah": buildah,
            "os": os_name,
            "architecture": architecture,
            "rootless": rootless,
        }

    def available_port(self):
        for _ in range(20):
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
                sock.bind(("127.0.0.1", 0))
                port = sock.getsockname()[1]
            if port >= 20000:
                return port
        raise NativeSecurityFailure("registry", "high localhost port")

    def registry_status(self, url, authenticated):
        headers = {}
        if authenticated:
            token = base64.b64encode(PUBLIC_CREDENTIAL.encode("utf-8")).decode("ascii")
            headers["Authorization"] = "Basic " + token
        request = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code
        except (OSError, urllib.error.URLError):
            return None

    def start_registry(self, root, nonce):
        case = "registry"
        auth = root / "registry-auth"
        data = root / "registry-data"
        auth.mkdir(mode=0o755)
        data.mkdir(mode=0o755)
        htpasswd = auth / "htpasswd"
        htpasswd.write_text(PUBLIC_HTPASSWD + "\n")
        htpasswd.chmod(0o644)
        port = self.available_port()
        self.registry_name = "chalk-native-security-registry-" + nonce
        self.command(
            case,
            "authenticated registry start",
            [
                self.podman,
                "run",
                "--detach",
                "--name",
                self.registry_name,
                "--publish",
                f"127.0.0.1:{port}:5000",
                "--env",
                "REGISTRY_AUTH=htpasswd",
                "--env",
                "REGISTRY_AUTH_HTPASSWD_REALM=Chalk native security test",
                "--env",
                "REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd",
                "--volume",
                f"{auth.resolve()}:/auth:ro,Z",
                "--volume",
                f"{data.resolve()}:/var/lib/registry:Z",
                REGISTRY_IMAGE,
            ],
            timeout=300,
        )
        url = f"http://127.0.0.1:{port}/v2/"
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if (
                self.registry_status(url, False) == 401
                and self.registry_status(url, True) == 200
            ):
                return f"localhost:{port}"
            time.sleep(0.25)
        raise NativeSecurityFailure(case, "authenticated registry readiness")

    def write_fixture(self, root, source):
        context = root / "crafted-image"
        context.mkdir()
        mark = {
            "MAGIC": "dadfedabbadabbed",
            "CHALK_ID": HISTORICAL_CHALK_ID,
            "PODMAN_IMAGE_ID": "sha256:" + FORGED_DIGEST,
            "_CURRENT_HASH": FORGED_DIGEST,
            "_IMAGE_CONFIG_DIGEST": FORGED_DIGEST,
            "DOCKER_PLATFORM": "forged/architecture",
            "_IMAGE_OS": "forged-os",
            "_IMAGE_ARCHITECTURE": "forged-architecture",
            "_IMAGE_VARIANT": "forged-variant",
            "_IMAGE_USER": "forged-user",
            "_IMAGE_ENTRYPOINT": ["/forged-entrypoint"],
            "_IMAGE_CMD": ["forged-command"],
            "_IMAGE_ONBUILD": ["RUN forged-missing-inspection"],
            "_OPERATION": "forged-operation",
            "_OP_ARGV": ["forged-operation-argv"],
            "_OP_ARTIFACT_CONTEXT": "forged-context",
            "_OP_ARTIFACT_TYPE": "forged-context",
            "_REPO_TAGS": {
                "forged.invalid": {
                    "attacker/image": {"forged": FORGED_DIGEST},
                },
            },
            "_REPO_DIGESTS": {
                "forged.invalid": {"attacker/image": [FORGED_DIGEST]},
            },
            "_REPO_LIST_DIGESTS": {
                "forged.invalid": {"attacker/image": [FORGED_DIGEST]},
            },
            "X_FORGED_UNDECLARED_FIELD": "forged-context",
        }
        # MAGIC must remain the first property for Chalk's embedded-mark scan.
        (context / "chalk.json").write_text(json.dumps(mark) + "\n")
        (context / "Containerfile").write_text(
            f"FROM {DEFAULT_BASE_IMAGE}\n"
            "COPY --chmod=0444 chalk.json /chalk.json\n"
            f"USER {ENGINE_USER}\n"
            f"ENTRYPOINT {json.dumps(ENGINE_ENTRYPOINT)}\n"
            f"CMD {json.dumps(ENGINE_COMMAND)}\n"
        )
        self.image_references.append(source)
        self.command(
            "fixture",
            "crafted image build",
            [
                self.podman,
                "build",
                "--pull=always",
                "--no-cache",
                "--tag",
                source,
                "--file",
                str(context / "Containerfile"),
                str(context),
            ],
            timeout=600,
        )
        image = self.inspect_image("fixture", source)
        config = image.get("Config") or {}
        self.require("fixture", "image user", config.get("User") == ENGINE_USER)
        self.require(
            "fixture", "image entrypoint", config.get("Entrypoint") == ENGINE_ENTRYPOINT
        )
        self.require("fixture", "image command", config.get("Cmd") == ENGINE_COMMAND)
        self.require("fixture", "missing OnBuild field", not config.get("OnBuild"))
        startup = self.command(
            "fixture",
            "startup truth",
            [self.podman, "run", "--rm", source],
        )
        self.require(
            "fixture", "startup truth", startup.stdout == ENGINE_STARTUP_OUTPUT
        )
        installed_mark = self.command(
            "fixture",
            "installed mark",
            [
                self.podman,
                "run",
                "--rm",
                "--entrypoint",
                "/bin/cat",
                source,
                "/chalk.json",
            ],
        )
        try:
            installed = json.loads(installed_mark.stdout)
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise NativeSecurityFailure("fixture", "installed mark document") from None
        self.require(
            "fixture",
            "historical Chalk ID",
            installed.get("CHALK_ID") == HISTORICAL_CHALK_ID,
        )

    def write_case_config(self, case_root):
        additional_report = case_root / "additional-report.jsonl"
        custom_log = case_root / "custom-log.txt"
        report_cache = case_root / "report-cache.jsonl"
        config = case_root / "native-security.c4m"
        config.write_text(
            'log_format = "plain"\n'
            "sink_config native_security_additional_report {\n"
            "  enabled: true\n"
            '  sink: "file"\n'
            '  filename: env("CHALK_NATIVE_SECURITY_ADDITIONAL_REPORT")\n'
            "  use_search_path: false\n"
            "}\n"
            "sink_config native_security_log {\n"
            "  enabled: true\n"
            '  sink: "file"\n'
            '  filename: env("CHALK_NATIVE_SECURITY_LOG")\n'
            "  use_search_path: false\n"
            '  filters: ["fix_new_line"]\n'
            "}\n"
            "sink_config native_security_failure {\n"
            "  enabled: true\n"
            '  sink: "post"\n'
            '  uri: "http://127.0.0.1:1/podman-native-security"\n'
            "  disable_after_errors: 1\n"
            "}\n"
            'subscribe("report", "native_security_additional_report")\n'
            'subscribe("logs", "native_security_log")\n'
            'subscribe("report", "native_security_failure")\n'
            "use_report_cache = true\n"
            'report_cache_location = env("CHALK_NATIVE_SECURITY_CACHE")\n'
        )
        return config, additional_report, custom_log, report_cache

    def read_ledger(self, case):
        try:
            entries = [
                json.loads(line)
                for line in self.ledger.read_text().splitlines()
                if line.strip()
            ]
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            raise NativeSecurityFailure(case, "private engine ledger") from None
        self.require(
            case,
            "private engine ledger mode",
            self.ledger.stat().st_mode & 0o777 == 0o600,
        )
        return entries

    def reports_from_file(self, case, field, path):
        self.require(case, field, path.is_file() and path.stat().st_size > 0)
        try:
            return flatten_reports(json_values(path.read_bytes()))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise NativeSecurityFailure(case, field) from None

    def reports_from_cache(self, case, path):
        field = "report cache document"
        self.require(case, field, path.is_file() and path.stat().st_size > 0)
        reports = []
        try:
            for line in path.read_bytes().splitlines():
                if not line.strip():
                    continue
                entry = json.loads(line)
                reports.extend(flatten_reports(json_values(entry["$message"].encode())))
        except (KeyError, TypeError, UnicodeDecodeError, json.JSONDecodeError):
            raise NativeSecurityFailure(case, field) from None
        return reports

    def operation_report(self, case, field, reports, operation):
        matches = [
            item
            for item in reports
            if isinstance(item, dict) and item.get("_OPERATION") == operation
        ]
        self.require(case, field, len(matches) == 1)
        return matches[0]

    def assert_report_truth(self, case, report, operation, inspected):
        self.require(case, "operation authority", report.get("_OPERATION") == operation)
        artifacts = report.get("_CHALKS") or []
        self.require(case, "artifact count", len(artifacts) == 1)
        artifact = artifacts[0]
        image_id = inspected.get("Id", "")
        config = inspected.get("Config") or {}
        expected_platform = (
            inspected.get("Os", "") + "/" + inspected.get("Architecture", "")
        )
        variant = inspected.get("Variant", "")
        if variant:
            expected_platform += "/" + variant

        self.require(
            case, "historical Chalk ID", artifact.get("CHALK_ID") == HISTORICAL_CHALK_ID
        )
        self.require(
            case,
            "Podman image ID authority",
            normalize_digest(artifact.get("PODMAN_IMAGE_ID"))
            == normalize_digest(image_id),
        )
        self.require(
            case,
            "current hash authority",
            normalize_digest(artifact.get("_CURRENT_HASH"))
            == normalize_digest(image_id),
        )
        self.require(
            case,
            "config digest authority",
            normalize_digest(artifact.get("_IMAGE_CONFIG_DIGEST"))
            == normalize_digest(image_id),
        )
        self.require(
            case,
            "platform authority",
            artifact.get("DOCKER_PLATFORM") == expected_platform,
        )
        self.require(
            case,
            "OS authority",
            artifact.get("_IMAGE_OS") == inspected.get("Os"),
        )
        self.require(
            case,
            "architecture authority",
            artifact.get("_IMAGE_ARCHITECTURE") == inspected.get("Architecture"),
        )
        if variant:
            self.require(
                case, "variant authority", artifact.get("_IMAGE_VARIANT") == variant
            )
        else:
            self.require(
                case,
                "missing variant authority",
                "_IMAGE_VARIANT" not in artifact,
            )
        self.require(
            case,
            "user authority",
            artifact.get("_IMAGE_USER") == config.get("User"),
        )
        self.require(
            case,
            "entrypoint authority",
            artifact.get("_IMAGE_ENTRYPOINT") == config.get("Entrypoint"),
        )
        self.require(
            case,
            "command authority",
            artifact.get("_IMAGE_CMD") == config.get("Cmd"),
        )
        self.require(
            case, "missing OnBuild authority", "_IMAGE_ONBUILD" not in artifact
        )
        self.require(
            case,
            "artifact context authority",
            artifact.get("_OP_ARTIFACT_CONTEXT") == operation,
        )
        self.require(
            case,
            "artifact type authority",
            artifact.get("_OP_ARTIFACT_TYPE") == "Podman Image",
        )
        serialized = json.dumps(report, sort_keys=True)
        self.require(case, "credential redaction marker", "<<redact>>" in serialized)
        self.require(
            case, "credential confinement", PUBLIC_CREDENTIAL not in serialized
        )
        self.require(case, "password confinement", PUBLIC_PASSWORD not in serialized)
        self.require(
            case,
            "forged digest exclusion",
            FORGED_DIGEST not in serialized,
        )
        for value in FORGED_VALUES:
            self.require(case, "forged field exclusion", value not in serialized)

    def case_environment(self, case_root, additional_report, custom_log, report_cache):
        home = case_root / "home"
        (home / ".local" / "chalk").mkdir(parents=True)
        env = dict(os.environ)
        env.update(
            {
                "HOME": str(home),
                "PATH": str(self.ledger.parent) + os.pathsep + env.get("PATH", ""),
                "CHALK_NATIVE_SECURITY_CACHE": str(report_cache),
                "CHALK_NATIVE_SECURITY_LEDGER": str(self.ledger),
                "CHALK_NATIVE_SECURITY_LOG": str(custom_log),
                "CHALK_NATIVE_SECURITY_REAL_HOME": os.environ.get("HOME", ""),
                "CHALK_NATIVE_SECURITY_REAL_PODMAN": self.podman,
                "CHALK_NATIVE_SECURITY_ADDITIONAL_REPORT": str(additional_report),
            }
        )
        return env, home / ".local" / "chalk" / "chalk.log"

    def run_case(self, root, name, operation, form, source, reference):
        case_root = root / name
        case_root.mkdir()
        config, additional_report, custom_log, report_cache = self.write_case_config(
            case_root
        )
        env, default_report = self.case_environment(
            case_root, additional_report, custom_log, report_cache
        )
        credential_args = (
            ["--creds=" + PUBLIC_CREDENTIAL]
            if form == "equals"
            else ["--creds", PUBLIC_CREDENTIAL]
        )
        if operation == "push":
            native_args = [
                "push",
                *credential_args,
                "--tls-verify=false",
                source,
                reference,
            ]
        else:
            native_args = [
                "pull",
                *credential_args,
                "--tls-verify=false",
                reference,
            ]

        self.ledger.write_text("")
        self.ledger.chmod(0o600)
        result = self.command(
            name,
            "Chalk transfer status",
            [
                self.chalk,
                "--config-file=" + str(config),
                "--use-embedded-config",
                "--skip-custom-reports",
                "--no-color",
                "--log-level=trace",
                "podman",
                *native_args,
            ],
            cwd=case_root,
            env=env,
            timeout=300,
        )
        entries = self.read_ledger(name)
        launches = [entry for entry in entries if entry and entry[0] == operation]
        self.require(name, "exact native credential argv", launches == [native_args])
        self.require(
            name,
            "native credential delivery",
            PUBLIC_CREDENTIAL.encode() in self.ledger.read_bytes(),
        )

        retained = result.stdout + result.stderr
        retained_paths = [default_report, additional_report, custom_log, report_cache]
        for path in retained_paths:
            if path.exists():
                retained += path.read_bytes()
        self.require(
            name,
            "retained credential confinement",
            PUBLIC_CREDENTIAL.encode() not in retained,
        )
        self.require(
            name,
            "retained password confinement",
            PUBLIC_PASSWORD.encode() not in retained,
        )

        inspected = self.inspect_image(
            name, source if operation == "push" else reference
        )
        report_groups = (
            (
                "default report",
                self.reports_from_file(name, "default report document", default_report),
            ),
            (
                "additional report sink",
                self.reports_from_file(
                    name,
                    "additional report sink document",
                    additional_report,
                ),
            ),
            ("report cache", self.reports_from_cache(name, report_cache)),
        )
        for report_name, reports in report_groups:
            report = self.operation_report(name, report_name, reports, operation)
            self.assert_report_truth(name, report, operation, inspected)
        self.require(
            name,
            "custom log output",
            custom_log.is_file() and custom_log.stat().st_size > 0,
        )
        self.receipt["cases"].append(
            {
                "name": name,
                "operation": operation,
                "credential_form": form,
                "native_status": result.returncode,
                "credential_forwarded": True,
                "retained_outputs_redacted": True,
                "engine_metadata_authoritative": True,
                "historical_chalk_id_preserved": True,
                "passed": True,
            }
        )
        # Remove the raw credential as soon as this case has been evaluated.
        self.ledger.write_text("")
        self.ledger.chmod(0o600)

    def remove_local_reference(self, case, reference):
        result = self.command(
            case,
            "local pull reference reset",
            [self.podman, "image", "rm", "--force", reference],
            expected=None,
        )
        self.require(case, "local pull reference reset", result.returncode in (0, 1))

    def cleanup(self):
        failures = []
        if self.registry_name:
            result = self.command(
                "cleanup",
                "registry container removal",
                [self.podman, "rm", "--force", self.registry_name],
                expected=None,
                timeout=60,
            )
            if result.returncode != 0:
                failures.append("registry container removal")
            self.registry_name = None
        for reference in reversed(self.image_references):
            result = self.command(
                "cleanup",
                "owned image removal",
                [self.podman, "image", "rm", "--force", reference],
                expected=None,
                timeout=60,
            )
            if result.returncode not in (0, 1):
                failures.append("owned image removal")
        self.image_references.clear()
        if self.ledger is not None:
            try:
                self.ledger.unlink(missing_ok=True)
            except OSError:
                failures.append("private ledger removal")
        if failures:
            raise NativeSecurityFailure("cleanup", failures[0])

    def execute(self):
        self.require("prerequisites", "Chalk executable", bool(self.chalk))
        self.require("prerequisites", "Podman executable", bool(self.podman))
        self.receipt["binary_sha256"] = hashlib.sha256(
            Path(self.chalk).read_bytes()
        ).hexdigest()
        self.engine_info()
        nonce = hashlib.sha256(os.urandom(32)).hexdigest()[:12]
        failure = None
        with tempfile.TemporaryDirectory(
            prefix="chalk-podman-native-security-"
        ) as temp:
            root = Path(temp)
            recorder = root / "recorder"
            recorder.mkdir(mode=0o700)
            engine = recorder / "podman"
            engine.write_text(ENGINE_RECORDER)
            engine.chmod(0o700)
            self.ledger = recorder / "engine-ledger.jsonl"
            self.ledger.write_text("")
            self.ledger.chmod(0o600)
            try:
                registry = self.start_registry(root, nonce)
                source = "localhost/chalk-native-security-" + nonce + ":source"
                repository = registry + "/chalk-native-security-" + nonce + "/crafted"
                equals_ref = repository + ":equals"
                separated_ref = repository + ":separated"
                self.image_references.extend([equals_ref, separated_ref])
                self.write_fixture(root, source)
                self.run_case(
                    root,
                    "push-creds-equals",
                    "push",
                    "equals",
                    source,
                    equals_ref,
                )
                self.run_case(
                    root,
                    "push-creds-separated",
                    "push",
                    "separated",
                    source,
                    separated_ref,
                )
                self.remove_local_reference("pull-creds-equals", equals_ref)
                self.run_case(
                    root,
                    "pull-creds-equals",
                    "pull",
                    "equals",
                    source,
                    equals_ref,
                )
                self.remove_local_reference("pull-creds-separated", separated_ref)
                self.run_case(
                    root,
                    "pull-creds-separated",
                    "pull",
                    "separated",
                    source,
                    separated_ref,
                )
            except NativeSecurityFailure as error:
                failure = error
            except Exception:
                failure = NativeSecurityFailure("runner", "unexpected error")
            try:
                self.cleanup()
            except NativeSecurityFailure as error:
                if failure is None:
                    failure = error

        if failure is not None:
            self.receipt["failure"] = {
                "case": failure.case,
                "field": failure.field,
            }
        self.receipt["passed"] = failure is None
        self.write_receipt()
        if failure is not None:
            sys.stderr.write(
                "Podman native security regression failed: "
                f"{failure.case}: {failure.field}\n"
            )
            return 1
        print("4 Podman native security cases passed")
        return 0

    def write_receipt(self):
        self.output.parent.mkdir(parents=True, exist_ok=True)
        serialized = json.dumps(self.receipt, indent=2) + "\n"
        if PUBLIC_CREDENTIAL in serialized or PUBLIC_PASSWORD in serialized:
            serialized = (
                json.dumps(
                    {
                        "schema_version": 1,
                        "test": "podman-native-security",
                        "passed": False,
                        "failure": {
                            "case": "artifact",
                            "field": "credential confinement",
                        },
                    },
                    indent=2,
                )
                + "\n"
            )
        self.output.write_text(serialized)


def main():
    args = parse_args()
    chalk = resolve_executable(args.chalk)
    podman = resolve_executable(args.podman)
    runner = NativeSecurityRunner(chalk, podman, args.output)
    try:
        return runner.execute()
    except NativeSecurityFailure as error:
        runner.receipt["failure"] = {
            "case": error.case,
            "field": error.field,
        }
        runner.receipt["passed"] = False
        try:
            runner.write_receipt()
        except OSError:
            pass
        sys.stderr.write(
            "Podman native security regression failed: "
            f"{error.case}: {error.field}\n"
        )
        return 1
    except OSError:
        runner.receipt["failure"] = {
            "case": "prerequisites",
            "field": "runner initialization",
        }
        runner.receipt["passed"] = False
        try:
            runner.write_receipt()
        except OSError:
            pass
        sys.stderr.write(
            "Podman native security regression failed: "
            "prerequisites: runner initialization\n"
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())

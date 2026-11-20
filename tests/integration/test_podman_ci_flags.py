#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1]).resolve()
podman = shutil.which("podman")
assert podman
out = Path("artifacts/podman/ci-flags").resolve()
out.mkdir(parents=True, exist_ok=True)
checks = []
observations = []
images = []
containers = []
suffix = str(os.getpid())
alpine = (
    "docker.io/library/alpine@sha256:"
    "eafc1edb577d2e9b458664a15f23ea1c370214193226069eb22921169fc7e43f"
)
report_log = Path.home() / ".local/chalk/chalk.log"
ci_build_isolation = "rootless"
ci_build_env = dict(os.environ, BUILDAH_ISOLATION=ci_build_isolation)
GITLAB_REPORT_PATTERN = (
    r"\x1b\[0Ksection_start:(?P<timestamp>[0-9]+):"
    r"chalk_report\[collapsed=true\]\n"
    r"\x1b\[0KChalk Report\n"
    r"(?P<report>\[.*\])\n"
    r"\x1b\[0Ksection_end:(?P=timestamp):chalk_report\n"
    r"\x1b\[0K\n?"
)


def invoke(argv, *, cwd=None, env=None, require_success=True):
    started = time.monotonic()
    result = subprocess.run(
        argv, cwd=cwd, env=env, capture_output=True, text=True, timeout=240
    )
    elapsed = time.monotonic() - started
    with (out / "commands.jsonl").open("a") as log:
        log.write(
            json.dumps(
                {
                    "argv": argv,
                    "exit": result.returncode,
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                    "elapsed_seconds": elapsed,
                }
            )
            + "\n"
        )
    if require_success:
        assert result.returncode == 0, (argv, result.returncode, result.stderr)
    return result, elapsed


def check(name, condition):
    checks.append({"name": name, "passed": bool(condition)})
    assert condition, name


def inspect(tag):
    result, _ = invoke([podman, "image", "inspect", tag])
    return json.loads(result.stdout)[0]


def tag(name):
    value = "localhost/chalk-ci-" + name + ":" + suffix
    images.append(value)
    return value


def reports_since(offset):
    if not report_log.exists():
        return []
    data = report_log.read_text()[offset:]
    decoder = json.JSONDecoder()
    reports = []
    while data.strip():
        value, end = decoder.raw_decode(data.lstrip())
        reports.extend(value if isinstance(value, list) else [value])
        data = data.lstrip()[end:]
    return reports


def gitlab_reports(prefix, output):
    matches = list(re.finditer(GITLAB_REPORT_PATTERN, output, re.DOTALL))
    check(prefix + " has exactly one configured GitLab report", len(matches) == 1)
    reports = json.loads(matches[0].group("report"))
    check(
        prefix + " output is one build report",
        isinstance(reports, list)
        and len(reports) == 1
        and isinstance(reports[0], dict)
        and reports[0].get("_OPERATION") == "build",
    )
    return reports


def values_for_key(value, wanted):
    values = []
    if isinstance(value, dict):
        for key, child in value.items():
            if key == wanted:
                values.append(child)
            values.extend(values_for_key(child, wanted))
    elif isinstance(value, list):
        for child in value:
            values.extend(values_for_key(child, wanted))
    return values


def check_report_redaction(prefix, documents, sentinels, required_fields):
    serialized = json.dumps(documents, sort_keys=True)
    check(prefix + " serialized reports exist", bool(documents))
    for sentinel in sentinels:
        check(prefix + " omits " + sentinel, sentinel not in serialized)
    present = []
    for field in required_fields:
        values = values_for_key(documents, field)
        check(prefix + " includes " + field, bool(values))
        check(
            prefix + " redacts " + field,
            "<<redact>>" in json.dumps(values, sort_keys=True),
        )
        present.append(field)
    return present


try:
    version, _ = invoke([podman, "version"])
    buildah, _ = invoke([podman, "info", "--format", "{{.Host.BuildahVersion}}"])
    check("podman 6.1.3", "6.1.3" in version.stdout)
    observations.append(
        {
            "podman_version": version.stdout,
            "buildah_version": buildah.stdout.strip(),
            "ci_build_isolation": ci_build_isolation,
        }
    )

    with tempfile.TemporaryDirectory(prefix="chalk-ci-flags-") as temp:
        root = Path(temp)
        wrapped = root / "wrapped"
        proxy_dir = root / "proxy"
        wrapped.mkdir()
        proxy_dir.mkdir()
        (wrapped / "podman").symlink_to(binary)
        calls = root / "calls.jsonl"
        proxy = proxy_dir / "podman"
        proxy.write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ['PODMAN_CI_CALLS'], 'a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
os.execv(os.environ['PODMAN_CI_REAL'], [os.environ['PODMAN_CI_REAL'], *sys.argv[1:]])
""")
        proxy.chmod(0o755)
        launcher = root / "launcher.py"
        launcher.write_text("""#!/usr/bin/env python3
import subprocess, sys
result = subprocess.run(sys.argv[1:])
sys.exit(result.returncode)
""")
        env = dict(
            ci_build_env,
            PATH=str(wrapped)
            + os.pathsep
            + str(proxy_dir)
            + os.pathsep
            + os.environ["PATH"],
            PODMAN_CI_REAL=podman,
            PODMAN_CI_CALLS=str(calls),
        )

        def wrapped_invoke(argv, *, cwd, require_success=True):
            return invoke(
                [sys.executable, str(launcher), str(wrapped / "podman"), *argv],
                cwd=cwd,
                env=env,
                require_success=require_success,
            )

        context = root / "context"
        tools = root / ("tools-argv-secret-" + suffix)
        context.mkdir()
        tools.mkdir()
        (context / "chalk.c4m").write_text(
            "report_template insertion_default {\n"
            "  key._OP_ALL_PS_INFO.use = true\n"
            "}\n"
        )
        (tools / "tool.txt").write_text("named-context-payload\n")
        secret_bytes = b"secret-sentinel-must-not-appear\n"
        secret_hash = hashlib.sha256(secret_bytes).hexdigest()
        secret_source = "token-argv-secret-" + suffix
        (context / secret_source).write_bytes(secret_bytes)
        version_secret = "build-argv-secret-" + suffix
        env_secret = "env-argv-secret-" + suffix
        secret_spec = "id=token,src=" + secret_source
        (context / "start.sh").write_text(
            'printf "user=%s arg=<%s>\\n" "$(id -u)" "$*"\n'
            "cat /tool.txt /inputs /secret.hash\n"
        )
        containerfile = (
            f"FROM {alpine} AS builder\n"
            "ARG VERSION=unset\n"
            'RUN printf "%s|%s\\n" "$VERSION" "$APP_ENV" > /inputs\n'
            "RUN --mount=type=secret,id=token,required "
            "sha256sum /run/secrets/token | cut -d' ' -f1 > /secret.hash\n"
            f"FROM {alpine} AS runtime\n"
            "USER 1000\n"
            "COPY --from=tools tool.txt /tool.txt\n"
            "COPY --from=builder /inputs /inputs\n"
            "COPY --from=builder /secret.hash /secret.hash\n"
            "COPY start.sh /start.sh\n"
            'ENTRYPOINT ["/bin/sh", "/start.sh"]\n'
            'CMD ["runtime"]\n'
            f"FROM {alpine} AS unused\n"
            'ENTRYPOINT ["/bin/false"]\n'
            'CMD ["unused"]\n'
        )
        (context / "Containerfile").write_text(containerfile)
        latest = tag("app-latest")
        sha = tag("app-sha")
        iid = context / "image.iid"
        argv = [
            "build",
            "--file",
            "Containerfile",
            "--target",
            "runtime",
            "--build-arg",
            "VERSION=" + version_secret,
            "--secret",
            secret_spec,
            "--build-context",
            "tools=" + str(tools),
            "--iidfile",
            str(iid),
            "-t",
            latest,
            "-t",
            sha,
            "--label",
            "ci=flags",
            "--annotation",
            "ci=annot",
            "--env",
            "APP_ENV=" + env_secret,
            "--pull=missing",
            "--network=none",
            "--no-cache",
            "--layers=false",
            "-q",
            ".",
        ]
        report_offset = len(report_log.read_text()) if report_log.exists() else 0
        calls.write_text("")
        result, _ = wrapped_invoke(argv, cwd=context)
        reports = [
            r for r in reports_since(report_offset) if r.get("_OPERATION") == "build"
        ]
        recorded = [json.loads(line) for line in calls.read_text().splitlines()]
        builds = [args for args in recorded if args and args[0] == "build"]
        check("combined build status", result.returncode == 0)
        check("combined instrumented once", len(builds) == 1)
        check(
            "customer target preserved",
            "--target" in builds[0]
            and builds[0][builds[0].index("--target") + 1] == "runtime",
        )
        check(
            "single iidfile is customer path",
            builds[0].count("--iidfile") == 1
            and builds[0][builds[0].index("--iidfile") + 1] == str(iid),
        )
        check("network option reached native build", "--network=none" in builds[0])
        check("cache option reached successful native build", "--no-cache" in builds[0])
        check(
            "native build received confidential argv",
            "VERSION=" + version_secret in builds[0]
            and secret_spec in builds[0]
            and "APP_ENV=" + env_secret in builds[0]
            and "tools=" + str(tools) in builds[0],
        )
        check(
            "quiet stdout contains only an image id and newline",
            re.fullmatch(r"[0-9a-f]{64}\n", result.stdout) is not None,
        )
        gitlab_stderr_reports = gitlab_reports("combined GitLab stderr", result.stderr)
        check(
            "configured GitLab stderr report records one artifact",
            gitlab_stderr_reports[0].get("_OP_CHALK_COUNT") == 1,
        )
        check("iidfile exists", iid.is_file())
        latest_info = inspect(latest)
        sha_info = inspect(sha)
        check(
            "quiet stdout exactly matches native image-id output",
            result.stdout == latest_info["Id"].removeprefix("sha256:") + "\n",
        )
        expected_iid_bytes = (
            "sha256:" + latest_info["Id"].removeprefix("sha256:")
        ).encode("ascii")
        check(
            "iidfile is exact sha256-prefixed image id",
            iid.read_bytes() == expected_iid_bytes,
        )
        check("both tags share iidfile image", sha_info["Id"] == latest_info["Id"])
        config = latest_info["Config"]
        check("runtime user", (config.get("User") or "") == "1000")
        check("runtime cmd", (config.get("Cmd") or []) == ["runtime"])
        entry = config.get("Entrypoint") or []
        check("chalk entrypoint", entry[:3] == ["/chalk", "exec", "--heartbeat"])
        run_default, _ = invoke([podman, "run", "--rm", "--network=none", latest])
        runtime_lines = run_default.stdout.splitlines()
        check(
            "runtime startup and named context",
            "user=1000 arg=<runtime>" in runtime_lines
            and "named-context-payload" in runtime_lines,
        )
        check(
            "runtime consumed build arg and env",
            version_secret + "|" + env_secret in runtime_lines,
        )
        check("runtime consumed expected secret bytes", secret_hash in runtime_lines)
        mark_text, _ = invoke(
            [
                podman,
                "run",
                "--rm",
                "--network=none",
                "--entrypoint",
                "/bin/cat",
                latest,
                "/chalk.json",
            ]
        )
        mark = json.loads(mark_text.stdout)
        redacted_fields = check_report_redaction(
            "successful build",
            [mark, *reports, *gitlab_stderr_reports],
            [version_secret, env_secret, secret_spec, secret_source, str(tools)],
            [
                "INJECTOR_ARGV",
                "_ARGV",
                "_OP_ARGV",
                "_OP_ANCESTOR_ARGVS",
                "_OP_ALL_PS_INFO",
            ],
        )
        check(
            "secret file contents absent from mark and reports",
            secret_bytes.decode().strip()
            not in mark_text.stdout
            + json.dumps(reports)
            + json.dumps(gitlab_stderr_reports),
        )
        check(
            "DOCKER_TAGS has both names",
            set(mark.get("DOCKER_TAGS") or []) == {latest, sha},
        )
        check("DOCKER_TARGET is runtime", mark.get("DOCKER_TARGET") == "runtime")
        check(
            "original Containerfile is unchanged in mark",
            mark.get("DOCKER_FILE") == containerfile,
        )
        check("CHALK_ID present", bool(mark.get("CHALK_ID")))
        gitlab_artifacts = [
            artifact
            for report in gitlab_stderr_reports
            for artifact in report.get("_CHALKS", [])
        ]
        check(
            "GitLab stderr report identity matches built image",
            any(
                artifact.get("CHALK_ID") == mark.get("CHALK_ID")
                and artifact.get("_CURRENT_HASH", "").removeprefix("sha256:")
                == latest_info["Id"].removeprefix("sha256:")
                for artifact in gitlab_artifacts
            ),
        )
        artifacts = [
            artifact for report in reports for artifact in report.get("_CHALKS", [])
        ]
        check(
            "report identity matches built image",
            any(
                artifact.get("CHALK_ID") == mark.get("CHALK_ID")
                and artifact.get("PODMAN_IMAGE_ID", "").removeprefix("sha256:")
                == latest_info["Id"].removeprefix("sha256:")
                for artifact in artifacts
            ),
        )
        observations.append(
            {
                "combined": {
                    "image_id": latest_info["Id"],
                    "chalk_id": mark.get("CHALK_ID"),
                    "native_build_count": len(builds),
                    "gitlab_stderr_report_count": len(gitlab_stderr_reports),
                    "redacted_fields": redacted_fields,
                }
            }
        )
        (out / "combined-mark.json").write_text(json.dumps(mark, indent=2) + "\n")
        (out / "combined-build-reports.json").write_text(
            json.dumps(reports, indent=2) + "\n"
        )
        (out / "combined-gitlab-stderr-reports.json").write_text(
            json.dumps(gitlab_stderr_reports, indent=2) + "\n"
        )

        (context / "Containerfile").write_text(
            'FROM scratch\nENTRYPOINT ["/scratch-start"]\nCMD ["scratch-cmd"]\n'
        )
        for quiet in (False, True):
            scratch = tag("scratch-single-attempt-" + str(quiet))
            args = ["build", "--network=none", "-t", scratch, "."]
            if quiet:
                args.insert(1, "-q")
            calls.write_text("")
            result, _ = wrapped_invoke(args, cwd=context, require_success=False)
            check(
                "shell guard failure is nonzero " + str(quiet), result.returncode != 0
            )
            builds = [
                json.loads(line)
                for line in calls.read_text().splitlines()
                if json.loads(line) and json.loads(line)[0] == "build"
            ]
            check(
                "scratch single attempt without replay " + str(quiet),
                len(builds) == 1 and "--build-context" in builds[0],
            )
            check(
                "scratch failure has no successful fallback notice " + str(quiet),
                "retrying" not in result.stderr
                and "Build succeeded" not in result.stderr,
            )
            inspected, _ = invoke(
                [podman, "image", "inspect", scratch], require_success=False
            )
            check(
                "scratch failure creates no image " + str(quiet),
                inspected.returncode != 0,
            )
            observations.append(
                {
                    "scratch_single_attempt": {
                        "quiet": quiet,
                        "status": result.returncode,
                        "build_count": len(builds),
                    }
                }
            )
        (context / "chalk.c4m").unlink()

        (context / "Containerfile").write_text(
            f"FROM {alpine} AS builder\n"
            'ENTRYPOINT ["/bin/echo", "stage-builder"]\n'
            'CMD ["cmd-builder"]\n'
            f"FROM {alpine} AS runtime\n"
            'ENTRYPOINT ["/bin/echo", "stage-runtime"]\n'
            'CMD ["cmd-runtime"]\n'
        )
        middle = tag("middle")
        calls.write_text("")
        wrapped_invoke(["build", "--target", "builder", "-t", middle, "."], cwd=context)
        middle_builds = [
            json.loads(line)
            for line in calls.read_text().splitlines()
            if json.loads(line) and json.loads(line)[0] == "build"
        ]
        check("middle target instrumented once", len(middle_builds) == 1)
        middle_info = inspect(middle)
        check(
            "middle target keeps distinct startup",
            middle_info["Config"].get("Entrypoint")
            == [
                "/chalk",
                "exec",
                "--heartbeat",
                "--exec-command-name",
                "/bin/echo",
                "--",
                "stage-builder",
            ],
        )
        check(
            "middle target keeps distinct cmd",
            middle_info["Config"].get("Cmd") == ["cmd-builder"],
        )
        final = tag("final-target")
        calls.write_text("")
        wrapped_invoke(["build", "--target", "runtime", "-t", final, "."], cwd=context)
        final_builds = [
            json.loads(line)
            for line in calls.read_text().splitlines()
            if json.loads(line) and json.loads(line)[0] == "build"
        ]
        check("final named target instrumented once", len(final_builds) == 1)
        final_info = inspect(final)
        check(
            "final target keeps distinct startup",
            final_info["Config"].get("Entrypoint")
            == [
                "/chalk",
                "exec",
                "--heartbeat",
                "--exec-command-name",
                "/bin/echo",
                "--",
                "stage-runtime",
            ],
        )
        check(
            "final named target keeps distinct cmd",
            final_info["Config"].get("Cmd") == ["cmd-runtime"],
        )

        declared = tag("declared-base")
        replacement = tag("replacement-base")
        named_output = tag("named-context-fallback")
        invoke([podman, "tag", alpine, declared])
        replacement_ctx = root / "replacement"
        replacement_ctx.mkdir()
        (replacement_ctx / "Containerfile").write_text(
            f"FROM {alpine}\n"
            'RUN printf "replacement-context\\n" > /replacement-proof\n'
            'ENTRYPOINT ["/bin/echo", "replacement-start"]\n'
            'CMD ["replacement-cmd"]\n'
        )
        invoke(
            [
                podman,
                "build",
                "--network=none",
                "-t",
                replacement,
                str(replacement_ctx),
            ],
            env=ci_build_env,
        )
        named_ctx = root / "named-replacement"
        named_ctx.mkdir()
        (named_ctx / "Containerfile").write_text("FROM " + declared + "\n")
        named_argv = [
            "build",
            "--build-context",
            declared + "=docker-image://" + replacement,
            "-t",
            named_output,
            ".",
        ]
        calls.write_text("")
        named_result, _ = wrapped_invoke(named_argv, cwd=named_ctx)
        named_calls = [json.loads(line) for line in calls.read_text().splitlines()]
        check("named-context replacement native status", named_result.returncode == 0)
        check(
            "named-context replacement uses one original native build",
            named_calls == [named_argv],
        )
        named_info = inspect(named_output)
        check(
            "named-context replacement keeps replacement startup",
            named_info["Config"].get("Entrypoint") == ["/bin/echo", "replacement-start"]
            and named_info["Config"].get("Cmd") == ["replacement-cmd"],
        )
        named_files, _ = invoke(
            [
                podman,
                "run",
                "--rm",
                "--entrypoint",
                "/bin/sh",
                named_output,
                "-c",
                "test -f /replacement-proof && test ! -e /chalk && "
                "test ! -e /chalk.json",
            ]
        )
        check(
            "named-context replacement contains no Chalk", named_files.returncode == 0
        )
        observations.append(
            {
                "named_context_fallback": {
                    "status": named_result.returncode,
                    "native_calls": len(named_calls),
                    "entrypoint": named_info["Config"].get("Entrypoint"),
                }
            }
        )

        never_ctx = root / "never"
        never_ctx.mkdir()
        (never_ctx / "Containerfile").write_text(
            "FROM registry.invalid/chalk-ci-never:latest\n" 'ENTRYPOINT ["/bin/true"]\n'
        )
        never_tag = tag("never")
        calls.write_text("")
        never_result, _ = wrapped_invoke(
            ["build", "--pull=never", "-t", never_tag, str(never_ctx)],
            cwd=root,
            require_success=False,
        )
        never_calls = [json.loads(line) for line in calls.read_text().splitlines()]
        check(
            "pull=never does not fetch",
            not any(args[:2] == ["pull", "--quiet"] for args in never_calls),
        )
        check(
            "pull=never falls back to native argv",
            any(
                args and args[0] == "build" and "--pull=never" in args
                for args in never_calls
            ),
        )
        observations.append(
            {
                "pull_never_exit": never_result.returncode,
                "pull_never_call_count": len(never_calls),
            }
        )

        fallback_tag = tag("fallback")
        calls.write_text("")
        wrapped_invoke(
            ["build", "--from", "scratch", "-t", fallback_tag, "."],
            cwd=context,
            require_success=False,
        )
        fallback_calls = [json.loads(line) for line in calls.read_text().splitlines()]
        check(
            "unknown flag is native once",
            len([args for args in fallback_calls if args and args[0] == "build"]) == 1,
        )
        check(
            "unknown flag does not probe info",
            not any(args and args[0] == "info" for args in fallback_calls),
        )
finally:
    for container in reversed(containers):
        subprocess.run([podman, "rm", "-f", container], capture_output=True)
    for image in reversed(images):
        subprocess.run([podman, "image", "rm", "-f", image], capture_output=True)
    (out / "evidence.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "source_sha": os.environ.get("CI_COMMIT_SHA"),
                "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                "checks": checks,
                "observations": observations,
                "passed": sys.exc_info()[0] is None,
            },
            indent=2,
        )
        + "\n"
    )

#!/usr/bin/env python3
"""Verify wrapping controls on a disposable local native Podman engine."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tarfile
import uuid

from podman_compatibility_probe import DEFAULT_BASE_IMAGE

binary = Path(sys.argv[1]).resolve()
engine = shutil.which("podman")
assert engine, "a local Podman engine is required"
output = Path("artifacts/podman/native-controls.json")
output.parent.mkdir(parents=True, exist_ok=True)
record = {"passed": False, "cases": [], "commands": [], "cleanup": []}
images = []
containers = []


def save():
    output.write_text(json.dumps(record, indent=2) + "\n")


def run(args, *, required=True, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, timeout=180, **kwargs)
    record["commands"].append(
        {
            "argv": args,
            "status": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
        }
    )
    save()
    if required:
        assert result.returncode == 0, record["commands"][-1]
    return result


def check_descendant_users(root, prefix, env, ledger):
    context = root / "descendant-users"
    context.mkdir()
    recipe = context / "Containerfile"
    (context / "start.sh").write_text(
        'echo application "$(id -u):$(id -g)" "${CALLER_HOOK:-direct}"\n'
    )
    startup = 'ENTRYPOINT ["/bin/sh", "/start.sh"]\n'

    def build(contents, format_args, wrapped):
        recipe.write_text(contents)
        image = "localhost/chalk-descendant-user:" + uuid.uuid4().hex
        images.append(image)
        argv = ["build", "--pull=never", *format_args, "--tag", image, str(context)]
        if wrapped:
            ledger.write_text("")
            result = run([*prefix, "podman", *argv], env=env)
            builds = [
                call
                for line in ledger.read_text().splitlines()
                if (call := json.loads(line))[:1] == ["build"]
            ]
            assert len(builds) == 1 and "--build-context" in builds[0], (
                builds,
                result.stderr,
            )
            assert [arg for arg in builds[0] if arg.startswith("--format")] == [
                arg for arg in format_args if arg.startswith("--format")
            ], builds
        else:
            run([engine, *argv])
        assert recipe.read_text() == contents
        return image

    def image_state(image):
        inspection = json.loads(run([engine, "image", "inspect", image]).stdout)[0]
        output = run([engine, "run", "--rm", "--network=none", image]).stdout.strip()
        return inspection["ManifestType"], output

    def image_mark(image):
        return json.loads(
            run(
                [
                    engine,
                    "run",
                    "--rm",
                    "--network=none",
                    "--entrypoint",
                    "/bin/cat",
                    image,
                    "/chalk.json",
                ]
            ).stdout
        )

    users = [
        ("literal", "USER 10011:10012\n", "application 10011:10012 direct"),
        (
            "variable",
            "ARG APP_USER=10021:10022\nUSER $APP_USER\n",
            "application 10021:10022 direct",
        ),
        (
            "deferred",
            "USER 10031:10032\nONBUILD USER 10033:10034\nONBUILD ENV CALLER_HOOK=applied\n",
            "application 10033:10034 applied",
        ),
    ]
    for user_case, instructions, expected in users:
        parent_recipe = f"FROM {DEFAULT_BASE_IMAGE}\nCOPY start.sh /start.sh\n{instructions}{startup}"
        for fmt, flags, manifest_type in [
            ("default", [], None),
            ("oci", ["--format", "oci"], "application/vnd.oci.image.manifest.v1+json"),
            (
                "docker",
                ["--format=docker"],
                "application/vnd.docker.distribution.manifest.v2+json",
            ),
        ]:
            parent_flags = ["--format=docker"] if user_case == "deferred" else flags
            native_parent = build(parent_recipe, parent_flags, False)
            parent = build(parent_recipe, parent_flags, True)
            assert image_state(parent) == image_state(native_parent), (user_case, fmt)
            child_recipe = f"FROM {parent}\n"
            native_child = build(child_recipe, flags, False)
            child = build(child_recipe, flags, True)
            native_type, native_startup = image_state(native_child)
            wrapped_type, wrapped_startup = image_state(child)
            assert native_type == wrapped_type, (
                user_case,
                fmt,
                native_type,
                wrapped_type,
            )
            if manifest_type:
                assert native_type == manifest_type, (user_case, fmt, native_type)
            assert native_startup == wrapped_startup == expected, (
                user_case,
                fmt,
                expected,
                native_startup,
                wrapped_startup,
            )
            parent_mark = image_mark(parent)
            native_mark = image_mark(native_child)
            child_mark = image_mark(child)
            assert native_mark == parent_mark, (user_case, fmt)
            assert parent_mark["CHALK_ID"] and child_mark["CHALK_ID"], (user_case, fmt)
            assert child_mark["CHALK_ID"] != parent_mark["CHALK_ID"], (user_case, fmt)
            assert (
                child_mark["DOCKER_BASE_IMAGE_CHALK"]["CHALK_ID"]
                == parent_mark["CHALK_ID"]
            )
            record["cases"].append(
                {
                    "name": f"{user_case}-user-{fmt}-descendant",
                    "passed": True,
                    "native_format": native_type,
                    "wrapped_format": wrapped_type,
                    "native_startup": native_startup,
                    "wrapped_startup": wrapped_startup,
                    "parent_chalk_id": parent_mark["CHALK_ID"],
                    "native_child_chalk_id": native_mark["CHALK_ID"],
                    "wrapped_child_chalk_id": child_mark["CHALK_ID"],
                    "wrapped_child_parent_chalk_id": child_mark[
                        "DOCKER_BASE_IMAGE_CHALK"
                    ]["CHALK_ID"],
                }
            )
            save()


try:
    info = json.loads(run([engine, "info", "--format", "json"]).stdout)
    record["engine"] = info
    run([engine, "pull", "--quiet", DEFAULT_BASE_IMAGE])
    with tempfile.TemporaryDirectory(prefix="podman-native-controls-") as directory:
        root = Path(directory)
        proxy = root / "bin"
        proxy.mkdir()
        ledger = root / "engine.jsonl"
        (proxy / "podman").write_text(
            f"#!{sys.executable}\nimport json,os,sys\n"
            "with open(os.environ['PODMAN_NATIVE_CONTROL_LEDGER'], 'a') as out:\n"
            " out.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "os.execv(os.environ['PODMAN_NATIVE_CONTROL_ENGINE'], "
            "[os.environ['PODMAN_NATIVE_CONTROL_ENGINE'], *sys.argv[1:]])\n"
        )
        (proxy / "podman").chmod(0o755)
        env = dict(
            os.environ,
            PATH=str(proxy) + os.pathsep + os.environ["PATH"],
            PODMAN_NATIVE_CONTROL_LEDGER=str(ledger),
            PODMAN_NATIVE_CONTROL_ENGINE=engine,
        )
        cases = [
            ("default", "", "", '["/bin/echo", "hello"]', '["tail"]', True),
            ("virtual", "", "", '["/bin/echo", "hello"]', '["tail"]', False),
            (
                "explicit-on",
                "podman.wrap_entrypoint = true\n",
                "",
                '["/bin/echo", "hello"]',
                '["tail"]',
                True,
            ),
            (
                "off-docker-on",
                "podman.wrap_entrypoint = false\ndocker.wrap_entrypoint = true\n",
                "",
                '["/bin/echo", "hello"]',
                '["tail"]',
                False,
            ),
            (
                "on-docker-off",
                "docker.wrap_entrypoint = false\n",
                "",
                '["/bin/echo", "hello"]',
                '["tail"]',
                True,
            ),
            ("non-root", "", "1000:1000", '["/bin/echo", "hello"]', '["tail"]', True),
            ("cmd-only", "", "", None, '["/bin/echo", "cmd-only"]', True),
            (
                "already-wrapped",
                "",
                "",
                '["/chalk", "exec", "--heartbeat", "--", "/bin/echo", "already"]',
                '["tail"]',
                True,
            ),
        ]
        for name, settings, user, entrypoint, cmd, wrapped in cases:
            context = root / name
            context.mkdir()
            recipe = f"FROM {DEFAULT_BASE_IMAGE}\n"
            if user:
                recipe += f"USER {user}\n"
            if entrypoint:
                recipe += f"ENTRYPOINT {entrypoint}\n"
            recipe += f"CMD {cmd}\n"
            (context / "Containerfile").write_text(recipe)
            config = context / "settings.c4m"
            config.write_text(settings)
            image = "localhost/chalk-native-control-" + uuid.uuid4().hex
            images.append(image)
            argv = ["build", "--pull=never", "--tag", image, str(context)]
            ledger.write_text("")
            prefix = [
                str(binary),
                "--config-file=" + str(config),
                "--use-embedded-config",
                "--no-color",
                "--no-run-sbom-tools",
                "--no-run-sast-tools",
                "--skip-command-report",
                "--skip-custom-reports",
            ]
            virtual_flags = ["--virtual"] if name == "virtual" else []
            result = run([*prefix, *virtual_flags, "podman", *argv], env=env)
            if virtual_flags:
                assert (
                    result.stderr.splitlines().count(
                        "chalk: Running the native Podman build. "
                        "Chalk did not produce a virtual mark."
                    )
                    == 1
                ), result.stderr
            calls = [json.loads(line) for line in ledger.read_text().splitlines()]
            builds = [call for call in calls if call[:1] == ["build"]]
            assert len(builds) == 1, (name, calls)
            assert ("--build-context" in builds[0]) is wrapped, (name, builds)
            if not wrapped:
                assert calls == [argv], calls
            config_image = json.loads(run([engine, "image", "inspect", image]).stdout)[
                0
            ]["Config"]
            assert config_image.get("User", "") == user, (name, config_image)
            effective = (config_image.get("Entrypoint") or []) + (
                config_image.get("Cmd") or []
            )
            original = (json.loads(entrypoint) if entrypoint else []) + json.loads(cmd)
            if not wrapped or name == "already-wrapped":
                assert effective == original, (name, effective, original)
            else:
                assert effective[:3] == ["/chalk", "exec", "--heartbeat"], name
                separator = effective.index("--")
                application = effective[separator + 1 :]
                if "--exec-command-name" in effective[:separator]:
                    executable_at = effective.index("--exec-command-name") + 1
                    application = [effective[executable_at], *application]
                assert application == original, (name, application, original)
            container = run(
                [engine, "create", "--entrypoint", "/bin/true", image]
            ).stdout.strip()
            containers.append(container)
            mark_path = context / "extracted-mark.json"
            extracted = run(
                [engine, "cp", container + ":/chalk.json", str(mark_path)],
                required=wrapped,
            )
            archive = context / "image.tar"
            run(
                [
                    engine,
                    "save",
                    "--format",
                    "docker-archive",
                    "--output",
                    str(archive),
                    image,
                ]
            )
            with tarfile.open(archive) as saved:
                manifest = json.load(saved.extractfile("manifest.json"))
                image_config = json.load(saved.extractfile(manifest[0]["Config"]))
            hooks = image_config.get("config", {}).get("OnBuild") or []
            assert not hooks, (name, hooks)
            if wrapped:
                mark = json.loads(mark_path.read_text())
                assert mark.get("CHALK_ID"), (name, mark)
            else:
                assert extracted.returncode != 0
                assert (
                    run(
                        [
                            engine,
                            "cp",
                            container + ":/chalk",
                            str(context / "unexpected-chalk"),
                        ],
                        required=False,
                    ).returncode
                    != 0
                )
            record["cases"].append(
                {
                    "name": name,
                    "passed": True,
                    "image": image,
                    "wrapped": wrapped,
                    "calls": calls,
                    "config": config_image,
                }
            )
            save()
        for case_name, opener, declaration in [
            ("custom-escape", "RUN cat `\n<<EOF", "# escape=`\n"),
            ("vertical-tab", "RUN\vcat <<EOF", ""),
            ("form-feed", "RUN\fcat <<EOF", ""),
            ("carriage-return", "RUN cat\r<<EOF", ""),
            ("inline-hash", "RUN echo ok # <<EOF", ""),
        ]:
            escaped = root / case_name
            escaped.mkdir()
            escaped_recipe = (
                f"{declaration}FROM {DEFAULT_BASE_IMAGE}\n{opener}\n"
                'ENTRYPOINT ["/forged"]\nEOF\nCMD ["/bin/true"]\n'
            )
            (escaped / "Containerfile").write_text(escaped_recipe)
            native_image = "localhost/chalk-native-escape-" + uuid.uuid4().hex
            wrapped_image = "localhost/chalk-wrapped-escape-" + uuid.uuid4().hex
            native = run(
                [engine, "build", "--pull=never", "--tag", native_image, str(escaped)],
                required=False,
            )
            if native.returncode == 0:
                images.append(native_image)
            escaped_args = [
                "build",
                "--pull=never",
                "--tag",
                wrapped_image,
                str(escaped),
            ]
            ledger.write_text("")
            passthrough = run(
                [*prefix, "podman", *escaped_args], env=env, required=False
            )
            calls = [json.loads(line) for line in ledger.read_text().splitlines()]
            assert calls == [escaped_args], calls
            assert passthrough.returncode == native.returncode, "heredoc native status"
            assert (escaped / "Containerfile").read_bytes() == escaped_recipe.encode()
            if passthrough.returncode == 0:
                images.append(wrapped_image)
                original_config = json.loads(
                    run([engine, "image", "inspect", native_image]).stdout
                )[0]["Config"]
                actual_config = json.loads(
                    run([engine, "image", "inspect", wrapped_image]).stdout
                )[0]["Config"]
                for key in ("Entrypoint", "Cmd", "User", "OnBuild"):
                    assert actual_config.get(key) == original_config.get(key), key
            record["cases"].append(
                {
                    "name": case_name + "-native-passthrough",
                    "passed": True,
                    "native_status": native.returncode,
                    "calls": calls,
                }
            )
            save()
        check_descendant_users(root, prefix, env, ledger)
    record["passed"] = True
finally:
    for container in containers:
        result = run([engine, "rm", "--force", container], required=False)
        record["cleanup"].append({"container": container, "status": result.returncode})
    for image in images:
        result = run([engine, "rmi", "--force", image], required=False)
        record["cleanup"].append({"image": image, "status": result.returncode})
    save()
print(f"{len(record['cases'])} native Podman wrapping cases passed")

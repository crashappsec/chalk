#!/usr/bin/env python3
"""Probe the Podman features required by Chalk build instrumentation."""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

DEFAULT_BASE_IMAGE = (
    "docker.io/library/alpine:3.22.1@"
    "sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1"
)
DEFAULT_FIXTURE_ID = "podman-build-capabilities-v2"
PINNED_IMAGE = re.compile(r"@sha256:[0-9a-f]{64}$")
STABLE_VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


class ProbeFailure(RuntimeError):
    pass


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--podman", default="podman", help="Podman executable")
    parser.add_argument("--fixture-id", default=DEFAULT_FIXTURE_ID)
    parser.add_argument("--expect-podman", required=True)
    parser.add_argument("--expect-buildah", required=True)
    parser.add_argument("--base-image", default=DEFAULT_BASE_IMAGE)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("artifacts/podman/compatibility-probe.json"),
    )
    parser.add_argument("--keep-images", action="store_true")
    return parser.parse_args()


def run(receipt, argv, *, check=True):
    completed = subprocess.run(argv, capture_output=True, text=True)
    record = {
        "argv": [str(value) for value in argv],
        "exit_code": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    }
    receipt["commands"].append(record)
    if check and completed.returncode != 0:
        raise ProbeFailure(
            f"command exited with status {completed.returncode}: {argv!r}"
        )
    return completed


def stable_version(value, name):
    if not isinstance(value, str) or STABLE_VERSION.fullmatch(value) is None:
        raise ProbeFailure(f"podman info returned an invalid {name} version")
    return value


def inspect_image(receipt, podman, reference):
    inspected = run(
        receipt,
        [podman, "image", "inspect", reference, "--format", "json"],
    )
    try:
        values = json.loads(inspected.stdout)
        value = values[0]
    except (IndexError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise ProbeFailure(
            f"Podman returned invalid image metadata for {reference}"
        ) from error
    return {
        "reference": reference,
        "id": value.get("Id", ""),
        "digest": value.get("Digest", ""),
        "repo_digests": value.get("RepoDigests") or [],
        "os": value.get("Os", ""),
        "architecture": value.get("Architecture", ""),
    }


def tag_component(value):
    result = re.sub(r"[^a-z0-9_.-]+", "-", value.lower()).strip("-.")
    if not result:
        raise ProbeFailure("fixture ID cannot form an image tag")
    return result[:80]


def write_fixture(root, base_image, base_tag):
    base_context = root / "base"
    final_context = root / "final"
    asset_context = root / "assets"
    base_context.mkdir()
    final_context.mkdir()
    asset_context.mkdir()
    (asset_context / "payload").write_text("named-context\n")
    helper = asset_context / "probe-helper"
    helper.write_text(
        "#!/bin/sh\nset -eu\n"
        'test "$(cat /probe-assets/payload)" = named-context\n'
        "cp /probe-assets/payload /probe-mounted-context\n"
    )
    helper.chmod(0o755)
    (base_context / "Containerfile").write_text(
        f"FROM {base_image}\n"
        "RUN printf base-ready > /probe-base-ready\n"
        'ONBUILD RUN ["/bin/sh", "-eu", "-c", '
        '"test \\"$(cat /probe-base-ready)\\" = base-ready; '
        'printf inherited-onbuild > /probe-inherited-onbuild"]\n'
    )
    (final_context / "Containerfile").write_text(
        f"FROM {base_tag}\n"
        "RUN --mount=type=bind,from=probe_assets,source=.,target=/probe-assets "
        '["/probe-assets/probe-helper"]\n'
        "COPY --chmod=0555 --from=probe_assets payload /probe-copied-context\n"
        'RUN ["/bin/sh", "-eu", "-c", '
        '"test \\"$(cat /probe-inherited-onbuild)\\" = inherited-onbuild; '
        'test \\"$(cat /probe-mounted-context)\\" = named-context; '
        'test \\"$(cat /probe-copied-context)\\" = named-context; '
        'test \\"$(stat -c %a /probe-copied-context)\\" = 555"]\n'
    )
    return base_context, final_context, asset_context


def main():
    args = parse_args()
    receipt = {
        "schema_version": 1,
        "fixture_id": args.fixture_id,
        "evidence_id": os.environ.get("CI_PIPELINE_ID"),
        "source_sha": os.environ.get("CI_COMMIT_SHA"),
        "started_at": utc_now(),
        "expected_engines": {
            "podman": args.expect_podman,
            "buildah": args.expect_buildah,
        },
        "base_image": args.base_image,
        "engine": {},
        "images": {},
        "features": {
            "named_build_context": False,
            "run_mount_from_context_exec_form": False,
            "copy_chmod": False,
            "inherited_onbuild": False,
        },
        "commands": [],
        "passed": False,
    }
    generated_images = []
    exit_code = 1
    try:
        if STABLE_VERSION.fullmatch(args.expect_podman) is None:
            raise ProbeFailure("--expect-podman must be a stable x.y.z release")
        if STABLE_VERSION.fullmatch(args.expect_buildah) is None:
            raise ProbeFailure("--expect-buildah must be a stable x.y.z release")
        if PINNED_IMAGE.search(args.base_image) is None:
            raise ProbeFailure("--base-image must end with an immutable sha256 digest")

        info_result = run(receipt, [args.podman, "info", "--format", "json"])
        try:
            info = json.loads(info_result.stdout)
            host = info["host"]
            engine = {
                "podman": stable_version(info["version"]["Version"], "Podman"),
                "buildah": stable_version(host["buildahVersion"], "Buildah"),
                "os": host["os"],
                "architecture": host["arch"],
                "remote": host.get("serviceIsRemote", False),
            }
        except (KeyError, TypeError, json.JSONDecodeError) as error:
            raise ProbeFailure(
                "podman info returned an incomplete JSON document"
            ) from error
        receipt["engine"] = engine
        if engine["podman"] != args.expect_podman:
            raise ProbeFailure(
                f"expected Podman {args.expect_podman}, observed {engine['podman']}"
            )
        if engine["buildah"] != args.expect_buildah:
            raise ProbeFailure(
                f"expected Buildah {args.expect_buildah}, observed {engine['buildah']}"
            )
        if engine["os"] != "linux" or engine["architecture"] not in {
            "amd64",
            "x86_64",
            "arm64",
            "aarch64",
        }:
            raise ProbeFailure("probe requires a Linux amd64 or arm64 Podman host")
        if engine["remote"]:
            raise ProbeFailure("probe requires a local Podman service")

        suffix = tag_component(args.fixture_id + "-" + engine["architecture"])
        base_tag = f"localhost/chalk-{suffix}:base"
        final_tag = f"localhost/chalk-{suffix}:result"
        generated_images.extend([final_tag, base_tag])

        with tempfile.TemporaryDirectory(prefix="chalk-podman-compat-") as temp:
            base_context, final_context, asset_context = write_fixture(
                Path(temp), args.base_image, base_tag
            )
            run(receipt, [args.podman, "pull", "--quiet", args.base_image])
            receipt["images"]["input"] = inspect_image(
                receipt, args.podman, args.base_image
            )
            run(
                receipt,
                [
                    args.podman,
                    "build",
                    "--pull=never",
                    "--format",
                    "docker",
                    "--tag",
                    base_tag,
                    "--file",
                    str(base_context / "Containerfile"),
                    str(base_context),
                ],
            )
            receipt["images"]["onbuild_base"] = inspect_image(
                receipt, args.podman, base_tag
            )
            run(
                receipt,
                [
                    args.podman,
                    "build",
                    "--pull=never",
                    "--format",
                    "docker",
                    "--tag",
                    final_tag,
                    "--build-context",
                    f"probe_assets={asset_context}",
                    "--file",
                    str(final_context / "Containerfile"),
                    str(final_context),
                ],
            )
            receipt["images"]["result"] = inspect_image(receipt, args.podman, final_tag)
            run(
                receipt,
                [
                    args.podman,
                    "run",
                    "--rm",
                    "--entrypoint",
                    "/bin/sh",
                    final_tag,
                    "-eu",
                    "-c",
                    'test "$(cat /probe-inherited-onbuild)" = inherited-onbuild; '
                    'test "$(cat /probe-mounted-context)" = named-context; '
                    'test "$(cat /probe-copied-context)" = named-context; '
                    'test "$(stat -c %a /probe-copied-context)" = 555',
                ],
            )

        for feature in receipt["features"]:
            receipt["features"][feature] = True
        receipt["passed"] = True
        exit_code = 0
    except (OSError, ProbeFailure) as error:
        receipt["error"] = str(error)
    finally:
        if not args.keep_images:
            for image in generated_images:
                run(
                    receipt,
                    [args.podman, "image", "rm", "--force", image],
                    check=False,
                )
        receipt["finished_at"] = utc_now()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")

    print(json.dumps(receipt, indent=2, sort_keys=True))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())

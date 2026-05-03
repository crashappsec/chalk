# Copyright (c) 2026, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
"""End-to-end tests for the caller-attestation plugin.

The plugin ingests a JSON envelope from the spawning process —
either inline via `CHALK_CALLER_ATTESTATION` or from a file path
in `CHALK_CALLER_ATTESTATION_FILE` — validates the outer shape,
distributes host/build/process buckets to top-level chalk keys, and
status-wraps each per-artifact entry against chalk's own unchalked
hash.

Tests cover the contract documented in
`docs/design-caller-attestation.md`:

  - status="match" on hash agreement; no hashes echoed in the mark
  - status="mismatch" on hash disagreement; both hashes surface,
    a warn is logged, the chalk operation succeeds
  - status="unverified" path is exercised indirectly via mismatch
    semantics (chalk always computes a hash for the sidecar codec
    used here, so unverified isn't reachable from this codec —
    asserted in the unit test instead)
  - per-path entries that don't match any tracked artifact land in
    host-level CALLER_ATTESTED_UNTRACKED_ARTIFACT_INFO with a warn
  - file-channel fallback works the same as the env-var channel
  - INFO / HOST_INFO / BUILD_INFO buckets pass through unchanged
  - X-prefixed unknown top-level keys are accepted silently;
    other unknown top-level keys produce a warn
  - validation failures (bad JSON, wrong version, missing sha256,
    bad sha256 format) cause the envelope to be discarded with an
    error log; chalk continues without attestation
  - no envelope at all → operation is a no-op for this plugin
"""
import hashlib
import json
from pathlib import Path

import pytest

from .chalk.runner import Chalk

# Use the .onnx path here because it cleanly maps to the model_sidecar
# codec which always computes an unchalked hash.  That keeps these
# tests focused on attestation behavior, not codec quirks.
ARTIFACT_BYTES = b"opaque-model-bytes"


def _write_artifact(tmp_data_dir: Path) -> Path:
    artifact = tmp_data_dir / "model.onnx"
    artifact.write_bytes(ARTIFACT_BYTES)
    return artifact


def _attestation_env(envelope: dict) -> dict[str, str]:
    return {"CHALK_CALLER_ATTESTATION": json.dumps(envelope)}


def _resolve(p: Path) -> str:
    return str(p.resolve(strict=True))


def _good_sha(artifact: Path) -> str:
    return hashlib.sha256(artifact.read_bytes()).hexdigest()


def test_match_status_no_hashes_in_mark(tmp_data_dir: Path, chalk: Chalk):
    """status=match: per-artifact mark contains status+info, no hashes;
    the three host-level buckets land at the top of the report."""
    artifact = _write_artifact(tmp_data_dir)
    sha = _good_sha(artifact)
    envelope = {
        "version": 1,
        "CALLER_ATTESTED_INFO": {"attestor": "crayon", "version": "0.1"},
        "CALLER_ATTESTED_HOST_INFO": {"host": "laptop"},
        "CALLER_ATTESTED_BUILD_INFO": {"pipeline": "test"},
        "CALLER_ATTESTED_ARTIFACT_INFO": {
            _resolve(artifact): {
                "sha256": sha,
                "info": {"source": "huggingface", "repo": "meta-llama/test"},
            },
        },
    }
    insert = chalk.insert(artifact=artifact, env=_attestation_env(envelope))

    # Per-artifact key — lives inside the artifact mark.
    insert.mark.contains(
        {
            "CALLER_ATTESTED_ARTIFACT_INFO": {
                "status": "match",
                "info": {"source": "huggingface"},
            },
        }
    )
    # On `match`, hashes must NOT surface — they only appear when
    # there is something to flag.
    assert "attested_sha256" not in insert.mark["CALLER_ATTESTED_ARTIFACT_INFO"]
    assert "observed_sha256" not in insert.mark["CALLER_ATTESTED_ARTIFACT_INFO"]

    # Host-level buckets — at the top of the report, not inside the
    # per-artifact mark.
    insert.report.contains(
        {
            "CALLER_ATTESTED_INFO": {"attestor": "crayon"},
            "CALLER_ATTESTED_HOST_INFO": {"host": "laptop"},
            "CALLER_ATTESTED_BUILD_INFO": {"pipeline": "test"},
        }
    )


def test_mismatch_surfaces_both_hashes_and_warns(tmp_data_dir: Path, chalk: Chalk):
    """status=mismatch: both hashes present, warn logged, op succeeds."""
    artifact = _write_artifact(tmp_data_dir)
    sha_observed = _good_sha(artifact)
    sha_attested = "0" * 64
    envelope = {
        "version": 1,
        "CALLER_ATTESTED_ARTIFACT_INFO": {
            _resolve(artifact): {"sha256": sha_attested, "info": {"src": "x"}},
        },
    }
    insert = chalk.insert(artifact=artifact, env=_attestation_env(envelope))

    insert.mark.contains(
        {
            "CALLER_ATTESTED_ARTIFACT_INFO": {
                "status": "mismatch",
                "attested_sha256": sha_attested,
                "observed_sha256": sha_observed,
                "info": {"src": "x"},
            },
        }
    )
    assert "caller-attested hash mismatch" in insert.logs
    assert sha_attested in insert.logs
    assert sha_observed in insert.logs


def test_untracked_attestation_aggregates_in_report(tmp_data_dir: Path, chalk: Chalk):
    """A per-path entry whose path chalk didn't process lands in the
    host-level CALLER_ATTESTED_UNTRACKED_ARTIFACT_INFO with a warn."""
    artifact = _write_artifact(tmp_data_dir)
    sha = _good_sha(artifact)
    ghost = str((tmp_data_dir / "ghost.onnx").resolve())
    envelope = {
        "version": 1,
        "CALLER_ATTESTED_ARTIFACT_INFO": {
            _resolve(artifact): {"sha256": sha, "info": {"x": 1}},
            ghost: {"sha256": "1" * 64, "info": {"note": "never processed"}},
        },
    }
    insert = chalk.insert(artifact=artifact, env=_attestation_env(envelope))

    # The matched artifact's mark gets a status=match entry as usual.
    insert.mark.contains({"CALLER_ATTESTED_ARTIFACT_INFO": {"status": "match"}})

    # The unmatched path lands at host-level — no status wrapper there,
    # since chalk never observed the file.
    insert.report.contains(
        {
            "CALLER_ATTESTED_UNTRACKED_ARTIFACT_INFO": {
                ghost: {"sha256": "1" * 64, "info": {"note": "never processed"}},
            },
        }
    )
    assert ghost in insert.logs
    assert "untracked" in insert.logs.lower() or "not processed" in insert.logs


def test_file_channel_equivalent_to_env(tmp_data_dir: Path, chalk: Chalk):
    """CHALK_CALLER_ATTESTATION_FILE produces the same result as the
    inline env-var channel.  Used by callers whose attestation
    payload exceeds ARG_MAX (or who want to write+unlink for
    secrets)."""
    artifact = _write_artifact(tmp_data_dir)
    sha = _good_sha(artifact)
    envelope = {
        "version": 1,
        "CALLER_ATTESTED_INFO": {"channel": "file"},
        "CALLER_ATTESTED_ARTIFACT_INFO": {
            _resolve(artifact): {"sha256": sha, "info": {"v": "f"}},
        },
    }
    envelope_path = tmp_data_dir / "envelope.json"
    envelope_path.write_text(json.dumps(envelope))
    insert = chalk.insert(
        artifact=artifact,
        env={"CHALK_CALLER_ATTESTATION_FILE": str(envelope_path)},
    )
    insert.mark.contains({"CALLER_ATTESTED_ARTIFACT_INFO": {"status": "match"}})
    insert.report.contains({"CALLER_ATTESTED_INFO": {"channel": "file"}})


def test_no_envelope_is_a_no_op(tmp_data_dir: Path, chalk: Chalk):
    """With neither env var set, no CALLER_ATTESTED_* keys appear."""
    artifact = _write_artifact(tmp_data_dir)
    insert = chalk.insert(artifact=artifact)
    # The per-artifact key lives in the mark; the rest are host-level
    # and live at the top of the report.
    assert "CALLER_ATTESTED_ARTIFACT_INFO" not in insert.mark
    for k in (
        "CALLER_ATTESTED_INFO",
        "CALLER_ATTESTED_HOST_INFO",
        "CALLER_ATTESTED_BUILD_INFO",
        "CALLER_ATTESTED_UNTRACKED_ARTIFACT_INFO",
    ):
        assert k not in insert.report, f"{k} should be absent in no-envelope insert"


@pytest.mark.parametrize(
    "envelope_str,err_substr",
    [
        ("not valid json", "malformed JSON"),
        ('{"version": 99, "CALLER_ATTESTED_INFO": {}}', "unsupported `version`"),
        ('{"version": "1"}', "unsupported `version`"),
        ('{"CALLER_ATTESTED_INFO": {}}', "missing required `version`"),
        (
            '{"version": 1, "CALLER_ATTESTED_INFO": "string"}',
            "must be a JSON object",
        ),
        (
            '{"version": 1, "CALLER_ATTESTED_ARTIFACT_INFO": {"/p":' ' {"info":{}}}}',
            "missing required string 'sha256'",
        ),
        (
            '{"version": 1, "CALLER_ATTESTED_ARTIFACT_INFO": {"/p":'
            ' {"sha256":"short"}}}',
            "invalid 'sha256'",
        ),
        (
            '{"version": 1, "CALLER_ATTESTED_ARTIFACT_INFO": {"/p":'
            ' {"sha256":"' + "0" * 64 + '","extra":"field"}}}',
            "unexpected field 'extra'",
        ),
    ],
)
def test_validation_failure_discards_envelope(
    tmp_data_dir: Path, chalk: Chalk, envelope_str: str, err_substr: str
):
    """Each shape that violates the protocol contract: the chalk op
    still succeeds, but the mark contains no CALLER_ATTESTED_* keys
    and chalk logs an `error:` describing the violation."""
    artifact = _write_artifact(tmp_data_dir)
    insert = chalk.insert(
        artifact=artifact,
        env={"CHALK_CALLER_ATTESTATION": envelope_str},
        # The validation paths intentionally produce an `error:` log
        # (the envelope is discarded); the chalk runner would
        # otherwise treat any error in the report as a test failure.
        ignore_errors=True,
    )
    assert any(
        err_substr in e for e in insert.errors
    ), f"expected an error containing '{err_substr}'; got: {insert.errors}"
    # Envelope was rejected as a whole — none of the keys land,
    # neither in the per-artifact mark nor the host-level report.
    assert "CALLER_ATTESTED_ARTIFACT_INFO" not in insert.mark
    for k in (
        "CALLER_ATTESTED_INFO",
        "CALLER_ATTESTED_HOST_INFO",
        "CALLER_ATTESTED_BUILD_INFO",
    ):
        assert k not in insert.report


def test_x_prefixed_top_level_silently_accepted(tmp_data_dir: Path, chalk: Chalk):
    """X-* unknown top-level keys are reserved for caller experimentation;
    they pass through silently, with no warn log."""
    artifact = _write_artifact(tmp_data_dir)
    sha = _good_sha(artifact)
    envelope = {
        "version": 1,
        "X-experimental": {"foo": "bar"},
        "CALLER_ATTESTED_ARTIFACT_INFO": {
            _resolve(artifact): {"sha256": sha},
        },
    }
    insert = chalk.insert(artifact=artifact, env=_attestation_env(envelope))
    # No warning about the X-* key (mismatch warns can still appear from
    # other tests; we only check absence of the unknown-key warn here).
    assert "unknown top-level key" not in insert.logs
    insert.mark.contains({"CALLER_ATTESTED_ARTIFACT_INFO": {"status": "match"}})


def test_other_unknown_top_level_warns(tmp_data_dir: Path, chalk: Chalk):
    """Non-X-prefixed unknown top-level keys produce a warn but are
    otherwise tolerated; the rest of the envelope still applies."""
    artifact = _write_artifact(tmp_data_dir)
    sha = _good_sha(artifact)
    envelope = {
        "version": 1,
        "WHATEVER": {"foo": "bar"},
        "CALLER_ATTESTED_ARTIFACT_INFO": {
            _resolve(artifact): {"sha256": sha},
        },
    }
    insert = chalk.insert(artifact=artifact, env=_attestation_env(envelope))
    assert "unknown top-level key 'WHATEVER'" in insert.logs
    insert.mark.contains({"CALLER_ATTESTED_ARTIFACT_INFO": {"status": "match"}})

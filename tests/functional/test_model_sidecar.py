# Copyright (c) 2026, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
"""End-to-end tests for the model_sidecar codec.

The codec is the deliberate carve-out described in
docs/design-model-codecs.md: ML model artifact formats we cannot
mark in-band (`.onnx`, `.bin`, legacy non-ZIP `.pt`/`.pth`) get a
`<path>.chalk` sidecar instead of artifact mutation.  These tests
cover the behaviors the design doc asserts:

  - insert produces a `<path>.chalk` sidecar containing a valid mark
  - the artifact's bytes are byte-identical pre and post insert
  - extract reads the mark back from the sidecar
  - delete removes the sidecar and leaves the artifact untouched
  - virtual mode (--virtual) does NOT produce a sidecar; mark goes
    to the virtual-chalk sink instead
"""
from pathlib import Path

import pytest

from .chalk.runner import Chalk
from .utils.dict import Contains
from .utils.log import get_logger


logger = get_logger()


# Bytes that aren't a real ONNX protobuf — but the codec is content-
# agnostic and only matches on extension, so an opaque blob is fine
# for a sidecar test.  (Real ONNX testing would require protobuf
# parsing and is out of scope until the ONNX codec lands.)
def _write_blob(path: Path, content: bytes = b"opaque-model-bytes\x00\x01\x02") -> None:
    path.write_bytes(content)


@pytest.mark.parametrize("extension", ["onnx", "bin"])
def test_sidecar_insert_creates_sidecar(
    tmp_data_dir: Path,
    chalk: Chalk,
    extension: str,
):
    """Insert produces <path>.chalk and does not modify the artifact."""
    artifact = tmp_data_dir / f"model.{extension}"
    payload = b"original-bytes-for-" + extension.encode()
    _write_blob(artifact, payload)
    pre_bytes = artifact.read_bytes()

    insert = chalk.insert(artifact=artifact)
    assert insert.report.marks_by_path.contains(
        {str(artifact): {"ARTIFACT_TYPE": "ML model"}},
    )

    sidecar = artifact.with_suffix(artifact.suffix + ".chalk")
    assert sidecar.is_file(), f"sidecar {sidecar} should exist after insert"

    sidecar_bytes = sidecar.read_text()
    assert "dadfedabbadabbed" in sidecar_bytes, "MAGIC missing from sidecar"
    assert "CHALK_ID" in sidecar_bytes, "CHALK_ID missing from sidecar"

    # The artifact itself must not have been mutated.
    assert (
        artifact.read_bytes() == pre_bytes
    ), "sidecar codec must leave the artifact's bytes untouched"


@pytest.mark.parametrize("extension", ["onnx", "bin"])
def test_sidecar_extract_reads_mark(
    tmp_data_dir: Path,
    chalk: Chalk,
    extension: str,
):
    """Extract returns the chalk mark from the sidecar."""
    artifact = tmp_data_dir / f"model.{extension}"
    _write_blob(artifact)

    insert = chalk.insert(artifact=artifact)
    extract = chalk.extract(artifact=artifact)
    assert extract.report.marks_by_path.contains(
        {str(artifact): {"_OP_ARTIFACT_TYPE": "ML model"}},
    )
    assert extract.mark.contains(insert.mark.if_exists())


@pytest.mark.parametrize("extension", ["onnx", "bin"])
def test_sidecar_delete_removes_sidecar(
    tmp_data_dir: Path,
    chalk: Chalk,
    extension: str,
):
    """Delete removes the sidecar; the artifact's bytes are unchanged."""
    artifact = tmp_data_dir / f"model.{extension}"
    pre_bytes = b"keep-me-alive-" + extension.encode()
    _write_blob(artifact, pre_bytes)

    chalk.insert(artifact=artifact)
    sidecar = artifact.with_suffix(artifact.suffix + ".chalk")
    assert sidecar.is_file()

    chalk.delete(artifact=artifact)
    assert not sidecar.is_file(), "sidecar should be gone after chalk delete"
    assert artifact.read_bytes() == pre_bytes, "delete must not modify the artifact"


@pytest.mark.parametrize("extension", ["onnx", "bin"])
def test_sidecar_virtual_does_not_write_sidecar(
    tmp_data_dir: Path,
    chalk: Chalk,
    extension: str,
):
    """Under --virtual the mark goes to the virtual-chalk sink, not
    a sidecar file alongside the artifact.  This is the standard
    chalk behavior for any codec — confirming it for sidecar so a
    future regression doesn't accidentally double-write."""
    artifact = tmp_data_dir / f"model.{extension}"
    _write_blob(artifact)

    insert = chalk.insert(artifact=artifact, virtual=True)
    assert insert.report.marks_by_path.contains({str(artifact): {}})

    sidecar = artifact.with_suffix(artifact.suffix + ".chalk")
    assert not sidecar.is_file(), "virtual mode should not produce a sidecar file"


def test_sidecar_extension_not_in_list_is_ignored(
    tmp_data_dir: Path,
    chalk: Chalk,
):
    """A file whose extension is NOT in sidecar_extensions must not be
    claimed by the sidecar codec — the carve-out is narrow.
    Default list is onnx / bin / pt / pth; .opaque is not in it."""
    artifact = tmp_data_dir / "model.opaque"
    _write_blob(artifact)

    insert = chalk.insert(
        artifact=artifact,
        expecting_chalkmarks=False,
    )
    assert insert  # ran cleanly, just produced no marks
    sidecar = artifact.with_suffix(artifact.suffix + ".chalk")
    assert (
        not sidecar.is_file()
    ), "files outside sidecar_extensions must not get a sidecar"

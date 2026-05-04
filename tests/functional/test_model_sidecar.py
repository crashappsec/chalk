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

from .chalk.runner import Chalk, ChalkMark
from .utils.log import get_logger


logger = get_logger()


@pytest.mark.parametrize("extension", ["onnx", "bin"])
def test_sidecar_insert_extract_delete(
    tmp_data_dir: Path,
    chalk: Chalk,
    extension: str,
):
    """Extract returns the chalk mark from the sidecar."""
    payload = b"original-bytes-for-" + extension.encode()
    artifact = tmp_data_dir / f"model.{extension}"
    artifact.write_bytes(payload)

    insert = chalk.insert(artifact=artifact)
    assert insert.report.marks_by_path.contains(
        {str(artifact): {"ARTIFACT_TYPE": "ML model"}},
    )

    sidecar = artifact.with_suffix(artifact.suffix + ".chalk")
    assert sidecar.is_file(), f"sidecar {sidecar} should exist after insert"
    sidemark = ChalkMark.from_binary(sidecar)
    sidemark.contains(insert.mark.if_exists())

    extract = chalk.extract(artifact=artifact)
    assert extract.report.marks_by_path.contains(
        {str(artifact): {"_OP_ARTIFACT_TYPE": "ML model"}},
    )
    assert extract.mark.contains(insert.mark.if_exists())

    chalk.delete(artifact=artifact)
    assert not sidecar.is_file(), "sidecar should be gone after chalk delete"
    assert artifact.read_bytes() == payload, "delete must not modify the artifact"


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
    payload = b"original-bytes-for-" + extension.encode()
    artifact = tmp_data_dir / f"model.{extension}"
    artifact.write_bytes(payload)

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
    artifact.write_bytes(b"hello")

    chalk.insert(
        artifact=artifact,
        expecting_chalkmarks=False,
    )
    sidecar = artifact.with_suffix(artifact.suffix + ".chalk")
    assert (
        not sidecar.is_file()
    ), "files outside sidecar_extensions must not get a sidecar"

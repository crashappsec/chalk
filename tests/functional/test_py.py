# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import shutil
from pathlib import Path

import pytest

from .chalk.runner import Chalk
from .chalk.validate import (
    MAGIC,
    ArtifactInfo,
    validate_chalk_report,
    validate_extracted_chalk,
    validate_virtual_chalk,
)
from .conf import PYS, SHEBANG
from .utils.log import get_logger


logger = get_logger()


@pytest.mark.parametrize(
    "test_file",
    [
        "sample_1",
        "sample_2",
        "sample_3",
        "sample_4",
    ],
)
def test_virtual_valid(tmp_data_dir: Path, chalk: Chalk, test_file: str):
    shutil.copytree(PYS / test_file, tmp_data_dir, dirs_exist_ok=True)
    artifact_info = ArtifactInfo.all_shebangs()

    # chalk reports generated by insertion, json array that has one element
    insert = chalk.insert(artifact=tmp_data_dir, virtual=True)
    validate_chalk_report(
        chalk_report=insert.report, artifact_map=artifact_info, virtual=True
    )

    # array of json chalk objects as output, of which we are only expecting one
    extract = chalk.extract(artifact=tmp_data_dir)
    validate_extracted_chalk(
        extracted_chalk=extract.report, artifact_map=artifact_info, virtual=True
    )
    validate_virtual_chalk(
        tmp_data_dir=tmp_data_dir, artifact_map=artifact_info, virtual=True
    )


@pytest.mark.parametrize(
    "test_file",
    [
        "sample_1",
        "sample_2",
        "sample_3",
        "sample_4",
    ],
)
def test_nonvirtual_valid(tmp_data_dir: Path, chalk: Chalk, test_file: str):
    shutil.copytree(PYS / test_file, tmp_data_dir, dirs_exist_ok=True)
    artifact_info = ArtifactInfo.all_shebangs()

    # chalk reports generated by insertion, json array that has one element
    insert = chalk.insert(artifact=tmp_data_dir, virtual=False)
    validate_chalk_report(
        chalk_report=insert.report, artifact_map=artifact_info, virtual=False
    )

    # array of json chalk objects as output, of which we are only expecting one
    extract = chalk.extract(artifact=tmp_data_dir)
    validate_extracted_chalk(
        extracted_chalk=extract.report, artifact_map=artifact_info, virtual=False
    )
    validate_virtual_chalk(
        tmp_data_dir=tmp_data_dir, artifact_map=artifact_info, virtual=False
    )

    # check that first line shebangs are not clobbered in non-virtual chalk
    for file in tmp_data_dir.iterdir():
        if file.suffix in {"key", "pub"}:
            continue

        is_artifact = str(file) in artifact_info
        text = file.read_text()
        lines = text.splitlines()
        first_line = next(iter(lines), "")

        # shebang only should be present in artifacts
        assert first_line.startswith(SHEBANG) == is_artifact

        if is_artifact:
            # chalk mark with MAGIC expected in last line
            assert lines[-1].startswith("#")
            assert MAGIC in lines[-1]
        else:
            assert MAGIC not in text
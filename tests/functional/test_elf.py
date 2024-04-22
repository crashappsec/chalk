# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from pathlib import Path

import pytest

from .chalk.runner import Chalk
from .chalk.validate import (
    ArtifactInfo,
    validate_chalk_report,
    validate_extracted_chalk,
    validate_virtual_chalk,
)
from .conf import DATE_PATH, GDB, LS_PATH, UNAME_PATH
from .utils.log import get_logger
from .utils.os import run


logger = get_logger()


# XXX parameterizing this in case we need ELF files with different properties
# but we don't want to simply run different binaries like date/ls/cat/uname
# if we don't expect the behavior to vary
@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_virtual_valid(copy_files: list[Path], tmp_data_dir: Path, chalk: Chalk):
    artifact = copy_files[0]
    artifact_info = ArtifactInfo.one_elf(artifact)

    insert = chalk.insert(artifact=tmp_data_dir, virtual=True)
    validate_chalk_report(
        chalk_report=insert.report, artifact_map=artifact_info, virtual=True
    )

    extract = chalk.extract(artifact=tmp_data_dir)
    validate_extracted_chalk(
        extracted_chalk=extract.report, artifact_map=artifact_info, virtual=True
    )
    validate_virtual_chalk(
        tmp_data_dir=tmp_data_dir, artifact_map=artifact_info, virtual=True
    )

    # compare extractions
    extract2 = chalk.extract(artifact=tmp_data_dir)
    assert extract.report.datetime < extract2.report.datetime


@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_nonvirtual_valid(copy_files: list[Path], tmp_data_dir: Path, chalk: Chalk):
    artifact = copy_files[0]
    artifact_info = ArtifactInfo.one_elf(artifact)

    insert = chalk.insert(artifact=tmp_data_dir, virtual=False)
    validate_chalk_report(
        chalk_report=insert.report, artifact_map=artifact_info, virtual=False
    )

    extract = chalk.extract(artifact=tmp_data_dir)
    validate_extracted_chalk(
        extracted_chalk=extract.report, artifact_map=artifact_info, virtual=False
    )
    validate_virtual_chalk(
        tmp_data_dir=tmp_data_dir, artifact_map=artifact_info, virtual=False
    )


@pytest.mark.requires_gdb
@pytest.mark.parametrize(
    "copy_files",
    [
        [i]
        for i in [
            LS_PATH,
            DATE_PATH,
            UNAME_PATH,
        ]
        if i and not Path(i).is_symlink()
    ],
    indirect=True,
)
def test_entrypoint(copy_files: list[Path], chalk: Chalk):
    """
    Validate ELF entrypoints

    Since chalk rewrites the entrypoints on elf when wrapping
    we want to validate that we don't clobber the entrypoint
    or corrupt memoryfor the elf when we do so
    """
    bin_path = copy_files[0]
    cmd = ["gdb", "--quiet", "-x", "./commands.gdb", str(bin_path)]

    before = run(cmd, cwd=GDB).json(after="{", everything=False)
    chalk.insert(bin_path, virtual=False)
    after = run(cmd, cwd=GDB).json(after="{", everything=False)

    assert before == after

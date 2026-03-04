# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from pathlib import Path

import pytest

from .chalk.runner import Chalk
from .conf import DATE_PATH, GDB, LS_PATH, UNAME_PATH
from .utils.log import get_logger
from .utils.os import run

logger = get_logger()


@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
@pytest.mark.parametrize("virtual", [True, False])
def test_valid(
    copy_files: list[Path],
    tmp_data_dir: Path,
    chalk: Chalk,
    virtual: bool,
):
    artifact = copy_files[0]

    insert = chalk.insert(artifact=tmp_data_dir, virtual=virtual)
    assert insert.report.marks_by_path.contains({str(artifact): {}})

    extract = chalk.extract(artifact=tmp_data_dir, virtual=virtual)
    if not virtual:
        assert extract.report.marks_by_path.contains({str(artifact): {}})

    # compare extractions
    extract2 = chalk.extract(artifact=tmp_data_dir, virtual=virtual)
    assert extract.report.datetime < extract2.report.datetime


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

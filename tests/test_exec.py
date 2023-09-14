# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from pathlib import Path

import pytest

from .chalk.runner import Chalk, ChalkReport
from .conf import CONFIGS, SLEEP_PATH, UNAME_PATH
from .utils.bin import sha256
from .utils.log import get_logger


logger = get_logger()


# chalk exec forking should not affect behavior
@pytest.mark.parametrize("as_parent", [True, False])
@pytest.mark.parametrize("copy_files", [[UNAME_PATH]], indirect=True)
def test_exec_unchalked(
    as_parent: bool,
    copy_files: list[Path],
    chalk: Chalk,
):
    bin_path = copy_files[0]
    bin_hash = sha256(bin_path)

    exec_proc = chalk.run(
        command="exec",
        exec_command=bin_path,
        log_level="none",
        as_parent=as_parent,
    )
    # first line must be linux
    assert exec_proc.text.startswith("Linux")

    assert exec_proc.report["_OPERATION"] == "exec"
    # we expect the binary to be unmarked
    assert exec_proc.report["_UNMARKED"] == [str(bin_path)]

    assert exec_proc.mark["_OP_ARTIFACT_PATH"] == str(bin_path)
    assert exec_proc.mark["_OP_ARTIFACT_TYPE"] == "ELF"
    # current hash should be identical to bin hash since we didn't change the binary
    assert exec_proc.mark["_CURRENT_HASH"] == bin_hash

    # expect process info to be included
    # but can't check exact values for most of these
    assert exec_proc.mark["_PROCESS_PID"] > 0
    assert exec_proc.mark["_PROCESS_PARENT_PID"] > 0
    assert exec_proc.mark["_PROCESS_UID"] is not None


@pytest.mark.parametrize("as_parent", [True, False])
@pytest.mark.parametrize("copy_files", [[UNAME_PATH]], indirect=True)
def test_exec_chalked(
    as_parent: bool,
    copy_files: list[Path],
    chalk: Chalk,
):
    bin_path = copy_files[0]
    bin_hash = sha256(bin_path)

    # add chalk mark
    chalk.insert(artifact=bin_path, virtual=False)

    # hash of chalked binary
    chalk_hash = sha256(bin_path)
    assert bin_hash != chalk_hash

    exec_proc = chalk.run(
        command="exec",
        exec_command=bin_path,
        log_level="none",
        as_parent=as_parent,
    )
    # first line must be linux
    assert exec_proc.text.startswith("Linux")

    assert exec_proc.report["_OPERATION"] == "exec"
    # we expect the binary to be marked
    assert "_UNMARKED" not in exec_proc.report

    assert exec_proc.mark["_OP_ARTIFACT_PATH"] == str(bin_path)
    assert exec_proc.mark["_OP_ARTIFACT_TYPE"] == "ELF"
    assert exec_proc.mark["_CURRENT_HASH"] == chalk_hash

    # expect bin info to be available
    assert exec_proc.mark["_OP_ARTIFACT_PATH"] == str(bin_path)
    assert exec_proc.mark["ARTIFACT_TYPE"] == "ELF"
    assert exec_proc.mark["HASH"] != bin_hash
    assert chalk_hash != bin_hash

    # expect process info to be included
    # but can't check exact values for most of these
    assert exec_proc.mark["_PROCESS_PID"] > 0
    assert exec_proc.mark["_PROCESS_PARENT_PID"] > 0
    assert exec_proc.mark["_PROCESS_UID"] is not None


# exec wrapping with heartbeat
@pytest.mark.parametrize("copy_files", [[SLEEP_PATH]], indirect=True)
def test_exec_heartbeat(
    copy_files: list[Path],
    chalk: Chalk,
):
    bin_path = copy_files[0]
    bin_hash = sha256(bin_path)

    # add chalk mark
    chalk.insert(artifact=bin_path, virtual=False)

    # hash of chalked binary
    chalk_hash = sha256(bin_path)
    assert bin_hash != chalk_hash

    result = chalk.run(
        command="exec",
        heartbeat=True,
        config=CONFIGS / "heartbeat.conf",
        exec_command=bin_path,
        params=["5"],
    )

    report = result.reports[0]
    assert report["_OPERATION"] == "exec"
    assert report.mark["_OP_ARTIFACT_PATH"] == str(bin_path)
    assert report.mark["_CURRENT_HASH"] == chalk_hash
    assert report.mark["ARTIFACT_TYPE"] == "ELF"
    assert report.mark["_PROCESS_PID"] != ""

    # there should be a few heartbeats
    assert len(result.reports) > 1
    for other_report in result.reports[1:]:
        assert other_report["_OPERATION"] == "heartbeat"
        assert other_report.mark == report.mark

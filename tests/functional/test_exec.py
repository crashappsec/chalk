# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from pathlib import Path
import sys

import pytest

from .chalk.runner import Chalk
from .conf import CONFIGS, SLEEP_PATH, UNAME_PATH
from .utils.dict import Contains, ContainsDict
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

    exec_proc = chalk.exec(
        bin_path,
        as_parent=as_parent,
        config=CONFIGS / "procfs.c4m",
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
@pytest.mark.parametrize("copy_files", [[SLEEP_PATH]], indirect=True)
def test_exec_chalked(
    as_parent: bool,
    copy_files: list[Path],
    chalk: Chalk,
    tmp_data_dir: Path,
):
    bin_path = copy_files[0]
    bin_hash = sha256(bin_path)

    # add chalk mark
    chalk.insert(
        artifact=bin_path,
        virtual=False,
    )

    # hash of chalked binary
    chalk_hash = sha256(bin_path)
    assert bin_hash != chalk_hash

    exec_proc = chalk.exec(
        bin_path,
        params=["3"],
        as_parent=as_parent,
        config=CONFIGS / "procfs.c4m",
    )

    assert exec_proc.report["_OPERATION"] == "exec"
    # we expect the binary to be marked
    assert str(bin_path) not in exec_proc.report.get("_UNMARKED", [])

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
    assert exec_proc.mark.has(
        _PROCESS_PID=int,
        _PROCESS_PARENT_PID=int,
        _PROCESS_ARGV=[str(bin_path), "3"],
        _PROCESS_CWD=str(tmp_data_dir),
        _PROCESS_EXE_PATH=str(bin_path),
        _PROCESS_COMMAND_NAME=bin_path.name,
        _PROCESS_PGID=int,
        _PROCESS_START_TIME=float,
        _PROCESS_UTIME=float,
        _PROCESS_STIME=float,
        _PROCESS_CHILDREN_UTIME=float,
        _PROCESS_CHILDREN_STIME=float,
        _PROCESS_STATE="Sleeping",
        _PROCESS_UMASK=int,
        _PROCESS_UID=[int, int, int, int],
        _PROCESS_GID=[int, int, int, int],
        _PROCESS_NUM_FD_SIZE=int,
        _PROCESS_GROUPS=[int],
        _PROCESS_SECCOMP_STATUS="disabled",
        _PROCESS_FD_INFO={
            "0": {
                "pos": 0,
                "mnt_id": int,
                "ino": int,
                "path": "/dev/null",
                "flags": str,
            }
        },
        _PROCESS_MOUNT_INFO=Contains(
            [
                ContainsDict(
                    {
                        "mount_id": int,
                        "parent_id": int,
                        "major": int,
                        "minor": int,
                        "root": "/",
                        "mount_point": str,
                        "options": list,
                        "tags": [],
                        "fs_type": str,
                        "source": str,
                        "super": list,
                    }
                ),
            ],
        ),
        _PROCESS_DETAIL={
            "pid": int,
        },
    )
    assert exec_proc.report.has(
        _OP_ANCESTOR_ARGVS=Contains([[sys.executable] + sys.argv]),
    )


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

    result = chalk.exec(
        bin_path,
        heartbeat=True,
        config=CONFIGS / "heartbeat.c4m",
        params=["5"],
    )

    exec_report = result.reports[0]
    assert exec_report["_OPERATION"] == "exec"
    assert exec_report.mark["_OP_ARTIFACT_PATH"] == str(bin_path)
    assert exec_report.mark["_CURRENT_HASH"] == chalk_hash
    assert exec_report.mark["ARTIFACT_TYPE"] == "ELF"
    assert exec_report.mark["_PROCESS_PID"] != ""

    # there should be a few heartbeats
    assert len(result.reports) > 1
    for heartbeat_report in result.reports[1:]:
        assert heartbeat_report["_OPERATION"] == "heartbeat"
        assert heartbeat_report.mark == exec_report.mark

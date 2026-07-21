# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from pathlib import Path
import operator
import sys

import requests
import pytest

from .chalk.runner import Chalk
from .conf import CONFIGS, DNS_SINK_SERVER, SLEEP_PATH, UNAME_PATH

from .utils.dict import ANY, Contains, ContainsDict, IntCompare
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
    server_dns: str,
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
        env={"DNS_SERVER": DNS_SINK_SERVER},
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
                "path": str,
                "flags": int,
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
        # parallel tests change argv so its harder to test for specific argv
        # but we can check that some of the ancesor argv has python
        _OP_ANCESTOR_ARGVS=Contains([Contains([sys.executable])]),
    )
    metadata_id = exec_proc.mark["METADATA_ID"]
    exec_id = exec_proc.report["_EXEC_ID"]
    monotime = exec_proc.report["_MONOTIME"]
    timestamp = exec_proc.report["_TIMESTAMP"]
    queries = requests.get(f"{server_dns}/queries").json()
    assert f"{monotime}.{timestamp}.{exec_id}.{metadata_id}.chalk.test" in queries


# exec wrapping with heartbeat
@pytest.mark.parametrize("copy_files", [[SLEEP_PATH]], indirect=True)
def test_exec_heartbeat(
    copy_files: list[Path],
    chalk: Chalk,
    server_dns: str,
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
        env={"DNS_SERVER": DNS_SINK_SERVER},
    )

    exec_report = result.reports[0]
    assert exec_report.has(
        _OPERATION="exec",
        _EXEC_ID=ANY,
    )
    assert exec_report.mark.has(
        _OP_ARTIFACT_PATH=str(bin_path),
        _CURRENT_HASH=chalk_hash,
        ARTIFACT_TYPE="ELF",
        METADATA_ID=ANY,
        _PROCESS_PID=ANY,
    )

    # there should be a few heartbeats
    assert len(result.reports) > 1
    metadata_id = exec_report.mark["METADATA_ID"]
    exec_id = exec_report["_EXEC_ID"]
    queries = requests.get(f"{server_dns}/queries").json()
    prev_since_monotime = 0
    prev_since_timestamp = 0
    for i, heartbeat_report in enumerate(result.reports[1:], start=1):
        assert heartbeat_report.has(
            _OPERATION="heartbeat",
            _EXEC_ID=exec_id,
            _HEARTBEAT_COUNT=i,
            _SINCE_MONOTIME=IntCompare(prev_since_monotime, operator.gt),
            _SINCE_TIMESTAMP=IntCompare(prev_since_timestamp, operator.gt),
        )
        prev_since_monotime = heartbeat_report["_SINCE_MONOTIME"]
        prev_since_timestamp = heartbeat_report["_SINCE_TIMESTAMP"]
        assert heartbeat_report.mark == exec_report.mark
        assert (
            f"{i}.{prev_since_timestamp}.{prev_since_monotime}.{exec_id}.{metadata_id}.chalk.test"
            in queries
        )

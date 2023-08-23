import json
import os
import shutil
import time
from pathlib import Path

import pytest

from .chalk.runner import Chalk
from .utils.bin import sha256
from .utils.log import get_logger
from .utils.validate import ArtifactInfo, validate_chalk_report

logger = get_logger()
CONFIGFILES = Path(__file__).parent / "data" / "configs"


# chalk exec forking should not affect behavior
@pytest.mark.parametrize(
    "flag",
    [
        "--chalk-as-parent",
        "--no-chalk-as-parent",
    ],
)
def test_exec_unchalked(
    flag: str,
    tmp_data_dir: Path,
    chalk: Chalk,
):
    shutil.copy("/bin/uname", tmp_data_dir / "uname")
    bin_path = tmp_data_dir / "uname"
    bin_hash = sha256(tmp_data_dir / "uname")

    exec_proc = chalk.run(
        chalk_cmd="exec",
        params=[flag, f"--exec-command-name={bin_path}", "--log-level=none"],
    )
    assert exec_proc.returncode == 0
    _stderr = exec_proc.stderr.decode()
    assert _stderr == ""

    _stdout = exec_proc.stdout.decode()
    # first line must be linux
    assert _stdout.startswith("Linux")
    _stdout = _stdout.removeprefix("Linux")
    chalk_report = json.loads(_stdout, strict=False)[0]

    assert chalk_report["_OPERATION"] == "exec"
    # we expect the binary to be unmarked
    assert chalk_report["_UNMARKED"] == [str(bin_path)]

    sub_chalk = chalk_report["_CHALKS"][0]
    assert sub_chalk["_OP_ARTIFACT_PATH"] == str(bin_path)
    assert sub_chalk["_OP_ARTIFACT_TYPE"] == "ELF"
    # current hash should be identical to bin hash since we didn't change the binary
    assert sub_chalk["_CURRENT_HASH"] == bin_hash

    # expect process info to be included
    # but can't check exact values for most of these
    assert sub_chalk["_PROCESS_PID"] > 0
    assert sub_chalk["_PROCESS_PARENT_PID"] > 0
    assert sub_chalk["_PROCESS_UID"] is not None


@pytest.mark.parametrize(
    "flag",
    [
        "--chalk-as-parent",
        "--no-chalk-as-parent",
    ],
)
def test_exec_chalked(
    flag: str,
    tmp_data_dir: Path,
    chalk: Chalk,
):
    shutil.copy("/bin/uname", tmp_data_dir / "uname")
    bin_path = tmp_data_dir / "uname"
    bin_hash = sha256(tmp_data_dir / "uname")

    # add chalk mark
    chalk.insert(artifact=bin_path, virtual=False)

    # hash of chalked binary
    current_hash = sha256(tmp_data_dir / "uname")

    exec_proc = chalk.run(
        chalk_cmd="exec",
        params=[flag, f"--exec-command-name={bin_path}", "--log-level=none"],
    )
    assert exec_proc.returncode == 0
    _stderr = exec_proc.stderr.decode()
    assert _stderr == ""

    _stdout = exec_proc.stdout.decode()
    # first line must be linux
    assert _stdout.startswith("Linux")
    _stdout = _stdout.removeprefix("Linux")
    chalk_report = json.loads(_stdout, strict=False)[0]

    assert chalk_report["_OPERATION"] == "exec"
    # we expect the binary to be marked
    assert "_UNMARKED" not in chalk_report

    sub_chalk = chalk_report["_CHALKS"][0]
    assert sub_chalk["_OP_ARTIFACT_PATH"] == str(bin_path)
    assert sub_chalk["_OP_ARTIFACT_TYPE"] == "ELF"
    assert sub_chalk["_CURRENT_HASH"] == current_hash

    # expect bin info to be available
    assert sub_chalk["_OP_ARTIFACT_PATH"] == str(bin_path)
    assert sub_chalk["ARTIFACT_TYPE"] == "ELF"
    assert sub_chalk["HASH"] == bin_hash
    assert current_hash != bin_hash

    # expect process info to be included
    # but can't check exact values for most of these
    assert sub_chalk["_PROCESS_PID"] > 0
    assert sub_chalk["_PROCESS_PARENT_PID"] > 0
    assert sub_chalk["_PROCESS_UID"] is not None


# exec wrapping with heartbeat
def test_exec_heartbeat(
    tmp_data_dir: Path,
    chalk: Chalk,
):
    bin = "sleep"
    shutil.copy(f"/bin/{bin}", tmp_data_dir / bin)
    bin_path = tmp_data_dir / bin
    bin_hash = sha256(tmp_data_dir / bin)

    # add chalk mark
    chalk.insert(artifact=bin_path, virtual=False)

    # hash of chalked binary
    current_hash = sha256(tmp_data_dir / bin)
    assert bin_hash != current_hash

    log_file = "/tmp/heartbeat.log"

    heartbeat_conf = CONFIGFILES / "heartbeat.conf"
    exec_proc = chalk.run(
        chalk_cmd="exec",
        params=[
            "--heartbeat",
            f"--config-file={heartbeat_conf}",
            # sleep 5 seconds -- expecting ~4 heartbeats
            f"--exec-command-name={bin_path}",
            "5",
        ],
    )

    # should not error but skip stdout checking
    assert exec_proc.returncode == 0
    _stderr = exec_proc.stderr.decode()
    assert _stderr == ""

    # validate contents of log file
    assert os.path.isfile(log_file)
    with open(log_file) as file:
        lines = file.readlines()

        _exec = lines[0]
        exec_report = json.loads(_exec)[0]
        assert exec_report["_OPERATION"] == "exec"
        assert "_CHALKS" in exec_report

        _chalk = exec_report["_CHALKS"][0]
        assert _chalk["_OP_ARTIFACT_PATH"] == str(bin_path)
        assert _chalk["_CURRENT_HASH"] == current_hash
        assert _chalk["ARTIFACT_TYPE"] == "ELF"
        assert _chalk["_PROCESS_PID"] != ""

        assert len(lines[1:]) > 0, "no heartbeats reported"
        for line in lines[1:]:
            heartbeat_report = json.loads(line)[0]
            assert heartbeat_report["_OPERATION"] == "heartbeat"
            assert "_CHALKS" in heartbeat_report
            assert heartbeat_report["_CHALKS"][0] == _chalk

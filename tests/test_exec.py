import json
import shutil
from pathlib import Path

import pytest

from .chalk.runner import Chalk
from .utils.bin import sha256
from .utils.log import get_logger

logger = get_logger()


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

from pathlib import Path

import pytest

from .chalk.runner import Chalk, ChalkReport
from .conf import CONFIGS, SLEEP_PATH, UNAME_PATH
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
@pytest.mark.parametrize("copy_files", [[UNAME_PATH]], indirect=True)
def test_exec_unchalked(
    flag: str,
    tmp_data_dir: Path,
    copy_files: list[Path],
    chalk: Chalk,
):
    bin_path = copy_files[0]
    bin_hash = sha256(bin_path)

    exec_proc = chalk.run(
        chalk_cmd="exec",
        params=[flag, f"--exec-command-name={bin_path}", "--log-level=none"],
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


@pytest.mark.parametrize(
    "flag",
    [
        "--chalk-as-parent",
        "--no-chalk-as-parent",
    ],
)
@pytest.mark.parametrize("copy_files", [[UNAME_PATH]], indirect=True)
def test_exec_chalked(
    flag: str,
    tmp_data_dir: Path,
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
        chalk_cmd="exec",
        params=[flag, f"--exec-command-name={bin_path}", "--log-level=none"],
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
    assert exec_proc.mark["HASH"] == bin_hash
    assert chalk_hash != bin_hash

    # expect process info to be included
    # but can't check exact values for most of these
    assert exec_proc.mark["_PROCESS_PID"] > 0
    assert exec_proc.mark["_PROCESS_PARENT_PID"] > 0
    assert exec_proc.mark["_PROCESS_UID"] is not None


# exec wrapping with heartbeat
@pytest.mark.parametrize("copy_files", [[SLEEP_PATH]], indirect=True)
def test_exec_heartbeat(
    tmp_data_dir: Path,
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

    # custom config sets to use use this log file
    log_file = Path("/tmp/heartbeat.log")
    heartbeat_conf = CONFIGS / "heartbeat.conf"
    chalk.run(
        chalk_cmd="exec",
        params=[
            "--heartbeat",
            f"--config-file={heartbeat_conf}",
            # sleep 5 seconds -- expecting ~4 heartbeats
            f"--exec-command-name={bin_path}",
            "5",
        ],
    )

    # validate contents of log file
    assert log_file.is_file()
    first_line, *other_lines = log_file.read_text().splitlines()

    report = ChalkReport.from_json(first_line)
    assert report["_OPERATION"] == "exec"

    assert report.mark["_OP_ARTIFACT_PATH"] == str(bin_path)
    assert report.mark["_CURRENT_HASH"] == chalk_hash
    assert report.mark["ARTIFACT_TYPE"] == "ELF"
    assert report.mark["_PROCESS_PID"] != ""

    # as mentioned above, there should be a few heartbeats
    assert len(other_lines) > 0, "no heartbeats reported"
    for line in other_lines:
        other_report = ChalkReport.from_json(line)
        assert other_report["_OPERATION"] == "heartbeat"
        assert other_report.mark == report.mark

import json
import os
import shutil
import stat
from datetime import timezone
from pathlib import Path
from subprocess import check_output

import dateutil.parser
import pytest

from .chalk.runner import Chalk
from .utils.bin import sha256
from .utils.log import get_logger
from .utils.validate import (
    ArtifactInfo,
    validate_chalk_report,
    validate_extracted_chalk,
    validate_virtual_chalk,
)

logger = get_logger()


# tests multiple insertions and extractions on the same binary
def test_insert_extract_repeated(tmp_data_dir: Path, chalk: Chalk):
    bin_path = "/bin/ls"
    assert Path(bin_path).is_file(), f"{bin_path} does not exist!"
    bin_hash = sha256(Path(bin_path))

    artifact = tmp_data_dir / "ls"
    shutil.copy(bin_path, artifact)

    artifact_info = {str(artifact): ArtifactInfo(type="ELF", hash=bin_hash)}

    chalk_reports = chalk.insert(artifact=artifact, virtual=False)
    assert len(chalk_reports) == 1
    chalk_report = chalk_reports[0]
    validate_chalk_report(
        chalk_report=chalk_report, artifact_map=artifact_info, virtual=False
    )

    extracted_chalks = chalk.extract(artifact=artifact)
    assert len(extracted_chalks) == 1
    single_chalk = extracted_chalks[0]
    validate_extracted_chalk(
        extracted_chalk=single_chalk, artifact_map=artifact_info, virtual=False
    )
    validate_virtual_chalk(
        tmp_data_dir=tmp_data_dir, artifact_map=artifact_info, virtual=False
    )

    _chalk = single_chalk["_CHALKS"][0]
    assert (
        # timestamp in milliseconds so multiply by 1000
        dateutil.parser.isoparse(single_chalk["_DATETIME"])
        .replace(tzinfo=timezone.utc)
        .timestamp()
        * 1000
        == single_chalk["_TIMESTAMP"]
    )
    assert single_chalk["_DATETIME"] > _chalk["DATETIME"]

    # store chalk_rand and timestamp1 to compare against second chalk
    rand1 = _chalk["CHALK_RAND"]
    timestamp1 = single_chalk["_TIMESTAMP"]

    # repeat the above process re-chalking the same binary and assert that the
    # fields are appropriately updated
    chalk_reports_2 = chalk.insert(artifact=artifact, virtual=False)
    validate_chalk_report(
        chalk_report=chalk_reports_2[0], artifact_map=artifact_info, virtual=False
    )

    extracted_chalks_2 = chalk.extract(artifact=artifact)
    validate_extracted_chalk(
        extracted_chalk=extracted_chalks_2[0], artifact_map=artifact_info, virtual=False
    )

    # but this time timestamps and random values should be different
    _chalk = extracted_chalks_2[0]["_CHALKS"][0]
    assert rand1 != _chalk["CHALK_RAND"]
    timestamp2 = extracted_chalks_2[0]["_TIMESTAMP"]
    assert timestamp1 < timestamp2
    last_chalk_datetime = _chalk["DATETIME"]

    # do one final extraction
    extracted = chalk.run(
        chalk_cmd="extract",
        target=artifact,
        params=["--log-level=none"],
    )
    assert extracted
    extracted_chalks_3 = json.loads(extracted.stderr, strict=False)
    # basic fields
    validate_extracted_chalk(
        extracted_chalk=extracted_chalks_3[0], artifact_map=artifact_info, virtual=False
    )
    _chalk = extracted_chalks_3[0]["_CHALKS"][0]
    # _TIMESTAMP is time at extraction time, so these will be different
    assert timestamp2 < extracted_chalks_3[0]["_TIMESTAMP"]
    assert last_chalk_datetime == _chalk["DATETIME"]

    # ensure that the binary executes properly although chalked
    st = os.stat(artifact)
    os.chmod(artifact, st.st_mode | stat.S_IEXEC)
    assert check_output([str(artifact)]).decode() == check_output(["/bin/ls"]).decode()


# test insertion and extraction on a directory with multiple binaries
def test_insert_extract_directory(tmp_data_dir: Path, chalk: Chalk):
    artifact = tmp_data_dir

    ls_path = "/bin/ls"
    assert Path(ls_path).is_file(), f"{ls_path} does not exist!"
    shutil.copy(ls_path, artifact / "ls")
    ls_hash = sha256(Path(ls_path))

    date_path = "/bin/date"
    assert Path(date_path).is_file(), f"{date_path} does not exist!"
    shutil.copy(date_path, artifact / "date")
    date_hash = sha256(Path(date_path))

    artifact_info = {
        str(tmp_data_dir / "ls"): ArtifactInfo(type="ELF", hash=ls_hash),
        str(tmp_data_dir / "date"): ArtifactInfo(type="ELF", hash=date_hash),
    }

    chalk_reports = chalk.insert(artifact=artifact, virtual=False)
    validate_chalk_report(
        chalk_report=chalk_reports[0], artifact_map=artifact_info, virtual=False
    )

    output = chalk.extract(artifact=artifact)
    validate_extracted_chalk(
        extracted_chalk=output[0], artifact_map=artifact_info, virtual=False
    )
    validate_virtual_chalk(
        tmp_data_dir=tmp_data_dir, artifact_map=artifact_info, virtual=False
    )


@pytest.mark.parametrize("bin", ["date"])
def test_virtual(bin: str, tmp_data_dir: Path, chalk: Chalk):
    bin_path = f"/bin/{bin}"
    assert Path(bin_path).is_file(), f"{bin_path} does not exist!"

    shutil.copy(bin_path, tmp_data_dir / bin)
    bin_hash = sha256(Path(bin_path))

    artifact_info = {str(tmp_data_dir / bin): ArtifactInfo(type="ELF", hash=bin_hash)}

    chalk_reports = chalk.insert(artifact=tmp_data_dir, virtual=True)
    assert len(chalk_reports) == 1
    chalk_report = chalk_reports[0]

    # check chalk report
    validate_chalk_report(
        chalk_report=chalk_report, artifact_map=artifact_info, virtual=True
    )

    virtual_extract_out = chalk.extract(artifact=tmp_data_dir)
    assert len(virtual_extract_out) == 1
    extract_output = virtual_extract_out[0]

    # virtual output validation
    validate_extracted_chalk(
        extracted_chalk=extract_output, artifact_map=artifact_info, virtual=True
    )
    validate_virtual_chalk(
        tmp_data_dir=tmp_data_dir, artifact_map=artifact_info, virtual=True
    )

    # store to compare later
    timestamp_1 = extract_output["_TIMESTAMP"]

    # compare extractions
    proc = chalk.run(
        chalk_cmd="extract",
        target=tmp_data_dir / bin,
        params=["--log-level=none"],
    )
    assert proc
    virtual_extract_2 = json.loads(proc.stderr, strict=False)
    assert timestamp_1 < virtual_extract_2[0]["_TIMESTAMP"]

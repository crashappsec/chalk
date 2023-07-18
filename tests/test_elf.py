import json
import shutil
from pathlib import Path

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


# XXX parameterizing this in case we need ELF files with different properties
# but we don't want to simply run different binaries like date/ls/cat/uname
# if we don't expect the behavior to vary
@pytest.mark.parametrize("bin", ["ls"])
def test_virtual_valid(bin: str, tmp_data_dir: Path, chalk: Chalk):
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
    virtual_extract_2 = json.loads(proc.stdout, strict=False)
    assert timestamp_1 < virtual_extract_2[0]["_TIMESTAMP"]


@pytest.mark.parametrize("bin", ["ls"])
def test_nonvirtual_valid(bin: str, tmp_data_dir: Path, chalk: Chalk):
    bin_path = f"/bin/{bin}"
    assert Path(bin_path).is_file(), f"{bin_path} does not exist!"

    shutil.copy(bin_path, tmp_data_dir / bin)
    bin_hash = sha256(Path(bin_path))

    artifact_info = {str(tmp_data_dir / bin): ArtifactInfo(type="ELF", hash=bin_hash)}

    chalk_reports = chalk.insert(artifact=tmp_data_dir, virtual=False)
    assert len(chalk_reports) == 1
    chalk_report = chalk_reports[0]

    # check chalk report
    validate_chalk_report(
        chalk_report=chalk_report, artifact_map=artifact_info, virtual=False
    )

    virtual_extract_out = chalk.extract(artifact=tmp_data_dir)
    assert len(virtual_extract_out) == 1
    extract_output = virtual_extract_out[0]

    # virtual output validation
    validate_extracted_chalk(
        extracted_chalk=extract_output, artifact_map=artifact_info, virtual=False
    )
    validate_virtual_chalk(
        tmp_data_dir=tmp_data_dir, artifact_map=artifact_info, virtual=False
    )

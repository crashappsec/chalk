from pathlib import Path

import pytest

from .chalk.runner import Chalk
from .chalk.validate import (
    ArtifactInfo,
    validate_chalk_report,
    validate_extracted_chalk,
    validate_virtual_chalk,
)
from .conf import LS_PATH
from .utils.log import get_logger


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

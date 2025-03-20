# Copyright (c) 2025, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from pathlib import Path
import zipfile

import pytest

from .chalk.runner import Chalk
from .conf import ZIPS
from .utils.log import get_logger


logger = get_logger()


# Test data fixtures
PYTHON_LAMBDA_ZIP = ZIPS / "python" / "my_deployment_package.zip"
NODEJS_LAMBDA_ZIP = ZIPS / "nodejs" / "function.zip"
GOLANG_LAMBDA_ZIP = ZIPS / "golang" / "myFunction.zip"
MISC_LAMBDA_ZIP = ZIPS / "misc" / "misc.zip"
EMPTY_ZIP = ZIPS / "empty" / "empty.zip"


def verify_chalk_binary_in_zip(zip_path: Path):
    """Helper function to verify chalk binary exists in the zip file."""
    with zipfile.ZipFile(zip_path, "r") as zip_ref:
        # Verify the chalk binary was added
        assert "chalk" in zip_ref.namelist()


@pytest.mark.parametrize(
    "copy_files",
    [
        [PYTHON_LAMBDA_ZIP],
        [NODEJS_LAMBDA_ZIP],
    ],
    indirect=True,
)
def test_lambda_insert(
    tmp_data_dir: Path,
    chalk: Chalk,
    copy_files: list[Path],
):
    """Test `chalk insert --inject-binary` adds the binary to the zip."""
    test_file = copy_files[0]

    # Run chalk insert with the --inject-binary
    insert = chalk.insert(artifact=tmp_data_dir, virtual=False, inject_binary=True)

    # Verify the chalk mark was added
    assert str(test_file) in insert.marks_by_path.keys()
    assert insert.marks_by_path[str(test_file)].contains({"_OP_ARTIFACT_TYPE": "ZIP"})
    # Verify only one was added
    assert len(insert.marks) == 1

    # Verify chalk binary was added to the zip
    verify_chalk_binary_in_zip(test_file)


def test_lambda_insert_empty_zip(
    tmp_data_dir: Path,
    chalk: Chalk,
):
    """Test `chalk insert --inject-binary` on an empty zip file.

    Empty zip files should be handled gracefully - the command should
    complete with exit code 0 but no chalk marks should be created.
    """

    # Run chalk insert with the --inject-binary
    insert = chalk.insert(
        artifact=tmp_data_dir,
        virtual=False,
        inject_binary=True,
        expecting_chalkmarks=False,  # Don't expect marks for empty zip
    )


@pytest.mark.parametrize(
    "copy_files",
    [
        [PYTHON_LAMBDA_ZIP],
    ],
    indirect=True,
)
def test_lambda_extract_after_insert(
    tmp_data_dir: Path,
    chalk: Chalk,
    copy_files: list[Path],
):
    """Test extraction works correctly after insertion.

    After inserting chalk binary with --inject-binary flag, we should be able to
    extract the chalk marks without errors, and the marks should
    identify the file as a ZIP artifact.
    """
    test_file = copy_files[0]

    # First insert a chalk mark with --inject-binary flag
    insert = chalk.insert(artifact=tmp_data_dir, virtual=False, inject_binary=True)
    assert insert.marks_by_path.contains({str(test_file): {}})
    assert insert.mark.contains({"_OP_ARTIFACT_TYPE": "ZIP"})

    # Now extract and verify we can read the chalk mark
    extract = chalk.extract(artifact=tmp_data_dir)
    assert extract.marks_by_path.contains({str(test_file): {}})
    assert extract.mark.contains({"_OP_ARTIFACT_TYPE": "ZIP"})


@pytest.mark.parametrize(
    "copy_files",
    [
        [GOLANG_LAMBDA_ZIP],
        [MISC_LAMBDA_ZIP],
    ],
    indirect=True,
)
def test_lambda_with_other_lambda_zips(
    tmp_data_dir: Path,
    chalk: Chalk,
    copy_files: list[Path],
):
    """Test the --inject-binary flag with full suite of lambda zip fixutres.

    The binary insertion should work with various zip archives used for
    different lambda fixutures (Go, misc).
    """
    test_file = copy_files[0]

    # Run chalk insert with the --inject-binary flag
    insert = chalk.insert(artifact=tmp_data_dir, virtual=False, inject_binary=True)

    # Verify the chalk mark was added
    assert insert.marks_by_path.contains({str(test_file): {}})
    assert insert.mark.contains({"_OP_ARTIFACT_TYPE": "ZIP"})

    # Verify chalk binary was added to the zip
    extract_dir = tmp_data_dir / "extracted"
    verify_chalk_binary_in_zip(test_file)

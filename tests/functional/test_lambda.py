# Copyright (c) 2025, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from pathlib import Path
import shutil
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


def verify_chalk_binary_in_zip(zip_path: Path, extract_dir: Path):
    """Helper function to verify chalk binary exists in the zip file."""
    # Extract the zip contents
    extract_dir.mkdir(exist_ok=True)

    with zipfile.ZipFile(zip_path, "r") as zip_ref:
        zip_ref.extractall(extract_dir)

    # Verify the chalk binary was added
    chalk_binary_path = extract_dir / "chalk"
    assert chalk_binary_path.exists(), "Chalk binary was not found in the zip"
    # TODO: uncomment when zip archive exec perms if fixed
    # assert os.access(chalk_binary_path, os.X_OK), "Chalk binary is not executable"


def verify_chalk_mark_added(result, test_file):
    """Helper function to verify chalk mark was added to the file."""
    assert result.report.marks_by_path.contains(
        {str(test_file): {}}
    ), "Chalk mark was not added to the zip file"


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
    """Test `chalk insert --lambda` adds the binary to the zip."""
    test_file = copy_files[0]

    # Run chalk insert with the --lambda
    insert = chalk.insert(
        artifact=tmp_data_dir,
        virtual=False,
        params=["--lambda"],
    )

    # Verify the chalk mark was added
    verify_chalk_mark_added(insert, test_file)

    # Verify chalk binary was added to the zip
    extract_dir = tmp_data_dir / "extracted"
    verify_chalk_binary_in_zip(test_file, extract_dir)

    # Cleanup
    shutil.rmtree(extract_dir)


def test_lambda_insert_empty_zip(
    tmp_data_dir: Path,
    chalk: Chalk,
):
    """Test `chalk insert --lambda` on an empty zip file.

    Empty zip files should be handled gracefully - the command should
    complete with exit code 0 but no chalk marks should be created.
    """

    # Run chalk insert with the --lambda
    insert = chalk.insert(
        artifact=tmp_data_dir,
        virtual=False,
        params=["--lambda"],
        expecting_chalkmarks=False,  # Don't expect marks for empty zip
    )

    # Verify command succeeded but no marks were created
    assert insert.exit_code == 0, "Command should have exited with code 0"
    assert (
        "_CHALKS" not in insert.report
    ), "No chalks should be created for empty zip file"
    assert (
        "_OP_CHALK_COUNT" in insert.report and insert.report["_OP_CHALK_COUNT"] == 0
    ), "Chalk count should be 0"


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

    After inserting chalk with --lambda flag, we should be able to
    extract the chalk marks without errors, and the marks should
    identify the file as a ZIP artifact.
    """
    test_file = copy_files[0]

    # First insert a chalk mark with lambda flag
    insert = chalk.insert(
        artifact=tmp_data_dir,
        virtual=False,
        params=["--lambda"],
    )
    verify_chalk_mark_added(insert, test_file)

    # Now extract and verify we can read the chalk mark
    extract = chalk.extract(artifact=tmp_data_dir, ignore_errors=True)
    verify_chalk_mark_added(extract, test_file)

    # chalk_binary_path = tmp_data_dir / "chalk"
    # Verify ZIP artifact type is detected
    for mark in extract.marks:
        assert mark.has(ARTIFACT_TYPE="ZIP"), "ZIP artifact type not detected"
    # TODO: uncomment when zip archive exec perms if fixed
    # assert os.access(chalk_binary_path, os.X_OK), "Chalk binary is not executable"


@pytest.mark.parametrize(
    "copy_files",
    [
        [GOLANG_LAMBDA_ZIP],
        [MISC_LAMBDA_ZIP],
    ],
    indirect=True,
)
def test_lambda_with_other_zip_formats(
    tmp_data_dir: Path,
    chalk: Chalk,
    copy_files: list[Path],
):
    """Test the --lambda flag with different zip file formats.

    The lambda insertion should work with various zip formats commonly
    used for different lambda runtimes (Go, misc).
    """
    test_file = copy_files[0]

    # Run chalk insert with the lambda flag
    insert = chalk.insert(
        artifact=tmp_data_dir,
        virtual=False,
        params=["--lambda"],
    )

    # Verify the chalk mark was added
    verify_chalk_mark_added(insert, test_file)

    # Verify chalk binary was added to the zip
    extract_dir = tmp_data_dir / "extracted"
    verify_chalk_binary_in_zip(test_file, extract_dir)

    # Cleanup
    shutil.rmtree(extract_dir)

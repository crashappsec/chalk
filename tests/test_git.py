# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from pathlib import Path

import pytest

from .chalk.runner import Chalk
from .conf import LS_PATH
from .utils.dict import ANY, MISSING
from .utils.git import init


@pytest.mark.parametrize("remote", ["git@github.com:crashappsec/chalk.git", None])
@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_repo(
    tmp_data_dir: Path,
    chalk_copy: Chalk,
    copy_files: list[Path],
    remote: str,
):
    init(tmp_data_dir, remote=remote, first_commit=True)
    artifact = copy_files[0]
    result = chalk_copy.insert(artifact, log_level="trace")
    assert result.mark.has(
        BRANCH="main",
        COMMIT_ID=ANY,
        ORIGIN_URI=remote or "local",
        VCS_DIR_WHEN_CHALKED=str(tmp_data_dir),
    )


@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_empty_repo(
    tmp_data_dir: Path,
    chalk_copy: Chalk,
    copy_files: list[Path],
):
    init(tmp_data_dir, first_commit=False)
    artifact = copy_files[0]
    result = chalk_copy.insert(artifact, log_level="trace")
    assert result.mark.has(
        BRANCH=MISSING,
        COMMIT_ID=MISSING,
        ORIGIN_URI=MISSING,
        VCS_DIR_WHEN_CHALKED=MISSING,
    )

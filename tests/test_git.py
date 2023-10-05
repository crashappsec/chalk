# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from pathlib import Path

import pytest

from .chalk.runner import Chalk
from .conf import LS_PATH
from .utils.dict import ANY
from .utils.git import init


@pytest.mark.parametrize("first_commit", [True, False])
@pytest.mark.parametrize("remote", ["git@github.com:crashappsec/chalk.git", None])
@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_repo(
    tmp_data_dir: Path,
    chalk_copy: Chalk,
    copy_files: list[Path],
    remote: str,
    first_commit: bool,
):
    init(tmp_data_dir, remote=remote, first_commit=first_commit)
    artifact = copy_files[0]
    result = chalk_copy.insert(artifact, log_level="error")
    assert result.mark.has(
        BRANCH="main",
        COMMIT_ID=ANY,
        ORIGIN_URI=remote or "local",
    )

# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import re
from pathlib import Path
from typing import Optional

import os
import pytest

from .chalk.runner import Chalk
from .conf import LS_PATH
from .utils.dict import ANY, MISSING
from .utils.git import DATE_FORMAT, Git


@pytest.mark.parametrize(
    "remote, sign",
    [
        ("git@github.com:crashappsec/chalk.git", False),
        (None, False),
        pytest.param(
            None,
            True,
            marks=pytest.mark.skipif(
                not os.environ.get("GPG_KEY"),
                reason="GPG_KEY is required",
            ),
        ),
    ],
)
@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_repo(
    tmp_data_dir: Path,
    chalk_copy: Chalk,
    copy_files: list[Path],
    remote: Optional[str],
    sign: bool,
    random_hex: str,
):
    commit_message = "fix widget\n\nBefore this commit, the widget behaved incorrectly when foo."
    tag_message = "Changes since the previous tag:\n\n- Fix widget\n- Improve performance of bar by 42%"
    git = (
        Git(tmp_data_dir, sign=sign)
        .init(remote=remote)
        .add()
        .commit(commit_message)
        .tag(f"{random_hex}-1")
        .tag(f"{random_hex}-2", tag_message)
    )
    artifact = copy_files[0]
    result = chalk_copy.insert(artifact, log_level="trace")
    author = re.compile(rf"^{git.author} \d+ [+-]\d+$")
    committer = re.compile(rf"^{git.committer} \d+ [+-]\d+$")
    assert result.mark.has(
        BRANCH="main",
        COMMIT_ID=ANY,
        COMMIT_SIGNED=sign,
        AUTHOR=author,
        DATE_AUTHORED=DATE_FORMAT,
        COMMITTER=committer,
        DATE_COMMITTED=DATE_FORMAT,
        COMMIT_MESSAGE=commit_message,
        TAG=f"{random_hex}-2",
        TAG_SIGNED=sign,
        TAGGER=committer,
        DATE_TAGGED=DATE_FORMAT,
        TAG_MESSAGE=tag_message,
        ORIGIN_URI=remote or "local",
        VCS_DIR_WHEN_CHALKED=str(tmp_data_dir),
    )


@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_empty_repo(
    tmp_data_dir: Path,
    chalk_copy: Chalk,
    copy_files: list[Path],
):
    Git(tmp_data_dir).init()
    artifact = copy_files[0]
    result = chalk_copy.insert(artifact, log_level="trace")
    assert result.mark.has(
        BRANCH=MISSING,
        COMMIT_ID=MISSING,
        COMMIT_SIGNED=MISSING,
        TAG=MISSING,
        TAG_SIGNED=MISSING,
        ORIGIN_URI=MISSING,
        VCS_DIR_WHEN_CHALKED=MISSING,
    )

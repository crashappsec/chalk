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
    "remote, sign, symbolic_ref",
    [
        ("git@github.com:crashappsec/chalk.git", False, False),
        (None, False, False),
        pytest.param(
            None,
            True,
            True,
            marks=pytest.mark.skipif(
                not os.environ.get("GPG_KEY"),
                reason="GPG_KEY is required",
            ),
        ),
    ],
)
@pytest.mark.parametrize("pack", [True, False])
@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
@pytest.mark.parametrize(
    "set_tag_message",
    [
        False,
        True,
    ],
)
def test_repo(
    tmp_data_dir: Path,
    chalk_copy: Chalk,
    copy_files: list[Path],
    remote: Optional[str],
    sign: bool,
    random_hex: str,
    set_tag_message: bool,
    pack: bool,
    symbolic_ref: bool,
):
    commit_message = (
        "fix widget\n\nBefore this commit, the widget behaved incorrectly when foo."
    )
    tag_message = "Changes since the previous tag:\n\n- Fix widget\n- Improve performance of bar by 42%"
    git = (
        Git(tmp_data_dir, sign=sign)
        .init(remote=remote, branch="foo/bar")
        .add()
        .commit(commit_message)
        .tag(f"foo/{random_hex}-1")
        .tag(f"foo/{random_hex}-2", tag_message if set_tag_message else None)
    )
    if pack:
        git.pack()
    if symbolic_ref:
        git.symbolic_ref(f"refs/tags/foo/{random_hex}-2")
    artifact = copy_files[0]
    result = chalk_copy.insert(artifact)
    author = re.compile(rf"^{git.author} \d+ [+-]\d+$")
    committer = re.compile(rf"^{git.committer} \d+ [+-]\d+$")
    assert result.mark.has(
        BRANCH="foo/bar" if not symbolic_ref else MISSING,
        COMMIT_ID=ANY,
        COMMIT_SIGNED=sign,
        AUTHOR=author,
        DATE_AUTHORED=DATE_FORMAT,
        COMMITTER=committer,
        DATE_COMMITTED=DATE_FORMAT,
        COMMIT_MESSAGE=commit_message,
        TAG=f"foo/{random_hex}-2",
        TAG_SIGNED=sign,
        TAGGER=committer if (sign or set_tag_message) else MISSING,
        DATE_TAGGED=DATE_FORMAT if (sign or set_tag_message) else MISSING,
        TAG_MESSAGE=tag_message if set_tag_message else ("dummy" if sign else MISSING),
        ORIGIN_URI=remote or "local",
        VCS_DIR_WHEN_CHALKED=str(tmp_data_dir),
    )
    assert result.report.has(
        _ORIGIN_URI=remote or "local",
    )


@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_empty_repo(
    tmp_data_dir: Path,
    chalk_copy: Chalk,
    copy_files: list[Path],
):
    Git(tmp_data_dir).init()
    artifact = copy_files[0]
    result = chalk_copy.insert(artifact)
    assert result.mark.has(
        BRANCH=MISSING,
        COMMIT_ID=MISSING,
        COMMIT_SIGNED=MISSING,
        TAG=MISSING,
        TAG_SIGNED=MISSING,
        ORIGIN_URI=MISSING,
        VCS_DIR_WHEN_CHALKED=MISSING,
    )


@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_refetch_tag(
    tmp_data_dir: Path,
    chalk_copy: Chalk,
    copy_files: list[Path],
):
    repo = Git(tmp_data_dir).clone(
        "https://github.com/crashappsec/chalk-docker-git-context.git"
    )
    # replicate what github checkout action does
    # https://github.com/crashappsec/chalk/issues/345
    repo.fetch(
        ref="1-signed",
        refs={repo.latest_commit: "refs/tags/1-signed"},
    )
    artifact = copy_files[0]
    result = chalk_copy.insert(artifact)
    assert result.mark.has(
        TAG="1-signed",
        TAG_SIGNED=True,
    )

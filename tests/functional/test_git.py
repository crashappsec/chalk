# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import os
from pathlib import Path
from typing import Optional

import pytest

from .chalk.runner import Chalk
from .conf import LS_PATH
from .utils.dict import ANY, MISSING, Iso8601
from .utils.git import Git


@pytest.mark.parametrize(
    "remote, sign, symbolic_ref, annotate, empty",
    [
        ("git@github.com:crashappsec/chalk.git", False, False, True, False),
        (None, False, False, True, False),
        (None, False, False, False, False),
        (None, False, False, True, True),
        pytest.param(
            None,
            True,
            True,
            True,
            False,
            marks=pytest.mark.skipif(
                not os.environ.get("GPG_KEY"),
                reason="GPG_KEY is required",
            ),
        ),
    ],
)
@pytest.mark.parametrize("pack", [True, False])
@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_repo(
    tmp_data_dir: Path,
    chalk_copy: Chalk,
    copy_files: list[Path],
    remote: Optional[str],
    sign: bool,
    annotate: bool,
    random_hex: str,
    pack: bool,
    symbolic_ref: bool,
    empty: bool,
):
    commit_message = (
        ("fix widget\n\nBefore this commit, the widget behaved incorrectly when foo.")
        if not empty
        else ""
    )
    tag_message = (
        "Changes since the previous tag:\n\n- Fix widget\n- Improve performance of bar by 42%"
        if not empty
        else ""
    )
    dummy = tmp_data_dir / "dummy"
    dummy.write_text("hello")
    git = (
        Git(tmp_data_dir, sign=sign)
        .init(remote=remote, branch="foo/bar")
        .add()
        .commit(commit_message)
        .tag(f"foo/{random_hex}-1")
        .tag(f"foo/{random_hex}-2", tag_message if sign or annotate else None)
    )
    if pack:
        git.pack()
    if symbolic_ref:
        git.symbolic_ref(f"refs/tags/foo/{random_hex}-2")
    dummy.unlink()
    artifact = copy_files[0]
    result = chalk_copy.insert(artifact)
    assert result.mark.has(
        BRANCH="foo/bar" if not symbolic_ref else MISSING,
        COMMIT_ID=ANY,
        COMMIT_SIGNED=sign,
        AUTHOR=git.author,
        DATE_AUTHORED=Iso8601(),
        COMMITTER=git.committer,
        DATE_COMMITTED=Iso8601(),
        COMMIT_MESSAGE=commit_message if not empty else MISSING,
        TAG=f"foo/{random_hex}-2",
        TAG_SIGNED=sign,
        TAGGER=git.committer if (sign or annotate) else MISSING,
        DATE_TAGGED=Iso8601() if (sign or annotate) else MISSING,
        TAG_MESSAGE=(tag_message if (sign or annotate) and not empty else MISSING),
        ORIGIN_URI=remote or "local",
        VCS_DIR_WHEN_CHALKED=str(tmp_data_dir),
        VCS_MISSING_FILES=[dummy.name],
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

# Copyright (c) 2023-2026, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import hashlib
import os
import shutil
from pathlib import Path
from typing import Optional

import pytest

from .chalk.runner import Chalk
from .conf import LS_PATH
from .utils.dict import ANY, MISSING, Iso8601
from .utils.git import Git


def _git_blob_hash(content: bytes) -> str:
    header = f"blob {len(content)}\0".encode()
    return hashlib.sha1(header + content).hexdigest()[:7]


@pytest.mark.parametrize(
    "remote, expected_remote, sign, symbolic_ref, annotate, empty",
    [
        ("git@github.com:crashappsec/chalk.git", None, False, False, True, False),
        (
            "https://octocat:p@ssword@github.com/octocat/example.git",
            "https://github.com/octocat/example.git",
            False,
            False,
            False,
            False,
        ),
        (None, None, False, False, True, False),
        (None, None, False, False, False, False),
        (None, None, False, False, True, True),
        pytest.param(
            None,
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
    expected_remote: Optional[str],
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
    deleted = tmp_data_dir / "deleted"
    deleted.write_text("hello")
    committed = tmp_data_dir / "committed"
    committed.write_text("original content")
    staged_mod = tmp_data_dir / "staged_mod"
    staged_mod.write_text("staged original")
    wt_mod1 = tmp_data_dir / "wt_mod1"
    wt_mod1.write_text("wt one original")
    wt_mod2 = tmp_data_dir / "wt_mod2"
    wt_mod2.write_text("wt two original")
    rename_src = tmp_data_dir / "rename_src"
    rename_src.write_text("relocated by a bare move")
    rename_dst = tmp_data_dir / "rename_dst"
    typechange = tmp_data_dir / "typechange"
    typechange.write_text("regular file becoming a symlink")
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
    deleted.unlink()
    committed.write_text("modified content")
    # staged-only modification -> INDEX_MODIFIED
    staged_mod.write_text("staged modified")
    git.run(["git", "add", staged_mod.name])
    # multiple working-tree modifications -> WT_MODIFIED
    wt_mod1.write_text("wt one changed")
    wt_mod2.write_text("wt two changed")
    # working-tree rename via bare mv -> WT_RENAMED (NOT git mv/INDEX_RENAMED)
    rename_src.rename(rename_dst)
    # typechange: tracked regular file replaced by a symlink -> WT_TYPECHANGE
    typechange.unlink()
    typechange.symlink_to(wt_mod1.name)
    untracked = tmp_data_dir / "untracked"
    untracked.write_text("new file")
    untracked2 = tmp_data_dir / "untracked2"
    untracked2.write_text("another new file")
    artifact = copy_files[0]
    result = chalk_copy.insert(artifact)
    orig_hash = _git_blob_hash(b"original content")
    mod_hash = _git_blob_hash(b"modified content")
    del_hash = _git_blob_hash(b"hello")
    rename_hash = _git_blob_hash(b"relocated by a bare move")
    staged_orig_hash = _git_blob_hash(b"staged original")
    staged_mod_hash = _git_blob_hash(b"staged modified")
    typechange_hash = _git_blob_hash(b"regular file becoming a symlink")
    # a symlink blob stores its target path as the file content
    symlink_hash = _git_blob_hash(wt_mod1.name.encode())
    wt1_orig_hash = _git_blob_hash(b"wt one original")
    wt1_mod_hash = _git_blob_hash(b"wt one changed")
    wt2_orig_hash = _git_blob_hash(b"wt two original")
    wt2_mod_hash = _git_blob_hash(b"wt two changed")
    # The diff is HEAD-tree vs index+workdir with neither rename detection nor
    # untracked files, so: the bare-mv rename shows only as a deletion of the
    # source (rename_dst is untracked -> absent), and the typechange shows as a
    # deletion of the old regular file plus an addition of the new symlink.
    # Entries are ordered by path.
    expected_patch = f"""\
diff --git a/committed b/committed
index {orig_hash}..{mod_hash} 100644
--- a/committed
+++ b/committed
@@ -1 +1 @@
-original content
\\ No newline at end of file
+modified content
\\ No newline at end of file
diff --git a/deleted b/deleted
deleted file mode 100644
index {del_hash}..0000000
--- a/deleted
+++ /dev/null
@@ -1 +0,0 @@
-hello
\\ No newline at end of file
diff --git a/rename_src b/rename_src
deleted file mode 100644
index {rename_hash}..0000000
--- a/rename_src
+++ /dev/null
@@ -1 +0,0 @@
-relocated by a bare move
\\ No newline at end of file
diff --git a/staged_mod b/staged_mod
index {staged_orig_hash}..{staged_mod_hash} 100644
--- a/staged_mod
+++ b/staged_mod
@@ -1 +1 @@
-staged original
\\ No newline at end of file
+staged modified
\\ No newline at end of file
diff --git a/typechange b/typechange
deleted file mode 100644
index {typechange_hash}..0000000
--- a/typechange
+++ /dev/null
@@ -1 +0,0 @@
-regular file becoming a symlink
\\ No newline at end of file
diff --git a/typechange b/typechange
new file mode 120000
index 0000000..{symlink_hash}
--- /dev/null
+++ b/typechange
@@ -0,0 +1 @@
+wt_mod1
\\ No newline at end of file
diff --git a/wt_mod1 b/wt_mod1
index {wt1_orig_hash}..{wt1_mod_hash} 100644
--- a/wt_mod1
+++ b/wt_mod1
@@ -1 +1 @@
-wt one original
\\ No newline at end of file
+wt one changed
\\ No newline at end of file
diff --git a/wt_mod2 b/wt_mod2
index {wt2_orig_hash}..{wt2_mod_hash} 100644
--- a/wt_mod2
+++ b/wt_mod2
@@ -1 +1 @@
-wt two original
\\ No newline at end of file
+wt two changed
\\ No newline at end of file
"""
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
        ORIGIN_URI=expected_remote or remote or "local",
        VCS_DIR_WHEN_CHALKED=str(tmp_data_dir),
        VCS_MISSING_FILES={deleted.name},
        VCS_MODIFIED_FILES={
            committed.name,
            staged_mod.name,
            wt_mod1.name,
            wt_mod2.name,
            rename_dst.name,
            typechange.name,
        },
        VCS_UNTRACKED_FILES={untracked.name, untracked2.name},
        VCS_DIFF_STAT={"files": 8, "insertions": 5, "deletions": 7},
        VCS_DIFF_PATCH=expected_patch,
        _OP_ARTIFACT_PATH_WITHIN_VCTL=artifact.name,
    )
    assert result.report.has(
        _ORIGIN_URI=expected_remote or remote or "local",
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
def test_worktree(
    tmp_data_dir: Path,
    chalk_copy: Chalk,
    copy_files: list[Path],
):
    git = Git(tmp_data_dir).init(branch="main").add().commit()
    wt_dir = tmp_data_dir / "wt"
    git.worktree(wt_dir, branch="feature")

    artifact = wt_dir / copy_files[0].name
    shutil.copy(copy_files[0], artifact)

    result = chalk_copy.insert(artifact)
    assert result.mark.has(
        BRANCH="feature",
        COMMIT_ID=git.latest_commit,
        AUTHOR=git.author,
        COMMITTER=git.committer,
        DATE_AUTHORED=Iso8601(),
        DATE_COMMITTED=Iso8601(),
        VCS_DIR_WHEN_CHALKED=str(wt_dir),
        ORIGIN_URI="local",
        _OP_ARTIFACT_PATH_WITHIN_VCTL=artifact.name,
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


@pytest.mark.parametrize("copy_files", [[LS_PATH]], indirect=True)
def test_tag_refetch_ssl_cert_failure(
    tmp_data_dir: Path,
    chalk_copy: Chalk,
    copy_files: list[Path],
):
    # SSL cert setup only runs on the lightweight-tag refetch path, and a
    # cert-load failure only degrades that best-effort refetch. It must be
    # attributed to the refetch phase (a non-fatal _TAG GIT_REFETCH_FAILED
    # warning), NOT surfaced as a hard _TAG GIT_COLLECTION_FAILED, while TAG is
    # still collected from local tags. Regression guard for SSL cert-setup
    # failures being misfiled into the tag error channel.
    bad_cert = tmp_data_dir / "malformed.pem"
    bad_cert.write_text(
        "-----BEGIN CERTIFICATE-----\nnot a certificate\n-----END CERTIFICATE-----\n"
    )
    # No remote: the tag refetch bails out before fetching, so the SSL
    # cert-load failure is the only thing that can populate the refetch error
    # channel -- isolating the misclassification under test.
    Git(tmp_data_dir).init(branch="main").add().commit().tag("v1.0.0")
    artifact = copy_files[0]
    result = chalk_copy.insert(artifact, env={"SSL_CERT_FILE": str(bad_cert)})
    assert result.mark.has(
        TAG="v1.0.0",
        FAILED_KEYS={
            "_TAG": [
                {
                    "code": "GIT_REFETCH_FAILED",
                },
            ],
        },
    )

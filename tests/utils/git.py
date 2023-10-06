# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from contextlib import chdir
from pathlib import Path
from typing import Optional

from .log import get_logger
from .os import CalledProcessError, run


logger = get_logger()


def get_latest_commit(gitdir: Path) -> Optional[str]:
    with chdir(gitdir):
        try:
            return run(["git", "log", "-n1", "--pretty=format:'%H'"]).text
        except CalledProcessError as e:
            logger.error("Could not lookup git commit", error=e)
            return None


def init(
    path: Path,
    *,
    first_commit: bool = True,
    add: bool = True,
    remote: Optional[str] = None
):
    run(["git", "init"], cwd=path)
    run(["git", "branch", "-m", "main"], cwd=path)
    run(["git", "config", "user.name", "test"], cwd=path)
    run(["git", "config", "user.email", "test@test.com"], cwd=path)
    if remote:
        run(["git", "remote", "add", "origin", remote], cwd=path)
    if add or first_commit:
        run(["git", "add", "."], cwd=path)
    if first_commit:
        run(["git", "commit", "--allow-empty", "-m", "dummy"], cwd=path)

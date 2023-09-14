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


def init(path: Path):
    run(["git", "init"], cwd=path)
    run(["git", "branch", "-m", "main"], cwd=path)
    run(["git", "config", "user.name", "test"], cwd=path)
    run(["git", "config", "user.email", "test@test.com"], cwd=path)
    run(["git", "add", "."], cwd=path)
    run(["git", "commit", "--allow-empty", "-m", "dummy"], cwd=path)

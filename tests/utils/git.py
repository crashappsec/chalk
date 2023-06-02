import os
from contextlib import chdir
from pathlib import Path

from .log import get_logger

logger = get_logger()


def get_git_commit(gitdir: Path) -> Optional[str]:
    with chdir(gitdir):
        commit = None
        try:
            info_commit = (
                os.popen("git log | grep commit | cut -d' ' -f2 | head -n1")
                .read()
                .rstrip()
            )
        except Exception as e:
            logger.error("Could not lookup git commit", error=e)
            info_commit = None
        finally:
            return info_commit

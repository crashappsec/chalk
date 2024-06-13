# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import functools
import re
from pathlib import Path
from typing import Optional

import os

from .log import get_logger
from .os import run


logger = get_logger()

DATE_FORMAT = re.compile(r"^\w+ \w+ \d+ \d+:\d+:\d+ \d+ [+-]\d+$")


class Git:
    author = "author <author@test.com>"
    committer = "committer <committer@test.com>"

    def __init__(self, path: Path, sign: bool = False):
        self.path = path
        self.sign = sign
        self.run = functools.partial(run, cwd=self.path)

    def init(
        self,
        *,
        first_commit: bool = True,
        add: bool = True,
        remote: Optional[str] = None,
        branch: str = "main",
    ):
        author_name, author_email = self.author.split()
        committer_name, committer_email = self.committer.split()
        self.run(["git", "init"])
        self.run(["git", "branch", "-m", branch])
        self.config("author.name", author_name)
        self.config("author.email", author_email)
        self.config("committer.name", committer_name)
        self.config("committer.email", committer_email)
        if self.sign:
            self.config("commit.gpgsign", "true")
            self.config("tag.gpgsign", "true")
            self.config("user.signingkey", os.environ.get("GPG_KEY", ""))
        if remote:
            self.run(["git", "remote", "add", "origin", remote])
        return self

    def config(self, key: str, value: str):
        self.run(["git", "config", key, value])

    def add(self):
        self.run(["git", "add", "."])
        return self

    def commit(self, message="dummy"):
        self.run(["git", "commit", "--allow-empty", "-m", message])
        return self

    def tag(self, tag: str, message=""):
        args = ["git", "tag", tag]
        if message or self.sign:
            args += ["-a", "-m", message or "dummy"]
        self.run(args)
        return self

    def pack(self):
        self.run(["git", "gc"])
        return self

    @property
    def latest_commit(self) -> str:
        return self.run(["git", "rev-parse", "HEAD"]).text

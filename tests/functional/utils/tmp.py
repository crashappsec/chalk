# Copyright (c) 2024, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from contextlib import contextmanager
from pathlib import Path
from tempfile import NamedTemporaryFile
from typing import Optional

import os


@contextmanager
def make_tmp_file(path: Optional[str] = None, mode="w+b", delete=True):
    # tempfile does not allow to create file with specific path
    # as it always randomizes the name
    if path:
        path = Path(path).resolve()
        os.makedirs(path.parent, exist_ok=True)
        try:
            with path.open(mode) as f:
                yield path
        finally:
            if delete:
                path.unlink(missing_ok=True)
    else:
        with NamedTemporaryFile(mode=mode, delete=delete) as f:
            yield Path(f.name)

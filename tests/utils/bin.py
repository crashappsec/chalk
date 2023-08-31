import hashlib
from pathlib import Path


def sha256(fpath: Path) -> str:
    """Returns sha256 of the file"""
    assert fpath.is_file(), f"{fpath} is not a file"
    return hashlib.sha256(fpath.read_bytes()).hexdigest()

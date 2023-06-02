from pathlib import Path
from subprocess import CalledProcessError, check_output


def sha256(fpath: Path) -> str:
    """Returns sha256 of the file"""
    assert fpath.is_file(), f"{fpath} is not a file"
    try:
        shabin = Path(check_output(["which", "sha256sum"]).decode().strip())
    except CalledProcessError as e:
        raise RuntimeError("Could not find binary to compute sha256") from e

    try:
        return check_output([shabin, fpath]).decode().strip().split()[0]
    except CalledProcessError as e:
        raise RuntimeError(f"Could not compute hash for {fpath}") from e

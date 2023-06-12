from contextlib import chdir
from pathlib import Path
from tempfile import TemporaryDirectory

import pytest

from .chalk.runner import Chalk
from .utils.log import get_logger

logger = get_logger()


@pytest.fixture
def tmp_data_dir():
    with TemporaryDirectory() as tmp_dir:
        with chdir(tmp_dir):
            yield Path(tmp_dir)


@pytest.fixture(scope="session")
def chalk():
    chalk = Chalk(binary=(Path(__file__).parent.parent / "chalk").resolve())
    assert chalk.binary is None or chalk.binary.is_file()
    yield chalk

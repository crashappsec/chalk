import shutil
import sqlite3
from contextlib import chdir, closing
from functools import lru_cache
from pathlib import Path
from tempfile import TemporaryDirectory

import pytest
import requests

from .chalk.runner import Chalk
from .conf import SERVER_CERT, SERVER_DB, SERVER_HTTP, SERVER_HTTPS
from .utils.log import get_logger


logger = get_logger()


def pytest_addoption(parser):
    # https://docs.pytest.org/en/7.4.x/how-to/logging.html#live-logs
    # log_cli is only an ini option so we add argument for it
    parser.addoption(
        "--logs", action="store_true", default=False, help="show live logs"
    )


@pytest.hookimpl
def pytest_configure(config):
    config.inicfg["log_cli"] = config.getoption("--logs")


@pytest.fixture(scope="function")
def tmp_data_dir():
    with TemporaryDirectory() as tmp_dir:
        with chdir(tmp_dir):
            yield Path(tmp_dir)


@pytest.fixture(scope="session")
def chalk():
    chalk = Chalk(binary=(Path(__file__).parent.parent / "chalk").resolve())
    assert chalk.binary and chalk.binary.is_file()
    yield chalk


@pytest.fixture(scope="function")
def chalk_copy(chalk: Chalk, tmp_data_dir: Path):
    """
    Make copy of chalk into temporary folder

    This is especially useful if test case modifies chalk binary itself
    """
    path = tmp_data_dir / "chalk"
    assert path != chalk.binary
    logger.info("making a copy of chalk", base=chalk.binary, copy=path)
    shutil.copy(chalk.binary, path)
    chalk = Chalk(binary=path)
    yield chalk


@pytest.fixture()
def server_sql():
    if not SERVER_DB.is_file():
        raise pytest.skip(f"{SERVER_DB} is missing. skipping test")
    with closing(sqlite3.connect(SERVER_DB)) as conn:

        def execute(sql: str):
            cur = conn.cursor()
            res = cur.execute(sql).fetchone()
            return str(res[0]) if res else None

        yield execute


@pytest.fixture()
def server_cert():
    if not SERVER_CERT.is_file():
        raise pytest.skip(f"{SERVER_CERT} is missing. skipping test")
    return str(SERVER_CERT)


@lru_cache()
def is_server_up(url: str, **kwargs):
    try:
        r = requests.get(url, allow_redirects=True, timeout=5, **kwargs)
        r.raise_for_status()
    except Exception:
        logger.exception("server error", url=url)
        return False
    else:
        logger.info("server response succedded", url=url, status=r.status_code)
        return True


@pytest.fixture()
def server_http():
    if not is_server_up(f"{SERVER_HTTP}/health"):
        raise pytest.skip(f"{SERVER_HTTP} is down. skipping test")
    return SERVER_HTTP


@pytest.fixture()
def server_https(server_cert: str):
    if not is_server_up(f"{SERVER_HTTPS}/health", verify=server_cert):
        raise pytest.skip(f"{SERVER_HTTPS} is down. skipping test")
    return SERVER_HTTPS

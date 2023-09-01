import shutil
import sqlite3
from contextlib import ExitStack, chdir, closing
from functools import lru_cache
from pathlib import Path
from secrets import token_bytes
from tempfile import NamedTemporaryFile, TemporaryDirectory

import os
import pytest
import requests
from filelock import FileLock

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


def lock(name: str):
    return FileLock(Path(__file__).with_name(name).resolve())


@pytest.fixture(autouse=True)
def be_exclusive(request, worker_id):
    try:
        workercount = request.config.workerinput["workercount"]
    except AttributeError:
        yield
    else:
        if request.node.get_closest_marker("exclusive"):
            with ExitStack() as stack:
                # as test case is exclusive, lock all worker locks
                for i in range(workercount):
                    stack.enter_context(lock(f"worker-gw{i}.lck"))
                yield
        else:
            with lock(f"worker-{worker_id}.lck"):
                yield


@pytest.fixture()
def random_hex():
    return token_bytes(5).hex()


@pytest.fixture(scope="function")
def tmp_data_dir():
    with TemporaryDirectory() as tmp_dir:
        with chdir(tmp_dir):
            yield Path(tmp_dir)


@pytest.fixture(scope="function")
def tmp_file(request):
    config = {
        "mode": "w+b",
        "delete": True,
    }
    config.update(getattr(request, "param", {}))
    path = config.pop("path")
    # tempfile does not allow to create file with specific path
    # as it always randomizes the name
    if path:
        path = Path(path).resolve()
        os.makedirs(path.parent, exist_ok=True)
        try:
            with path.open(config["mode"]) as f:
                yield f
        finally:
            if config["delete"]:
                path.unlink(missing_ok=True)
    else:
        with NamedTemporaryFile(**config) as f:
            yield f


@pytest.fixture(scope="function")
def copy_files(tmp_data_dir: Path, request):
    paths: list[Path] = []
    assert isinstance(request.param, list)
    for i in request.param:
        shutil.copy(i, tmp_data_dir)
        paths.append(tmp_data_dir / Path(i).name)
    yield paths


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
        pytest.skip(f"{SERVER_DB} is missing. skipping test")
    with closing(sqlite3.connect(SERVER_DB)) as conn:

        def execute(sql: str):
            cur = conn.cursor()
            res = cur.execute(sql).fetchone()
            return str(res[0]) if res else None

        yield execute


@pytest.fixture()
def server_cert():
    if not SERVER_CERT.is_file():
        pytest.skip(f"{SERVER_CERT} is missing. skipping test")
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
        pytest.skip(f"{SERVER_HTTP} is down. skipping test")
    return SERVER_HTTP


@pytest.fixture()
def server_https(server_cert: str):
    if not is_server_up(f"{SERVER_HTTPS}/health", verify=server_cert):
        pytest.skip(f"{SERVER_HTTPS} is down. skipping test")
    return SERVER_HTTPS

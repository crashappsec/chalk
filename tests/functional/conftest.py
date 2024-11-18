# Copyright (c) 2023-2024, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import shutil
import sqlite3
from contextlib import ExitStack, chdir, closing
from functools import lru_cache
from pathlib import Path
from secrets import token_bytes
from tempfile import TemporaryDirectory

import os
import pytest
import requests
from filelock import FileLock

from . import conf
from .chalk.runner import Chalk
from .conf import (
    CONFIGS,
    GDB_PATH,
    SERVER_CERT,
    SERVER_CHALKDUST,
    SERVER_DB,
    SERVER_HTTP,
    SERVER_HTTPS,
    SERVER_IMDS,
    SERVER_STATIC,
)
from .utils.log import get_logger
from .utils.tmp import make_tmp_file


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


@pytest.fixture(autouse=True)
def requires_gdb(request):
    if request.node.get_closest_marker("requires_gdb") and not GDB_PATH:
        pytest.skip(f"gdb is not installed. skipping test")


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
    path = config.pop("path", None)
    with make_tmp_file(path, **config) as tmp:
        yield tmp


@pytest.fixture(scope="function")
def copy_files(tmp_data_dir: Path, request):
    paths: list[Path] = []
    assert isinstance(request.param, list)
    for i in request.param:
        shutil.copy(i, tmp_data_dir)
        paths.append(tmp_data_dir / Path(i).name)
    yield paths


@pytest.fixture(scope="session")
def chalk_default():
    """
    Returns bare chalk binary (for some testing case
    where we don't need stdout enabled in config)
    """
    root = Path(__file__).parent.parent.parent
    # if present use chalk backup as it does not have cosign setup
    binary = root / "chalk.bck"
    if not binary.exists():
        binary = root / "chalk"
    chalk = Chalk(binary=binary)
    assert chalk.binary and chalk.binary.is_file()
    yield chalk


@pytest.fixture(scope="session")
def chalk(
    chalk_default: Chalk,
):
    # make a copy of chalk that has testing config loaded
    # for most tests need output from stdout
    tmp = Path("/tmp/chalk").with_suffix(f".{token_bytes(5).hex()}")
    shutil.copy(chalk_default.binary, tmp)
    chalk = Chalk(binary=tmp)
    # sanity check
    assert chalk.binary and chalk.binary.is_file()
    chalk.load(Path(__file__).parent / "testing.c4m", use_embedded=False)
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


@pytest.fixture()
def server_imds():
    if not is_server_up(f"{SERVER_IMDS}/health"):
        pytest.skip(f"{SERVER_IMDS} is down. skipping test")
    return SERVER_IMDS


@pytest.fixture()
def server_static():
    if not is_server_up(f"{SERVER_STATIC}/conftest.py"):
        pytest.skip(f"{SERVER_STATIC} is down. skipping test")
    return SERVER_STATIC


@pytest.fixture()
def server_chalkdust():
    return SERVER_CHALKDUST


@pytest.fixture(scope="session")
def configs():
    """
    Renders all configs into a temporary folder

    Rendering is done via python string formatting however
    as '{' and '}' are often used in con4m configs, [[ and ]]
    are used instead for string formatting delimiters.
    """
    with TemporaryDirectory() as tmp_dir:
        tmp = Path(tmp_dir)
        for root, dirs, files in os.walk(CONFIGS):
            for f in files:
                config = Path(root) / f
                tmp_config = tmp / config.relative_to(CONFIGS)
                template = (
                    config.read_text()
                    .replace("{", "{{")
                    .replace("}", "}}")
                    .replace("[[", "{")
                    .replace("]]", "}")
                )
                context = {"configs": tmp, **vars(conf)}
                data = template.format(**context)
                tmp_config.parent.mkdir(parents=True, exist_ok=True)
                tmp_config.write_text(data)
        yield tmp

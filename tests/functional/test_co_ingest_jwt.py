# Copyright (c) 2026, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
"""
Crash Override chalk ingest keys are Gatekeeper-signed ES256 JWTs. Released
chalk binaries must load one as the CO token and send it as the report
bearer, with and without `exp`, for every segment length class.
See utils/ingest_jwt.py.
"""

import hashlib
import platform
from pathlib import Path

import httpx
import pytest

from .chalk.runner import Chalk
from .conf import REPO
from .utils.ingest_jwt import Case, cases, run_case

CO_CONFIGS = REPO / "configs" / "co"
# oldest release that must accept the tokens
RELEASED_VERSION = "1.2.0"
CASES = cases()


@pytest.fixture(scope="session")
def released_chalk(tmp_path_factory: pytest.TempPathFactory) -> Path:
    arch = "arm64" if platform.machine() in {"aarch64", "arm64"} else "x86_64"
    url = f"https://dl.crashoverride.run/chalk/chalk-{RELEASED_VERSION}-linux-{arch}"
    binary = tmp_path_factory.mktemp("released") / "chalk"
    binary.write_bytes(httpx.get(url, follow_redirects=True).raise_for_status().content)
    expected = (
        httpx.get(f"{url}.sha256", follow_redirects=True)
        .raise_for_status()
        .text.split()[0]
    )
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == expected
    return binary


@pytest.mark.parametrize("case", CASES, ids=[c.name for c in CASES])
def test_released_chalk_sends_ingest_jwt(released_chalk: Path, case: Case):
    result = run_case(released_chalk, CO_CONFIGS, case)
    assert result.ok, result


@pytest.mark.parametrize("case", CASES, ids=[c.name for c in CASES])
def test_chalk_sends_ingest_jwt(chalk_default: Chalk, case: Case):
    result = run_case(chalk_default.binary, CO_CONFIGS, case)
    assert result.ok, result

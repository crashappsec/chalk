# Copyright (c) 2025, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from pathlib import Path

from .chalk.runner import Chalk
from .utils.log import get_logger


logger = get_logger()


def test_cert(
    server_cert: Path,
    chalk: Chalk,
):
    insert = chalk.extract(
        artifact=server_cert,
    )
    assert insert.mark.has(_X509_SUBJECT="/CN=tls.chalk.local")

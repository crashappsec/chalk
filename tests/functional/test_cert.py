# Copyright (c) 2025, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import base64
import re
from pathlib import Path

import certifi

from .chalk.runner import Chalk
from .conf import CONFIGS
from .utils.dict import Contains
from .utils.log import get_logger


logger = get_logger()

COLON_HEX = re.compile(r"^([0-9a-f]{2}:)*([0-9a-f]{2})$")


def test_cert(
    server_cert: Path,
    chalk: Chalk,
):
    insert = chalk.extract(
        config=CONFIGS / "certs.c4m",
        artifact=certifi.where(),
        env={
            "CO_CERT": base64.b64encode(server_cert.read_bytes()).decode(),
        },
    )
    assert insert.marks.contains(
        Contains(
            [
                {
                    "_OP_ARTIFACT_PATH": re.compile(r"/cacert.pem$"),
                    "_X509_SIGNATURE": COLON_HEX,
                    "_X509_SUBJECT": "/C=US/O=DigiCert Inc/OU=www.digicert.com/CN=DigiCert Global Root CA",
                },
                {
                    "_OP_ARTIFACT_ENV_VAR_NAME": "CO_CERT",
                    "_X509_SIGNATURE": COLON_HEX,
                    "_X509_SUBJECT": "/CN=tls.chalk.local",
                },
            ]
        )
    )

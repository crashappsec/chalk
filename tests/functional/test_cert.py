# Copyright (c) 2025, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import base64
import re
from pathlib import Path

import certifi
import pytest

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
            "BAD_ENV_VAR": "   a",
            "CO_CERT": base64.b64encode(server_cert.read_bytes()).decode(),
        },
    )
    assert insert.marks.contains(
        Contains(
            [
                {
                    "_OP_ARTIFACT_PATH": re.compile(r"/cacert.pem$"),
                    "_X509_SIGNATURE": COLON_HEX,
                    "_X509_SUBJECT": {
                        "commonName": "DigiCert Global Root CA",
                    },
                    "_X509_SUBJECT_SHORT": {
                        "CN": "DigiCert Global Root CA",
                    },
                },
                {
                    "_OP_ARTIFACT_ENV_VAR_NAME": "CO_CERT",
                    "_X509_SIGNATURE": COLON_HEX,
                    "_X509_SUBJECT": {
                        "commonName": "tls.chalk.local",
                    },
                    "_X509_SUBJECT_SHORT": {
                        "CN": "tls.chalk.local",
                    },
                },
            ]
        )
    )


@pytest.mark.parametrize(
    "bad_env_var",
    [
        "AAAA AAA",
        "AAAAAAAA AAA",
    ],
)
def test_cert_bad_env_var_boundary_base64_does_not_crash(
    server_cert: Path,
    chalk: Chalk,
    bad_env_var: str,
):
    extract = chalk.extract(
        config=CONFIGS / "certs.c4m",
        artifact=certifi.where(),
        env={
            "BAD_ENV_VAR": bad_env_var,
            "CO_CERT": base64.b64encode(server_cert.read_bytes()).decode(),
        },
    )
    assert extract.marks.contains(
        Contains(
            [
                {
                    "_OP_ARTIFACT_ENV_VAR_NAME": "CO_CERT",
                    "_X509_SIGNATURE": COLON_HEX,
                    "_X509_SUBJECT": {
                        "commonName": "tls.chalk.local",
                    },
                    "_X509_SUBJECT_SHORT": {
                        "CN": "tls.chalk.local",
                    },
                },
            ]
        )
    )

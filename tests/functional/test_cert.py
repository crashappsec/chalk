# Copyright (c) 2025, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import base64
import re
from pathlib import Path

import certifi
from cryptography import x509
from cryptography.hazmat.primitives import serialization

from .chalk.runner import Chalk
from .conf import CONFIGS
from .utils.dict import Contains
from .utils.log import get_logger

logger = get_logger()

COLON_HEX = re.compile(r"^([0-9a-f]{2}:)*([0-9a-f]{2})$")
PEM_PUBLIC_KEY = re.compile(r"^-----BEGIN PUBLIC KEY-----")


def malformed_public_key_der(cert_pem: bytes) -> bytes:
    cert = x509.load_pem_x509_certificate(cert_pem)
    public_key = cert.public_key()
    cert_der = bytearray(cert.public_bytes(serialization.Encoding.DER))
    encoded_key = public_key.public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.PKCS1,
    )
    key_offset = cert_der.index(encoded_key)
    assert cert_der[key_offset] == 0x30
    cert_der[key_offset] = 0x31
    return bytes(cert_der)


def test_cert(
    server_cert: Path,
    chalk: Chalk,
):
    insert = chalk.extract(
        config=CONFIGS / "certs.c4m",
        artifact=certifi.where(),
        env={
            "BAD_ENV_VAR": "   a",
            "BAD_ENV_VAR_2": "AAAA AAA",
            "BAD_ENV_VAR_3": "AAAAAAAA AAA",
            "CO_CERT": base64.b64encode(server_cert.read_bytes()).decode(),
        },
    )
    assert insert.marks.contains(
        Contains(
            [
                {
                    "_OP_ARTIFACT_PATH": re.compile(r"/cacert.pem$"),
                    "_X509_SIGNATURE": COLON_HEX,
                    "_X509_KEY": PEM_PUBLIC_KEY,
                    "_X509_KEY_TYPE": "id-ecPublicKey",
                    "_X509_SUBJECT": {
                        "commonName": "COMODO ECC Certification Authority",
                    },
                    "_X509_SUBJECT_SHORT": {
                        "CN": "COMODO ECC Certification Authority",
                    },
                },
                {
                    "_OP_ARTIFACT_ENV_VAR_NAME": "CO_CERT",
                    "_X509_SIGNATURE": COLON_HEX,
                    "_X509_KEY": PEM_PUBLIC_KEY,
                    "_X509_KEY_TYPE": "rsaEncryption",
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


def test_malformed_public_key_does_not_crash(
    server_cert: Path,
    chalk: Chalk,
    tmp_data_dir: Path,
):
    malformed_cert = tmp_data_dir / "malformed.der"
    malformed_cert.write_bytes(malformed_public_key_der(server_cert.read_bytes()))
    insert = chalk.extract(
        config=CONFIGS / "certs.c4m",
        artifact=malformed_cert,
        expecting_chalkmarks=False,
    )
    assert "_CHALKS" not in insert.report

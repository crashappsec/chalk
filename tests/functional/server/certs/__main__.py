import os
from pathlib import Path

from ...utils.log import get_logger
from .selfsigned import generate_selfsigned_cert


logger = get_logger()


def generate_cert(
    domains: list[str],
    ips: list[str],
    keyfile: Path,
    certfile: Path,
):
    cert, key = generate_selfsigned_cert(domains, ips)
    keyfile.parent.mkdir(parents=True, exist_ok=True)
    certfile.parent.mkdir(parents=True, exist_ok=True)
    keyfile.write_bytes(key)
    certfile.write_bytes(cert)
    logger.info("Generated self-signed certificate")
    logger.info(f"key: {keyfile}")
    logger.info(f"pem: {certfile}")


domain = os.environ.get("DOMAIN")
cert = os.environ.get("CERT")
key = os.environ.get("KEY")

if __name__ == "__main__":
    if domain and cert and key:
        certfile = Path(cert)
        keyfile = Path(key)
        if not certfile.is_file() or not keyfile.is_file():
            generate_cert(domains=[domain], ips=[], keyfile=keyfile, certfile=certfile)

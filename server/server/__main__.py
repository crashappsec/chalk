# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import argparse
import logging
import sys
import typing
from pathlib import Path

import os
import uvicorn

from . import api
from .__version__ import __version__
from .api import title
from .certs.selfsigned import generate_selfsigned_cert


logger = logging.getLogger(api.__name__.split(".")[0])

parser = argparse.ArgumentParser(
    title, formatter_class=argparse.ArgumentDefaultsHelpFormatter
)


def existing_file(p):
    path = Path(p).absolute()
    if not path.is_file():
        parser.error(f"{p} file does not exist")
    return path


parser.add_argument(
    "--version",
    action="store_true",
    default=False,
    help="show server version and exit",
)

subparsers = parser.add_subparsers()

server = subparsers.add_parser(
    "run",
    description=(
        "By default http server is used. "
        "For https server you must provide --certfile and --keyfile args. "
        "If you dont have cert already, "
        "you can either generate it with certonly command, "
        "or also provide --domain/--ips in which case cert will be created "
        "before starting the server."
    ),
    help="Run API server",
    formatter_class=argparse.ArgumentDefaultsHelpFormatter,
)
server.add_argument(
    "--host",
    help="host the server is listening at",
    default="0.0.0.0",
)
server.add_argument(
    "-p",
    "--port",
    help="port the server is running at",
    default=int(os.environ.get("PORT", 8585)),
    type=int,
)
group = server.add_mutually_exclusive_group()
group.add_argument(
    "-r",
    "--reload",
    help="reload server on changes",
    action="store_true",
    default=False,
)
group.add_argument(
    "-k",
    "--workers",
    help="number of workers for the server",
    type=int,
)
certfile = server.add_argument(
    "--certfile",
    help="path to TLS cert",
    type=lambda p: Path(p).absolute(),
)
keyfile = server.add_argument(
    "--keyfile",
    help="path to TLS cert private key",
    type=lambda p: Path(p).absolute(),
)
domains = server.add_argument(
    "--domain",
    dest="domains",
    help="if cert does not exist, domain to generate a certificate for",
    default=[],
    nargs="+",
)
ips = server.add_argument(
    "--ip",
    dest="ips",
    help="if cert does not exist, allow addressing by IP, for when you don't have real DNS",
    default=[],
    nargs="+",
)
server.add_argument(
    "--use-existing-cert",
    help="if cert already exists, use it",
    action="store_true",
    default=False,
)

cert = subparsers.add_parser(
    "certonly",
    description="Generate self-signed certificate",
    help="Generate self-signed certificate",
    formatter_class=argparse.ArgumentDefaultsHelpFormatter,
)
cert_domains = cert.add_argument(
    "--domain",
    dest="domains",
    help="domain to generate a certificate for",
    nargs="+",
    default=[],
    required=True,
)
cert.add_argument(
    "--ips",
    dest="ips",
    help="allow addressing by IP, for when you don't have real DNS",
    default=[],
    nargs="+",
)
cert.add_argument(
    "--certfile",
    help="path where to save TLS cert",
    type=lambda p: Path(p).absolute(),
    required=True,
)
cert.add_argument(
    "--keyfile",
    help="path where to save TLS cert private key",
    type=lambda p: Path(p).absolute(),
    required=True,
)


def run_server(
    host: str,
    port: int,
    reload: bool,
    workers: typing.Optional[int],
    keyfile: typing.Optional[Path],
    certfile: typing.Optional[Path],
):
    app = f"{api.__name__}:app"
    workers = workers or os.cpu_count()
    if reload:
        workers = None
    uvicorn.run(
        app,
        port=port,
        host=host,
        workers=workers,
        reload=reload,
        ssl_keyfile=keyfile,
        ssl_certfile=certfile,
    )


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


def main():
    args = parser.parse_args()

    if args.version:
        print(__version__)
        return 0

    # not running any command
    if not getattr(args, "port", None) and not getattr(args, "domains", None):
        parser.print_help(sys.stderr)
        return 1

    certfile_exists = args.certfile and args.certfile.is_file()
    keyfile_exists = args.keyfile and args.keyfile.is_file()

    # require both file to exist if any exist
    if certfile_exists or keyfile_exists:
        certfile.type = existing_file
        keyfile.type = existing_file

        def dont_overwrite_cert(_):
            if getattr(args, "use_existing_cert", False):
                return ""
            parser.error(
                f"{args.certfile} or {args.keyfile} already exist. "
                "Refusing to overwrite them."
            )

        domains.type = dont_overwrite_cert
        cert_domains.type = dont_overwrite_cert

    # if paths are provided but they dont exist, ensure domain is required
    # so that cert can be created
    if all(
        [
            not certfile_exists,
            not keyfile_exists,
            any([args.certfile, args.keyfile]),
        ]
    ):
        certfile.required = True
        keyfile.required = True
        domains.required = True

    # reparse args with updated requirements
    args = parser.parse_args()

    given_domains = [i for i in args.domains if i]
    if given_domains:
        generate_cert(
            domains=given_domains,
            ips=args.ips,
            keyfile=args.keyfile,
            certfile=args.certfile,
        )

    # running in certonly mode
    if not getattr(args, "port", None):
        return 0

    run_server(
        host=args.host,
        port=args.port,
        reload=args.reload,
        workers=args.workers,
        keyfile=args.keyfile,
        certfile=args.certfile,
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())

import argparse
import os
import sys
from pathlib import Path

import uvicorn
from certs.selfsigned import generate_selfsigned_cert
from conf.version import __version__
from fastapp import app

if __name__ == "__main__":
    parser = argparse.ArgumentParser("Local chalk API server")

    parser.add_argument(
        "--version",
        action="store_true",
        default=False,
        help="show server version and exit",
    )
    subparsers = parser.add_subparsers()
    parser.add_argument(
        "--port", help="port the server is running at", default=8585, type=int
    )
    parser.add_argument(
        "--certfile", help="path to TLS cert", type=lambda p: Path(p).absolute()
    )
    parser.add_argument(
        "--keyfile",
        help="path to private key for TLS cert",
        type=lambda p: Path(p).absolute(),
    )
    parser.add_argument(
        "--workers",
        help="number of workers for the server",
        type=int,
        default=4,
    )
    parser.add_argument(
        "--reload",
        help="reload server on changes",
        action="store_true",
        default=False,
    )

    # FIXME add groups (possibly via click?)
    parser.add_argument(
        "--domain",
        help="domain to generate a certificate for",
        type=str,
    )
    parser.add_argument(
        "--ips",
        help="allow addressing by IP, for when you don't have real DNS",
        default=[],
        nargs="+",
    )
    parser.add_argument(
        "--cert-output",
        help="output directory for generated certificates",
        type=lambda p: Path(p).absolute(),
        default=Path(__file__).parent / "keys",
    )

    parser.add_argument(
        "--certs-only",
        action="store_true",
        default=False,
        help="only generate self-signed certs and exit",
    )

    parser.add_argument(
        "--cert-name",
        default="self-signed",
        help="Prefix to use in cert and key to be generated (xxx.cert & xxx.key)",
    )

    args = parser.parse_args()

    if args.version:
        print(__version__)
        sys.exit(0)

    if args.domain or args.ips:
        assert args.domain, "we need a domain, even if dummy alias"
        os.makedirs(args.cert_output, exist_ok=True)
        key_file = args.cert_output / f"{args.cert_name}.key"
        cert_file = args.cert_output / f"{args.cert_name}.cert"
        if key_file.is_file() or cert_file.is_file():
            raise RuntimeError(
                (
                    f"Refusing to overwrite existing certificates in {args.cert_output}. "
                    "Please remove them or pass them via --keyfile and --certfile"
                )
            )
        cert_pem, key_pem = generate_selfsigned_cert(args.domain, args.ips)
        with open(key_file, "wb") as outf:
            outf.write(key_pem)
        with open(cert_file, "wb") as outf:
            outf.write(cert_pem)

        # FIXME will remove oncew we move into click
        if args.certs_only:
            sys.exit(0)

        if args.keyfile or args.certfile:
            print(
                "Generated certificates in {args.cert_output} but proceeding to use the passed certificates"
            )
        else:
            args.keyfile = key_file
            args.certfile = cert_file

    if args.keyfile or args.certfile:
        assert args.keyfile and args.certfile, "both a key and cert are required"

    if args.keyfile and args.certfile:
        assert args.keyfile.is_file(), "Key file not found"
        assert args.certfile.is_file(), "Cert file not found"
        app.ssl_keyfile = args.keyfile
        app.cert_file = args.certfile
        uvicorn.run(
            "main:app",
            port=args.port,
            host="0.0.0.0",
            workers=args.workers,
            reload=args.reload,
            ssl_keyfile=args.keyfile,
            ssl_certfile=args.certfile,
        )
    else:
        uvicorn.run("fastapp:app", host="0.0.0.0", port=args.port)

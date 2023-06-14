import argparse
import json
import logging.config
import os
import sys
from pathlib import Path

import sqlalchemy
import uvicorn
from certs.selfsigned import generate_selfsigned_cert
from conf.info import CHALK_VER, CONFIG_TOOL_VER, SERVER_VER
from db import crud, models, schemas
from db.database import SessionLocal, engine
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.openapi.utils import get_openapi
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi_healthcheck import HealthCheckFactory, healthCheckRoute
from sqlalchemy.orm import Session

models.Base.metadata.create_all(bind=engine)

logging.config.fileConfig(
    Path(__file__).parent / "conf" / "logging.conf", disable_existing_loggers=True
)
logger = logging.getLogger(__name__)

title = "Local Chalk Ingestion Server"


def custom_openapi():
    if app.openapi_schema:
        return app.openapi_schema
    openapi_schema = get_openapi(
        title=title,
        description="CrashOverride local chalk API",
        routes=app.routes,
    )
    openapi_schema["info"]["x-logo"] = {"url": "/site/images/logo@2x.png"}
    app.openapi_schema = openapi_schema
    return app.openapi_schema


app = FastAPI(
    title=title,
    version=SERVER_VER,
)

_healthChecks = HealthCheckFactory()

app.add_api_route("/health", endpoint=healthCheckRoute(factory=_healthChecks))
app.mount("/about", StaticFiles(directory="site", html=True), name="site")


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


@app.get("/", response_class=RedirectResponse)
async def redirect_to_docs():
    return RedirectResponse("/about")


@app.get("/version")
async def versions():
    versions = {
        "chalk_version": CHALK_VER,
        "chalk_api_server_version": SERVER_VER,
        "chalk_config_tool_version": CONFIG_TOOL_VER,
    }
    return versions


@app.post("/ping")
async def ping(request: Request, db: Session = Depends(get_db)):
    try:
        raw = await request.body()
        stats = json.loads(raw)
        for entry in stats:
            stat = schemas.Stats(
                operation=entry["_OPERATION"],
                timestamp=entry["_TIMESTAMP"],
                op_chalk_count=entry["_OP_CHALK_COUNT"],
                op_chalker_commit_id=entry["_OP_CHALKER_COMMIT_ID"],
                op_chalker_version=entry["_OP_CHALKER_VERSION"],
                op_platform=entry["_OP_PLATFORM"],
            )
            crud.add_stat(db, stat=stat)
    except Exception as e:
        logger.exception(f"beacon {e}", exc_info=True)
    finally:
        return {"pong"}


@app.post("/report")
async def add_chalk(request: Request, db: Session = Depends(get_db)):
    try:
        all_unique = True
        raw = await request.body()
        chalks = json.loads(raw)
        for entry in chalks:
            if "_CHALKS" not in entry:
                continue
            for c in entry["_CHALKS"]:
                chalk = schemas.Chalk(
                    id=c["CHALK_ID"],
                    metadata_hash=c["METADATA_HASH"],
                    metadata_id=c["METADATA_ID"],
                    raw=json.dumps(entry),
                )
                try:
                    crud.add_chalk(db, chalk=chalk)
                except (
                    sqlalchemy.exc.IntegrityError,
                    sqlalchemy.exc.PendingRollbackError,
                ):
                    logger.warning("Duplicate chalk id %s", c["CHALK_ID"])
                    all_unique = False
    except Exception:
        logger.exception("report", exc_info=True)
        raise HTTPException(status_code=500, detail="Unhandled data")
    finally:
        if not all_unique:
            raise HTTPException(status_code=409, detail="Duplicate chalk")


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

    args = parser.parse_args()

    if args.version:
        print(SERVER_VER)
        sys.exit(0)

    if args.domain or args.ips:
        assert args.domain, "we need a domain, even if dummy alias"
        os.makedirs(args.cert_output, exist_ok=True)
        key_file = args.cert_output / "self-signed.key"
        cert_file = args.cert_output / "self-signed.cert"
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

        if args.keyfile or args.certfile:
            logger.warning(
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
        uvicorn.run(app, host="0.0.0.0", port=args.port)

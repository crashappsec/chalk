import os
import json
import logging.config

import sqlalchemy
from db import crud, models, schemas
from db.database import SessionLocal, engine
from fastapi import Depends, FastAPI, HTTPException, Request, Response
from fastapi.encoders import jsonable_encoder
from fastapi.openapi.utils import get_openapi
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi_healthcheck import HealthCheckFactory, healthCheckRoute
from pydantic import BaseModel
from sqlalchemy.orm import Session

import selfsigned

__version__  = "0.1"
SELF_SIGNED_DOMAIN = "tests.crashoverride.run"
IP_ADDRESS         = None
TLS_PRIV_KEY       = None
TLS_CERT           = None

##Gather the various component versions
SERVER_VER      = __version__
MODULE_LOCATION = os.path.abspath(os.path.dirname(__file__))
with open(os.path.join(MODULE_LOCATION, "..", "..", "chalk_internal.nimble" ),"r") as f:
    line = f.readline()
    if "version" in line:
        CHALK_VER = line.split("=")[-1].replace('"', '').strip()
with open(os.path.join(MODULE_LOCATION, "..", "..", "config-tool", "chalk-config", "chalkconf.py"),"r") as f:     
    for line in f.readlines():
        if "__version__" in line:
            CONFIG_TOOL_VER = line.split("=")[-1].replace('"', '').strip()
            break


##Paths use to save/load auto-generated self-signed keys and certs 
## also usedin docker-compose.yml
SELF_SIGNED_CERT_PATH        = os.path.join(MODULE_LOCATION, "data", "chalk-selfsigned-certificate.crt")
SELF_SIGNED_PRIVATE_KEY_PATH = os.path.join(MODULE_LOCATION, "data", "chalk-selfsigned-private.key")

models.Base.metadata.create_all(bind=engine)

logging.config.fileConfig("logging.conf", disable_existing_loggers=True)
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
    description="",
    version="0.1",
    ssl_keyfile=TLS_PRIV_KEY,
    ssl_certfile=TLS_CERT
)
# Add Health Checks
_healthChecks = HealthCheckFactory()

app.add_api_route("/health", endpoint=healthCheckRoute(factory=_healthChecks))
app.mount("/about", StaticFiles(directory="site", html=True), name="site")


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def generate_self_signed_tls_certificate(domain=None):
    if not domain:
        domain = SELF_SIGNED_DOMAIN
    print("[+] Generating self-signed certificate for %s"%(domain))
    ##Check if cert/key files already present?
    try:
        os.stat(SELF_SIGNED_CERT_PATH)
        os.stat(SELF_SIGNED_PRIVATE_KEY_PATH)
        ##They exist, read n return them
        with open(SELF_SIGNED_CERT_PATH, "r") as f:
            SELF_SIGNED_CERT_DATA = f.read()
        with open(SELF_SIGNED_PRIVATE_KEY_PATH, "r") as f:
            SELF_SIGNED_PRIVATE_KEY_DATA = f.read()
        print("[+] Self-signed certificate present, reading from disk....")   
        return SELF_SIGNED_CERT_DATA, SELF_SIGNED_PRIVATE_KEY_DATA
    except OSError as err:
        ##Files not present, generate them
        print("[+] Generating self-signed certificate for %s......"%(domain))
        SELF_SIGNED_CERT_DATA, SELF_SIGNED_PRIVATE_KEY_DATA = selfsigned.generate_selfsigned_cert(domain, IP_ADDRESS, TLS_PRIV_KEY )
        with open(SELF_SIGNED_CERT_PATH, "wb") as f:
            print("[+] Writing certficate to %s"%(SELF_SIGNED_CERT_PATH))
            f.write(SELF_SIGNED_CERT_DATA)
        with open(SELF_SIGNED_PRIVATE_KEY_PATH, "wb") as f:
            print("[+] Writing private key to %s"%(SELF_SIGNED_PRIVATE_KEY_PATH))
            f.write(SELF_SIGNED_PRIVATE_KEY_DATA)
        return SELF_SIGNED_CERT_DATA, SELF_SIGNED_PRIVATE_KEY_DATA


@app.get("/", response_class=RedirectResponse)
async def redirect_to_docs():
    return RedirectResponse("/about")


@app.get("/versions")
async def redirect_to_docs():
    versions = {"chalk_version":CHALK_VER,
                "chalk_api_server_version":SERVER_VER,
                "chalk_config_tool_versions":CONFIG_TOOL_VER}
    return versions


@app.post("/beacon")
async def beacon(request: Request, db: Session = Depends(get_db)):
    try:
        raw = await request.body()
        for line in raw.decode().split("\n"):
            if not line:
                continue
            entry = json.loads(line, strict=False)
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
        print(e)
        logger.exception("beacon", exc_info=True)
    finally:
        return {"OK"}


@app.post("/report")
async def add_chalk(request: Request, db: Session = Depends(get_db)):
    try:
        all_unique = True
        raw = await request.body()
        for line in raw.decode().split("\n"):
            if not line:
                continue
            entry = json.loads(line, strict=False)
            if "_CHALKS" not in entry:
                continue
            for c in entry["_CHALKS"]:
                chalk = schemas.Chalk(
                    id=c["CHALK_ID"],
                    metadata_hash=c["METADATA_HASH"],
                    metadata_id=c["METADATA_ID"],
                    raw=line,
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
    ##Used by docker to generate self-signed certs before launching the server
    import sys
    if len(sys.argv) >1 and sys.argv[1] == "generate_certificate":
        if len(sys.argv) >2:
            ##Specify the domain to generate the self-signed cert for
            cert,priv_key = generate_self_signed_tls_certificate(sys.argv[2])
        else:
            ##Generate cert for deault domain of tests.crashoverride.run
            cert,priv_key = generate_self_signed_tls_certificate()
        print(cert)
import json
import logging.config
from pathlib import Path

import sqlalchemy
from conf.version import __version__
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
    Path(__file__).parent / "conf" / "logging.conf",
    disable_existing_loggers=True,
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
    version=__version__,
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
async def version():
    return {"version": __version__}


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
                    raw=json.dumps(
                        {
                            **c,
                            **{k: v for k, v in entry.items() if k != "_CHALKS"},
                        }
                    ),
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


@app.get("/chalks")
async def get_chalks(request: Request, db: Session = Depends(get_db)):
    chalks = crud.get_chalks(db)
    return [c.raw for c in chalks]

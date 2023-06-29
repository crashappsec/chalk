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
async def ping(
    request: Request, stats: list[schemas.Stat], db: Session = Depends(get_db)
):
    try:
        crud.add_stats(db, stats=stats)
    except Exception as e:
        logger.exception(f"beacon {e}", exc_info=True)
    finally:
        return {"ping": "pong"}


@app.post("/report")
async def add_chalks(
    request: Request, reports: list[dict], db: Session = Depends(get_db)
):
    try:
        model_chalks: list[schemas.Chalk] = []
        for report in reports:
            if "_CHALKS" not in report:
                continue
            for c in report["_CHALKS"]:
                model_chalks.append(
                    schemas.Chalk(
                        id=c["CHALK_ID"],
                        metadata_hash=c["METADATA_HASH"],
                        metadata_id=c["METADATA_ID"],
                        raw=json.dumps(
                            {
                                **c,
                                **{k: v for k, v in report.items() if k != "_CHALKS"},
                            }
                        ),
                    )
                )
        try:
            crud.add_chalks(db, chalks=model_chalks)
        except (
            sqlalchemy.exc.IntegrityError,
            sqlalchemy.exc.PendingRollbackError,
        ) as e:
            logger.warning("Duplicate chalks %s", e)
            raise HTTPException(status_code=409, detail="Duplicate chalk")
    except KeyError:
        raise HTTPException(status_code=400)
    except HTTPException:
        raise
    except Exception:
        logger.exception("report", exc_info=True)
        raise HTTPException(status_code=500, detail="Unhandled data")


@app.get("/chalks")
async def get_chalks(request: Request, db: Session = Depends(get_db)):
    chalks = crud.get_chalks(db)
    return [c.raw for c in chalks]


@app.get("/chalks/{metadata_id}")
async def get_chalk(request: Request, metadata_id: str, db: Session = Depends(get_db)):
    chalk = crud.get_chalk(db, metadata_id)
    if chalk is None:
        raise HTTPException(status_code=404)
    return chalk.raw

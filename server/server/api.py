# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import dataclasses
import logging.config
from typing import Any, Optional

import sqlalchemy
from fastapi import Depends, FastAPI, HTTPException, Request, Response, status
from fastapi.responses import RedirectResponse
from sqlalchemy.orm import Session

from .__version__ import __version__
from .db import models, schemas
from .db.database import SessionLocal, engine
from .log import config


config()
logger = logging.getLogger(__name__)

try:
    # sqlite does not have DDL locks therefore when multiple workers
    # start at the same time, some of them can fail creating tables
    models.Base.metadata.create_all(bind=engine)
except Exception as error:
    logger.error(error)


title = "Local Chalk Ingestion Server"


app = FastAPI(
    title=title,
    version=__version__,
)


@dataclasses.dataclass()
class HealthResponse:
    status: str


@app.get("/health")
async def healthcheck() -> HealthResponse:
    return HealthResponse(status="ok")


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


@app.get("/", response_class=RedirectResponse)
async def redirect_to_docs():
    return RedirectResponse("/docs")


@app.get("/version")
async def version():
    return {"version": __version__}


@app.post("/ping")
async def ping(stats: list[schemas.Stat], db: Session = Depends(get_db)):
    try:
        model_stats = [models.Stat(**dict(s)) for s in stats]
        db.add_all(model_stats)
        db.commit()
    except Exception as e:
        logger.exception(f"beacon {e}", exc_info=True)
    finally:
        return {"ping": "pong"}


@app.put("/report/presign", status_code=200)
async def presign_report_url(
    request: Request,
    response: Response,
):
    return RedirectResponse(
        request.url_for("accept_report"),
        status_code=status.HTTP_307_TEMPORARY_REDIRECT,
    )


@app.post("/report", status_code=200)
@app.put("/report", status_code=200)
async def accept_report(
    reports: list[dict],
    response: Response,
    db: Session = Depends(get_db),
):
    try:
        for report in reports:
            operation = report.get("_OPERATION")
            if not isinstance(operation, str):
                logger.error("Skipping report %s", str(report))
                continue
            operation = operation.lower()
            # save any sent reports
            db.add(models.Report(operation=operation, raw=report))
            # if operation creates new chalkmark,
            # save normalized chalkmark into db
            if operation not in {"insert", "build"}:
                continue
            if "_CHALKS" not in report:
                continue
            for c in report["_CHALKS"]:
                if "CHALK_ID" not in c:
                    logger.error("Skipping chalk %s", str(c))
                    continue
                db.add(
                    models.Chalk(
                        chalk_id=c["CHALK_ID"],
                        metadata_hash=c["METADATA_HASH"],
                        metadata_id=c["METADATA_ID"],
                        raw={
                            **c,
                            **{k: v for k, v in report.items() if k != "_CHALKS"},
                        },
                    )
                )
        try:
            db.commit()
        except (
            sqlalchemy.exc.IntegrityError,
            sqlalchemy.exc.PendingRollbackError,
        ) as e:
            logger.warning("Duplicate chalks %s", e)
            response.status_code = status.HTTP_202_ACCEPTED
            return
    except KeyError as e:
        raise HTTPException(status_code=400, detail=f"Chalk missing: {e}")
    except HTTPException:
        raise
    except Exception:
        logger.exception("report", exc_info=True)
        raise HTTPException(status_code=500, detail="Unhandled data")


@app.get("/chalks")
async def list_chalks(db: Session = Depends(get_db)) -> list[dict[str, Any]]:
    chalks = db.query(models.Chalk).all()
    return [c.raw for c in chalks]


@app.get("/chalks/{metadata_id}")
async def get_chalk(metadata_id: str, db: Session = Depends(get_db)) -> dict[str, Any]:
    chalk = db.query(models.Chalk).get(metadata_id)
    if chalk is None:
        raise HTTPException(status_code=404)
    return chalk.raw


@app.get("/reports")
async def list_reports(
    db: Session = Depends(get_db), operation: Optional[str] = None
) -> list[dict[str, Any]]:
    reports = db.query(models.Report)
    if operation:
        reports = reports.filter_by(operation=operation.lower())
    return [c.raw for c in reports.all()]


@app.get("/stats")
async def list_stats(db: Session = Depends(get_db)) -> list[schemas.Stat]:
    chalk_stats = db.query(models.Stat).all()
    return [schemas.Stat.model_validate(vars(c)) for c in chalk_stats]

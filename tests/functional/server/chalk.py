# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import asyncio
import os
import pathlib
import secrets
import shutil
import tempfile
from typing import Any, Optional

import sqlalchemy
from fastapi import Body, Depends, HTTPException, Request, Response, status
from fastapi.responses import PlainTextResponse, RedirectResponse
from sqlalchemy.orm import Session

from ..utils.log import get_logger
from .app import app
from .db import models, schemas
from .db.database import SessionLocal, engine


logger = get_logger()

try:
    # sqlite does not have DDL locks therefore when multiple workers
    # start at the same time, some of them can fail creating tables
    models.Base.metadata.create_all(bind=engine)
except Exception:
    logger.exception("could not create all tables")
    raise


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


if os.environ.get("REDIRECT"):

    @app.post("/redirect")
    async def redirect():
        redirect = os.environ.get("REDIRECT")
        return RedirectResponse(
            f"{redirect}/report",
            status_code=status.HTTP_301_MOVED_PERMANENTLY,
        )


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


@app.post("/500")
async def error_500():
    raise HTTPException(500)


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
async def list_chalks(db: Session = Depends(get_db)):
    chalks = db.query(models.Chalk).all()
    return [c.raw for c in chalks]


@app.get("/chalks/{metadata_id}")
async def get_chalk(metadata_id: str, db: Session = Depends(get_db)) -> dict[str, Any]:
    chalk = db.query(models.Chalk).get(metadata_id)
    if chalk is None:
        raise HTTPException(status_code=404)
    return chalk.raw


@app.get("/reports")
async def list_reports(db: Session = Depends(get_db), operation: Optional[str] = None):
    reports = db.query(models.Report)
    if operation:
        reports = reports.filter_by(operation=operation.lower())
    return [c.raw for c in reports.all()]


@app.get("/stats")
async def list_stats(db: Session = Depends(get_db)) -> list[schemas.Stat]:
    chalk_stats = db.query(models.Stat).all()
    return [schemas.Stat.model_validate(vars(c)) for c in chalk_stats]


cosign: dict[str, str] = {}


@app.get("/cosign")
async def get_cosign():
    global cosign
    if not cosign:
        bin = shutil.which("cosign")
        assert bin
        with tempfile.TemporaryDirectory() as _tmp:
            password = secrets.token_bytes(16).hex()
            tmp = pathlib.Path(_tmp)
            process = await asyncio.subprocess.create_subprocess_exec(
                bin,
                "generate-key-pair",
                "--output-key-prefix",
                "chalk",
                env={"COSIGN_PASSWORD": password},
                cwd=tmp,
            )
            await process.wait()
            cosign = {
                "privateKey": (tmp / "chalk.key").read_text(),
                "publicKey": (tmp / "chalk.pub").read_text(),
                "password": password,
            }
    return cosign


@app.get("/dummy/{platform}", response_class=PlainTextResponse)
async def get_dummy_chalk(platform: str):
    return """
#!/bin/sh
echo $@
exit 0
""".strip()


objects: dict[str, Any] = {}


@app.head("/presign/objects/{key}")
async def object_exists_presign(key: str, request: Request):
    redirect = request.url_for("object_exists", key=key)
    return RedirectResponse(
        f"{redirect}?signature=foobar",
        status_code=status.HTTP_307_TEMPORARY_REDIRECT,
    )


@app.get("/presign/objects/{key}")
async def object_get_presign(key: str, request: Request):
    redirect = request.url_for("object_get", key=key)
    return RedirectResponse(
        f"{redirect}?signature=foobar",
        status_code=status.HTTP_307_TEMPORARY_REDIRECT,
    )


@app.put("/presign/objects/{key}")
async def object_create_presign(key: str, request: Request):
    redirect = request.url_for("object_create", key=key)
    return RedirectResponse(
        f"{redirect}?signature=foobar",
        status_code=status.HTTP_307_TEMPORARY_REDIRECT,
    )


@app.head("/objects/{key}")
async def object_exists(key: str):
    if key not in objects:
        raise HTTPException(status_code=404)


@app.get("/objects/{key}")
async def object_get(key: str):
    if key not in objects:
        raise HTTPException(status_code=404)
    return objects[key]


@app.put("/objects/{key}")
async def object_create(key: str, data: dict = Body(None)):
    if key in objects:
        raise HTTPException(status_code=status.HTTP_412_PRECONDITION_FAILED)
    objects[key] = data

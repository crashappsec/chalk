# Copyright (c) 2023-2025, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import uuid
import time
from typing import Annotated

from fastapi import (
    FastAPI,
    Response,
    Header,
)

app = FastAPI()


@app.get("/health")
def health():
    return


extensions: dict[str, int] = {}


@app.post("/2020-01-01/extension/register")
async def register(response: Response):
    extension_id = str(uuid.uuid4())
    extensions[extension_id] = 0
    response.headers["Lambda-Extension-Identifier"] = extension_id
    return {}


@app.get("/2020-01-01/extension/event/next")
async def next(lambda_extension_identifier: Annotated[str, Header()]):
    time.sleep(1)
    extensions[lambda_extension_identifier] += 1
    print(extensions)
    if extensions[lambda_extension_identifier] < 5:
        return {"eventType": "INVOKE"}
    else:
        return {"eventType": "SHUTDOWN"}


@app.post("/2020-01-01/extension/exit")
async def exit(lambda_extension_identifier: Annotated[str, Header()]):
    extensions.pop(lambda_extension_identifier, None)
    return {}

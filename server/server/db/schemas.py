# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from datetime import datetime

from pydantic import BaseModel, Field, Json


class Exec(BaseModel):
    raw: Json

    class Config:
        orm_mode = True


class Chalk(BaseModel):
    id: str
    metadata_hash: str
    metadata_id: str
    raw: Json

    class Config:
        orm_mode = True


class Stat(BaseModel):
    operation: str = Field(alias="_OPERATION")
    timestamp: int = Field(alias="_TIMESTAMP")
    op_chalk_count: int = Field(alias="_OP_CHALK_COUNT")
    op_chalker_commit_id: str = Field(alias="_OP_CHALKER_COMMIT_ID")
    op_chalker_version: str = Field(alias="_OP_CHALKER_VERSION")
    op_platform: str = Field(alias="_OP_PLATFORM")

    class Config:
        orm_mode = True
        allow_population_by_field_name = True

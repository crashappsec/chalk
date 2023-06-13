from datetime import datetime

from pydantic import BaseModel, Json


class Chalk(BaseModel):
    id: str
    metadata_hash: str
    metadata_id: str
    raw: Json

    class Config:
        orm_mode = True


class Stats(BaseModel):
    id: int | None
    operation: str
    timestamp: int
    op_chalk_count: int
    op_chalker_commit_id: str
    op_chalker_version: str
    op_platform: str

    class Config:
        orm_mode = True

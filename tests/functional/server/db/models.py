# Copyright (c) 2023, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
from sqlalchemy import JSON, Column, Integer, String

from .database import Base


class Chalk(Base):
    __tablename__ = "chalks"

    metadata_id = Column(String, primary_key=True, index=True)
    metadata_hash = Column(String)
    chalk_id = Column(String)
    raw = Column(JSON)


class Report(Base):
    __tablename__ = "reports"

    id = Column(Integer, primary_key=True, autoincrement=True)
    operation = Column(String)  # exec, heartbeat
    raw = Column(JSON)


class Stat(Base):
    __tablename__ = "stats"

    id = Column(Integer, primary_key=True, autoincrement=True)
    operation = Column(String)
    timestamp = Column(Integer)
    op_chalk_count = Column(Integer)
    op_chalker_commit_id = Column(String)
    op_chalker_version = Column(String)
    op_platform = Column(String)

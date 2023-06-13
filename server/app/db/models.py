from sqlalchemy import JSON, Column, Integer, String

from .database import Base


class Chalk(Base):
    __tablename__ = "chalks"

    id = Column(String, primary_key=True, index=True)
    metadata_hash = Column(String)
    metadata_id = Column(String)
    raw = Column(JSON)
    # TODO fill out rest


class Stats(Base):
    __tablename__ = "stats"

    id = Column(Integer, primary_key=True, autoincrement=True)
    operation = Column(String)
    timestamp = Column(Integer)
    op_chalk_count = Column(Integer)
    op_chalker_commit_id = Column(String)
    op_chalker_version = Column(String)
    op_platform = Column(String)

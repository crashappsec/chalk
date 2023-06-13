from sqlalchemy.orm import Session

from . import models, schemas


def add_chalk(db: Session, chalk: schemas.Chalk) -> models.Chalk:
    db_chalk = models.Chalk(
        id=chalk.id,
        metadata_hash=chalk.metadata_hash,
        metadata_id=chalk.metadata_id,
        raw=chalk.raw,
    )
    db.add(db_chalk)
    db.commit()
    db.refresh(db_chalk)
    return db_chalk


def add_stat(db: Session, stat: schemas.Stats) -> models.Chalk:
    db_stat = models.Stats(
        operation=stat.operation,
        timestamp=stat.timestamp,
        op_chalk_count=stat.op_chalk_count,
        op_chalker_commit_id=stat.op_chalker_commit_id,
        op_chalker_version=stat.op_chalker_version,
        op_platform=stat.op_platform,
    )
    db.add(db_stat)
    db.commit()
    db.refresh(db_stat)
    return db_stat

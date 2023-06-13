# { "MAGIC" : "dadfedabbadabbed", "CHALK_ID" : "6MT3JR-V26M-V32C-9S6RWK", "CHALK_VERSION" : "0.5.0", "DATETIME" : "2023-06-12T11:42:50.748+03:00", "INSERTION_HOSTINFO" : "Darwin Kernel Version 22.5.0: Mon Apr 24 20:52:24 PDT 2023; root:xnu-8796.121.2~5/RELEASE_ARM64_T6000", "INSERTION_NODENAME" : "mac.home", "ARTIFACT_PATH" : "/Users/nettrino/projects/crashappsec/chalk-internal/server/app/db/database.py", "ARTIFACT_TYPE" : "Python", "HASH" : "549cb561196942c4b83776ed7b1331102b1c0e7bf6290ca778ff6bbfd35889ab", "ORIGIN_URI" : "git@github.com:crashappsec/chalk-internal.git", "BRANCH" : "nettrino/fastapi", "COMMIT_ID" : "53527c8e9d13716a619b5e7ce0e3dd22c3003b79", "CODE_OWNERS" : "@viega", "INJECTOR_VERSION" : "0.4.3", "INJECTOR_PLATFORM" : "Darwin arm64", "INJECTOR_COMMIT_ID" : "53527c8e9d13716a619b5e7ce0e3dd22c3003b79", "CHALK_RAND" : "f07a1750d4e075e8", "METADATA_HASH" : "05c84ee00a8c0ce23948da0cd40fa0c809408b8c42e4287a56435604e162a7b5", "METADATA_ID" : "0Q44XR-0AHG-6E4E-A8V86D" }
from sqlalchemy import create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker

SQLALCHEMY_DATABASE_URL = "sqlite:///./data/sql_app.db"

engine = create_engine(
    SQLALCHEMY_DATABASE_URL, connect_args={"check_same_thread": False}
)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

Base = declarative_base()

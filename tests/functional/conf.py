# Copyright (c) 2023-2024, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
import os
import shutil
from pathlib import Path


DOCKER_SSH_REPO = (
    os.environ.get("DOCKER_GIT_CONTEXT_SSH_REPO")
    or "crashappsec/chalk-docker-git-context"
)
DOCKER_TOKEN_REPO = (
    os.environ.get("DOCKER_GIT_CONTEXT_TOKEN_REPO")
    or "crashappsec/chalk-docker-git-context-private"
)

TESTS = Path(__file__).parent
REPO = TESTS.parent.parent
DATA = TESTS / "data"
GDB = TESTS / "gdb"

CODEOWNERS = DATA / "codeowners"
CONFIGS = DATA / "configs"
DOCKERFILES = DATA / "dockerfiles"
MARKS = DATA / "marks"
PYS = DATA / "python"
SINK_CONFIGS = DATA / "sink_configs"
ZIPS = DATA / "zip"

# base profiles and outconf
BASE_REPORT_TEMPLATES = (
    TESTS.parent.parent / "src" / "configs" / "base_report_templates.c4m"
)
BASE_MARK_TEMPLATES = (
    TESTS.parent.parent / "src" / "configs" / "base_chalk_templates.c4m"
)
BASE_OUTCONF = TESTS.parent.parent / "src" / "configs" / "base_outconf.c4m"

# pushing to a registry is orchestrated over the docker socket
# which means that the push comes from the host
# therefore this is sufficient for the docker push command
# as well as the buildx
IP = os.environ.get("IP") or "localhost"
REGISTRY = f"{IP}:5044"
REGISTRY_TLS = f"{IP}:5045"
REGISTRY_TLS_INSECURE = f"{IP}:5046"
REGISTRY_PROXY = f"{IP}:5047"

SERVER_CHALKDUST = "https://chalkdust.io"
SERVER_IMDS = "http://169.254.169.254"
SERVER_STATIC = "http://static:8000"
SERVER_HTTP = "http://chalk.local:8585"
SERVER_HTTPS = "https://tls.chalk.local:5858"
SERVER_DB = (Path(__file__).parent / "server" / "chalkdb.sqlite").resolve()
SERVER_CERT = (Path(__file__).parent / "server" / "cert.pem").resolve()

IN_GITHUB_ACTIONS = os.getenv("GITHUB_ACTIONS") or False

MAGIC = "dadfedabbadabbed"
SHEBANG = "#!"

CAT_PATH = shutil.which("cat")
DATE_PATH = shutil.which("date")
LS_PATH = shutil.which("ls")
UNAME_PATH = shutil.which("uname")
SLEEP_PATH = shutil.which("sleep")
GDB_PATH = shutil.which("gdb")

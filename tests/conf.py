# Copyright (c) 2023, Crash Override, Inc.
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

ROOT = Path(__file__).parent
DATA = ROOT / "data"
GDB = ROOT / "gdb"

CODEOWNERS = DATA / "codeowners"
CONFIGS = DATA / "configs"
DOCKERFILES = DATA / "dockerfiles"
MARKS = DATA / "marks"
PYS = DATA / "python"
SINK_CONFIGS = DATA / "sink_configs"
ZIPS = DATA / "zip"

# base profiles and outconf
BASE_REPORT_TEMPLATES = ROOT.parent / "src" / "configs" / "base_report_templates.c4m"
BASE_MARK_TEMPLATES = ROOT.parent / "src" / "configs" / "base_chalk_templates.c4m"
BASE_OUTCONF = ROOT.parent / "src" / "configs" / "base_outconf.c4m"

# pushing to a registry is orchestrated over the docker socket
# which means that the push comes from the host
# therefore this is sufficient for the docker push command
# FIXME: once we have buildx support we'll need to enable
# insecure registry https://docs.docker.com/registry/insecure/
REGISTRY = f"{os.environ.get('IP') or 'localhost'}:5044"

SERVER_CHALKDUST = "https://chalkdust.io"
SERVER_IMDS = "http://169.254.169.254"
SERVER_STATIC = "http://static:8000"
SERVER_HTTP = "http://chalk.local:8585"
SERVER_HTTPS = "https://tls.chalk.local:5858"
SERVER_DB = (Path(__file__).parent.parent / "server" / "chalkdb.sqlite").resolve()
SERVER_CERT = (Path(__file__).parent.parent / "server" / "cert.pem").resolve()

IN_GITHUB_ACTIONS = os.getenv("GITHUB_ACTIONS") or False

MAGIC = "dadfedabbadabbed"
SHEBANG = "#!"

CAT_PATH = shutil.which("cat")
DATE_PATH = shutil.which("date")
LS_PATH = shutil.which("ls")
UNAME_PATH = shutil.which("uname")
SLEEP_PATH = shutil.which("sleep")
GDB_PATH = shutil.which("gdb")

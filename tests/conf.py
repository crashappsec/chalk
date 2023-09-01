import shutil
from pathlib import Path

import os


ROOT = Path(__file__).parent
DATA = ROOT / "data"

CODEOWNERS = DATA / "codeowners"
CONFIGS = DATA / "configs"
DOCKERFILES = DATA / "dockerfiles"
PYS = DATA / "python"
SINK_CONFIGS = DATA / "sink_configs"
ZIPS = DATA / "zip"

# base profiles and outconf
BASE_PROFILES = ROOT.parent / "src" / "configs" / "base_profiles.c4m"
BASE_OUTCONF = ROOT.parent / "src" / "configs" / "base_outconf.c4m"

# pushing to a registry is orchestrated over the docker socket
# which means that the push comes from the host
# therefore this is sufficient for the docker push command
# FIXME: once we have buildx support we'll need to enable
# insecure registry https://docs.docker.com/registry/insecure/
REGISTRY = "localhost:5044"

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

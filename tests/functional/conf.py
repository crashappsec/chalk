# Copyright (c) 2023-2026, Crash Override, Inc.
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
REGISTRY_AUTH = f"{IP}:5048"

SERVER_CHALKDUST = "https://chalkdust.io"
SERVER_IMDS = "http://169.254.169.254"
SERVER_DNS = "http://dns.chalk.local:8054"
DNS_SINK_SERVER = "dns.chalk.local:5354"
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
HELLO_GO_PATH = shutil.which("hello_go")
GDB_PATH = shutil.which("gdb")


K8S_TOKEN = "test-k8s-token"
K8S_NAMESPACE = "default"
K8S_POD_NAME = "test-pod"
K8S_CONTAINER_NAME = "app"
K8S_CLUSTER = {
    "uid": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "name": "test-cluster",
    "endpoint": "https://test-cluster.example.com",
}
K8S_CLOUD = {
    "provider": "aws",
    "region": "us-east-1",
    "vpc_id": "vpc-0123456789abcdef0",
}

AWS_ACCESS_KEY_ID = os.environ.get("AWS_ACCESS_KEY_ID", "")
AWS_SECRET_ACCESS_KEY = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
AWS_SESSION_TOKEN = os.environ.get("AWS_SESSION_TOKEN", "")
AWS_ACCOUNT_ID = os.environ.get("AWS_ACCOUNT_ID", "")


AWS_ECR_REPO = os.environ.get(
    "AWS_ECR_REPO",
    AWS_ACCOUNT_ID and f"{AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com",
)
DOCKER_HUB_REPO = os.environ.get("DOCKER_HUB_REPO", "crashappsec/chalk_tests")
GHCR_REPO = os.environ.get("GHCR_REPO", "crashappsec/chalk-ci-tests")


def aws_secrets_configured() -> bool:
    return all(
        [
            bool(AWS_ACCESS_KEY_ID),
            bool(AWS_SECRET_ACCESS_KEY),
        ]
    )

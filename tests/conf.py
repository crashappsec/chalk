from pathlib import Path

import os


CONFIG_DIR = (Path(__file__).parent / "data" / "sink_configs").resolve()

SERVER_HTTP = "http://chalk.local:8585"
SERVER_HTTPS = "https://tls.chalk.local:5858"
SERVER_DB = (Path(__file__).parent.parent / "server" / "chalkdb.sqlite").resolve()
SERVER_CERT = (Path(__file__).parent.parent / "server" / "cert.pem").resolve()

IN_GITHUB_ACTIONS = os.getenv("GITHUB_ACTIONS") or False

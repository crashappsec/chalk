# Copyright (c) 2026, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
"""
Gatekeeper chalk ingest JWTs against a chalk binary.

Gatekeeper issues chalk ingest keys as ES256 JWTs: header exactly `alg`,
`kid`, `typ`; claims `iss`, `aud`, `sub`, `jti`, `org_id`, `scope`, `iat`,
and `exp` only for dated keys. chalk does not verify them; nimutils'
`parseJwtToken` base64-decodes the header and payload and reads `exp`. Its
`base64Pad` appends `len mod 4` "=" (3 instead of 1 for a segment of length
3 mod 4), so every header/payload length class (0, 2, 3 mod 4) is checked.

Each case checks the token three ways:
- `is_jwt_valid()`, the validator of the CO components' token parameter
  (interactive `chalk load`);
- `chalk load --params` of `crashoverride2` with the token, as
  setup-chalk-action does (this path does not run parameter validators);
- `chalk extract`: the runtime `jwt` auth parses the token again, and the
  report upload's `Authorization` header is captured on a local listener.

Tokens are signed with a throwaway P-256 key; nothing leaves the host.

Standalone (stdlib + cryptography only), one JSON line per case, exit 1 on
any unexpected result:

    python -I tests/functional/utils/ingest_jwt.py --chalk ./chalk \\
        --configs configs/co
"""

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import asdict, dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from itertools import product
from pathlib import Path
from typing import Optional

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

# test environment values from the Gatekeeper contract
ISSUER = "https://gatekeeper.test.crashoverride.run/"
AUDIENCE = "chalk:test"
KID = "chalk-ingest-test-kms-1"
TYP = "gk-chalk-ingest+jwt"
SCOPE = "chalk:ingest"
KEY_ID = "cak_" + "0123456789abcdef01234567"
ORG_ID = "org_01JZ0000000000000000000000"

OPERATIONS = ["insert", "extract", "build", "push", "exec", "env"]


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def segment(value: dict) -> str:
    return b64url(json.dumps(value, separators=(",", ":")).encode())


def header(kid: str = KID) -> dict:
    return {"alg": "ES256", "kid": kid, "typ": TYP}


def claims(exp: Optional[int], org_id: str = ORG_ID, iat: Optional[int] = None) -> dict:
    iat = int(time.time()) if iat is None else iat
    value = {
        "iss": ISSUER,
        "aud": AUDIENCE,
        "sub": KEY_ID,
        "jti": KEY_ID,
        "org_id": org_id,
        "scope": SCOPE,
        "iat": iat,
    }
    if exp is not None:
        value["exp"] = exp
    return value


def sign(key: ec.EllipticCurvePrivateKey, head: dict, payload: dict) -> str:
    signing_input = f"{segment(head)}.{segment(payload)}"
    # JWS ES256 is the raw 64-byte R || S, not DER (RFC 7518 section 3.4)
    r, s = decode_dss_signature(
        key.sign(signing_input.encode(), ec.ECDSA(hashes.SHA256()))
    )
    return f"{signing_input}.{b64url(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


@dataclass
class Case:
    name: str
    token: str
    dated: bool
    expect_accepted: bool
    header_len: int
    payload_len: int
    signature_len: int


def make_case(
    key: ec.EllipticCurvePrivateKey,
    header_mod: int,
    payload_mod: int,
    exp: Optional[int],
    name: str,
    expect_accepted: bool = True,
) -> Case:
    """
    Real claim values, with the kid and org_id lengthened by up to two
    characters so the header and payload segments hit the requested length
    class mod 4 (base64url of n bytes has length 0, 2 or 3 mod 4).
    """
    iat = int(time.time())
    head = next(
        h
        for h in (header(KID + "0" * i) for i in range(3))
        if len(segment(h)) % 4 == header_mod
    )
    payload = next(
        p
        for p in (claims(exp, ORG_ID + "0" * i, iat) for i in range(3))
        if len(segment(p)) % 4 == payload_mod
    )
    token = sign(key, head, payload)
    parts = token.split(".")
    return Case(
        name=name,
        token=token,
        dated=exp is not None,
        expect_accepted=expect_accepted,
        header_len=len(parts[0]),
        payload_len=len(parts[1]),
        signature_len=len(parts[2]),
    )


def cases(key: Optional[ec.EllipticCurvePrivateKey] = None) -> list[Case]:
    """
    Every header x payload length class, dated (`exp` in a day) and
    undated. Expired controls show the payload really is decoded: chalk must
    refuse them in `is_jwt_valid` and at runtime with its expiry error.
    """
    key = key or ec.generate_private_key(ec.SECP256R1())
    now = int(time.time())
    result = []
    for dated, header_mod, payload_mod in product([True, False], [0, 2, 3], [0, 2, 3]):
        result.append(
            make_case(
                key,
                header_mod,
                payload_mod,
                now + 86400 if dated else None,
                f"{'dated' if dated else 'undated'}-h{header_mod}-p{payload_mod}",
            )
        )
    for payload_mod in [0, 2, 3]:
        result.append(
            make_case(
                key,
                0,
                payload_mod,
                now - 3600,
                f"expired-h0-p{payload_mod}",
                expect_accepted=False,
            )
        )
    return result


class Capture(ThreadingHTTPServer):
    """
    Presign endpoint: records the sign request's Authorization header and
    redirects the upload back here, like chalkapi does to S3.
    """

    daemon_threads = True

    def __init__(self):
        self.requests: list[tuple[str, str, Optional[str], int]] = []
        super().__init__(("127.0.0.1", 0), self.Handler)

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server_address[1]}"

    def bearers(self, path: str) -> list[Optional[str]]:
        return [auth for method, p, auth, _ in self.requests if p == path]

    def uploads(self, path: str) -> list[int]:
        return [size for method, p, _, size in self.requests if p == path]

    class Handler(BaseHTTPRequestHandler):
        def do_PUT(self):  # noqa: N802
            size = int(self.headers.get("content-length") or 0)
            self.rfile.read(size)
            self.server.requests.append(
                ("PUT", self.path, self.headers.get("authorization"), size)
            )
            if self.path.startswith("/report/"):
                self.send_response(307)
                self.send_header(
                    "location", self.server.url + "/upload/" + self.path[8:]
                )
            else:
                self.send_response(200)
            self.send_header("content-length", "0")
            self.end_headers()

        def log_message(self, *args):
            pass


@dataclass
class Result:
    case: str
    dated: bool
    header_len: int
    header_mod: int
    payload_len: int
    payload_mod: int
    signature_len: int
    jwt_valid: bool
    loaded: bool
    bearer_sent: bool
    uploaded: bool
    runtime_error: str
    expected: bool
    output: str = ""

    @property
    def ok(self) -> bool:
        if self.expected:
            return (
                self.jwt_valid
                and self.loaded
                and self.bearer_sent
                and self.uploaded
                and not self.runtime_error
            )
        # proves `exp` was decoded, not that the token failed to parse
        return (
            not self.jwt_valid
            and not self.bearer_sent
            and self.runtime_error.startswith("JWT token has expired since")
        )


def params(configs: Path, token: str, url: str) -> list[list]:
    # [is_attribute, component url, name, type, value] as setup-chalk-action
    # passes them; released chalk crashes on omitted parameters
    component = str(configs / "crashoverride2")
    return [
        [True, component, "auth_config.crashoverride_reporting.token", "string", token],
        *[
            [True, component, f"sink_config.crashoverride_{op}.uri", "string"]
            + [f"{url}/report/{op}"]
            for op in OPERATIONS
        ],
    ]


def misconfigured(output: str) -> str:
    marker = "auth_config.crashoverride_reporting is misconfigured: "
    for line in output.splitlines():
        if marker in line:
            return line.split(marker, 1)[1].split('"', 1)[0]
    return ""


VALIDATOR = """
if is_jwt_valid(env("CO_TOKEN")) {
  error("is_jwt_valid: true")
} else {
  error("is_jwt_valid: false")
}
"""


def run_case(chalk: Path, configs: Path, case: Case, timeout: int = 120) -> Result:
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        binary = work / "chalk"
        shutil.copy(chalk, binary)
        binary.chmod(0o755)
        validator = work / "validator.c4m"
        validator.write_text(VALIDATOR)
        profile = work / "profile.c4m"
        profile.write_text(f'use crashoverride2 from "{configs.absolute()}"\n')
        target = work / "target"
        target.mkdir()
        (target / "hello.sh").write_text("#!/bin/sh\necho hello\n")
        env = {**os.environ, "HOME": str(work)}

        def chalk_run(*args: str, stdin: str = "") -> str:
            proc = subprocess.run(
                [str(binary), *args],
                input=stdin,
                capture_output=True,
                text=True,
                env={**env, "CO_TOKEN": case.token},
                cwd=work,
                timeout=timeout,
            )
            return f"exit {proc.returncode}\n{proc.stdout}{proc.stderr}"

        jwt_valid = "is_jwt_valid: true" in chalk_run(
            "version", f"--config-file={validator}"
        )
        with Capture() as capture:
            thread = threading.Thread(target=capture.serve_forever, daemon=True)
            thread.start()
            try:
                load = chalk_run(
                    "load",
                    "--replace",
                    str(profile),
                    "--params",
                    stdin=json.dumps(params(configs, case.token, capture.url)),
                )
                loaded = load.startswith("exit 0\n") and "Invalid JWT" not in load
                extract = chalk_run("extract", str(target)) if loaded else ""
            finally:
                capture.shutdown()

        bearers = capture.bearers("/report/extract")
        result = Result(
            case=case.name,
            dated=case.dated,
            header_len=case.header_len,
            header_mod=case.header_len % 4,
            payload_len=case.payload_len,
            payload_mod=case.payload_len % 4,
            signature_len=case.signature_len,
            jwt_valid=jwt_valid,
            loaded=loaded,
            bearer_sent=bool(bearers)
            and all(b == f"Bearer {case.token}" for b in bearers),
            uploaded=any(capture.uploads("/upload/extract")),
            runtime_error=misconfigured(extract),
            expected=case.expect_accepted,
        )
        if not result.ok:
            result.output = load + extract
        return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument("--chalk", type=Path, required=True)
    parser.add_argument("--configs", type=Path, required=True)
    args = parser.parse_args()
    failed = 0
    for case in cases():
        result = run_case(args.chalk, args.configs, case)
        failed += not result.ok
        sys.stdout.write(json.dumps({**asdict(result), "ok": result.ok}) + "\n")
    return int(failed > 0)


if __name__ == "__main__":
    sys.exit(main())

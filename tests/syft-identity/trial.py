#!/usr/bin/env python3
"""Build with Chalk and verify the SBOM referenced in its report."""

import argparse
from contextlib import contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit
from urllib.request import urlopen
import uuid

FIXTURE = Path(__file__).resolve().parent
PURL = "pkg:npm/resolve@1.22.8"


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


@contextmanager
def object_store():
    objects = {}

    class Handler(BaseHTTPRequestHandler):
        def do_HEAD(self):
            self.handle_object()

        def do_GET(self):
            self.handle_object()

        def do_PUT(self):
            self.handle_object()

        def handle_object(self):
            path = urlsplit(self.path).path
            if path.startswith("/presign/objects/"):
                self.send_response(307)
                self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}{path[8:]}")
                self.end_headers()
                return
            if self.command == "PUT":
                objects[path] = self.rfile.read(int(self.headers["Content-Length"]))
            data = objects.get(path)
            self.send_response(200 if data is not None else 404)
            self.end_headers()
            if self.command == "GET" and data is not None:
                self.wfile.write(data)

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}/presign/objects"
        finally:
            server.shutdown()
            thread.join()


def pointers(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in ("@_IMAGE_SBOM", "@SBOM") and isinstance(child, str):
                yield child
            else:
                yield from pointers(child)
    if isinstance(value, list):
        for child in value:
            yield from pointers(child)


def read_report_pointers(stdout):
    decoder = json.JSONDecoder()
    result = set()
    for match in re.finditer(r"(?m)^\s*(?=[\[{])", stdout):
        try:
            value, _ = decoder.raw_decode(stdout[match.end():])
        except json.JSONDecodeError:
            continue
        result.update(pointers(value))
    return sorted(result)


def component_refs(sbom):
    if sbom.get("bomFormat") != "CycloneDX":
        raise ValueError("The stored object is not a CycloneDX SBOM")
    packages = [component for component in sbom["components"] if component["name"] == "resolve"]
    refs = {component["bom-ref"] for component in packages}
    if len(packages) != 2 or len(refs) != 2 or {component.get("purl") for component in packages} != {PURL}:
        raise ValueError("Expected two resolve components with a shared package URL and distinct references")
    if any(not parse_qs(urlsplit(ref).query).get("package-id") for ref in refs):
        raise ValueError("CycloneDX reference is missing the Syft package ID")
    return sorted(refs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("chalk", type=Path)
    parser.add_argument("syft", type=Path)
    parser.add_argument("digest")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    if not re.fullmatch(r"[0-9a-f]{64}", args.digest) or not args.syft.is_file() or sha256(args.syft) != args.digest:
        parser.error("The supplied Syft binary must match the expected SHA-256")
    args.output.mkdir(parents=True)
    with tempfile.TemporaryDirectory() as temp, object_store() as store:
        temp = Path(temp)
        tools = temp / "bin"
        tools.mkdir()
        syft = tools / "syft"
        shutil.copyfile(args.syft, syft)
        syft.chmod(0o555)
        if sha256(syft) != args.digest:
            raise ValueError("The installed Syft binary failed the digest check")
        env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}", "SYFT_CHECK_FOR_APP_UPDATE": "false"}
        if shutil.which("syft", path=env["PATH"]) != str(syft):
            raise ValueError("The installed Syft binary does not precede other copies on PATH")
        version = json.loads(subprocess.check_output([syft, "version", "-o", "json"], env=env))
        if version["platform"] != "linux/amd64":
            raise ValueError("Expected a Linux AMD64 Syft binary")

        context = temp / "build"
        context.mkdir()
        for name in ("Dockerfile", "yarn.lock"):
            shutil.copyfile(FIXTURE / name, context / name)
        direct_sbom = json.loads(subprocess.check_output(
            [syft, "scan", str(context), "-o", "cyclonedx-json"], env=env,
        ))
        expected_refs = component_refs(direct_sbom)
        config = temp / "trial.c4m"
        config.write_text(f"""
log_level = "trace"
run_sbom_tools = true
tool.syft.syft_exe_dir = "{tools}"
tool.syft.syft_prefer_docker = false
tool.syft.syft_entrypoint = ""
tool.syft.syft_installer = ""
object_store_config trial {{
  enabled = true
  object_store = "presign"
  object_store_presign {{
    uri = "{store}"
  }}
}}
report_template.insertion_default.key.SBOM.use = true
report_template.insertion_default.key.SBOM.object_store = "trial"
report_template.insertion_default.key._IMAGE_SBOM.use = true
report_template.insertion_default.key._IMAGE_SBOM.object_store = "trial"
subscribe("report", "json_console_out")
""")
        image = f"chalk-syft-identity:{uuid.uuid4().hex}"
        try:
            result = subprocess.run([
                args.chalk.resolve(), "--no-color", f"--config-file={config}", "docker", "build",
                "--platform", "linux/amd64", "--tag", image, ".",
            ], cwd=context, env=env, text=True, capture_output=True)
            (args.output / "stdout.log").write_text(result.stdout)
            (args.output / "stderr.log").write_text(result.stderr)
            result.check_returncode()
            if f"find_syft: found syft in $PATH: {syft}" not in result.stderr:
                raise ValueError("Chalk did not report the pinned Syft executable")
            refs = {}
            for pointer in read_report_pointers(result.stdout):
                prefix = f"presign+{store}/"
                if not pointer.startswith(prefix):
                    raise ValueError("Chalk returned a pointer outside the trial store")
                with urlopen(pointer.removeprefix("presign+"), timeout=10) as response:
                    sbom = json.load(response)
                sbom = sbom.get("syft", sbom)
                if any(component.get("name") == "resolve" for component in sbom.get("components", [])):
                    refs[pointer] = component_refs(sbom)
                    if refs[pointer] != expected_refs:
                        raise ValueError("Stored CycloneDX references differ from the direct scan")
                    (args.output / "stored-sbom.json").write_text(json.dumps(sbom, indent=2) + "\n")
            if not refs:
                raise ValueError("No report pointer resolved to the fixture SBOM")
            (args.output / "result.json").write_text(json.dumps({
                "sha256": args.digest,
                "syft": version,
                "stored_bom_refs": refs,
            }, indent=2) + "\n")
        finally:
            subprocess.run(["docker", "image", "rm", image], capture_output=True)


if __name__ == "__main__":
    main()

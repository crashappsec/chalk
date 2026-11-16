#!/usr/bin/env python3
"""Run lifecycle reporting against a real Chalk binary and local DNS/HTTP sinks.

Linux: python3 tests/integration/test_redbox_reporting.py ./chalk
No production endpoints or credentials are used.
"""

import http.server
import json
import os
from pathlib import Path
import shutil
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else ROOT / "chalk"
CAPTURES = []


class LifecycleReporting(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="chalk-dns-test-")
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.chalk = self.path / "chalk"
        shutil.copy2(BINARY, self.chalk)
        self.events = []
        self.on_query = None
        events = self.events
        test = self

        class DNS(socketserver.BaseRequestHandler):
            def handle(self):
                packet, sock = self.request
                labels, offset = [], 12
                while packet[offset]:
                    size = packet[offset]
                    offset += 1
                    labels.append(packet[offset : offset + size].decode("ascii"))
                    offset += size
                name = ".".join(labels)
                events.append(("dns", name))
                CAPTURES.append(name)
                if test.on_query:
                    test.on_query(name)
                response = (
                    packet[:2]
                    + b"\x81\x80"
                    + struct.pack("!HHHH", 1, 0, 0, 0)
                    + packet[12:]
                )
                sock.sendto(response, self.client_address)

        class HTTP(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                events.append(("http", self.path))
                self.rfile.read(int(self.headers.get("Content-Length", "0")))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"{}")

            def log_message(self, *args):
                pass

        self.dns = socketserver.UDPServer(("127.0.0.1", 0), DNS)
        self.http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), HTTP)
        for server in (self.dns, self.http):
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(server.server_close)
            self.addCleanup(server.shutdown)

    def run_chalk(self, *args, **kwargs):
        return subprocess.run(
            [str(self.chalk), *args],
            cwd=self.path,
            text=True,
            capture_output=True,
            timeout=60,
            **kwargs,
        )

    def configure(
        self, extra="", *, enabled=True, command_report=False, build_template=None
    ):
        uri = str(ROOT / "configs/co/redbox")
        config = self.path / "profile.c4m"
        config.write_text(f"""keyspec _X_WORKSPACE_ID {{
  kind: RunTimeHost
  type: string
  value: "00000000-0000-4000-8000-000000000001"
}}
use redbox from "{ROOT / 'configs/co'}"
use_report_cache = false
skip_command_report = {str(not command_report).lower()}
publish_audit = false
run_sbom_tools = false
exec.initial_sleep_time = <<1 msecs>>
exec.heartbeat.rate = <<50 msecs>>
exec.postexec.run = false
sink_config.redbox_build.dns_server = "127.0.0.1:{self.dns.server_address[1]}"
sink_config.redbox_exec.dns_server = "127.0.0.1:{self.dns.server_address[1]}"
sink_config.redbox_heartbeat.dns_server = "127.0.0.1:{self.dns.server_address[1]}"
{extra}
""")
        params = [
            [False, uri, "redbox_domain", "string", "example.test"],
            [False, uri, "redbox_enabled", "bool", enabled],
        ]
        if build_template is not None:
            params.append(
                [
                    True,
                    uri,
                    "sink_config.redbox_build.domain_template",
                    "string",
                    build_template,
                ]
            )
        result = self.run_chalk(
            "load",
            "--no-use-external-config",
            "--no-use-embedded-config",
            "--params",
            str(config),
            input=json.dumps(params),
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.events.clear()

    def queries(self):
        return [value for kind, value in self.events if kind == "dns"]

    def probe_config(self, *, fallback=True, operation="env"):
        return f"""custom_report lifecycle_probe {{
  report_template: "redbox_build"
  sink_configs: ["redbox_build"]
  use_when: ["{operation}"]
  per_chalk: true
  report_if_empty: {str(fallback).lower()}
  before_command: true
}}
"""

    def test_empty_collection_emits_once(self):
        self.configure(self.probe_config())
        result = self.run_chalk("env")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.queries()), 1, result.stderr)
        labels = self.queries()[0].split(".")
        self.assertEqual(labels[1], "cb2")
        self.assertEqual(labels[7], "0")
        self.assertEqual(labels[8], "na")
        self.assertTrue(self.queries()[0].endswith(".chalk.example.test"))

    def test_empty_collection_remains_optional(self):
        self.configure(self.probe_config(fallback=False))
        result = self.run_chalk("env")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.queries(), [])

    def test_skip_custom_reports_disables_dns(self):
        self.configure(self.probe_config() + "\nskip_custom_reports = true")
        result = self.run_chalk("env")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.queries(), [])

    def test_component_disablement_preserves_exec(self):
        self.configure("exec.chalk_as_parent = true", enabled=False)
        result = self.run_chalk("exec", "--exec-command-name=/bin/sleep", "0.01")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.queries(), [])

    def test_invalid_dns_does_not_fail_operation(self):
        self.configure(
            self.probe_config(),
            build_template="{_TIMESTAMP}..invalid",
        )
        result = self.run_chalk("env")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.queries(), [])

    def test_early_docker_failure_still_reports_build(self):
        self.configure()
        # This test image deliberately has no Docker executable.
        result = self.run_chalk("docker", "build", ".")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.queries()), 1, result.stderr)
        self.assertTrue(self.queries()[0].startswith("cb.cb2."))
        self.assertEqual(self.queries()[0].split(".")[8], "na")

    def test_dns_precedes_command_http_report(self):
        self.configure(
            self.probe_config() + f"""
sink_config normal_http {{
  sink: "post"
  uri: "http://127.0.0.1:{self.http.server_address[1]}/report"
}}
subscribe("report", "normal_http")
""",
            command_report=True,
        )
        result = self.run_chalk("env")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            [kind for kind, _ in self.events], ["dns", "http"], result.stderr
        )

    def test_unmarked_exec_and_heartbeat_share_execution(self):
        self.check_exec_and_heartbeats(marked=False)

    def test_background_exec_and_heartbeat_share_execution(self):
        self.check_exec_and_heartbeats(marked=False, parent=False)

    def test_marked_exec_and_heartbeat_share_artifact(self):
        self.check_exec_and_heartbeats(marked=True)

    def check_exec_and_heartbeats(self, *, marked, parent=True):
        self.configure(
            f"exec.chalk_as_parent = {str(parent).lower()}\nexec.heartbeat.run = true"
        )
        stop = self.path / "stop"
        script = self.path / "wait.py"
        script.write_text(
            "from pathlib import Path\nimport time\n"
            f"while not Path({str(stop)!r}).exists(): time.sleep(0.01)\n"
        )
        executable = Path("/usr/bin/python3")
        if marked:
            executable = self.path / "python3"
            shutil.copy2("/usr/bin/python3", executable)
            inserted = self.run_chalk("insert", str(executable))
            self.assertEqual(inserted.returncode, 0, inserted.stderr)

        def received(query):
            if sum(q.startswith("ch.") for q in self.queries()) >= 3:
                stop.touch()

        self.on_query = received
        try:
            result = self.run_chalk(
                "exec", f"--exec-command-name={executable}", str(script)
            )
        finally:
            stop.touch()
        self.assertEqual(result.returncode, 0, result.stderr)
        startup = [q for q in self.queries() if q.startswith("ce.")]
        beats = [q for q in self.queries() if q.startswith("ch.")]
        self.assertEqual(len(startup), 1, result.stderr)
        self.assertGreaterEqual(len(beats), 1, result.stderr)
        execution = startup[0].split(".")[6]
        artifact = startup[0].split(".")[8]
        self.assertEqual(len(execution), 16)
        self.assertEqual(artifact == "na", not marked)
        for index, query in enumerate(beats, 1):
            self.assertEqual(query.split(".")[6], execution)
            self.assertEqual(query.split(".")[7], artifact)
            self.assertEqual(query.split(".")[5], str(index))

    def test_multiple_artifacts_emit_one_query_each(self):
        self.configure(self.probe_config(operation="insert"))
        artifacts = self.path / "artifacts"
        artifacts.mkdir()
        for name in ("one", "two"):
            shutil.copy2("/bin/busybox", artifacts / name)
        result = self.run_chalk("insert", str(artifacts))
        self.assertEqual(result.returncode, 0, result.stderr)
        queries = self.queries()
        self.assertEqual(len(queries), 2, result.stderr)
        self.assertEqual(len({query.split(".")[7] for query in queries}), 1)
        self.assertEqual(len({query.split(".")[8] for query in queries}), 2)


if __name__ == "__main__":
    result = unittest.main(exit=False).result
    capture_path = os.environ.get("CHALK_DNS_CAPTURE")
    if capture_path:
        Path(capture_path).write_text(json.dumps(CAPTURES, indent=2) + "\n")
    sys.exit(not result.wasSuccessful())

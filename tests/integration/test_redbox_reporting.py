#!/usr/bin/env python3
"""Run lifecycle reporting against a real Chalk binary and local DNS/HTTP sinks.

Linux: python3 tests/integration/test_redbox_reporting.py ./chalk
No production endpoints or credentials are used.
"""

from contextlib import contextmanager
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
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
        self.http_gate = None
        self.http_status = 200
        self.drop_dns = False
        self.dns_rcode = 0
        self.dns_answers = False
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
                if test.drop_dns:
                    return
                answer = b""
                if test.dns_answers and not test.dns_rcode:
                    qtype = struct.unpack("!H", packet[offset + 1 : offset + 3])[0]
                    data = b"\x7f\x00\x00\x01" if qtype == 1 else b"\x00" * 15 + b"\x01"
                    answer = (
                        b"\xc0\x0c"
                        + struct.pack("!HHIH", qtype, 1, 0, len(data))
                        + data
                    )
                response = (
                    packet[:2]
                    + struct.pack("!H", 0x8180 | test.dns_rcode)
                    + struct.pack("!HHHH", 1, int(bool(answer)), 0, 0)
                    + packet[12:]
                    + answer
                )
                sock.sendto(response, self.client_address)

        class HTTP(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                events.append(("http", self.path))
                self.rfile.read(int(self.headers.get("Content-Length", "0")))
                if test.http_gate:
                    test.http_gate.wait(10)
                self.send_response(test.http_status)
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
        self,
        extra="",
        *,
        enabled=True,
        command_report=False,
        build_template=None,
        beacon=False,
        initial_sleep_ms=1,
        beacon_server=None,
        workspace_id="00000000-0000-4000-8000-000000000001",
        declare_workspace=True,
        component=True,
        system_resolver=False,
        expect_success=True,
    ):
        if beacon_server is None:
            beacon_server = (
                "" if system_resolver else f"127.0.0.1:{self.dns.server_address[1]}"
            )
        workspace = ""
        if declare_workspace:
            value = (
                ""
                if workspace_id is None
                else f"value: {json.dumps(workspace_id, ensure_ascii=False)}"
            )
            workspace = f"keyspec _X_WORKSPACE_ID {{ kind: RunTimeHost; type: string; {value} }}"
        load = f'use redbox from "{ROOT / "configs/co"}"' if component else ""
        dns = ""
        if component:
            dns = f'redbox_beacon.dns_server = "{beacon_server}"\n'
            if not system_resolver:
                dns += "\n".join(
                    f'sink_config.redbox_{name}.dns_server = "127.0.0.1:{self.dns.server_address[1]}"'
                    for name in ("build", "exec", "heartbeat")
                )

        uri = str(ROOT / "configs/co/redbox")
        config = self.path / "profile.c4m"
        config.write_text(f"""{load}
{workspace}
use_report_cache = false
skip_command_report = {str(not command_report).lower()}
publish_audit = false
run_sbom_tools = false
exec.initial_sleep_time = <<{initial_sleep_ms} msecs>>
exec.heartbeat.rate = <<50 msecs>>
exec.postexec.run = false
{dns}
{extra}
""")
        params = [
            [False, uri, "redbox_domain", "string", "example.test"],
            [True, uri, "redbox_beacon.enabled", "bool", beacon],
        ]
        if not component:
            params = []
        if component and enabled is not None:
            params.append([False, uri, "redbox_enabled", "bool", enabled])
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
        if expect_success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.events.clear()
        return result

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
        expected_artifact = None
        if marked:
            executable = self.path / "python3"
            shutil.copy2("/usr/bin/python3", executable)
            inserted = self.run_chalk("insert", str(executable))
            self.assertEqual(inserted.returncode, 0, inserted.stderr)
            text = executable.read_bytes().decode("utf-8", errors="replace")
            start = re.search(r'\{\s*"MAGIC"\s*:\s*"dadfedabbadabbed"', text)
            self.assertIsNotNone(start)
            mark, _ = json.JSONDecoder().raw_decode(text[start.start() :])
            original = mark["METADATA_ID"]
            expected_artifact = hashlib.sha256(original.encode()).hexdigest()[:19]

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
        if marked:
            self.assertEqual(artifact, expected_artifact)
        for index, query in enumerate(beats, 1):
            self.assertEqual(query.split(".")[6], execution)
            self.assertEqual(query.split(".")[7], artifact)
            self.assertEqual(query.split(".")[5], str(index))

    def test_legacy_template_fields_are_preserved(self):
        self.configure(
            self.probe_config(operation="insert"),
            build_template="legacy.{_MONOTIME}.{CHALK_ID}.example.test",
        )
        artifact = self.path / "busybox"
        shutil.copy2("/bin/busybox", artifact)
        result = self.run_chalk("insert", str(artifact))
        self.assertEqual(result.returncode, 0, result.stderr)
        labels = self.queries()[0].split(".")
        self.assertTrue(labels[1].isdigit(), self.queries())
        self.assertNotEqual(labels[2], "na", self.queries())

    def beacon_config(self, extra=""):
        return f"""exec.chalk_as_parent = true
exec.heartbeat.run = true
sink_config normal_http {{
  sink: "post"
  uri: "http://127.0.0.1:{self.http.server_address[1]}/report"
}}
subscribe("report", "normal_http")
{extra}
"""

    def wait_for(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.01)
        self.fail(f"Timed out; events={self.events}")

    def test_independent_heartbeat_survives_stalled_http_and_stops_on_exit(self):
        self.configure(self.beacon_config(), command_report=True, beacon=True)
        self.http_gate = threading.Event()
        stop = self.path / "stop"
        script = self.path / "wait.py"
        script.write_text(
            "from pathlib import Path\nimport time\n"
            f"while not Path({str(stop)!r}).exists(): time.sleep(0.01)\n"
        )
        with subprocess.Popen(
            [
                str(self.chalk),
                "exec",
                "--exec-command-name=/usr/bin/python3",
                str(script),
            ],
            cwd=self.path,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ) as process:
            try:
                self.wait_for(lambda: any(kind == "http" for kind, _ in self.events))
                self.wait_for(
                    lambda: sum(q.startswith("hs.") for q in self.queries()) >= 3
                )
                self.assertIsNone(process.poll())
                self.assertFalse(any(q.startswith("ce.") for q in self.queries()))
                stop.touch()
                # The wrapped child is now a zombie until HTTP unblocks. The
                # independent worker must stop even while Chalk remains alive.
                time.sleep(0.15)
                count = len(self.queries())
                time.sleep(0.15)
                self.assertEqual(len(self.queries()), count)
            finally:
                stop.touch()
                self.http_gate.set()
            self.assertEqual(process.wait(timeout=10), 0)
        starts = [q for q in self.queries() if q.startswith("es.")]
        beats = [q for q in self.queries() if q.startswith("hs.")]
        self.assertEqual(len(starts), 1)
        execution = starts[0].split(".")[4]
        rich = [q for q in self.queries() if q.startswith("ce.")]
        self.assertEqual(len(rich), 1)
        self.assertEqual(rich[0].split(".")[6], execution)
        for index, query in enumerate(beats, 1):
            self.assertEqual(query.split(".")[4], execution)
            self.assertEqual(query.split(".")[5], str(index))
        self.assertEqual(starts[0].split(".")[7], "11e594f481958c10")

    def test_independent_beacon_precedes_collection_and_ignores_report_switches(self):
        self.configure(
            "exec.chalk_as_parent = true\n"
            "skip_custom_reports = true\nskip_command_report = true",
            beacon=True,
            initial_sleep_ms=2000,
        )
        started = time.monotonic()
        with subprocess.Popen(
            [str(self.chalk), "exec", "--exec-command-name=/bin/sleep", "0.3"],
            cwd=self.path,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ) as process:
            self.wait_for(lambda: any(q.startswith("es.") for q in self.queries()))
            self.assertLess(time.monotonic() - started, 1.5)
            self.assertEqual(process.wait(timeout=10), 0)
        self.assertTrue(all(q.startswith(("es.", "hs.")) for q in self.queries()))

    def test_independent_beacon_does_not_wait_for_dns_answers(self):
        self.configure(
            "exec.chalk_as_parent = true\nexec.heartbeat.run = true\nskip_custom_reports = true",
            beacon=True,
        )
        self.drop_dns = True
        started = time.monotonic()
        result = self.run_chalk("exec", "--exec-command-name=/bin/sleep", "0.35")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(time.monotonic() - started, 2)
        self.assertGreaterEqual(sum(q.startswith("hs.") for q in self.queries()), 3)
        self.assertNotIn("DNS query timed out", result.stderr)
        stamps = [int(q.split(".")[3]) for q in self.queries() if q.startswith("hs.")]
        self.assertGreater(len(set(stamps)), 1)
        self.assertTrue(any(stamp % 1000 for stamp in stamps))

    def test_independent_beacon_survives_failed_http(self):
        self.configure(
            self.beacon_config("skip_custom_reports = true"),
            command_report=True,
            beacon=True,
        )
        self.http_status = 503
        result = self.run_chalk("exec", "--exec-command-name=/bin/sleep", "0.35")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreaterEqual(sum(q.startswith("hs.") for q in self.queries()), 3)

    def test_independent_build_beacon_and_failsafe_exit_status(self):
        docker = self.path / "docker"
        docker.write_text("#!/bin/sh\nexit 7\n")
        docker.chmod(0o755)
        self.configure(
            f'docker_exe = "{docker}"\nskip_custom_reports = true', beacon=True
        )
        result = self.run_chalk("docker", "build", ".")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(len(self.queries()), 1, result.stderr)
        labels = self.queries()[0].split(".")
        self.assertEqual(labels[:2], ["bs", "bs1"])
        self.assertEqual(labels[6], "7")

    def test_component_defaults_do_not_enable_telemetry(self):
        self.configure(enabled=None)
        result = self.run_chalk("docker", "build", ".")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.queries(), [])

    def test_background_independent_beacon(self):
        self.configure(
            "exec.chalk_as_parent = false\nexec.heartbeat.run = true\nskip_custom_reports = true",
            beacon=True,
        )
        result = self.run_chalk("exec", "--exec-command-name=/bin/sleep", "0.35")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(q.startswith("es.") for q in self.queries()), 1)
        self.assertGreaterEqual(sum(q.startswith("hs.") for q in self.queries()), 3)
        time.sleep(0.1)
        count = len(self.queries())
        time.sleep(0.1)
        self.assertEqual(len(self.queries()), count)

    def test_independent_beacon_rejects_resolver_hostnames(self):
        self.configure(
            "exec.chalk_as_parent = true\nskip_custom_reports = true",
            beacon=True,
            beacon_server="resolver.example.test",
        )
        result = self.run_chalk("exec", "--exec-command-name=/bin/sleep", "0.01")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.queries(), [])

    @contextmanager
    def system_resolver(self):
        # Tests run in an isolated, network-disabled Linux container. Restore
        # resolver configuration even if a check fails.
        path = Path("/etc/resolv.conf")
        original = path.read_text()
        server = socketserver.UDPServer(("127.0.0.1", 53), self.dns.RequestHandlerClass)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            path.write_text("nameserver 127.0.0.1\noptions attempts:1 timeout:1\n")
            yield
        finally:
            path.write_text(original)
            server.shutdown()
            server.server_close()

    def test_deferred_dns_follows_custom_http_when_resolver_drops_queries(self):
        self.configure(
            f"""sink_config primary_http {{
  sink: "post"
  uri: "http://127.0.0.1:{self.http.server_address[1]}/primary"
}}
custom_report primary_http {{
  report_template: "redbox_build"
  sink_configs: ["primary_http"]
  use_when: ["env"]
}}
custom_report deferred_probe {{
  report_template: "redbox_build"
  sink_configs: ["redbox_build"]
  use_when: ["env"]
  after_others: true
}}
""",
            system_resolver=True,
        )
        self.drop_dns = True
        with self.system_resolver():
            started = time.monotonic()
            result = self.run_chalk("env")
            elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([kind for kind, _ in self.events], ["http", "dns"])
        self.assertLess(elapsed, 3)

    def test_default_system_resolver_success_and_failures(self):
        self.configure(
            """sink_config system_probe {
  sink: "dns"
  domain_template: "probe.example.test"
}
subscribe("report", "system_probe")
""",
            component=False,
            command_report=True,
        )
        with self.system_resolver():
            for answers, rcode, success in [
                (True, 0, True),
                (False, 0, False),
                (False, 3, False),
            ]:
                with self.subTest(answers=answers, rcode=rcode):
                    self.dns_answers, self.dns_rcode = answers, rcode
                    result = self.run_chalk("env")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(
                        "DNS lookup failed" not in result.stderr, success, result.stderr
                    )

    def test_opaque_and_absent_workspace_values(self):
        for value in ["sample_team/Case A", None, ""]:
            with self.subTest(value=value):
                self.configure(
                    "exec.chalk_as_parent = true", workspace_id=value, beacon=True
                )
                result = self.run_chalk(
                    "exec", "--exec-command-name=/bin/sleep", "0.01"
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = (
                    hashlib.sha256(value.encode()).hexdigest()[:16] if value else "na"
                )
                queries = self.queries()
                self.assertEqual(len(queries), 2, result.stderr)
                self.assertTrue(any(q.startswith("ce.") for q in queries))
                self.assertTrue(any(q.startswith("es.") for q in queries))
                self.assertTrue(
                    all(q.split(".")[-4] == expected for q in queries), queries
                )

    def test_missing_workspace_keyspec_has_clear_load_error(self):
        result = self.configure(declare_workspace=False, expect_success=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("_X_WORKSPACE_ID", result.stderr)
        self.assertIn("no matching keyspec", result.stderr)

    def test_without_component_does_not_use_exception_for_disablement(self):
        self.configure(component=False)
        result = self.run_chalk(
            "exec", "--log-level=trace", "--exec-command-name=/bin/sleep", "0.01"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("beacon skipped", result.stderr)
        self.assertEqual(self.queries(), [])

    def test_conflicting_custom_report_phases_are_rejected(self):
        result = self.configure(
            self.probe_config().replace(
                "before_command: true", "before_command: true\n  after_others: true"
            ),
            expect_success=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot set both", result.stderr)

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

#!/usr/bin/env python3
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1]).resolve()
real_podman = shutil.which('podman')
assert real_podman
output = Path('artifacts/podman/cancellation')
output.mkdir(parents=True, exist_ok=True)
checks = []
observations = []
report_log = Path.home() / '.local/chalk/chalk.log'


def check(name, value):
    checks.append({'name': name, 'passed': bool(value)})
    assert value, name


def process_table():
    result = {}
    for path in Path('/proc').glob('[0-9]*/stat'):
        try:
            raw = path.read_text()
            end = raw.rfind(')')
            fields = raw[end + 2:].split()
            result[int(path.parent.name)] = {'name': raw[raw.find('(') + 1:end],
                'state': fields[0], 'parent': int(fields[1]), 'start': fields[19]}
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            pass
    return result


def descendants(pid):
    table = process_table()
    owned = {pid}
    while True:
        found = {p for p, data in table.items() if data['parent'] in owned}
        if found <= owned:
            return {p: table[p] for p in owned if p in table}
        owned.update(found)


def survivors(owned):
    current = process_table()
    return {pid: current[pid] for pid, data in owned.items() if pid in current and
            current[pid]['start'] == data['start'] and current[pid]['state'] != 'Z'}


try:
    with tempfile.TemporaryDirectory(prefix='chalk-podman-cancel-') as temp:
        root = Path(temp)
        source = root / 'source'
        source.mkdir()
        (source / 'Containerfile').write_text(
            'FROM docker.io/library/alpine@sha256:eafc1edb577d2e9b458664a15f23ea1c370214193226069eb22921169fc7e43f\n'
            "RUN printf '%s%s\\n' CHALK_CANCEL_ READY && sleep 600\n"
            'ENTRYPOINT ["/bin/true"]\n')
        wrapped = root / 'wrapped'
        proxy = root / 'proxy'
        wrapped.mkdir()
        proxy.mkdir()
        (wrapped / 'podman').symlink_to(binary)
        (proxy / 'podman').write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['CANCEL_CALLS'], 'a') as stream:
    stream.write(json.dumps({'argv': sys.argv[1:], 'pid': os.getpid()}) + '\\n')
os.execv(os.environ['CANCEL_REAL'], [os.environ['CANCEL_REAL'], *sys.argv[1:]])
''')
        (proxy / 'podman').chmod(0o755)
        calls = root / 'calls.jsonl'
        env = dict(os.environ, PATH=str(wrapped) + os.pathsep + str(proxy) + os.pathsep + os.environ['PATH'],
                   CANCEL_CALLS=str(calls), CANCEL_REAL=real_podman)
        for sig in (signal.SIGINT, signal.SIGTERM):
            tag = 'localhost/chalk-cancel:' + str(os.getpid()) + '-' + sig.name.lower()
            calls.write_text('')
            report_offset = report_log.stat().st_size if report_log.exists() else 0
            process = subprocess.Popen([str(wrapped / 'podman'), 'build', '--file', 'Containerfile',
                                        '--tag', tag, '--platform', 'linux/amd64', '--format', 'oci', '.'],
                                       cwd=source, env=env, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       start_new_session=True, bufsize=0)
            transcript = bytearray()
            child_pid = None
            owned = {}
            try:
                deadline = time.monotonic() + 120
                while b'\nCHALK_CANCEL_READY\n' not in transcript:
                    assert process.poll() is None, transcript.decode(errors='replace')
                    assert time.monotonic() < deadline, 'actual RUN did not start'
                    readable, _, _ = select.select([process.stdout], [], [], 1)
                    if readable:
                        transcript.extend(os.read(process.stdout.fileno(), 65536))
                builds = [json.loads(line) for line in calls.read_text().splitlines()
                          if json.loads(line)['argv'][:1] == ['build']]
                check(sig.name + ' instrumented RUN reached', len(builds) == 1 and
                      '--build-context' in builds[0]['argv'])
                child_pid = builds[0]['pid']
                process_deadline = time.monotonic() + 5
                while time.monotonic() < process_deadline:
                    owned = descendants(child_pid)
                    if any(item['name'] == 'sleep' for item in owned.values()):
                        break
                    assert process.poll() is None, transcript.decode(errors='replace')
                    time.sleep(0.05)
                check(sig.name + ' RUN process observed', any(p['name'] == 'sleep' for p in owned.values()))
                cancel_started = time.monotonic()
                process.send_signal(sig)
                remaining, _ = process.communicate(timeout=30)
                transcript.extend(remaining)
                observation = {'signal': sig.name, 'wrapper_pid': process.pid,
                               'podman_pid': child_pid, 'returncode': process.returncode,
                               'elapsed_seconds': time.monotonic() - cancel_started,
                               'owned_processes': owned, 'survivors': survivors(owned)}
                observations.append(observation)
                check(sig.name + ' no report', (report_log.stat().st_size if report_log.exists() else 0) == report_offset)
                check(sig.name + ' cancellation exit', process.returncode in (-sig, 128 + sig))
                builds = [json.loads(line) for line in calls.read_text().splitlines()
                          if json.loads(line)['argv'][:1] == ['build']]
                check(sig.name + ' no fallback build', len(builds) == 1)
                deadline = time.monotonic() + 3
                remaining = survivors(owned)
                while remaining and time.monotonic() < deadline:
                    time.sleep(0.1)
                    remaining = survivors(owned)
                observation['survivors'] = remaining
                check(sig.name + ' RUN processes stopped', not remaining)
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    check(sig.name + ' Podman reaped', True)
                else:
                    check(sig.name + ' Podman reaped', False)
            finally:
                for pid in survivors(owned):
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                build_pids = [json.loads(line)['pid'] for line in calls.read_text().splitlines()
                              if json.loads(line)['argv'][:1] == ['build']]
                for group in [*build_pids, process.pid]:
                    if group is not None:
                        try:
                            os.killpg(group, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                process.wait()
                (output / (sig.name + '.log')).write_bytes(transcript)
                subprocess.run([real_podman, 'image', 'rm', '-f', tag], capture_output=True)
finally:
    (output / 'evidence.json').write_text(json.dumps({
        'schema_version': 1, 'source_sha': os.environ.get('CI_COMMIT_SHA'),
        'checks': checks, 'observations': observations, 'passed': sys.exc_info()[0] is None,
    }, indent=2) + '\n')

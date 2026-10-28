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


PHASE_PODMAN = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
import time

argv = sys.argv[1:]
with open(os.environ['CANCEL_PHASE_CALLS'], 'a') as stream:
    stream.write(json.dumps({'argv': argv, 'pid': os.getpid()}) + '\n')

phase = os.environ['CANCEL_PHASE']
base = os.environ['CANCEL_PHASE_BASE']
selected_id = os.environ['CANCEL_PHASE_ID']

def wait_if(name):
    if phase != name:
        return
    Path(os.environ['CANCEL_PHASE_READY']).write_text(str(os.getpid()))
    while True:
        time.sleep(0.1)

if argv == ['info', '--format', 'json']:
    sys.stdout.write('{"host":{"os":"linux","arch":"amd64",'
                     '"serviceIsRemote":false,"buildahVersion":"1.43.1"}}')
    sys.exit(0)

if argv == ['image', 'inspect', base, '--format', 'json']:
    wait_if('lookup')
    sys.stdout.write('[]\n')
    sys.stderr.write(f'Error: {base}: image not known\n')
    sys.exit(125)

if argv == ['pull', '--quiet', '--platform', 'linux/amd64', base]:
    wait_if('pull')
    sys.stdout.write(selected_id + '\n')
    sys.exit(0)

if argv == ['image', 'inspect', selected_id, '--format', 'json']:
    wait_if('selected-inspect')
    sys.stdout.write(json.dumps([{
        'Id': selected_id,
        'Os': 'linux',
        'Architecture': 'amd64',
        'Config': {'Entrypoint': ['/bin/true'], 'Cmd': []},
    }]))
    sys.exit(0)

if argv and argv[0] == 'build':
    sys.exit(0)

sys.exit(99)
'''


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

        phase_source = root / 'phase-source'
        phase_proxy = root / 'phase-proxy'
        phase_source.mkdir()
        phase_proxy.mkdir()
        phase_base = 'registry.invalid/chalk-cancel-phase:latest'
        phase_id = 'a' * 64
        (phase_source / 'Containerfile').write_text(
            f'FROM {phase_base}\nENTRYPOINT ["/bin/true"]\n')
        (phase_proxy / 'podman').write_text(PHASE_PODMAN)
        (phase_proxy / 'podman').chmod(0o755)
        phase_calls = root / 'phase-calls.jsonl'
        phase_expectations = {
            'lookup': [
                ['info', '--format', 'json'],
                ['image', 'inspect', phase_base, '--format', 'json'],
            ],
            'pull': [
                ['info', '--format', 'json'],
                ['image', 'inspect', phase_base, '--format', 'json'],
                ['pull', '--quiet', '--platform', 'linux/amd64', phase_base],
            ],
            'selected-inspect': [
                ['info', '--format', 'json'],
                ['image', 'inspect', phase_base, '--format', 'json'],
                ['pull', '--quiet', '--platform', 'linux/amd64', phase_base],
                ['image', 'inspect', phase_id, '--format', 'json'],
            ],
        }
        for phase, expected_calls in phase_expectations.items():
            phase_calls.write_text('')
            ready = root / (phase + '.ready')
            ready.unlink(missing_ok=True)
            report_offset = report_log.stat().st_size if report_log.exists() else 0
            phase_env = dict(
                os.environ,
                PATH=(str(wrapped) + os.pathsep + str(phase_proxy) +
                      os.pathsep + os.environ['PATH']),
                CANCEL_PHASE=phase,
                CANCEL_PHASE_BASE=phase_base,
                CANCEL_PHASE_ID=phase_id,
                CANCEL_PHASE_CALLS=str(phase_calls),
                CANCEL_PHASE_READY=str(ready),
            )
            process = subprocess.Popen(
                [str(wrapped / 'podman'), 'build', '--platform', 'linux/amd64', '.'],
                cwd=phase_source, env=phase_env, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            transcript = b''
            child_pid = None
            owned = {}
            try:
                deadline = time.monotonic() + 30
                while not ready.exists():
                    assert process.poll() is None, process.communicate()[0]
                    assert time.monotonic() < deadline, phase + ' did not start'
                    time.sleep(0.05)
                child_pid = int(ready.read_text())
                owned = descendants(child_pid)
                cancel_started = time.monotonic()
                process.send_signal(signal.SIGTERM)
                transcript = process.communicate(timeout=30)[0]
                recorded = [json.loads(line) for line in
                            phase_calls.read_text().splitlines()]
                observed_calls = [record['argv'] for record in recorded]
                builds = [argv for argv in observed_calls if argv[:1] == ['build']]
                remaining = survivors(owned)
                deadline = time.monotonic() + 3
                while remaining and time.monotonic() < deadline:
                    time.sleep(0.1)
                    remaining = survivors(owned)
                observation = {
                    'phase': phase,
                    'signal': signal.SIGTERM.name,
                    'wrapper_pid': process.pid,
                    'podman_pid': child_pid,
                    'returncode': process.returncode,
                    'elapsed_seconds': time.monotonic() - cancel_started,
                    'calls': observed_calls,
                    'survivors': remaining,
                }
                observations.append(observation)
                check(phase + ' cancellation exit',
                      process.returncode in (-signal.SIGTERM,
                                             128 + signal.SIGTERM))
                check(phase + ' exact child sequence',
                      observed_calls == expected_calls)
                check(phase + ' no fallback build', builds == [])
                check(phase + ' no report',
                      (report_log.stat().st_size if report_log.exists() else 0) ==
                      report_offset)
                check(phase + ' child stopped', not remaining)
            finally:
                if child_pid is not None:
                    try:
                        os.kill(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                (output / ('phase-' + phase + '.log')).write_bytes(transcript)

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

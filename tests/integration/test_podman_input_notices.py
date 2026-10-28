#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


binary = Path(sys.argv[1]).resolve()
binary_sha256 = hashlib.sha256(binary.read_bytes()).hexdigest()
evidence = []
output = Path('artifacts/podman/input-notices.json')
output.parent.mkdir(parents=True, exist_ok=True)


def record_failure(kind, error, traceback):
    output.write_text(json.dumps({
        'schema_version': 1,
        'source_sha': os.environ.get('CI_COMMIT_SHA'),
        'binary_sha256': binary_sha256,
        'binary_unchanged': hashlib.sha256(binary.read_bytes()).hexdigest() == binary_sha256,
        'cases': evidence,
        'passed': False,
        'failure': str(error),
    }, indent=2) + '\n')
    sys.__excepthook__(kind, error, traceback)


sys.excepthook = record_failure


FAKE_PODMAN = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
import time

argv = sys.argv[1:]
with open(os.environ['PODMAN_CALLS'], 'a') as stream:
    stream.write(json.dumps({'argv': argv, 'pid': os.getpid(),
                             'cwd': os.getcwd()}) + '\n')

if argv == ['info', '--format', 'json']:
    sys.stdout.write(os.environ.get('PODMAN_INFO', '{"host":{"os":"linux","arch":"amd64","serviceIsRemote":false,"buildahVersion":"1.43.1"}}'))
    sys.stderr.write(os.environ.get('PODMAN_INFO_STDERR', ''))
    sys.exit(int(os.environ.get('PODMAN_INFO_EXIT', '0')))

if argv[:2] == ['image', 'inspect']:
    selected_id = os.environ.get('PODMAN_SELECTED_ID')
    if selected_id and argv[2] == selected_id:
        sys.stdout.write(os.environ.get('PODMAN_SELECTED_INSPECT_STDOUT', ''))
        sys.stderr.write(os.environ.get('PODMAN_SELECTED_INSPECT_STDERR',
                                        'captured-selected-inspect-error\n'))
        sys.exit(int(os.environ.get('PODMAN_SELECTED_INSPECT_EXIT', '46')))
    sys.stdout.write(os.environ.get('PODMAN_INSPECT_STDOUT', ''))
    sys.stderr.write(os.environ.get('PODMAN_INSPECT_STDERR', 'captured-inspect-error\n'))
    sys.exit(int(os.environ.get('PODMAN_INSPECT_EXIT', '44')))

if argv[:2] == ['pull', '--quiet']:
    sys.stdout.write(os.environ.get('PODMAN_BASE_PULL_STDOUT', ''))
    sys.stderr.write(os.environ.get('PODMAN_BASE_PULL_STDERR', 'captured-pull-error\n'))
    sys.exit(int(os.environ.get('PODMAN_BASE_PULL_EXIT', '45')))

if argv and argv[0] == 'build':
    injected = '--build-context' in argv
    if injected and os.environ.get('PODMAN_WAIT_INJECTED') == '1':
        ready = Path(os.environ['PODMAN_READY'])
        ready.write_text(str(os.getpid()))
        while True:
            time.sleep(0.1)
    label = 'injected-build' if injected else 'native-build'
    sys.stdout.buffer.write(('stdout:' + label).encode() + b'\x00\n')
    sys.stderr.buffer.write(('stderr:' + label).encode() + b'\xff\n')
    key = 'PODMAN_INJECTED_EXIT' if injected else 'PODMAN_NATIVE_EXIT'
    sys.exit(int(os.environ.get(key, '0')))

if argv and argv[0] in ('push', 'pull'):
    label = 'native-' + argv[0]
    sys.stdout.buffer.write(('stdout:' + label).encode() + b'\x00\n')
    sys.stderr.buffer.write(('stderr:' + label).encode() + b'\xff\n')
    sys.exit(int(os.environ.get('PODMAN_NATIVE_EXIT', '0')))

sys.stderr.write('unexpected fake Podman invocation\n')
sys.exit(99)
'''


def call_records(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def calls(path):
    return [record['argv'] for record in call_records(path)]


def notice_lines(stderr):
    return [line.decode('utf-8') for line in stderr.splitlines()
            if line.startswith(b'chalk:')]


def native_stderr(stderr):
    return b''.join(line + b'\n' for line in stderr.splitlines()
                    if not line.startswith(b'chalk:'))


def assert_secret_free(result, *secrets):
    for secret in secrets:
        assert secret.encode() not in result.stderr, (secret, result.stderr)


def assert_notice_secret_free(result, *secrets):
    notices = '\n'.join(notice_lines(result.stderr)).encode()
    for secret in secrets:
        assert secret.encode() not in notices, (secret, notices)


def assert_skip(result, operation, *fragments):
    notices = notice_lines(result.stderr)
    matching = [line for line in notices
                if f'skipped Podman {operation} processing' in line]
    assert len(matching) == 1, (operation, notices, result)
    for fragment in fragments:
        assert fragment in matching[0], (fragment, matching[0])


with tempfile.TemporaryDirectory(prefix='podman-input-notices-') as temp:
    root = Path(temp)
    root.chmod(0o755)
    real_dir = root / 'real'
    wrap_dir = root / 'wrapped'
    home = root / 'home'
    for directory in (real_dir, wrap_dir, home):
        directory.mkdir()
        directory.chmod(0o777 if directory == home else 0o755)
    real = real_dir / 'podman'
    real.write_text(FAKE_PODMAN)
    real.chmod(0o755)
    wrapper = wrap_dir / 'podman'
    wrapper.symlink_to(binary)
    call_log = root / 'calls.jsonl'
    call_log.write_text('')
    call_log.chmod(0o666)

    base_env = dict(
        os.environ,
        HOME=str(home),
        PATH=str(real_dir) + os.pathsep + os.environ['PATH'],
        PODMAN_CALLS=str(call_log),
    )

    def run(args, *, env=None, cwd=None, interposed=False, user=None,
            level='none'):
        call_log.write_text('')
        current = dict(base_env)
        if env:
            current.update(env)
        if interposed:
            current['PATH'] = (str(wrap_dir) + os.pathsep + str(real_dir) +
                               os.pathsep + os.environ['PATH'])
            command = [str(wrapper), *args]
        else:
            command = [str(binary), '--no-use-external-config',
                       '--skip-command-report', '--skip-custom-reports',
                       '--no-color',
                       '--log-level=' + level, 'podman', *args]

        preexec_fn = None
        if user is not None:
            def drop_user():
                os.setgroups([])
                os.setgid(user)
                os.setuid(user)
            preexec_fn = drop_user
        result = subprocess.run(command, cwd=cwd or root, env=current,
                                stdin=subprocess.DEVNULL, capture_output=True,
                                preexec_fn=preexec_fn, timeout=30)
        return result, calls(call_log)

    def context(name, text):
        directory = root / name
        directory.mkdir()
        directory.chmod(0o755)
        containerfile = directory / 'Containerfile'
        containerfile.write_text(text)
        containerfile.chmod(0o644)
        return directory, containerfile

    missing_path = root / 'missing-path'
    missing_path.mkdir()
    missing_env = dict(base_env, PATH=str(missing_path))
    for args, operation, secret in (
        (['build', 'missing-context-secret-must-not-be-reported'], 'build',
         'missing-context-secret-must-not-be-reported'),
        (['push', 'missing-push-secret-must-not-be-reported'], 'push',
         'missing-push-secret-must-not-be-reported'),
        (['pull', 'missing-pull-secret-must-not-be-reported'], 'pull',
         'missing-pull-secret-must-not-be-reported'),
    ):
        result = subprocess.run(
            [str(binary), '--no-use-external-config', '--no-color',
             '--log-level=none', 'podman', *args],
            cwd=root, env=missing_env, stdin=subprocess.DEVNULL,
            capture_output=True, timeout=30,
        )
        assert result.returncode == 127, (args, result)
        assert_skip(result, operation, 'native Podman executable')
        assert_secret_free(result, secret)
        evidence.append({'case': 'missing-native-' + operation,
                         'exit_code': result.returncode,
                         'native_executions': 0})

    missing_route_secret = 'missing-route-secret-must-not-be-reported'
    result = subprocess.run(
        [str(binary), '--no-use-external-config', '--no-color',
         '--log-level=none', 'podman', 'build', '--build-arg',
         'TOKEN=' + missing_route_secret, '.'],
        cwd=root, env=missing_env, stdin=subprocess.DEVNULL,
        capture_output=True, timeout=30,
    )
    assert result.returncode == 127, result
    assert_skip(result, 'build', 'native Podman executable')
    assert len(notice_lines(result.stderr)) == 1, result.stderr
    assert b'unsupported flag' not in result.stderr
    assert_secret_free(result, missing_route_secret)
    evidence.append({'case': 'missing-native-replaces-routing-refusal',
                     'exit_code': result.returncode,
                     'native_executions': 0})

    routine = subprocess.run(
        [str(binary), '--no-use-external-config', '--no-color',
         '--log-level=none', 'podman', 'ps'],
        cwd=root, env=missing_env, stdin=subprocess.DEVNULL,
        capture_output=True, timeout=30,
    )
    assert routine.returncode == 127, routine
    assert not notice_lines(routine.stderr), routine.stderr
    evidence.append({'case': 'missing-native-routine-quiet',
                     'exit_code': routine.returncode,
                     'native_executions': 0})

    missing_context = root / 'context-secret-must-not-be-reported'
    result, seen = run(['build', str(missing_context)])
    assert result.returncode == 0, (result, seen)
    assert seen == [['build', str(missing_context)]], seen
    assert result.stdout == b'stdout:native-build\x00\n'
    assert native_stderr(result.stderr) == b'stderr:native-build\xff\n'
    assert_skip(result, 'build', 'context')
    assert_secret_free(result, 'context-secret-must-not-be-reported')
    evidence.append({'case': 'missing-context', 'exit_code': result.returncode,
                     'native_executions': 1})

    absent, _ = context('absent-containerfile', 'FROM scratch\n')
    (absent / 'Containerfile').unlink()
    result, seen = run(['build', str(absent)], interposed=True)
    assert result.returncode == 0, (result, seen)
    assert seen == [['build', str(absent)]], seen
    assert_skip(result, 'build', 'Containerfile')
    evidence.append({'case': 'missing-containerfile', 'exit_code': result.returncode,
                     'native_executions': 1})

    unreadable, unreadable_file = context(
        'unreadable-containerfile',
        'FROM scratch\nENTRYPOINT ["/bin/true"]\n',
    )
    unreadable_file.chmod(0)
    result, seen = run(['build', str(unreadable)],
                       user=65534 if os.geteuid() == 0 else None)
    assert result.returncode == 0, (result, seen)
    assert seen == [['build', str(unreadable)]], seen
    assert_skip(result, 'build', 'Containerfile', 'read')
    evidence.append({'case': 'unreadable-containerfile',
                     'exit_code': result.returncode, 'native_executions': 1})
    unreadable_file.chmod(0o644)

    parser_cases = [
        ('json', 'FROM scratch\nRUN true\nENTRYPOINT ["json-secret-must-not-be-reported"\n',
         'ENTRYPOINT', 3, 'json-secret-must-not-be-reported'),
        ('shell', 'FROM scratch\nSHELL ["shell-secret-must-not-be-reported"\nCMD echo ok\n',
         'SHELL', 2, 'shell-secret-must-not-be-reported'),
        ('arg', 'ARG TOKEN=${arg-secret-must-not-be-reported\nFROM $TOKEN\nCMD ["/bin/true"]\n',
         'FROM', 2, 'arg-secret-must-not-be-reported'),
        ('env', 'FROM scratch\nENV TOKEN=${env-secret-must-not-be-reported\nCMD ["/bin/true"]\n',
         'ENV', 2, 'env-secret-must-not-be-reported'),
    ]
    for name, source, instruction, line, secret in parser_cases:
        directory, _ = context('parser-' + name, source)
        result, seen = run(['build', str(directory)])
        assert result.returncode == 0, (name, result)
        assert seen == [['build', str(directory)]], (name, seen)
        assert_skip(result, 'build', instruction, f'line {line}')
        assert_secret_free(result, secret)
        evidence.append({'case': 'parser-' + name, 'exit_code': result.returncode,
                         'instruction': instruction, 'line': line,
                         'native_executions': 1})

    supported, _ = context(
        'supported-input',
        'FROM scratch\nENTRYPOINT ["/bin/true"]\n',
    )
    host_cases = [
        ('invalid', '{host-secret-must-not-be-reported', 'host information',
         'host-secret-must-not-be-reported'),
        ('os', '{"host":{"os":"os-secret-must-not-be-reported","arch":"amd64","serviceIsRemote":false}}',
         'operating system', 'os-secret-must-not-be-reported'),
        ('arch', '{"host":{"os":"linux","arch":"arch-secret-must-not-be-reported","serviceIsRemote":false}}',
         'architecture', 'arch-secret-must-not-be-reported'),
        ('remote', '{"host":{"os":"linux","arch":"amd64","serviceIsRemote":true}}',
         'remote', ''),
    ]
    for name, info, fragment, secret in host_cases:
        result, seen = run(['build', str(supported)], env={'PODMAN_INFO': info})
        assert result.returncode == 0, (name, result)
        assert seen == [
            ['info', '--format', 'json'],
            ['build', str(supported)],
        ], (name, seen)
        assert_skip(result, 'build', fragment)
        if secret:
            assert_secret_free(result, secret)
        evidence.append({'case': 'host-' + name, 'exit_code': result.returncode,
                         'native_executions': 2})

    no_startup, _ = context('no-startup', 'FROM scratch\nRUN true\n')
    result, seen = run(['build', str(no_startup)])
    assert result.returncode == 0
    assert seen == [
        ['info', '--format', 'json'],
        ['build', str(no_startup)],
    ], seen
    assert_skip(result, 'build', 'startup')
    evidence.append({'case': 'startup-absent', 'exit_code': result.returncode,
                     'native_executions': 2})

    root_secret = 'registry.invalid/base-secret-must-not-be-reported:latest'
    root_input, _ = context('root-unavailable', f'FROM {root_secret}\n')
    selected_base_notice = (
        'chalk: skipped Podman build processing: '
        'an immutable selected-base identity is unavailable.'
    )
    result, seen = run(['build', str(root_input)], env={
        'PODMAN_INSPECT_STDERR': 'remote-url-secret-must-not-be-reported\n',
        'PODMAN_BASE_PULL_STDERR': 'credential-secret-must-not-be-reported\n',
    })
    assert result.returncode == 0
    assert seen == [
        ['info', '--format', 'json'],
        ['image', 'inspect', root_secret, '--format', 'json'],
        ['build', str(root_input)],
    ], seen
    assert_skip(result, 'build',
                'an immutable selected-base identity is unavailable')
    assert selected_base_notice in notice_lines(result.stderr), result.stderr
    assert_secret_free(result, root_secret, 'remote-url-secret-must-not-be-reported',
                       'credential-secret-must-not-be-reported')
    lookup_records = call_records(call_log)
    assert lookup_records[-1]['argv'] == ['build', str(root_input)]
    assert lookup_records[-1]['cwd'] == str(root)
    evidence.append({'case': 'base-lookup-error',
                     'exit_code': result.returncode,
                     'native_executions': len(seen)})

    result, seen = run(['build', str(root_input)], env={
        'PODMAN_INSPECT_STDERR': 'lookup-error-must-not-be-reported\n',
        'PODMAN_NATIVE_EXIT': '23',
    })
    assert result.returncode == 23, result
    assert seen == [
        ['info', '--format', 'json'],
        ['image', 'inspect', root_secret, '--format', 'json'],
        ['build', str(root_input)],
    ], seen
    assert selected_base_notice in notice_lines(result.stderr), result.stderr
    lookup_failure_records = call_records(call_log)
    assert lookup_failure_records[-1]['argv'] == ['build', str(root_input)]
    assert lookup_failure_records[-1]['cwd'] == str(root)
    assert_secret_free(result, root_secret, 'lookup-error-must-not-be-reported')
    evidence.append({'case': 'base-lookup-error-native-failure',
                     'exit_code': result.returncode,
                     'native_executions': len(seen)})

    absent_env = {
        'PODMAN_INSPECT_EXIT': '125',
        'PODMAN_INSPECT_STDOUT': '[]\n',
        'PODMAN_INSPECT_STDERR': (
            'Warning: test diagnostic\n'
            f'Error: {root_secret}: image not known\n'
        ),
    }
    result, seen = run(['build', str(root_input)], env={
        **absent_env,
        'PODMAN_BASE_PULL_EXIT': '45',
        'PODMAN_BASE_PULL_STDERR': 'pull-error-must-not-be-reported\n',
    })
    assert result.returncode == 0, result
    assert seen == [
        ['info', '--format', 'json'],
        ['image', 'inspect', root_secret, '--format', 'json'],
        ['pull', '--quiet', root_secret],
        ['build', str(root_input)],
    ], seen
    assert selected_base_notice in notice_lines(result.stderr), result.stderr
    pull_failure_records = call_records(call_log)
    assert pull_failure_records[-1]['argv'] == ['build', str(root_input)]
    assert pull_failure_records[-1]['cwd'] == str(root)
    assert_secret_free(result, root_secret, 'pull-error-must-not-be-reported')
    evidence.append({'case': 'base-download-error-native-success',
                     'exit_code': result.returncode,
                     'native_executions': len(seen)})

    selected_id = 'a' * 64
    result, seen = run(['build', str(root_input)], env={
        **absent_env,
        'PODMAN_BASE_PULL_EXIT': '0',
        'PODMAN_BASE_PULL_STDOUT': selected_id + '\n',
        'PODMAN_BASE_PULL_STDERR': '',
        'PODMAN_SELECTED_ID': selected_id,
        'PODMAN_SELECTED_INSPECT_EXIT': '46',
        'PODMAN_SELECTED_INSPECT_STDERR': (
            'selected-inspect-error-must-not-be-reported\n'
        ),
        'PODMAN_NATIVE_EXIT': '23',
    })
    assert result.returncode == 23, result
    assert seen == [
        ['info', '--format', 'json'],
        ['image', 'inspect', root_secret, '--format', 'json'],
        ['pull', '--quiet', root_secret],
        ['image', 'inspect', selected_id, '--format', 'json'],
        ['build', str(root_input)],
    ], seen
    assert selected_base_notice in notice_lines(result.stderr), result.stderr
    selected_failure_records = call_records(call_log)
    assert selected_failure_records[-1]['argv'] == ['build', str(root_input)]
    assert selected_failure_records[-1]['cwd'] == str(root)
    assert_secret_free(result, root_secret,
                       'selected-inspect-error-must-not-be-reported')
    evidence.append({'case': 'selected-base-inspection-error-native-failure',
                     'exit_code': result.returncode,
                     'native_executions': len(seen)})

    result, seen = run(['build', '--pull=never', str(root_input)], env={
        'PODMAN_INSPECT_STDERR': 'remote-url-secret-must-not-be-reported\n',
        'PODMAN_BASE_PULL_STDERR': 'credential-secret-must-not-be-reported\n',
    })
    assert result.returncode == 0
    assert seen == [
        ['info', '--format', 'json'],
        ['image', 'inspect', root_secret, '--format', 'json'],
        ['build', '--pull=never', str(root_input)],
    ], seen
    assert_skip(result, 'build',
                'an immutable selected-base identity is unavailable')
    assert_secret_free(result, root_secret, 'remote-url-secret-must-not-be-reported',
                       'credential-secret-must-not-be-reported')
    evidence.append({'case': 'pull-never-does-not-fetch',
                     'exit_code': result.returncode,
                     'native_executions': len(seen)})

    result, seen = run(['build', '--pull=always', str(root_input)], env={
        'PODMAN_INSPECT_STDERR': 'remote-url-secret-must-not-be-reported\n',
        'PODMAN_BASE_PULL_STDERR': 'credential-secret-must-not-be-reported\n',
    })
    assert result.returncode == 0
    assert seen == [
        ['info', '--format', 'json'],
        ['pull', '--quiet', '--policy', 'always', root_secret],
        ['build', '--pull=always', str(root_input)],
    ], seen
    assert_skip(result, 'build',
                'an immutable selected-base identity is unavailable')
    assert_secret_free(result, root_secret, 'remote-url-secret-must-not-be-reported',
                       'credential-secret-must-not-be-reported')
    evidence.append({'case': 'pull-always-fetches-first',
                     'exit_code': result.returncode,
                     'native_executions': len(seen)})

    result, seen = run(['build', '--pull=newer', str(root_input)], env={
        'PODMAN_BASE_PULL_STDERR': 'credential-secret-must-not-be-reported\n',
    })
    assert result.returncode == 0
    assert seen[1][:4] == ['pull', '--quiet', '--policy', 'newer'], seen
    assert seen[-1] == ['build', '--pull=newer', str(root_input)], seen
    assert_secret_free(result, 'credential-secret-must-not-be-reported')
    evidence.append({'case': 'pull-newer-uses-native-policy',
                     'exit_code': result.returncode,
                     'native_executions': len(seen)})

    def assert_retry(result, seen, native_status):
        assert seen[0] == ['info', '--format', 'json'], seen
        builds = [argv for argv in seen if argv and argv[0] == 'build']
        assert len(builds) == 2, seen
        assert '--build-context' in builds[0], builds
        assert builds[1] == ['build', str(supported)], builds
        assert result.returncode == native_status, result
        expected_stdout = (b'stdout:injected-build\x00\n' +
                           b'stdout:native-build\x00\n')
        assert result.stdout == expected_stdout, {
            'actual_length': len(result.stdout),
            'actual_sha256': hashlib.sha256(result.stdout).hexdigest(),
            'expected_length': len(expected_stdout),
            'expected_sha256': hashlib.sha256(expected_stdout).hexdigest(),
        }
        assert native_stderr(result.stderr) == (b'stderr:injected-build\xff\n' +
                                                b'stderr:native-build\xff\n')

    result, seen = run(['build', str(supported)], env={
        'PODMAN_INJECTED_EXIT': '17',
        'PODMAN_NATIVE_EXIT': '0',
    })
    assert_retry(result, seen, 0)
    retry_notices = notice_lines(result.stderr)
    assert any('instrumented Podman build' in line and '17' in line and
               'retry' in line for line in retry_notices), retry_notices
    assert 'chalk: Build succeeded; Chalk did not instrument this build.' in retry_notices
    evidence.append({'case': 'retry-succeeded', 'exit_code': result.returncode,
                     'build_executions': 2})

    result, seen = run(['build', str(supported)], env={
        'PODMAN_INJECTED_EXIT': '17',
        'PODMAN_NATIVE_EXIT': '23',
    })
    assert_retry(result, seen, 23)
    retry_notices = notice_lines(result.stderr)
    assert any('instrumented Podman build' in line and '17' in line and
               'retry' in line for line in retry_notices), retry_notices
    assert any('native Podman retry' in line and '23' in line for line in retry_notices), retry_notices
    evidence.append({'case': 'retry-failed', 'exit_code': result.returncode,
                     'build_executions': 2})

    for cancelled_status in (130, 143):
        result, seen = run(['build', str(supported)], env={
            'PODMAN_INJECTED_EXIT': str(cancelled_status),
        })
        assert result.returncode == cancelled_status, result
        builds = [argv for argv in seen if argv and argv[0] == 'build']
        assert len(builds) == 1 and '--build-context' in builds[0], seen
        assert not any('retry' in line or 'Build succeeded' in line
                       for line in notice_lines(result.stderr)), result.stderr
        evidence.append({'case': 'child-cancelled-' + str(cancelled_status),
                         'exit_code': result.returncode, 'build_executions': 1})

    call_log.write_text('')
    ready = root / 'injected.ready'
    ready.unlink(missing_ok=True)
    signal_env = dict(base_env, PODMAN_WAIT_INJECTED='1', PODMAN_READY=str(ready))
    process = subprocess.Popen(
        [str(binary), '--no-use-external-config', '--no-color', '--log-level=none',
         'podman', 'build', str(supported)],
        cwd=root, env=signal_env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        deadline = time.monotonic() + 30
        while not ready.exists():
            assert process.poll() is None, process.communicate()
            assert time.monotonic() < deadline, 'instrumented build did not start'
            time.sleep(0.05)
        process.send_signal(signal.SIGTERM)
        _, stderr = process.communicate(timeout=30)
        assert process.returncode in (-signal.SIGTERM, 128 + signal.SIGTERM)
        seen = calls(call_log)
        builds = [argv for argv in seen if argv and argv[0] == 'build']
        assert len(builds) == 1 and '--build-context' in builds[0], seen
        assert not any('retry' in line or 'Build succeeded' in line
                       for line in notice_lines(stderr)), stderr
        evidence.append({'case': 'signal-cancelled',
                         'exit_code': process.returncode, 'build_executions': 1})
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()

    info_secret = 'info-secret-must-not-be-reported'
    result, seen = run(['build', str(supported)], env={
        'PODMAN_INFO_EXIT': '51',
        'PODMAN_INFO_STDERR': info_secret + '\n',
        'PODMAN_NATIVE_EXIT': '0',
    })
    assert result.returncode == 0
    assert seen == [
        ['info', '--format', 'json'],
        ['build', str(supported)],
    ], seen
    notices = notice_lines(result.stderr)
    assert any('Podman host inspection' in line and 'retry' in line
               for line in notices), notices
    assert 'chalk: Build succeeded; Chalk did not instrument this build.' in notices
    assert_secret_free(result, info_secret)
    evidence.append({'case': 'host-inspection-retry',
                     'exit_code': result.returncode, 'build_executions': 1})

    image_secret = 'registry.invalid/image-secret-must-not-be-reported:tag'
    result, seen = run(['push', image_secret], env={'PODMAN_NATIVE_EXIT': '19'},
                       level='error')
    assert result.returncode == 19
    assert seen == [
        ['image', 'inspect', image_secret, '--format', 'json'],
        ['push', image_secret],
    ], seen
    assert result.stdout == b'stdout:native-push\x00\n'
    assert result.stderr.count(b'stderr:native-push\xff\n') == 1, result.stderr
    assert b'pushing without chalk' in result.stderr
    assert_skip(result, 'push', 'scan')
    assert_notice_secret_free(result, image_secret, 'captured-inspect-error')
    assert b'captured-inspect-error' not in result.stderr
    evidence.append({'case': 'push-scan-unavailable',
                     'exit_code': result.returncode, 'native_pushes': 1})

    result, seen = run(['pull', image_secret], env={'PODMAN_NATIVE_EXIT': '0'},
                       level='error')
    assert result.returncode == 0
    assert seen == [
        ['pull', image_secret],
        ['image', 'inspect', image_secret, '--format', 'json'],
    ], seen
    assert result.stdout == b'stdout:native-pull\x00\n'
    assert result.stderr.count(b'stderr:native-pull\xff\n') == 1, result.stderr
    assert b'cannot be collected' in result.stderr
    assert_skip(result, 'pull', 'scan')
    assert_notice_secret_free(result, image_secret, 'captured-inspect-error')
    assert b'captured-inspect-error' not in result.stderr
    evidence.append({'case': 'pull-scan-unavailable',
                     'exit_code': result.returncode, 'native_pulls': 1})

binary_unchanged = hashlib.sha256(binary.read_bytes()).hexdigest() == binary_sha256
assert binary_unchanged, 'Chalk binary changed while the input notice contract ran'
output.write_text(json.dumps({
    'schema_version': 1,
    'source_sha': os.environ.get('CI_COMMIT_SHA'),
    'binary_sha256': binary_sha256,
    'binary_unchanged': binary_unchanged,
    'cases': evidence,
    'passed': True,
}, indent=2) + '\n')
print('Podman input, parser, retry, cancellation, and transfer notices passed')

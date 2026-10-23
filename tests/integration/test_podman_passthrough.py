#!/usr/bin/env python3
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1]).resolve()
evidence = []
output = Path('artifacts/podman/passthrough.json')
output.parent.mkdir(parents=True, exist_ok=True)

NOTICE_PREFIX = b'chalk: skipped Podman '


def notice_case(argv, operation=None, contains=(), excludes=()):
    return {'argv': argv, 'operation': operation,
            'contains': tuple(contains), 'excludes': tuple(excludes)}


def assert_skip_notice(stderr, native_stderr, case):
    assert stderr.endswith(native_stderr), (case['argv'], stderr, native_stderr)
    chalk_stderr = stderr[:-len(native_stderr)] if native_stderr else stderr
    notices = [line for line in chalk_stderr.splitlines(keepends=True)
               if line.startswith(NOTICE_PREFIX)]
    assert len(notices) == 1, (case['argv'], 'expected one skip notice', chalk_stderr)
    notice = notices[0]
    expected_prefix = NOTICE_PREFIX + case['operation'].encode() + b' processing: '
    assert notice.startswith(expected_prefix), (case['argv'], notice)
    assert notice.endswith(b'.\n'), (case['argv'], notice)
    assert len(notice) <= 200, (case['argv'], notice)
    for value in case['contains']:
        assert value.encode() in notice, (case['argv'], value, notice)
    for value in case['excludes']:
        assert value.encode() not in notice, (case['argv'], value, notice)
    return notice, chalk_stderr


def record_failure(kind, error, traceback):
    output.write_text(json.dumps({'schema_version': 1, 'source_sha': os.environ.get('CI_COMMIT_SHA'),
                                  'cases': evidence, 'passed': False,
                                  'failure': str(error)}, indent=2) + '\n')
    sys.__excepthook__(kind, error, traceback)


sys.excepthook = record_failure
with tempfile.TemporaryDirectory(prefix='podman-passthrough-') as temp:
    root = Path(temp)
    real_dir = root / 'real'
    wrap_dir = root / 'wrapped'
    real_dir.mkdir()
    wrap_dir.mkdir()
    real = real_dir / 'podman'
    real.write_text('''#!/usr/bin/env python3
import hashlib, json, os, signal, sys, time
from pathlib import Path
with open(os.environ['PODMAN_CALLS'], 'a') as f:
    f.write(json.dumps({'argv': sys.argv[1:], 'pid': os.getpid(), 'uid': os.getuid(),
                        'gid': os.getgid(), 'groups': os.getgroups(), 'cwd': os.getcwd(),
                        'tty_signals': [int(signal.getsignal(s)) for s in (signal.SIGTTIN, signal.SIGTTOU)],
                        'ignored_signals': [signal.getsignal(s) == signal.SIG_IGN for s in (signal.SIGINT, signal.SIGFPE)],
                        'signal_mask': sorted(int(s) for s in signal.pthread_sigmask(signal.SIG_BLOCK, [])),
                        'env': {key: hashlib.sha256(value.encode()).hexdigest()
                                for key, value in os.environ.items()}}) + '\\n')
if os.environ.get('PODMAN_WAIT') == '1':
    ready = Path(os.environ['PODMAN_READY'])
    ready.with_suffix('.tmp').write_text(str(os.getpid()))
    os.replace(ready.with_suffix('.tmp'), ready)
    while True:
        time.sleep(0.1)
data = sys.stdin.buffer.read()
sys.stdout.buffer.write(b'podman stdout\\x00' + data)
if os.environ.get('PODMAN_SILENT_STDERR') != '1':
    sys.stderr.buffer.write(b'podman stderr\\xff')
sys.exit(int(os.environ.get('PODMAN_EXIT', '0')))
''')
    real.chmod(0o755)
    wrapper = wrap_dir / 'podman'
    wrapper.symlink_to(binary)
    env = dict(os.environ, PATH=str(wrap_dir) + os.pathsep + str(real_dir) + os.pathsep + os.environ['PATH'])
    calls = root / 'calls.jsonl'
    env['PODMAN_CALLS'] = str(calls)
    # `push` and `pull` are deliberately absent. They used to pass through and
    # were asserted here; they are now instrumented, so chalk legitimately runs
    # extra probes (an `image inspect` to recover any existing mark) and this
    # test's "exactly one native and one wrapped execution" invariant no longer
    # describes them. Their behaviour is covered by test_podman_registry.py and
    # by the unit tests for classifyPodmanArgs. A push or pull that chalk
    # declines to instrument still passes through, and the malformed forms below
    # exercise that.
    cases = [
        notice_case([]), notice_case(['--help']), notice_case(['--version']),
        notice_case(['ps']),
        notice_case(['container', 'ps']), notice_case(['image', 'list']),
        notice_case(['login', '--username', 'example', '--password-stdin', 'example.invalid']),
        notice_case(['push'], 'push', contains=('image',)),
        notice_case(['pull'], 'pull', contains=('image',)),
        notice_case(['push', 'one', 'two', 'three'], 'push', contains=('image',)),
        notice_case(['pull', '--authfile', '/tmp/auth-value-must-not-be-reported',
                     'example.invalid/image:tag'],
                    'pull', contains=('--authfile',),
                    excludes=('/tmp/auth-value-must-not-be-reported',)),
        notice_case(['tag', 'one', 'two']),
        notice_case(['run', '--rm', 'image', 'arg with spaces', '']),
        notice_case(['inspect', '--format', '{{.Id}}', 'image']),
        notice_case(['unknown-command', '--unknown']),
        notice_case(['--remote', 'run', 'image', 'build']),
        notice_case(['-r', 'run', 'image', 'build']),
        notice_case(['-r=false', 'run', 'image', 'pull']),
        notice_case(['--connection', 'connection-value', 'run', 'image', 'push']),
        notice_case(['--url=ssh://operand-value@example.invalid/run/podman.sock',
                     'run', 'image', 'pull']),
        notice_case(['--unknown-global', 'operand', 'build', '.']),
        notice_case(['--remote', 'build', '.'], 'build', contains=('unsupported',)),
        notice_case(['-r', 'build', '.'], 'build',
                    contains=('unsupported', '-r')),
        notice_case(['-r=true', 'image', 'pull',
                     'remote-image-value-must-not-be-reported'],
                    'pull', contains=('unsupported', '-r'),
                    excludes=('remote-image-value-must-not-be-reported',)),
        notice_case(['build', '--help']),
        notice_case(['image', 'build', '--help']),
        notice_case(['build', '--from', 'another-stage-must-not-be-reported', '.'],
                    'build', contains=('--from',),
                    excludes=('another-stage-must-not-be-reported',)),
        notice_case(['build', '--platform', 'linux/arm64-value-must-not-be-reported', '.'],
                    'build', contains=('platform',),
                    excludes=('linux/arm64-value-must-not-be-reported',)),
        notice_case(['build', '--build-arg-file',
                     'PASSWORD=argument-secret-must-not-be-reported', '.'],
                    'build', contains=('--build-arg-file',),
                    excludes=('argument-secret-must-not-be-reported',)),
        notice_case(['build', '--layer-label=TOKEN=equals-secret-must-not-be-reported', '.'],
                    'build', contains=('--layer-label',),
                    excludes=('equals-secret-must-not-be-reported',)),
        notice_case(['build', '--unknown-valid-in-future=equals-value-must-not-be-reported', '.'],
                    'build', contains=('--unknown-valid-in-future',),
                    excludes=('equals-value-must-not-be-reported',)),
        notice_case(['build', '-tcompact-tag-value-must-not-be-reported', '.'],
                    'build', contains=('unsupported',),
                    excludes=('compact-tag-value-must-not-be-reported',)),
        notice_case(['build', '-fcompact-file-value-must-not-be-reported', '.'],
                    'build', contains=('unsupported',),
                    excludes=('compact-file-value-must-not-be-reported',)),
        notice_case(['build', '-'], 'build', contains=('context',)),
        notice_case(['build',
                     'https://user:remote-secret@example.invalid/context.git?token=remote-secret'],
                    'build', contains=('context',),
                    excludes=('remote-secret', 'https://', 'example.invalid')),
        notice_case(['build', '--unknown-valid-in-future',
                     'opaque-value-must-not-be-reported', '.'],
                    'build', contains=('--unknown-valid-in-future',),
                    excludes=('opaque-value-must-not-be-reported',)),
        notice_case(['image', 'build', '--build-arg',
                     'NESTED=nested-secret-must-not-be-reported', '.'],
                    'build', contains=('unsupported',),
                    excludes=('nested-secret-must-not-be-reported',)),
        notice_case(['image', 'push', 'nested-push-value-must-not-be-reported'],
                    'push', contains=('unsupported',),
                    excludes=('nested-push-value-must-not-be-reported',)),
        notice_case(['image', 'pull', 'nested-pull-value-must-not-be-reported'],
                    'pull', contains=('unsupported',),
                    excludes=('nested-pull-value-must-not-be-reported',)),
        notice_case(['--url=ssh://global-secret@example.invalid/run/podman.sock',
                     'image', 'pull', 'global-image-value-must-not-be-reported'],
                    'pull', contains=('unsupported',),
                    excludes=('global-secret', 'ssh://', 'example.invalid',
                              'global-image-value-must-not-be-reported')),
    ]
    report_log = Path.home() / '.local/chalk/chalk.log'
    report_offset = report_log.stat().st_size if report_log.exists() else 0
    for argv in (['help'], ['help', 'build']):
        calls.write_text('')
        quiet_help = subprocess.run([str(wrapper), *argv], env=env,
                                    capture_output=True, timeout=30)
        assert NOTICE_PREFIX not in quiet_help.stderr, (argv, quiet_help)
        assert calls.read_text() == '', (argv, calls.read_text())
        evidence.append({'argv': argv, 'quiet_help': True, 'executions': 0})
    for case in cases:
        argv = case['argv']
        for exit_code in (0, 7, 130, 143):
            env['PODMAN_EXIT'] = str(exit_code)
            calls.write_text('')
            expected = subprocess.run([str(real), *argv], input=b'input\x00\xff\n', env=env, capture_output=True, timeout=30)
            actual = subprocess.run([str(wrapper), *argv], input=b'input\x00\xff\n', env=env, capture_output=True, timeout=30)
            records = [json.loads(line) for line in calls.read_text().splitlines()]
            assert len(records) == 2, (argv, 'expected one native and one wrapped execution', records)
            assert records[0]['argv'] == records[1]['argv'] == argv, (argv, records)
            assert records[0]['env'] == records[1]['env'], (argv, records)
            for key in ('uid', 'gid', 'groups', 'cwd', 'tty_signals', 'ignored_signals', 'signal_mask'):
                assert records[0][key] == records[1][key], (argv, key, records)
            assert (actual.returncode, actual.stdout) == (expected.returncode, expected.stdout), (argv, exit_code, actual)
            if case['operation'] is None:
                assert actual.stderr == expected.stderr, (argv, exit_code, actual)
            else:
                notice, chalk_stderr = assert_skip_notice(actual.stderr, expected.stderr, case)
                assert chalk_stderr == notice, (argv, exit_code, chalk_stderr)
            evidence.append({'argv': argv, 'exit_code': actual.returncode,
                             'notice_operation': case['operation'],
                             'executions': len(records) - 1,
                             'stdout_bytes': len(actual.stdout), 'stderr_bytes': len(actual.stderr)})

    level_case = notice_case(
        ['build', '--build-arg-file', 'LEVEL=level-secret-must-not-be-reported', '.'],
        'build', contains=('--build-arg-file',),
        excludes=('level-secret-must-not-be-reported',),
    )
    for launch in ('direct', 'interposed'):
        for level in ('default', 'trace', 'error', 'none'):
            level_dir = root / f'{launch}-{level}'
            level_dir.mkdir()
            level_env = dict(env, HOME=str(level_dir / 'home'))
            (level_dir / 'home').mkdir()
            if launch == 'direct':
                chalk_args = [] if level == 'default' else [f'--log-level={level}']
                command = [str(binary), *chalk_args, 'podman', *level_case['argv']]
            else:
                if level != 'default':
                    (level_dir / 'chalk.c4m').write_text(f'podman_log_level: "{level}"\n')
                command = [str(wrapper), *level_case['argv']]
            for exit_code in (0, 7):
                level_env['PODMAN_EXIT'] = str(exit_code)
                calls.write_text('')
                actual = subprocess.run(command, cwd=level_dir, env=level_env,
                                        input=b'level-input\x00', capture_output=True,
                                        timeout=30)
                records = [json.loads(line) for line in calls.read_text().splitlines()]
                assert len(records) == 1, (launch, level, exit_code, records)
                assert records[0]['argv'] == level_case['argv'], (launch, level, records)
                assert (actual.returncode, actual.stdout) == (
                    exit_code, b'podman stdout\x00level-input\x00'
                ), (launch, level, exit_code, actual)
                assert_skip_notice(actual.stderr, b'podman stderr\xff', level_case)
                evidence.append({'argv': level_case['argv'], 'launch': launch,
                                 'log_level': level, 'exit_code': actual.returncode,
                                 'notice_operation': 'build', 'executions': 1})

    def inherited_signals():
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGFPE, signal.SIG_IGN)
        signal.signal(signal.SIGTTIN, signal.SIG_IGN)
        signal.signal(signal.SIGTTOU, signal.SIG_IGN)
        signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGUSR1])

    env['PODMAN_EXIT'] = '0'
    for marker in ('', '0001', 'not-a-number'):
        calls.write_text('')
        env['__CHALK_INVOCATIONS__'] = marker
        direct = subprocess.run([str(real), 'inspect', 'image'], env=env, input=b'',
                                capture_output=True, preexec_fn=inherited_signals, timeout=30)
        wrapped = subprocess.run([str(wrapper), 'inspect', 'image'], env=env, input=b'',
                                 capture_output=True, preexec_fn=inherited_signals, timeout=30)
        records = [json.loads(line) for line in calls.read_text().splitlines()]
        assert len(records) == 2, ('inherited state', records)
        for key in ('env', 'tty_signals', 'ignored_signals', 'signal_mask'):
            assert records[0][key] == records[1][key], ('inherited state', key, records)
        assert (direct.returncode, direct.stdout, direct.stderr) == (wrapped.returncode, wrapped.stdout, wrapped.stderr)
        evidence.append({'argv': ['inspect', 'image'], 'inherited_state_preserved': True,
                         'recursion_marker': marker, 'executions': len(records) - 1})
    env.pop('__CHALK_INVOCATIONS__')
    pipe_dir = root / 'pipe-native'
    pipe_dir.mkdir()
    pipe_native = pipe_dir / 'podman'
    pipe_native.write_text('#!/bin/sh\nprintf "called\\n" >> "$PODMAN_CALLS"\nkill -PIPE $$\nprintf "survived\\n"\n')
    pipe_native.chmod(0o755)
    pipe_env = dict(env, PATH=str(wrap_dir) + os.pathsep + str(pipe_dir) + os.pathsep + os.environ['PATH'])
    pipe_env.pop('__CHALK_INVOCATIONS__', None)
    for ignored in (False, True):
        calls.write_text('')
        setup = (lambda: signal.signal(signal.SIGPIPE, signal.SIG_IGN)) if ignored else None
        direct = subprocess.run([str(pipe_native), 'inspect'], env=pipe_env, capture_output=True,
                                preexec_fn=setup, timeout=30)
        wrapped = subprocess.run([str(wrapper), 'inspect'], env=pipe_env, capture_output=True,
                                 preexec_fn=setup, timeout=30)
        assert calls.read_text().splitlines() == ['called', 'called']
        assert (direct.returncode, direct.stdout, direct.stderr) == (wrapped.returncode, wrapped.stdout, wrapped.stderr)
        assert direct.returncode == (0 if ignored else -signal.SIGPIPE)
        evidence.append({'argv': ['inspect'], 'sigpipe_ignored': ignored,
                         'exit_code': wrapped.returncode, 'executions': 1})

    signal_case = notice_case(
        ['build', '--signal-probe=signal-value-must-not-be-reported', '.'],
        'build', contains=('--signal-probe',),
        excludes=('signal-value-must-not-be-reported',),
    )
    for ignored in (False, True):
        calls.write_text('')
        setup = (lambda: signal.signal(signal.SIGPIPE, signal.SIG_IGN)) if ignored else None
        direct = subprocess.run([str(pipe_native), *signal_case['argv']], env=pipe_env,
                                capture_output=True, preexec_fn=setup, timeout=30)
        wrapped = subprocess.run([str(wrapper), *signal_case['argv']], env=pipe_env,
                                 capture_output=True, preexec_fn=setup, timeout=30)
        assert calls.read_text().splitlines() == ['called', 'called']
        assert (direct.returncode, direct.stdout) == (wrapped.returncode, wrapped.stdout)
        assert direct.returncode == (0 if ignored else -signal.SIGPIPE)
        notice, chalk_stderr = assert_skip_notice(wrapped.stderr, direct.stderr, signal_case)
        assert chalk_stderr == notice
        evidence.append({'argv': signal_case['argv'], 'sigpipe_ignored': ignored,
                         'notice_operation': 'build', 'exit_code': wrapped.returncode,
                         'executions': 1})

    writer_case = notice_case(
        ['build', '--writer-probe=writer-value-must-not-be-reported', '.'],
        'build', contains=('--writer-probe',),
        excludes=('writer-value-must-not-be-reported',),
    )
    writer_env = dict(env, PODMAN_EXIT='7', PODMAN_SILENT_STDERR='1')

    def close_stderr():
        os.close(2)

    calls.write_text('')
    closed = subprocess.run(
        [str(binary), '--log-level=none', 'podman', *writer_case['argv']],
        env=writer_env, input=b'', stdout=subprocess.PIPE, preexec_fn=close_stderr,
        timeout=30,
    )
    records = [json.loads(line) for line in calls.read_text().splitlines()]
    assert len(records) == 1 and records[0]['argv'] == writer_case['argv'], records
    assert (closed.returncode, closed.stdout) == (7, b'podman stdout\x00'), closed
    evidence.append({'argv': writer_case['argv'], 'stderr_failure': 'closed',
                     'exit_code': closed.returncode, 'executions': 1})

    calls.write_text('')
    read_fd, write_fd = os.pipe()
    os.close(read_fd)
    try:
        no_reader = subprocess.run(
            [str(wrapper), *writer_case['argv']], env=writer_env, input=b'',
            stdout=subprocess.PIPE, stderr=write_fd, timeout=30,
        )
    finally:
        os.close(write_fd)
    records = [json.loads(line) for line in calls.read_text().splitlines()]
    assert len(records) == 1 and records[0]['argv'] == writer_case['argv'], records
    assert (no_reader.returncode, no_reader.stdout) == (7, b'podman stdout\x00'), no_reader
    evidence.append({'argv': writer_case['argv'], 'stderr_failure': 'no-reader-pipe',
                     'exit_code': no_reader.returncode, 'executions': 1})

    context = root / 'context'
    context.mkdir()
    (root / 'Containerfile').write_text('FROM scratch\nENTRYPOINT ["/cwd-file"]\n')
    (context / 'Containerfile').write_text('FROM scratch\nENTRYPOINT ["/context-file"]\n')
    collision_args = ['build', '--file', 'Containerfile', '--tag', 'test',
                      '--platform', 'linux/amd64', '--format', 'oci', str(context)]
    collision_case = notice_case(
        collision_args, 'build', contains=('outside the build context',),
    )
    calls.write_text('')
    direct = subprocess.run([str(real), *collision_args], cwd=root, env=env, input=b'',
                            capture_output=True, timeout=30)
    wrapped = subprocess.run([str(wrapper), *collision_args], cwd=root, env=env, input=b'',
                             capture_output=True, timeout=30)
    records = [json.loads(line) for line in calls.read_text().splitlines()]
    assert len(records) == 2, ('cwd Containerfile must take precedence without probes', records)
    assert records[0]['argv'] == records[1]['argv'] == collision_args
    assert (direct.returncode, direct.stdout) == (wrapped.returncode, wrapped.stdout)
    notice, chalk_stderr = assert_skip_notice(wrapped.stderr, direct.stderr, collision_case)
    assert chalk_stderr == notice
    evidence.append({'argv': collision_args, 'containerfile_precedence_preserved': True,
                     'notice_operation': 'build', 'executions': len(records) - 1})
    for suffix in ('.containerignore', '.dockerignore'):
        sidecar = context / ('Containerfile' + suffix)
        sidecar.write_text('sensitive-file\n')
        args = ['build', '--file', 'Containerfile', '--tag', 'test',
                '--platform', 'linux/amd64', '--format', 'oci', '.']
        sidecar_case = notice_case(
            args, 'build', contains=('ignore file is unsupported',),
        )
        calls.write_text('')
        direct = subprocess.run([str(real), *args], cwd=context, env=env, input=b'',
                                capture_output=True, timeout=30)
        wrapped = subprocess.run([str(wrapper), *args], cwd=context, env=env, input=b'',
                                 capture_output=True, timeout=30)
        records = [json.loads(line) for line in calls.read_text().splitlines()]
        assert len(records) == 2, ('sidecar ignore must pass through without probes', suffix, records)
        assert records[0]['argv'] == records[1]['argv'] == args
        assert (direct.returncode, direct.stdout) == (wrapped.returncode, wrapped.stdout)
        notice, chalk_stderr = assert_skip_notice(wrapped.stderr, direct.stderr, sidecar_case)
        assert chalk_stderr == notice
        evidence.append({'argv': args, 'sidecar_ignore': suffix,
                         'notice_operation': 'build', 'executions': len(records) - 1})
        sidecar.unlink()
    assert (report_log.stat().st_size if report_log.exists() else 0) == report_offset, 'passthrough emitted a report'
    for sig in (signal.SIGINT, signal.SIGTERM):
        calls.write_text('')
        ready = root / 'ready'
        ready.unlink(missing_ok=True)
        env.update(PODMAN_WAIT='1', PODMAN_READY=str(ready))
        process = subprocess.Popen([str(wrapper), 'run', 'image'], env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 30
            while not ready.exists():
                assert process.poll() is None, process.communicate()
                assert time.monotonic() < deadline, 'wrapped child did not start'
                time.sleep(0.05)
            child_pid = int(ready.read_text())
            process.send_signal(sig)
            process.communicate(timeout=30)
            assert process.returncode in (-sig, 128 + sig), process.returncode
            records = [json.loads(line) for line in calls.read_text().splitlines()]
            assert len(records) == 1, records
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError('child remains after wrapper cancellation')
            assert (report_log.stat().st_size if report_log.exists() else 0) == report_offset, 'cancellation emitted a report'
            evidence.append({'signal': sig.name, 'executions': 1, 'child_reaped': True})
        finally:
            if ready.exists():
                try:
                    os.kill(int(ready.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()

output.write_text(json.dumps({'schema_version': 1, 'source_sha': os.environ.get('CI_COMMIT_SHA'),
                              'cases': evidence, 'passed': True}, indent=2) + '\n')
print(f'{len(evidence)} Podman passthrough cases passed')

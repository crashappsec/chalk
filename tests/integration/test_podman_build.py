#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import time
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
real_podman = shutil.which('podman')
assert real_podman
assert os.geteuid() != 0, 'the report-permission fault requires the rootless fixture user'
out = Path('artifacts/podman/build').resolve()
out.mkdir(parents=True, exist_ok=True)
checks = []
report_log = Path.home() / '.local/chalk/chalk.log'


def reports_since(offset):
    if not report_log.exists():
        return []
    data = report_log.read_text()[offset:]
    decoder = json.JSONDecoder()
    reports = []
    while data.strip():
        value, end = decoder.raw_decode(data.lstrip())
        reports.extend(value if isinstance(value, list) else [value])
        data = data.lstrip()[end:]
    return reports
images = []


def run(argv, *, cwd=None, env=None, timeout=180):
    result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    with (out / 'commands.log').open('a') as log:
        log.write(json.dumps(argv) + '\n' + result.stdout + result.stderr + '\n')
    assert result.returncode == 0, (argv, result.returncode, result.stderr)
    return result.stdout.strip()


def check(name, value):
    checks.append({'name': name, 'passed': bool(value)})
    assert value, name


def snapshot(source):
    return {str(p.relative_to(source)): {
        'mode': p.lstat().st_mode, 'mtime': p.lstat().st_mtime_ns,
        'uid': p.lstat().st_uid, 'gid': p.lstat().st_gid,
        'data': os.readlink(p) if p.is_symlink() else
        hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None,
    } for p in [source, *sorted(source.rglob('*'))]}


try:
    with tempfile.TemporaryDirectory(prefix='chalk-live-podman-') as temp:
        root = Path(temp)
        source = root / 'source'
        source.mkdir()
        containerfile = ('FROM docker.io/library/alpine@sha256:eafc1edb577d2e9b458664a15f23ea1c370214193226069eb22921169fc7e43f\n'
                         'WORKDIR /app\nCOPY . /app/\n'
                         'ENTRYPOINT ["/bin/sh", "/app/app.sh"]\nCMD ["default"]\n')
        (source / 'Containerfile').write_text(containerfile)
        (source / 'app.sh').write_text('test ! -e /app/ignored-secret && test ! -e /app/sidecar-secret || exit 17\nprintf "application %s\\n" "$*"\n')
        (source / 'ignored-secret').write_text('context-secret-must-not-be-copied\n')
        (source / 'chalk').write_text('customer file\n')
        (source / '.containerignore').write_text('ignored-secret\nContainerfile\n.chalk*\n')
        (source / 'link').symlink_to('chalk')
        for file in source.iterdir():
            if not file.is_symlink():
                file.chmod(0o444)
        source.chmod(0o555)
        before = snapshot(source)
        wrapped_dir = root / 'wrapped'
        proxy_dir = root / 'proxy'
        wrapped_dir.mkdir()
        proxy_dir.mkdir()
        (wrapped_dir / 'podman').symlink_to(binary)
        proxy = proxy_dir / 'podman'
        calls = root / 'calls.jsonl'
        proxy.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys, time
from pathlib import Path
with open(os.environ['PODMAN_TEST_CALLS'], 'a') as f:
    f.write(json.dumps({'args': sys.argv[1:], 'pid': os.getpid()}) + '\\n')
if len(sys.argv) > 1 and sys.argv[1] == 'info' and os.environ.get('PODMAN_TEST_INFO_EXIT'):
    sys.exit(int(os.environ['PODMAN_TEST_INFO_EXIT']))
if any(a == '--build-context' or a.startswith('--build-context=') for a in sys.argv) and os.environ.get('PODMAN_TEST_WAIT'):
    ready = Path(os.environ['PODMAN_TEST_READY'])
    ready.with_suffix('.tmp').write_text(str(os.getpid()))
    os.replace(ready.with_suffix('.tmp'), ready)
    while True:
        time.sleep(0.1)
if any(a == '--build-context' or a.startswith('--build-context=') for a in sys.argv) and os.environ.get('PODMAN_TEST_INJECTED_EXIT'):
    sys.exit(int(os.environ['PODMAN_TEST_INJECTED_EXIT']))
if os.environ.get('PODMAN_TEST_REMOVE_IID'):
    result = subprocess.run([os.environ['PODMAN_TEST_REAL'], *sys.argv[1:]])
    iid = next((a.split('=', 1)[1] for a in sys.argv if a.startswith('--iidfile=')), None)
    if '--iidfile' in sys.argv:
        iid = sys.argv[sys.argv.index('--iidfile') + 1]
    if iid and Path(iid).is_file():
        Path(iid).unlink()
        with open(os.environ['PODMAN_TEST_CALLS'], 'a') as f:
            f.write(json.dumps({'args': [], 'stole_iid': True}) + '\\n')
    sys.exit(result.returncode)
os.execv(os.environ['PODMAN_TEST_REAL'], [os.environ['PODMAN_TEST_REAL'], *sys.argv[1:]])
''')
        proxy.chmod(0o755)
        env = dict(os.environ, PATH=str(wrapped_dir) + os.pathsep + str(proxy_dir) + os.pathsep + os.environ['PATH'],
                   PODMAN_TEST_REAL=real_podman, PODMAN_TEST_CALLS=str(calls),
                   PODMAN_TEST_SECRET='environment-secret-must-not-be-reported')
        try:
            for mode in ('ordinary', 'wrapped', 'fallback', 'setup-failure', 'unsupported',
                         'sidecar-containerignore', 'sidecar-dockerignore',
                         'report-failure', 'report-failure-writable', 'postzero'):
                source.chmod(0o755)
                for name in ('Containerfile.containerignore', 'Containerfile.dockerignore', 'sidecar-secret'):
                    (source / name).unlink(missing_ok=True)
                if mode.startswith('sidecar-'):
                    (source / 'sidecar-secret').write_text('excluded-only-by-sidecar\n')
                    (source / ('Containerfile.' + mode.removeprefix('sidecar-'))).write_text(
                        (source / '.containerignore').read_text() + 'sidecar-secret\n')
                    (source / 'sidecar-secret').chmod(0o444)
                    (source / ('Containerfile.' + mode.removeprefix('sidecar-'))).chmod(0o444)
                source.chmod(0o755 if mode == 'report-failure-writable' else 0o555)
                before = snapshot(source)
                tag = 'localhost/chalk-proof-' + mode + ':' + os.environ.get('CI_JOB_ID', str(os.getpid()))
                images.append(tag)
                argv = ['build', '--file', 'Containerfile', '--tag', tag, '--platform', 'linux/amd64', '--format', 'oci', '.']
                if mode == 'unsupported':
                    argv += ['--layer-label', 'PASSWORD=argument-secret-must-not-be-reported']
                calls.write_text('')
                env.pop('PODMAN_TEST_INJECTED_EXIT', None)
                env.pop('PODMAN_TEST_INFO_EXIT', None)
                env.pop('PODMAN_TEST_REMOVE_IID', None)
                if mode == 'postzero':
                    env['PODMAN_TEST_REMOVE_IID'] = '1'
                if mode == 'setup-failure':
                    env['PODMAN_TEST_INFO_EXIT'] = '17'
                if mode == 'fallback':
                    env['PODMAN_TEST_INJECTED_EXIT'] = '17'
                exe = real_podman if mode == 'ordinary' else str(wrapped_dir / 'podman')
                report_offset = len(report_log.read_text()) if report_log.exists() else 0
                if mode.startswith('report-failure'):
                    log_mode = report_log.stat().st_mode & 0o777
                    log_dir_mode = report_log.parent.stat().st_mode & 0o777
                    report_log.chmod(0o444)
                    report_log.parent.chmod(0o555)
                try:
                    run([exe, *argv], cwd=source, env=env)
                finally:
                    if mode.startswith('report-failure'):
                        report_log.parent.chmod(log_dir_mode)
                        report_log.chmod(log_mode)
                reports = reports_since(report_offset)
                records = [json.loads(line) for line in calls.read_text().splitlines()]
                recorded = [record['args'] for record in records]
                if mode == 'postzero':
                    check('postzero IID removed', any(r.get('stole_iid') for r in records))
                builds = [args for args in recorded if args and args[0] == 'build']
                if mode in ('wrapped', 'report-failure', 'report-failure-writable', 'postzero'):
                    check(mode + ' one instrumented build', len(builds) == 1 and '--build-context' in builds[0])
                elif mode == 'fallback':
                    check('one injected attempt and one original retry', len(builds) == 2 and '--build-context' in builds[0] and builds[1] == argv)
                elif mode == 'setup-failure':
                    check('setup failure runs original once', builds == [argv])
                elif mode == 'unsupported' or mode.startswith('sidecar-'):
                    check(mode + ' build passes through once without probes', recorded == [argv])
                    check(mode + ' build emits no report', not reports)
                if mode.startswith('report-failure'):
                    check('report sink failure produced no report', not reports)
                info = json.loads(run([real_podman, 'image', 'inspect', tag]))[0]
                (out / (mode + '-image.json')).write_text(json.dumps(info, indent=2) + '\n')
                entrypoint = info['Config']['Entrypoint']
                if mode in ('wrapped', 'report-failure', 'report-failure-writable', 'postzero'):
                    check(mode + ' Chalk entrypoint', entrypoint[:3] == ['/chalk', 'exec', '--heartbeat'])
                else:
                    check(mode + ' original entrypoint', entrypoint == ['/bin/sh', '/app/app.sh'])
                check(mode + ' default CMD', run([real_podman, 'run', '--rm', tag]) == 'application default')
                check(mode + ' command arguments', run([real_podman, 'run', '--rm', tag, 'one', 'two']) == 'application one two')
                check(mode + ' context unchanged', snapshot(source) == before)
                check(mode + ' filename collision', run([real_podman, 'run', '--rm', '--entrypoint', '/bin/cat', tag, '/app/chalk']) == 'customer file')
                check(mode + ' symlink', run([real_podman, 'run', '--rm', '--entrypoint', '/bin/busybox', tag, 'readlink', '/app/link']) == 'chalk')
                if mode in ('wrapped', 'report-failure', 'report-failure-writable', 'postzero'):
                    mark_text = run([real_podman, 'run', '--rm', '--entrypoint', '/bin/cat', tag, '/chalk.json'])
                    mark = json.loads(mark_text)
                    check(mode + ' image Chalk ID', bool(mark.get('CHALK_ID')))
                    check(mode + ' no secret in mark', env['PODMAN_TEST_SECRET'] not in mark_text)
                    build_reports = [r for r in reports if r.get('_OPERATION') == 'build']
                    artifacts = [a for r in build_reports for a in r.get('_CHALKS', [])]
                    if mode == 'wrapped':
                        installed_sha = run([real_podman, 'run', '--rm', '--entrypoint', '/bin/sh', tag, '-c', 'sha256sum /chalk']).split()[0]
                        check('image contains unchanged generic binary', installed_sha == hashlib.sha256(binary.read_bytes()).hexdigest())
                        check('classified build report matches image', any(
                            a.get('CHALK_ID') == mark['CHALK_ID'] and
                            a.get('_OP_ARTIFACT_TYPE') == 'Podman Image' and
                            a.get('PODMAN_IMAGE_ID', '').removeprefix('sha256:') == info['Id'].removeprefix('sha256:')
                            for a in artifacts))
                    check(mode + ' no secret in build reports', env['PODMAN_TEST_SECRET'] not in json.dumps(reports))
                    (out / (mode + '-build-reports.json')).write_text(json.dumps(build_reports, indent=2) + '\n')
                    (out / (mode + '-mark.json')).write_text(json.dumps(mark, indent=2) + '\n')
                    if mode == 'wrapped' and os.environ.get('CI_JOB_ID'):
                        run([sys.executable, 'tests/integration/test_podman_registry.py', str(binary)])
                else:
                    run([real_podman, 'run', '--rm', '--entrypoint', '/bin/sh', tag, '-c', 'test ! -e /chalk.json && test ! -e /chalk'])

            env.pop('PODMAN_TEST_INFO_EXIT', None)
            env.pop('PODMAN_TEST_REMOVE_IID', None)
            env.pop('PODMAN_TEST_INJECTED_EXIT', None)
            run([sys.executable, str(Path(__file__).with_name('test_podman_startup.py')), str(binary)], timeout=None)
            check('startup inheritance contract', True)
            run([sys.executable, str(Path(__file__).with_name('test_podman_platform.py')), str(binary)], timeout=None)
            check('final-image platform contract', True)
            context_sidecar = root / 'context-sidecar'
            nested = context_sidecar / 'nested'
            nested.mkdir(parents=True)
            (nested / 'Containerfile').write_text(
                'FROM docker.io/library/alpine@sha256:eafc1edb577d2e9b458664a15f23ea1c370214193226069eb22921169fc7e43f\n'
                'WORKDIR /app\nCOPY . /app/\nENTRYPOINT ["/bin/true"]\n')
            (context_sidecar / 'context-sidecar-secret').write_text('must be excluded\n')
            (context_sidecar / 'Containerfile.containerignore').write_text('context-sidecar-secret\n')
            for path in (nested / 'Containerfile', context_sidecar / 'context-sidecar-secret',
                         context_sidecar / 'Containerfile.containerignore'):
                path.chmod(0o444)
            nested.chmod(0o555)
            context_sidecar.chmod(0o555)
            try:
                before = snapshot(context_sidecar)
                tag = ('localhost/chalk-proof-context-sidecar:' +
                       os.environ.get('CI_JOB_ID', str(os.getpid())))
                images.append(tag)
                sidecar_argv = ['build', '--file', 'Containerfile', '--tag', tag,
                                '--platform', 'linux/amd64', '--format', 'oci', '..']
                calls.write_text('')
                report_offset = len(report_log.read_text()) if report_log.exists() else 0
                run([str(wrapped_dir / 'podman'), *sidecar_argv], cwd=nested, env=env)
                records = [json.loads(line) for line in calls.read_text().splitlines()]
                check('context-relative sidecar passes through without probes',
                      [record['args'] for record in records] == [sidecar_argv])
                check('context-relative sidecar emits no report', not reports_since(report_offset))
                info = json.loads(run([real_podman, 'image', 'inspect', tag]))[0]
                check('context-relative sidecar keeps original entrypoint',
                      info['Config']['Entrypoint'] == ['/bin/true'])
                check('context-relative sidecar excludes secret',
                      run([real_podman, 'run', '--rm', '--entrypoint', '/bin/sh', tag,
                           '-c', 'test ! -e /app/context-sidecar-secret']) == '')
                check('context-relative sidecar leaves source unchanged',
                      snapshot(context_sidecar) == before)
            finally:
                context_sidecar.chmod(0o755)
                nested.chmod(0o755)

            env.pop('PODMAN_TEST_INFO_EXIT', None)
            env.pop('PODMAN_TEST_REMOVE_IID', None)
            env.pop('PODMAN_TEST_INJECTED_EXIT', None)
            reserved_cases = [
                ('entrypoint-chalk',
                 'COPY --chmod=0755 app /chalk\nENTRYPOINT ["/chalk"]\nCMD ["default"]\n',
                 {'app': '#!/bin/sh\nprintf "reserved application %s\\n" "$*"\n'}),
                ('occupied-chalk-json',
                 'COPY customer.json /chalk.json\nENTRYPOINT ["/bin/true"]\n',
                 {'customer.json': 'customer json\n'}),
                ('dangling-chalk-symlink',
                 'RUN ln -s /missing /chalk\nENTRYPOINT ["/bin/true"]\n',
                 {}),
            ]
            for name, instructions, files in reserved_cases:
                reserved = root / name
                reserved.mkdir()
                (reserved / 'Containerfile').write_text(
                    'FROM docker.io/library/alpine@sha256:eafc1edb577d2e9b458664a15f23ea1c370214193226069eb22921169fc7e43f\n' +
                    instructions)
                for path, contents in files.items():
                    (reserved / path).write_text(contents)
                for path in reserved.iterdir():
                    path.chmod(0o444)
                reserved.chmod(0o555)
                try:
                    before = snapshot(reserved)
                    tag = ('localhost/chalk-proof-' + name + ':' +
                           os.environ.get('CI_JOB_ID', str(os.getpid())))
                    images.append(tag)
                    reserved_argv = [
                        'build', '--file', 'Containerfile', '--tag', tag,
                        '--platform', 'linux/amd64', '--format', 'oci', '.',
                    ]
                    calls.write_text('')
                    run([str(wrapped_dir / 'podman'), *reserved_argv],
                        cwd=reserved, env=env)
                    records = [json.loads(line) for line in calls.read_text().splitlines()]
                    builds = [record['args'] for record in records
                              if record['args'][:1] == ['build']]
                    check(name + ' injected attempt then one original retry',
                          len(builds) == 2 and '--build-context' in builds[0] and
                          builds[1] == reserved_argv)
                    info = json.loads(run([real_podman, 'image', 'inspect', tag]))[0]
                    if name == 'entrypoint-chalk':
                        check(name + ' preserves application entrypoint',
                              info['Config']['Entrypoint'] == ['/chalk'])
                        check(name + ' preserves application execution',
                              run([real_podman, 'run', '--rm', tag]) ==
                              'reserved application default')
                    elif name == 'occupied-chalk-json':
                        check(name + ' preserves customer file',
                              run([real_podman, 'run', '--rm', '--entrypoint',
                                   '/bin/cat', tag, '/chalk.json']) == 'customer json')
                    else:
                        check(name + ' preserves dangling symlink',
                              run([real_podman, 'run', '--rm', '--entrypoint',
                                   '/bin/busybox', tag, 'readlink', '/chalk']) == '/missing')
                    check(name + ' leaves source unchanged', snapshot(reserved) == before)
                finally:
                    reserved.chmod(0o755)
            env.pop('PODMAN_TEST_INFO_EXIT', None)
            env.pop('PODMAN_TEST_REMOVE_IID', None)
            env.pop('PODMAN_TEST_INJECTED_EXIT', None)
            for exit_code in (130, 143):
                calls.write_text('')
                env['PODMAN_TEST_INJECTED_EXIT'] = str(exit_code)
                report_offset = len(report_log.read_text()) if report_log.exists() else 0
                result = subprocess.run([str(wrapped_dir / 'podman'), *argv], cwd=source,
                                        env=env, capture_output=True, timeout=30)
                check('child cancellation no report ' + str(exit_code), not reports_since(report_offset))
                check('child cancellation exit ' + str(exit_code), result.returncode == exit_code)
                builds = [json.loads(line)['args'] for line in calls.read_text().splitlines()
                          if json.loads(line)['args'][:1] == ['build']]
                check('child cancellation no retry ' + str(exit_code), len(builds) == 1)
            env.pop('PODMAN_TEST_INJECTED_EXIT', None)
            ready = root / 'ready'
            env.update(PODMAN_TEST_WAIT='1', PODMAN_TEST_READY=str(ready))
            for sig in (signal.SIGINT, signal.SIGTERM):
                ready.unlink(missing_ok=True)
                calls.write_text('')
                report_offset = len(report_log.read_text()) if report_log.exists() else 0
                process = subprocess.Popen([str(wrapped_dir / 'podman'), *argv], cwd=source, env=env,
                                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, start_new_session=True)
                try:
                    deadline = time.monotonic() + 30
                    while not ready.exists():
                        assert process.poll() is None, process.communicate()
                        assert time.monotonic() < deadline, 'instrumented child did not start'
                        time.sleep(0.05)
                    child_pid = int(ready.read_text())
                    process.send_signal(sig)
                    process.communicate(timeout=30)
                    check(sig.name + ' no report', not reports_since(report_offset))
                    check(sig.name + ' exit', process.returncode in (-sig, 128 + sig))
                    recorded = [json.loads(line)['args'] for line in calls.read_text().splitlines()]
                    builds = [args for args in recorded if args and args[0] == 'build']
                    check(sig.name + ' no fallback', len(builds) == 1)
                    try:
                        os.kill(child_pid, 0)
                    except ProcessLookupError:
                        check(sig.name + ' child reaped', True)
                    else:
                        check(sig.name + ' child reaped', False)
                finally:
                    if ready.exists():
                        try:
                            os.kill(int(ready.read_text()), signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                        try:
                            os.killpg(int(ready.read_text()), signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
        finally:
            source.chmod(0o755)
finally:
    for tag in images:
        subprocess.run([real_podman, 'image', 'rm', '-f', tag], capture_output=True)
    (out / 'evidence.json').write_text(json.dumps({'schema_version': 1,
        'source_sha': os.environ.get('CI_COMMIT_SHA'), 'checks': checks,
        'passed': sys.exc_info()[0] is None}, indent=2) + '\n')

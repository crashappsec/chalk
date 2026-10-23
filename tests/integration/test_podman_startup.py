#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1]).resolve()
podman = shutil.which('podman')
assert podman
out = Path('artifacts/podman/startup').resolve()
out.mkdir(parents=True, exist_ok=True)
checks = []
observations = []
images = []
suffix = str(os.getpid())
alpine = 'docker.io/library/alpine@sha256:eafc1edb577d2e9b458664a15f23ea1c370214193226069eb22921169fc7e43f'


def invoke(argv, *, cwd=None, env=None, require_success=True):
    started = time.monotonic()
    result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True,
                            text=True, timeout=180)
    elapsed = time.monotonic() - started
    with (out / 'commands.jsonl').open('a') as log:
        log.write(json.dumps({'argv': argv, 'exit': result.returncode,
                              'stdout': result.stdout, 'stderr': result.stderr,
                              'elapsed_seconds': elapsed}) + '\n')
    if require_success:
        assert result.returncode == 0, (argv, result.stderr)
    return result, elapsed


def check(name, condition):
    checks.append({'name': name, 'passed': bool(condition)})
    assert condition, name


def inspect(tag):
    result, _ = invoke([podman, 'image', 'inspect', tag])
    return json.loads(result.stdout)[0]


def tag(name):
    value = 'localhost/chalk-startup-' + name + ':' + suffix
    images.append(value)
    return value


try:
    with tempfile.TemporaryDirectory(prefix='chalk-startup-') as temp:
        root = Path(temp)
        wrapped = root / 'wrapped'
        proxy_dir = root / 'proxy'
        wrapped.mkdir()
        proxy_dir.mkdir()
        (wrapped / 'podman').symlink_to(binary)
        calls = root / 'calls.jsonl'
        proxy = proxy_dir / 'podman'
        proxy.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['PODMAN_STARTUP_CALLS'], 'a') as output:
    output.write(json.dumps(sys.argv[1:]) + '\\n')
os.execv(os.environ['PODMAN_STARTUP_REAL'], [os.environ['PODMAN_STARTUP_REAL'], *sys.argv[1:]])
''')
        proxy.chmod(0o755)
        env = dict(os.environ, PATH=str(wrapped) + os.pathsep + str(proxy_dir) +
                   os.pathsep + os.environ['PATH'], PODMAN_STARTUP_REAL=podman,
                   PODMAN_STARTUP_CALLS=str(calls))
        context = root / 'context'
        context.mkdir()
        (context / 'start.sh').write_text('printf "application <%s>\\n" "$*"\n')
        base = tag('base')
        (context / 'Containerfile').write_text(
            f'FROM {alpine}\nCOPY start.sh /start.sh\n'
            'ENTRYPOINT ["/bin/sh", "/start.sh"]\nCMD ["base"]\n'
            'SHELL ["/bin/sh", "-e", "-c"]\n')
        invoke([podman, 'build', '--format', 'docker', '-t', base, '.'], cwd=context)
        cases = [
            ('direct', f'FROM {base}\nCMD ["direct"]\n'),
            ('stage', f'FROM {base} AS base\nFROM base\nCMD ["stage"]\n'),
            ('transitive', f'FROM {base} AS base\nFROM base AS middle\nFROM middle\n'),
            ('cmd-before-entry', f'FROM {base} AS base\nCMD ["retained"]\n'
             'ENTRYPOINT ["/bin/sh", "/start.sh"]\nFROM base\n'),
            ('cmd-after-entry', f'FROM {base} AS base\nENTRYPOINT ["/bin/sh", "/start.sh"]\n'
             'CMD ["retained"]\nFROM base\n'),
            ('clear-inherited-cmd', f'FROM {base} AS base\nFROM base\n'
             'ENTRYPOINT ["/bin/sh", "/start.sh"]\n'),
            ('empty-cmd-before-entry', f'FROM {base}\nCMD []\n'
             'ENTRYPOINT ["/bin/sh", "/start.sh"]\n'),
            ('cmd-only', f'FROM {alpine}\nCMD ["/bin/echo", "cmd-only"]\n'),
            ('shell-entry', f'FROM {base} AS base\nENTRYPOINT echo shell-entry\n'
             'FROM base\nSHELL ["/bin/sh", "-x", "-c"]\n'),
            ('shell-cmd', f'FROM {alpine} AS base\nSHELL ["/bin/sh", "-e", "-c"]\n'
             'CMD echo shell-cmd\nFROM base\nSHELL ["/bin/sh", "-x", "-c"]\n'),
            ('shell-same-stage', f'FROM {alpine}\nSHELL ["/bin/sh", "-e", "-c"]\n'
             'CMD echo shell-before-change\nSHELL ["/bin/sh", "-x", "-c"]\n'),
            ('shell-inherited', f'FROM {base}\nENTRYPOINT echo inherited-shell\n'),
            ('nonzero', f'FROM {alpine}\nENTRYPOINT ["/bin/sh", "-c", "echo failure; exit 23"]\n'),
        ]
        wrapped_base = None
        for name, contents in cases + [('already-wrapped', '')]:
            if name == 'already-wrapped':
                contents = f'FROM {wrapped_base} AS base\nFROM base\nCMD ["rechalk"]\n'
            (context / 'Containerfile').write_text(contents)
            native_tag = tag(name + '-native')
            wrapped_tag = tag(name + '-wrapped')
            invoke([podman, 'build', '-t', native_tag, '.'], cwd=context)
            calls.write_text('')
            _, elapsed = invoke([str(wrapped / 'podman'), 'build', '-t', wrapped_tag, '.'],
                                cwd=context, env=env)
            recorded = [json.loads(line) for line in calls.read_text().splitlines()]
            builds = [args for args in recorded if args and args[0] == 'build']
            check(name + ' instrumented once', len(builds) == 1 and '--build-context' in builds[0])
            root_inspections = [args for args in recorded
                                if args[:2] == ['image', 'inspect'] and args[-2:] == ['--format', 'json']]
            check(name + ' root lookup count', len(root_inspections) == 1)
            native = inspect(native_tag)['Config']
            actual = inspect(wrapped_tag)['Config']
            entry = actual.get('Entrypoint') or []
            check(name + ' Chalk entrypoint', entry[:3] == ['/chalk', 'exec', '--heartbeat'])
            expected_entry = native.get('Entrypoint') or []
            if name == 'already-wrapped':
                check(name + ' no double wrapper', entry == expected_entry)
            else:
                application_entry = entry[entry.index('--') + 1:]
                if '--exec-command-name' in entry:
                    application_entry = [entry[entry.index('--exec-command-name') + 1], *application_entry]
                check(name + ' application entrypoint', application_entry == expected_entry)
            check(name + ' CMD parity', (actual.get('Cmd') or []) == (native.get('Cmd') or []))
            for label, args in [('default', []), ('override', ['/bin/echo', 'override'])]:
                original, _ = invoke([podman, 'run', '--rm', '--network=none', native_tag, *args],
                                     require_success=False)
                instrumented, _ = invoke([podman, 'run', '--rm', '--network=none', wrapped_tag, *args],
                                         require_success=False)
                check(name + ' ' + label + ' startup parity',
                      (instrumented.returncode, instrumented.stdout) ==
                      (original.returncode, original.stdout))
                check(name + ' ' + label + ' application ran', bool(original.stdout.strip()))
            mark_result, _ = invoke([podman, 'run', '--rm', '--network=none', '--entrypoint',
                                     '/bin/cat', wrapped_tag, '/chalk.json'])
            mark = json.loads(mark_result.stdout)
            check(name + ' image mark', bool(mark.get('CHALK_ID')))
            observations.append({'case': name, 'native_config': native, 'wrapped_config': actual,
                                 'calls': recorded, 'build_seconds': elapsed,
                                 'chalk_id': mark['CHALK_ID']})
            if name == 'direct':
                wrapped_base = wrapped_tag
finally:
    for image in reversed(images):
        subprocess.run([podman, 'image', 'rm', '-f', image], capture_output=True)
    (out / 'evidence.json').write_text(json.dumps({
        'schema_version': 1, 'source_sha': os.environ.get('CI_COMMIT_SHA'),
        'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'checks': checks, 'observations': observations,
        'passed': sys.exc_info()[0] is None,
    }, indent=2) + '\n')

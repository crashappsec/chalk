#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
real = shutil.which('podman')
assert real
out = Path('artifacts/podman/registry')
out.mkdir(parents=True, exist_ok=True)
checks = []


def check(name, value):
    checks.append({'name': name, 'passed': bool(value)})
    assert value, name


try:
    image = json.loads(Path('artifacts/podman/build/wrapped-image.json').read_text())
    mark = json.loads(Path('artifacts/podman/build/wrapped-mark.json').read_text())
    repository = os.environ['CI_REGISTRY_IMAGE'] + '/podman-contract'
    tag = repository + ':' + os.environ['CI_COMMIT_SHA'] + '-' + os.environ['CI_JOB_ID']
    with tempfile.TemporaryDirectory(prefix='chalk-podman-registry-') as temp:
        root = Path(temp)
        wrapper_dir = root / 'wrapped'
        real_dir = root / 'real'
        wrapper_dir.mkdir()
        real_dir.mkdir()
        (wrapper_dir / 'podman').symlink_to(binary)
        calls = root / 'calls.jsonl'
        (real_dir / 'podman').write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['REGISTRY_CALLS'], 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
os.execv(os.environ['REGISTRY_REAL'], [os.environ['REGISTRY_REAL'], *sys.argv[1:]])
''')
        (real_dir / 'podman').chmod(0o755)
        env = dict(os.environ, PATH=str(wrapper_dir) + os.pathsep + str(real_dir) + os.pathsep + os.environ['PATH'],
                   REGISTRY_CALLS=str(calls), REGISTRY_REAL=real)
        expected_calls = []

        def run(args, *, input=None):
            expected_calls.append(args)
            result = subprocess.run([str(wrapper_dir / 'podman'), *args], env=env,
                                    input=input, capture_output=True, text=True, timeout=180)
            check(args[0] + ' exit zero', result.returncode == 0)
            return result.stdout

        run(['login', '--username', os.environ['CI_REGISTRY_USER'], '--password-stdin', os.environ['CI_REGISTRY']],
            input=os.environ['CI_REGISTRY_PASSWORD'])
        run(['tag', image['Id'], tag])
        digest_file = root / 'digest'
        run(['push', '--digestfile', str(digest_file), tag])
        digest = digest_file.read_text().strip()
        check('registry digest format', len(digest) == 71 and digest.startswith('sha256:') and
              all(c in '0123456789abcdef' for c in digest[7:]))
        reference = repository + '@' + digest
        run(['pull', reference])
        pull_calls = [json.loads(line) for line in calls.read_text().splitlines()]
        mark_copies = [args for args in pull_calls if args[0] == 'cp']
        check('pull extracts one image mark', len(mark_copies) == 1 and len(mark_copies[0]) == 3)
        container_id, mark_path = mark_copies[0][1].split(':', 1)
        check('pull extracts the Chalk mark', mark_path == '/chalk.json' and
              len(container_id) == 64 and all(c in '0123456789abcdef' for c in container_id))
        expected_calls.extend([
            ['image', 'inspect', reference, '--format', 'json'],
            ['create', reference],
            ['cp', container_id + ':/chalk.json', mark_copies[0][2]],
            ['rm', '--force', container_id],
            ['image', 'inspect', reference, '--format', 'json'],
        ])
        pulled = json.loads(run(['image', 'inspect', reference]))[0]
        check('registry digest integrity', pulled['Digest'] == digest)
        installed_mark = json.loads(run(['run', '--rm', '--entrypoint', '/bin/cat', reference, '/chalk.json']))
        check('registry image retains Chalk ID', installed_mark['CHALK_ID'] == mark['CHALK_ID'])
        actual_calls = [json.loads(line) for line in calls.read_text().splitlines()]
        check('registry commands and pull inspection run in order exactly once', actual_calls == expected_calls)
        (out / 'image.json').write_text(json.dumps({'reference': reference, 'digest': digest,
            'chalk_id': mark['CHALK_ID'], 'image_id': pulled['Id']}, indent=2) + '\n')
finally:
    (out / 'evidence.json').write_text(json.dumps({'schema_version': 1,
        'source_sha': os.environ.get('CI_COMMIT_SHA'), 'checks': checks,
        'passed': sys.exc_info()[0] is None}, indent=2) + '\n')

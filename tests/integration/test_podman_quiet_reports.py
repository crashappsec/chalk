#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


binary = Path(sys.argv[1]).resolve()
image_id = 'a' * 64
gitlab_report_pattern = re.compile(
    r'\x1b\[0Ksection_start:(?P<timestamp>[0-9]+):'
    r'chalk_report\[collapsed=true\]\n'
    r'\x1b\[0KChalk Report\n'
    r'(?P<report>\[.*\])\n'
    r'\x1b\[0Ksection_end:(?P=timestamp):chalk_report\n'
    r'\x1b\[0K\n?',
    re.DOTALL,
)

fake_podman = f'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

argv = sys.argv[1:]
with Path(os.environ['PODMAN_CALLS']).open('a') as stream:
    stream.write(json.dumps(argv) + '\\n')

if argv == ['info', '--format', 'json']:
    sys.stderr.write('host inspection failed\\n')
    sys.exit(51)

if argv and argv[0] == 'build':
    quiet = False
    for arg in argv[1:]:
        if arg in ('-q', '--quiet'):
            quiet = True
        elif arg.startswith('-q=') or arg.startswith('--quiet='):
            quiet = arg.split('=', 1)[1].lower() == 'true'
    if quiet:
        sys.stdout.write('{image_id}\\n')
    else:
        sys.stdout.write('native build output\\n')
    sys.stderr.write('native build stderr\\n')
    sys.exit(0)

sys.stderr.write('unexpected fake Podman invocation: ' + repr(argv) + '\\n')
sys.exit(99)
'''


def extract_gitlab_reports(output):
    matches = list(gitlab_report_pattern.finditer(output))
    assert len(matches) == 1, output
    reports = json.loads(matches[0].group('report'))
    assert len(reports) == 1, reports
    assert reports[0].get('_OPERATION') == 'build', reports
    assert reports[0].get('_OP_CHALK_COUNT') == 0, reports
    return reports


with tempfile.TemporaryDirectory(prefix='podman-quiet-reports-') as temp:
    root = Path(temp)
    real_dir = root / 'real'
    home = root / 'home'
    context = root / 'context'
    for directory in (real_dir, home, context):
        directory.mkdir()
    (context / 'Containerfile').write_text(
        'FROM scratch\nENTRYPOINT ["/bin/true"]\n'
    )
    real = real_dir / 'podman'
    real.write_text(fake_podman)
    real.chmod(0o755)
    calls = root / 'calls.jsonl'
    calls.write_text('')
    env = dict(
        os.environ,
        CI='true',
        GITLAB_CI='true',
        HOME=str(home),
        PATH=str(real_dir) + os.pathsep + os.environ['PATH'],
        PODMAN_CALLS=str(calls),
    )

    def run(args):
        calls.write_text('')
        result = subprocess.run(
            [str(binary), '--no-use-external-config', '--no-color',
             '--log-level=none', 'podman', 'build', *args, '.'],
            cwd=context,
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        seen = [json.loads(line) for line in calls.read_text().splitlines()]
        assert result.returncode == 0, result
        assert seen == [
            ['info', '--format', 'json'],
            ['build', *args, '.'],
        ], seen
        return result

    for quiet_arg in ('-q', '--quiet', '-q=true', '--quiet=TRUE'):
        quiet = run([quiet_arg])
        assert quiet.stdout == image_id + '\n', (quiet_arg, quiet.stdout)
        extract_gitlab_reports(quiet.stderr)
        assert not gitlab_report_pattern.search(quiet.stdout), quiet.stdout

    nonquiet = run([])
    assert nonquiet.stdout.startswith('native build output\n'), nonquiet.stdout
    extract_gitlab_reports(nonquiet.stdout)
    assert not gitlab_report_pattern.search(nonquiet.stderr), nonquiet.stderr

    quiet_false = run(['--quiet=false'])
    assert quiet_false.stdout.startswith('native build output\n'), quiet_false.stdout
    extract_gitlab_reports(quiet_false.stdout)
    assert not gitlab_report_pattern.search(quiet_false.stderr), quiet_false.stderr

print('Podman quiet report routing passed')

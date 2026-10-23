#!/usr/bin/env python3
"""Regression test for how chalk finds the genuine podman behind itself.

When chalk is interposed as `podman`, resolvePodmanExe must skip the chalk
binary and fall through to the real command. It does that by sub-scanning each
PATH candidate and rejecting ones that are chalk.

That sub-scan used to examine the path as found, so a chalk binary reached
through a SYMLINK was not recognised: findExePath handed it back as if it were
the real podman, and the sameFile backstop in src/podman/run.nim turned that
into exit 127. The whole integration suite installs its wrapper with
symlink_to, so nothing could pass.

Three layouts are checked because they fail differently:

  copy              what setup.sh installs -- was already working
  symlink           what the test fixtures install -- was exit 127
  symlink -> copy   rules out the read-only bind mount as the cause

Each must reach the genuine command exactly once, and chalk must never exec
itself.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
assert binary.is_file(), binary
out = Path('artifacts/podman/exe-resolution')
out.mkdir(parents=True, exist_ok=True)
checks = []


def check(name, value):
    checks.append({'name': name, 'passed': bool(value)})
    assert value, name


with tempfile.TemporaryDirectory(prefix='chalk-exe-resolution-') as temp:
    root = Path(temp)
    real_dir = root / 'real'
    real_dir.mkdir()
    calls = root / 'calls.jsonl'

    # Stands in for the genuine podman. Records that it ran, so "chalk fell
    # through correctly" is observable rather than inferred from an exit code.
    real = real_dir / 'podman'
    real.write_text(
        '#!/usr/bin/env python3\n'
        'import json, os, sys\n'
        "with open(os.environ['EXE_RESOLUTION_CALLS'], 'a') as f:\n"
        "    f.write(json.dumps({'argv': sys.argv[1:]}) + '\\n')\n"
        'print("genuine-podman")\n'
    )
    real.chmod(0o755)

    layouts = {}
    for name in ('copy', 'symlink', 'link_to_copy'):
        wrap = root / ('wrap_' + name)
        wrap.mkdir()
        # Only ever chmod a real file. chmod on a symlink follows it, and the
        # binary under test may be a read-only mount.
        if name == 'copy':
            shutil.copy2(binary, wrap / 'podman')
            (wrap / 'podman').chmod(0o755)
        elif name == 'symlink':
            (wrap / 'podman').symlink_to(binary)
        else:
            local = root / 'local_copy_podman'
            if not local.exists():
                shutil.copy2(binary, local)
                local.chmod(0o755)
            (wrap / 'podman').symlink_to(local)
        layouts[name] = wrap

    results = {}
    for name, wrap in layouts.items():
        calls.write_text('')
        env = dict(
            os.environ,
            PATH=f'{wrap}{os.pathsep}{real_dir}{os.pathsep}' + os.environ['PATH'],
            EXE_RESOLUTION_CALLS=str(calls),
        )
        # --version is a pass-through: chalk must hand it to the real command.
        # A timeout here is itself a failure -- it means chalk exec'd itself.
        try:
            proc = subprocess.run([str(wrap / 'podman'), '--version'],
                                  env=env, capture_output=True, text=True,
                                  timeout=60)
            timed_out = False
        except subprocess.TimeoutExpired:
            proc = None
            timed_out = True

        records = [json.loads(line) for line in calls.read_text().splitlines()]
        results[name] = {
            'timed_out': timed_out,
            'returncode': None if proc is None else proc.returncode,
            'genuine_executions': len(records),
            'stdout': '' if proc is None else proc.stdout.strip(),
        }

        check(f'{name}: did not hang (chalk did not exec itself)', not timed_out)
        check(f'{name}: exited 0, not 127 "no command found"',
              proc is not None and proc.returncode == 0)
        check(f'{name}: reached the genuine podman exactly once',
              len(records) == 1)
        check(f'{name}: genuine podman produced the output',
              proc is not None and 'genuine-podman' in proc.stdout)

(out / 'evidence.json').write_text(json.dumps({
    'schema_version': 1,
    'source_sha': os.environ.get('CI_COMMIT_SHA'),
    'binary_sha256': __import__('hashlib').sha256(binary.read_bytes()).hexdigest(),
    'results': results,
    'checks': checks,
    'passed': all(c['passed'] for c in checks),
}, indent=2) + '\n')

print(f'exe resolution: {len(checks)} checks passed across {len(layouts)} layouts')

#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import sys

binary = Path(sys.argv[1]).resolve()
out = Path('artifacts/podman/sbom').resolve()
out.mkdir(parents=True, exist_ok=True)


def invoke(argv):
    result = subprocess.run(
        [argv[0], '--no-use-external-config', *argv[1:]],
        capture_output=True, text=True, timeout=60,
    )
    with (out / 'commands.jsonl').open('a') as log:
        log.write(json.dumps({'argv': argv, 'exit': result.returncode,
                              'stdout': result.stdout,
                              'stderr': result.stderr}) + '\n')
    return result


def main():
    usage = invoke([str(binary), 'extract', 'podman'])
    assert usage.returncode != 0
    assert 'requires --image' in usage.stderr or 'requires --image' in usage.stdout

    missing_digest = invoke([
        str(binary), 'extract', 'podman', '--image', 'img',
        '--registry-reference', 'example.com/repo:tag',
    ])
    assert missing_digest.returncode != 0

    short_digest = invoke([
        str(binary), 'extract', 'podman', '--image', 'img',
        '--registry-reference', 'example.com/repo@sha256:abcd',
    ])
    assert short_digest.returncode != 0

    sha512 = invoke([
        str(binary), 'extract', 'podman', '--image', 'img',
        '--registry-reference',
        'example.com/repo@sha512:' + ('a' * 64),
    ])
    assert sha512.returncode != 0

    bad_attachment = invoke([
        str(binary), 'extract', 'podman', '--image', 'img',
        '--registry-reference',
        'example.com/repo@sha256:' + ('a' * 64),
        '--sbom-attachment', 'sha256:xyz',
    ])
    assert bad_attachment.returncode != 0


if __name__ == '__main__':
    main()

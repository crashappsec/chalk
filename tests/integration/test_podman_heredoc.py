#!/usr/bin/env python3
"""Heredoc recipes reach the native engine unchanged, without injected files."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="podman-heredoc-") as directory:
    root = Path(directory)
    engine = root / "bin"
    engine.mkdir()
    ledger = root / "calls.jsonl"
    executable = engine / "podman"
    executable.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['PODMAN_HEREDOC_LEDGER'], 'a') as stream:
    stream.write(json.dumps(args) + '\\n')
if args == ['info', '--format', 'json']:
    print(json.dumps({'host': {'os': 'linux', 'arch': 'amd64',
          'serviceIsRemote': False, 'buildahVersion': '1.45.2'},
          'version': {'Version': '6.1.4'}}))
elif args and args[0] == 'build':
    sys.stdout.buffer.write(b'native stdout\\x00\\n')
    sys.stderr.buffer.write(b'native stderr\\xff\\n')
    sys.exit(17)
else:
    sys.exit(99)
""")
    executable.chmod(0o755)
    for instruction in ("RUN", "COPY"):
        for target in ([], ["--target", "selected"]):
            recipe = root / "Containerfile"
            contents = (
                f"FROM scratch AS selected\n{instruction} <<'EOF'\n"
                'FROM forged\nUSER forged\nCMD ["forged"]\n'
                'ENTRYPOINT ["forged"]\nEOF\n'
            )
            recipe.write_text(contents)
            ledger.write_text("")
            args = ["build", *target, "-f", str(recipe), str(root)]
            env = dict(
                os.environ,
                HOME=str(root),
                PATH=str(engine) + os.pathsep + os.environ["PATH"],
                PODMAN_HEREDOC_LEDGER=str(ledger),
            )
            result = subprocess.run(
                [
                    str(binary),
                    "--no-use-external-config",
                    "--skip-command-report",
                    "--skip-custom-reports",
                    "--no-color",
                    "--log-level=none",
                    "podman",
                    *args,
                ],
                env=env,
                cwd=root,
                capture_output=True,
                timeout=30,
            )
            calls = [json.loads(line) for line in ledger.read_text().splitlines()]
            assert result.returncode == 17, (instruction, target, result.returncode)
            assert calls == [args], calls
            assert result.stdout == b"native stdout\x00\n", result.stdout
            assert b"native stderr\xff\n" in result.stderr, result.stderr
            assert recipe.read_text() == contents
            assert sorted(path.name for path in root.iterdir()) == [
                "Containerfile",
                "bin",
                "calls.jsonl",
            ], list(root.iterdir())
print("4 Podman heredoc native pass-through cases passed")

#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
cd "$root"
mkdir -p .developer-diagnostics

make nimble.paths

for test in \
  tests/unit/test_podman.nim \
  tests/unit/test_podman_guard.nim \
  tests/unit/test_podman_exec.nim \
  tests/unit/test_podman_image.nim \
  tests/unit/test_podman_base_binding.nim \
  tests/unit/test_podman_repo_projection.nim
do
  make unit-tests args="--verbose pattern $test"
done

if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y build-essential
  else
    printf 'developer regressions: cc is required for tests/unit/test_podman_run.py\n' >&2
    exit 1
  fi
fi
python3 tests/unit/test_podman_run.py

docker compose run --rm --no-deps chalk nimble build -y
test -x chalk
python3 tests/integration/test_podman_input_notices.py "$root/chalk"

docker compose run --rm --no-deps chalk \
  nim c -d:debug --opt:none \
  --nimcache:.developer-diagnostics/diagnostic-cache \
  --passC:-Isrc \
  --compile:tests/integration/podman_launch_wrap.c \
  --passL:-Wl,--wrap=chalk_podman_run_attached \
  --out:.developer-diagnostics/chalk-diagnostic \
  src/chalk.nim
docker compose run --rm --no-deps chalk \
  nim c -d:debug --opt:none \
  --out:.developer-diagnostics/docker-build-status \
  tests/integration/docker_build_status.nim
docker compose run --rm --no-deps chalk \
  nim c \
  --out:.developer-diagnostics/signing-provider-diagnostic \
  tests/integration/stage02_provider.nim

export CHALK_BINARY=$root/chalk
export CHALK_DIAGNOSTIC=$root/.developer-diagnostics/chalk-diagnostic
export DOCKER_BUILD_STATUS=$root/.developer-diagnostics/docker-build-status
export SIGNING_PROVIDER=$root/.developer-diagnostics/signing-provider-diagnostic
export SOURCE_SHA=$(git rev-parse HEAD)
python3 - <<'IDENTITY'
import hashlib, json, os, subprocess
from pathlib import Path
out = Path('.developer-diagnostics/evidence')
out.mkdir(parents=True, exist_ok=True)
record = {'source': os.environ['SOURCE_SHA'], 'sha256': hashlib.sha256(Path('chalk').read_bytes()).hexdigest(),
          'dependencies': {name: subprocess.check_output(['git', '-C', '../'+name, 'rev-parse', 'HEAD'], text=True).strip()
                           for name in ('con4m', 'nimutils')},
          'helpers': {name: hashlib.sha256(Path(path).read_bytes()).hexdigest()
                      for name, path in [('chalk-diagnostic', os.environ['CHALK_DIAGNOSTIC']),
                                         ('docker-build-status', os.environ['DOCKER_BUILD_STATUS']),
                                         ('signing-provider', os.environ['SIGNING_PROVIDER'])]}}
(out / 'build-identity.json').write_text(json.dumps(record, indent=2)+'\n')
IDENTITY

python3 tests/integration/test_signing_provider.py

engine_env=$root/.developer-diagnostics/engines.env
tests/integration/install-pinned-engines.sh "$engine_env"
. "$engine_env"

python3 tests/integration/test_build_outcomes.py podman
python3 tests/integration/test_build_outcomes.py docker
python3 tests/integration/test_simulated_selector.py

status=$(git status --porcelain --untracked-files=no)
if [ -n "$status" ]; then
  printf '%s\n' "$status" >&2
  printf 'developer regressions: tracked source changed\n' >&2
  exit 1
fi

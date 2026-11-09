#!/bin/sh
set -eu

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  printf 'usage: %s <env-file>\n' "$0" >&2
  exit 2
fi

env_file=$1
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
prefix=$root/.developer-diagnostics/podman-6.1.4
archive_dir=$root/.developer-diagnostics/podman-archive
mkdir -p "$archive_dir"

machine=$(uname -m)
case $machine in
  x86_64|amd64)
    archive_arch=amd64
    archive_sha=9dd51073fac5a1742f88cf3caff5554615cb4d67ba554d25e8807be635547af5
    ;;
  aarch64|arm64)
    archive_arch=arm64
    archive_sha=c106d09d7524209ce01eb3a02a7e621e9c55ec31d0fada48439cf77aa07afdb6
    ;;
  *)
    printf 'pinned podman: unsupported machine %s\n' "$machine" >&2
    exit 2
    ;;
esac

archive=$archive_dir/podman-linux-$archive_arch.tar.gz
url=https://github.com/mgoltzsche/podman-static/releases/download/v6.1.4/podman-linux-$archive_arch.tar.gz
if [ ! -f "$archive" ]; then
  curl --fail --location --silent --show-error --output "$archive" "$url"
fi
got=$(sha256sum "$archive" | awk '{print $1}')
if [ "$got" != "$archive_sha" ]; then
  printf 'pinned podman: checksum mismatch for %s\n' "$archive" >&2
  exit 1
fi

rm -rf "$prefix"
mkdir -p "$prefix"
tar -xzf "$archive" -C "$prefix" --strip-components=1

bin_dir=$prefix/usr/local/bin
podman=$bin_dir/podman
if [ ! -x "$podman" ]; then
  printf 'pinned podman: archive has no usr/local/bin/podman\n' >&2
  exit 1
fi

conf=$prefix/etc/containers/containers.conf
mkdir -p "$(dirname "$conf")" "$prefix/usr/local/libexec/podman" "$prefix/usr/local/lib/podman"
cat > "$conf" <<EOF
[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
helper_binaries_dir = ["$prefix/usr/local/libexec/podman", "$prefix/usr/local/lib/podman", "$bin_dir"]
EOF

runtime=${XDG_RUNTIME_DIR:-}
if [ -z "$runtime" ]; then
  runtime=/tmp/podman-runtime-$(id -u)
fi
mkdir -p "$runtime"
chmod 700 "$runtime"

user_name=$(id -un)
if ! grep -q "^${user_name}:" /etc/subuid 2>/dev/null || ! grep -q "^${user_name}:" /etc/subgid 2>/dev/null; then
  if [ "$(id -u)" -eq 0 ]; then
    printf '%s:200000:65536\n' "$user_name" >> /etc/subuid
    printf '%s:200000:65536\n' "$user_name" >> /etc/subgid
  elif command -v sudo >/dev/null 2>&1; then
    sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 "$user_name"
  else
    printf 'pinned podman: %s has no subuid range\n' "$user_name" >&2
    exit 1
  fi
fi

if ! command -v newuidmap >/dev/null 2>&1; then
  if [ "$(id -u)" -eq 0 ]; then
    apt-get update
    apt-get install -y uidmap
  elif command -v sudo >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y uidmap
  else
    printf 'pinned podman: newuidmap is required\n' >&2
    exit 1
  fi
fi

PATH=$bin_dir:$PATH \
CONTAINERS_CONF=$conf \
XDG_RUNTIME_DIR=$runtime \
python3 - "$podman" "$root/.developer-diagnostics/evidence/engine.json" <<'PY'
import json, os, subprocess, sys
from pathlib import Path
podman = sys.argv[1]
output = Path(sys.argv[2])
output.parent.mkdir(parents=True, exist_ok=True)
evidence = {'machine': os.uname().machine, 'uid': os.getuid(), 'commands': []}
def probe(args):
    result = subprocess.run(args, capture_output=True, text=True)
    evidence['commands'].append({'args': args, 'status': result.returncode,
                                 'stdout': result.stdout, 'stderr': result.stderr})
    output.write_text(json.dumps(evidence, indent=2)+'\n')
    if result.returncode:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit('pinned podman: engine probe failed')
    return result
version = probe([podman, '--version'])
if version.stdout.strip() != 'podman version 6.1.4':
    sys.stderr.write(version.stdout + version.stderr)
    raise SystemExit('pinned podman: expected podman version 6.1.4')
info = probe([podman, 'info', '--format', 'json'])
parsed = json.loads(info.stdout)
if parsed['host']['buildahVersion'] != '1.45.2':
    raise SystemExit('pinned podman: expected Buildah 1.45.2')
if not parsed['host']['security']['rootless']:
    raise SystemExit('pinned podman: engine is not rootless')
PY

python3 - "$env_file" "$bin_dir:$PATH" "$conf" "$runtime" <<'PY'
import shlex, sys
env_file, path, conf, runtime = sys.argv[1:]
with open(env_file, 'w') as handle:
    handle.write('export PATH=%s\n' % shlex.quote(path))
    handle.write('export CONTAINERS_CONF=%s\n' % shlex.quote(conf))
    handle.write('export XDG_RUNTIME_DIR=%s\n' % shlex.quote(runtime))
PY

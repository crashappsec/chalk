#!/bin/sh
set -eu
umask 077

usage() {
  printf 'usage: %s <binary> <sha256> <install-dir>\n' "$0" >&2
  exit 2
}

if [ "$#" -ne 3 ]; then
  usage
fi

binary=$1
expected=$2
install_dir=$3

if [ -z "$binary" ] || [ -z "$expected" ] || [ -z "$install_dir" ]; then
  usage
fi

case $binary in
  /*) ;;
  *) binary=$(pwd)/$binary ;;
esac

expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
if ! printf '%s' "$expected" | grep -Eq '^[0-9a-f]{64}$'; then
  printf 'install-podman: expected checksum must be a 64-character hex SHA-256\n' >&2
  exit 1
fi

if [ ! -f "$binary" ]; then
  printf 'install-podman: binary is not a regular file\n' >&2
  exit 1
fi

file_sha256() {
  digest_line=
  if command -v sha256sum >/dev/null 2>&1; then
    digest_line=$(sha256sum "$1") || return 1
  elif command -v shasum >/dev/null 2>&1; then
    digest_line=$(shasum -a 256 "$1") || return 1
  else
    printf 'install-podman: sha256sum or shasum is required\n' >&2
    exit 1
  fi
  printf '%s\n' "${digest_line%% *}"
}

directory_mode() {
  if mode=$(stat -c '%a' "$1" 2>/dev/null); then
    :
  elif mode=$(stat -f '%Lp' "$1" 2>/dev/null); then
    :
  else
    return 1
  fi
  case $mode in
    ''|*[!0-7]*) return 1 ;;
    *) printf '%s\n' "$mode" ;;
  esac
}

got=$(file_sha256 "$binary") || {
  printf 'install-podman: failed to checksum binary\n' >&2
  exit 1
}
got=$(printf '%s' "$got" | tr 'A-F' 'a-f')
if [ "$got" != "$expected" ]; then
  printf 'install-podman: binary checksum mismatch\n' >&2
  exit 1
fi

case $install_dir in
  /*) ;;
  *) install_dir=$(pwd)/$install_dir ;;
esac

while [ "$install_dir" != / ] && [ "${install_dir%/}" != "$install_dir" ]; do
  install_dir=${install_dir%/}
done

if [ -L "$install_dir" ]; then
  printf 'install-podman: installation directory must not be a symlink\n' >&2
  exit 1
fi

if [ ! -e "$install_dir" ]; then
  printf 'install-podman: installation directory must already exist\n' >&2
  exit 1
fi

if [ ! -d "$install_dir" ]; then
  printf 'install-podman: installation directory is not a directory\n' >&2
  exit 1
fi

install_mode=$(directory_mode "$install_dir") || {
  printf 'install-podman: cannot determine installation directory permissions\n' >&2
  exit 1
}
case $install_mode in
  *00) ;;
  *)
    printf 'install-podman: installation directory must not grant group or other access\n' >&2
    exit 1
    ;;
esac

result_bin_dir=$install_dir/bin
CDPATH=
if ! cd -P "$install_dir"; then
  printf 'install-podman: cannot enter installation directory\n' >&2
  exit 1
fi

bin_dir=bin
dest=$bin_dir/podman

if [ -L "$bin_dir" ]; then
  printf 'install-podman: refusing existing symlink\n' >&2
  exit 1
fi

if [ -e "$bin_dir" ] && [ ! -d "$bin_dir" ]; then
  printf 'install-podman: bin path is not a directory\n' >&2
  exit 1
fi

if [ ! -e "$bin_dir" ]; then
  mkdir "$bin_dir" || {
    printf 'install-podman: cannot create bin directory\n' >&2
    exit 1
  }
fi

if [ -L "$dest" ]; then
  printf 'install-podman: refusing existing symlink\n' >&2
  exit 1
fi

if [ -e "$dest" ]; then
  if [ ! -f "$dest" ]; then
    printf 'install-podman: refusing conflicting content\n' >&2
    exit 1
  fi
  existing=$(file_sha256 "$dest") || {
    printf 'install-podman: failed to checksum installed binary\n' >&2
    exit 1
  }
  existing=$(printf '%s' "$existing" | tr 'A-F' 'a-f')
  if [ "$existing" = "$expected" ] && [ -x "$dest" ]; then
    printf '%s\n' "$result_bin_dir"
    exit 0
  fi
  printf 'install-podman: refusing conflicting content\n' >&2
  exit 1
fi

partial=
cleanup() {
  if [ -n "$partial" ]; then
    rm -f "$partial" || :
  fi
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

partial=$(mktemp "$bin_dir/.podman.partial.XXXXXX") || {
  printf 'install-podman: cannot create temporary file\n' >&2
  exit 1
}
cp "$binary" "$partial"
chmod 0755 "$partial"
copied=$(file_sha256 "$partial") || {
  printf 'install-podman: failed to checksum copied binary\n' >&2
  exit 1
}
copied=$(printf '%s' "$copied" | tr 'A-F' 'a-f')
if [ "$copied" != "$expected" ]; then
  printf 'install-podman: copied binary checksum mismatch\n' >&2
  exit 1
fi

if ! ln "$partial" "$dest"; then
  if [ -L "$dest" ]; then
    printf 'install-podman: refusing existing symlink\n' >&2
    exit 1
  fi
  if [ -f "$dest" ]; then
    existing=$(file_sha256 "$dest") || {
      printf 'install-podman: refusing conflicting content\n' >&2
      exit 1
    }
    existing=$(printf '%s' "$existing" | tr 'A-F' 'a-f')
    if [ "$existing" = "$expected" ] && [ -x "$dest" ]; then
      printf '%s\n' "$result_bin_dir"
      exit 0
    fi
  fi
  printf 'install-podman: refusing conflicting content\n' >&2
  exit 1
fi

cleanup
partial=
printf '%s\n' "$result_bin_dir"

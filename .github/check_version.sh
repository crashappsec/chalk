#!/usr/bin/env bash
set -eEu
set -o pipefail

FILEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$FILEDIR" 1> /dev/null 2>&1

# cd to root of the repo
cd ..

KEYSPEC=src/configs/base_keyspecs.c4m
current_version=$(make version)
keyspec_version=$(
    grep -E "chalk_version\s:=" $KEYSPEC \
        | cut -d'"' -f2
)

if [ "$current_version" != "$keyspec_version" ]; then
    echo $KEYSPEC chalk_version does not match nimble chalk version
    echo "$keyspec_version != $current_version"
    exit 1
fi

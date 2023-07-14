#!/usr/bin/env bash
#
set -eEu
set -o pipefail

FILEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$FILEDIR/.." 1> /dev/null 2>&1

version=$(cat chalk_internal.nimble | grep version | grep "=" | cut -d'"' -f2)

cd config-tool

function libpath {
    name=$1
    ldconfig -p | grep $name | awk '{print $4}'
}

set -x
poetry run pip install staticx
poetry run pyinstaller \
    --onefile chalk_config/chalkconf.py \
    --collect-all textual \
    --collect-all rich \
    --add-binary="$(libpath libm.so.6):."
staticx dist/chalkconf dist/chalkconf-static

function publish {
    arch=$1
    aws s3 cp dist/chalkconf-static s3://crashoverride-public-binaries/chalkconf-$version-linux-$arch --acl=public-read
}

publish $(uname -m)
case "$(uname -m)" in
    x86_64)
        publish amd64
        ;;
esac

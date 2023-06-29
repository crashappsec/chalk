#!/usr/bin/env bash
#
set -eEu
set -o pipefail

FILEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$FILEDIR/.." 1> /dev/null 2>&1

version=$(cat chalk_internal.nimble | grep version | grep "=" | cut -d'"' -f2)

cd server

function libpath {
    name=$1
    ldconfig -p | grep $name | awk '{print $4}'
}

set -x
poetry run pip install -r requirements.txt
poetry run pip install staticx

cd app
poetry run pyinstaller \
    --onefile main.py \
    --paths=./ \
    --add-data 'conf/*:conf/' \
    --add-binary="$(libpath libm.so.6):."
cp dist/main server
staticx server server-static

rm site.tar.gz
tar czf site.tar.gz site/

function publish {
    path=$1
    name=$2
    arch=$3
    ext=${4:-}
    aws s3 cp $path s3://crashoverride-public-binaries/$name-$version-linux-${arch}${ext} --acl=public-read
    case "$arch" in
        x86_64)
            aws s3 cp $path s3://crashoverride-public-binaries/$name-$version-linux-amd64$ext --acl=public-read
            ;;
    esac
}

publish server-static chalkserver $(uname -m)
aws s3 cp site.tar.gz s3://crashoverride-public-binaries/$name-$version.tar.gz --acl=public-read

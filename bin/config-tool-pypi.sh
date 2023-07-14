#!/usr/bin/env bash
#
set -eEu
set -o pipefail

FILEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$FILEDIR/.." 1> /dev/null 2>&1

cd config-tool

set -x
poetry install
poetry build
cd dist
rm index.html || true
ls -la
python -m http.server 29999 &
sleep 1
curl localhost:29999/ | sed '/simple/d' > simple.html
kill $!
mv simple.html index.html
ls -la
aws s3 cp --recursive . s3://crashoverride-public-binaries/chalk-config/ --acl=public-read

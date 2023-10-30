#!/usr/bin/env bash

set -e

name=insecure_builder

if ! docker buildx inspect $name &> /dev/null; then
    docker buildx create \
        --use \
        --config=<(cat ./data/templates/docker/buildkitd.toml | envsubst | tee /dev/stderr) \
        --name $name \
        node-amd64 \
        > /dev/null
    docker buildx create \
        --append \
        --config=<(cat ./data/templates/docker/buildkitd.toml | envsubst) \
        --name $name \
        node-arm64 \
        > /dev/null
fi

if which "${1:-}" &> /dev/null; then
    exec "$@"
else
    exec pytest "$@"
fi

#!/usr/bin/env bash

set -e

FILEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${SSH_AUTH_SOCK:-}" ] && [ -n "${SSH_KEY}" ]; then
    eval "$(ssh-agent)"
    ssh-add <(echo "$SSH_KEY")
fi

if which gpg &> /dev/null; then
    email="chalk@tests.com"
    passphrase="test"
    export GPG_TTY=$(tty)
    if ! gpg -K $email &> /dev/null; then
        gpg \
            --default-new-key-algo "ed25519/cert,sign+cv25519/encr" \
            --yes \
            --batch \
            --quick-generate-key \
            --passphrase $passphrase \
            $email
    fi
    # start gpg agent with the passphrase so that its not prompted later
    echo | gpg \
        --yes \
        --batch \
        --passphrase $passphrase \
        --pinentry-mode loopback \
        --clearsign \
        &> /dev/null
    export GPG_KEY=$(
        gpg \
            -K \
            --keyid-format=LONG \
            chalk@tests.com \
            | grep sec \
            | awk '{print $2}' \
            | cut -d/ -f2
    )
fi

insecure_builder=insecure_builder
if ! docker buildx inspect $insecure_builder &> /dev/null; then
    docker buildx create \
        --use \
        --config=<(cat $FILEDIR/data/templates/docker/buildkitd.toml | envsubst | tee /dev/stderr) \
        --name $insecure_builder \
        node-amd64 \
        > /dev/null
    docker buildx create \
        --append \
        --config=<(cat $FILEDIR/data/templates/docker/buildkitd.toml | envsubst) \
        --name $insecure_builder \
        node-arm64 \
        > /dev/null
fi

empty_builder=empty_builder
if ! docker buildx inspect $empty_builder &> /dev/null; then
    docker buildx create \
        --name $empty_builder \
        > /dev/null
fi

if which "${1:-}" &> /dev/null; then
    exec "$@"
else
    exec pytest "$@"
fi

#!/bin/sh
exec gpg \
    --passphrase "$GPG_PASSWORD" \
    --pinentry-mode loopback \
    "$@"

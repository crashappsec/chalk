#!/bin/sh
set -eu

sudo apt-get update
version=$(apt-cache madison docker-ce | awk '$3 ~ /:29[.]2[.]1-/ {print $3; exit}')
test -n "$version"
sudo apt-get install -y --allow-downgrades "docker-ce=$version" "docker-ce-cli=$version"
sudo systemctl restart docker
test "$(docker version --format '{{.Client.Version}}')" = 29.2.1
test "$(docker version --format '{{.Server.Version}}')" = 29.2.1

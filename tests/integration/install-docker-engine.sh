#!/bin/sh
set -eu

if [ "$(docker version --format '{{.Client.Version}}')" = 29.2.1 ] && \
   [ "$(docker version --format '{{.Server.Version}}')" = 29.2.1 ]; then
  exit 0
fi
sudo install -m 0755 -d /etc/apt/keyrings
curl --fail --location --silent --show-error https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
  "$(dpkg --print-architecture)" "$VERSION_CODENAME" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
version=$(apt-cache madison docker-ce | awk '$3 ~ /:29[.]2[.]1-/ {print $3; exit}')
test -n "$version"
sudo apt-get install -y --allow-downgrades "docker-ce=$version" "docker-ce-cli=$version" \
  containerd.io docker-buildx-plugin docker-compose-plugin
if ! sudo systemctl restart docker; then
  sudo systemctl status docker containerd --no-pager || true
  sudo journalctl -u docker -u containerd --since '-5 minutes' --no-pager || true
  exit 1
fi
test "$(docker version --format '{{.Client.Version}}')" = 29.2.1
test "$(docker version --format '{{.Server.Version}}')" = 29.2.1

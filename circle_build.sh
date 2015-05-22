#!/usr/bin/env bash

set -eux

# If there's a base image cached, load it. A click on CircleCI's "Clear
# Cache" will make sure we start with a clean slate.
mkdir -p ~/docker
if [[ -e ~/docker/base.tar ]]; then
  docker load -i ~/docker/base.tar
fi
# Pretend we're already bootstrapped, so that `make` doesn't try to get us
# started which is impossible without a working Go env.
touch .bootstrap && make '.git/hooks/*'
./build/build-docker-dev.sh
docker save "cockroachdb/cockroach-devbase" > ~/docker/base.tar
if [[ ! -e ~/docker/dnsmasq.tar ]]; then
  docker pull "cockroachdb/dnsmasq"
  docker save "cockroachdb/dnsmasq" > ~/docker/dnsmasq.tar
else
  docker load -i ~/docker/dnsmasq.tar
fi
# Print the history so that we can investigate potential steps which fatten
# the image needlessly.
docker history "cockroachdb/cockroach-dev"

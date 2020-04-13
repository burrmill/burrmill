#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

set -euo pipefail
my_dir=$(dirname "$(realpath "$BASH_SOURCE")")

cd "$my_dir"

uid=$(id -u) gid=$(id -g) user=$(id -un) group=$(id -gn)

# Cannot simply 'docker build' because we maintain two symlinks here, see
# https://github.com/moby/moby/issues/18789
tar czh --exclude-ignore=.dockerignore . |
  docker build - \
         --file=Dockerfile.localonly \
         --tag=local-cxx-${user}:latest \
         --build-arg=gid=$gid \
         --build-arg=group=$group \
         --build-arg=uid=$uid \
         --build-arg=user=$user

echo >&2 "$0: Pruning docker images"
docker image prune -f

echo >&2 "$0: Built and tagged image local-cxx-${user}:latest"

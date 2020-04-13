#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

set -euo pipefail
my_dir=$(dirname "$(realpath "$BASH_SOURCE")")
cd "$my_dir"

user=$(id -un)
proj=$(gcloud config list --format='get(core.project)')
echo >&2 "$0: project='$project'"
loc=$(gcloud projects describe $proj --format='value(labels.gs_location)')
echo >&2 "$0: location='$loc'"
[[ $proj && $loc ]] || { echo >&2 "$0: FATAL: One of these is empty"; exit 1; }
project_repo=$loc.gcr.io/$proj
echo >&2 "$0: Using repository '$project_repo'"

docker build . \
       --file=Dockerfile.cudamkl.localonly  \
       --tag=local-cxx-cudamkl-${user}:latest \
       --build-arg=user=$user \
       --build-arg=project_repo=$project_repo

echo >&2 "$0: Pruning docker images"
docker image prune -f

echo >&2 "$0: Built and tagged image local-cxx-cudamkl-${user}:latest"

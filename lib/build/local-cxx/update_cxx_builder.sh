#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# Overwrite the Dockerfile in ../cxx builder build directory.

set -euo pipefail
my_dir=$(dirname "$(realpath "$BASH_SOURCE")")

cd "$my_dir"
./setup.sh -d > ../cxx/Dockerfile
echo >&2 "Wrote $(realpath ../cxx/Dockerfile)"

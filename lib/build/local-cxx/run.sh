#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# Run your (local-cxx-USERNAME) builder image in the current directory, either
# interatively if no arguments provided, or non-interactively executing a bash
# command given in the command line. This is useful to debug builds intended to
# build by Cloud Build with the cxx builder.

set -euo pipefail

# Accept an environment override; used in run_cudamkl.sh.
: ${_local_image:=local-cxx-$USER}

if (( $# == 0 )); then
  exec docker run --rm -it -v$HOME:$HOME -w $PWD $_local_image
else
  exec docker run --rm     -v$HOME:$HOME -w $PWD $_local_image "$@"
fi

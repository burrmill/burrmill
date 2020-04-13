#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# Run your (local-cxx-cudamkl-USERNAME) cxx builder image extended with MKL and
# CUDA in the current directory, either interatively if no arguments provided,
# or by executing a bash command given in the command line. This is useful to
# debug Cloud Build of Kaldi (or requiring MKL/CUDA otherwise). The image must
# have already been built with make_local_cudamkl.sh. Unlike the local build,
# under GCB we compose a similar image within the same build that we build Kaldi
# and then discard it. In other words, the composed image is not stored in the
# Cloud Registry.

my_dir=$(dirname "$(realpath "$BASH_SOURCE")")

# Pass image name to run.sh via environment.
_local_image=local-cxx-cudamkl-${USER} exec "$my_dir/run.sh" "$@"

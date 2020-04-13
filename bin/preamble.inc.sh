# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# This file will set up correct paths if and only if it is located in the
# BurrMill's bin/ directory, directly under its root and besides the lib/ and
# libexec/ subdirectories.
#
# Source in every tool in bin/ as:
#   source "$(realpath -m "${BASH_SOURCE}/../preamble.inc.sh")"

# Full real path to this file.
_preamble_path=$(realpath "$BASH_SOURCE")

# These are defined everywhere, and in programs invoked by this shell.
export BURRMILL_BIN=$(dirname "$_preamble_path")
export BURRMILL_ROOT=$(realpath "$BURRMILL_BIN/..")
export BURRMILL_LIB="$BURRMILL_ROOT/lib"
export BURRMILL_ETC="$BURRMILL_ROOT/etc"
my_name=$(basename "${BASH_SOURCE[-1]}")

PATH="$BURRMILL_ROOT/libexec:$BURRMILL_BIN:$PATH"

# Minimal sanity check that the directories we're using exist at the least.
_oops=
for _sub in bin lib libexec; do
  if [[ ! -d "$BURRMILL_ROOT/$_sub" ]]; then
    echo >&2 "$my_name:FATAL:directory $BURRMILL_ROOT/$_sub is missing"
    _oops=y
  fi
done
[[ $_oops ]] && exit 1

unset _oops _sub _preamble_path

set -euo pipefail

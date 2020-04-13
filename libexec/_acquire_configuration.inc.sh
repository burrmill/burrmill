# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# Never source _*.inc.sh directly, only those not prefixed with the '_'.

# This scriptlet does the best to acquire the project configuration, but does
# not bomb out if any of its parts are unavailable. It is normally followed by
# _apply_configuration.inc.sh, except in early setup scripts where a
# configuration is not yet expected to exist.
#
# This is also where we check for necessary tools and their versions (bash
# itself at the moment, and gcloud).
#
# Please do not source any files _*.inc.sh; they are building blocks for
# higher-level scripts that could be sourced.
#
# Expects functions.inc.sh be imported.
# Outputs:
#    GCLOUD - real gcloud executable (always set, or die).
#    project - set on the best effort basis.
#    BURRMILL_{ROOT,LIB,ETC} - looked up if not already set in the environment.

#==============================================================================#
# Verify bash is recent enough.
#==============================================================================#
(( BASH_VERSINFO[0]*100+BASH_VERSINFO[1] < 402 )) &&
  Die "Bash version 4.2+ is required. This bash is" $BASH_VERSION

set +o posix
shopt -s compat42 &>/dev/null || true

#==============================================================================#
# Locate real gcloud.
#==============================================================================#
# We use --verbosity=error because gcloud sometimes produces pretty useless
# warnings about future-proofing some features, like filter syntax changes,
# many months in advance. We monitor the changes anyway.
GCLOUD="$(type -P gcloud) --verbosity=error" ||
  Die "Cannot find the 'gcloud' command.$LF2  Install Google Cloud SDK:"\
      "$(C y)https://cloud.google.com/sdk/install"

export GCLOUD CLOUDSDK_CORE_DISABLE_PROMPTS=1  # newer ask, like 'gcloud -q'.

#==============================================================================#
# Locate our root folder.
#==============================================================================#

# Did the user install us in the recommended, source-controlled way?
[[ ! ${BURRMILL_ROOT-} ]] &&
  BURRMILL_ROOT=$(git 2>/dev/null rev-parse --show-toplevel) || true

if [[ ! ${BURRMILL_ROOT} ]]; then
  Warn "Your BurrMill directory does not appear to be under Git source" \
       "control. It is nearly imperative${LF}to source-control your work, to" \
       "both upgrade the scripts to our latest, and keep track of your work."
  # Nope, try using relative locations up the tree to find the marker file.
  _this_dir=$(dirname "$(realpath "$BASH_SOURCE")")
  if [[ -f "$_this_dir/../.burrmill_root" ]]; then
    BURRMILL_ROOT=$(realpath "$_this_dir/..")
  elif [[ -f "$_this_dir/../../.burrmill_root" ]]; then
    BURRMILL_ROOT=$(realpath "$_this_dir/../..")
  else
    Die "Unable to guess the BurrMill root directory."
  fi
  unset _this_dir
fi

: ${BURRMILL_LIB:="${BURRMILL_ROOT?}/lib"}
: ${BURRMILL_ETC:="${BURRMILL_ROOT?}/etc"}

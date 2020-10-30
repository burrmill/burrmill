#!/bin/bash
# This file was installed by BurrMill.
#
# Fulfills Slurm's request to power-down nodes by deleting them.

set -u

. slurm_common.inc.sh

nodes=$(ExpandHostnames "$@") || exit  # Logs if anything went wrong.

Log info "Deleting compute nodes in $zone:" $nodes
$GCI delete --zone=$zone $nodes

# Ignore exit code from $GCI. Some nodes may not have existed in the first
# place, and the return code of gcloud will be non-zero in this case.
exit 0

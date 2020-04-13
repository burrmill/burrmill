#!/bin/bash
# This file was installed by BurrMill.
#
# Fulfills Slurm's request to power-down nodes by deleting them.

set -u

. slurm_common.inc.sh

nodes=$(ExpandHostnames "$@") || exit  # Logs if anything went wrong.

Log info "Deleting compute nodes in $zone:" $nodes
$GCI delete --zone=$zone $nodes

exit 0

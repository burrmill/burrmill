#!/bin/bash
#
# This file was installed by BurrMill.

# This is a Slurm trigger script to recover nodes that have been put by the
# controller into the DOWN state, which typically happens when GCE could not
# allocate resources for a compute node within the configured resume
# timeout. One or more arguments are nodespecs representing the failed nodes.
# They are accepted by scontrol as is, no need to expand to individual names.
#
# The trigger must be registered with slurmctld exactly once:
#
#  strigger --set --down --flags=PERM --offset=$offset --program=<full-path>
#
# The trigger will be called with the slurm user identity on the control node
# after at least --offset seconds has passed since the node has transitioned
# into the DOWN state.

set -u

reason=recovery
offset=20

. slurm_common.inc.sh

for n; do
  Log notice "Recovering failed node(s) '$n' in zone $zone"
  scontrol update nodename="$n" reason="$reason" state=DRAIN &&
  scontrol update nodename="$n" reason="$reason" state=POWER_DOWN ||
    Log alert "The command 'scontrol update nodename=$n' failed." \
              "Is scontrol on the PATH?"
done

exit 0

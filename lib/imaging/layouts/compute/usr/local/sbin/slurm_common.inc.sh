# This file was installed by BurrMill.
#
# Slurm-specific common bash routines, in addition to burrmill_common.inc.sh.

. burrmill_common.inc.sh

ExpandHostnames() {
  local hosts
  (( $# )) || Fatal "ExpandHostnames: invalid invocation: no arguments"
  hosts=$(SLURM_JOB_NODELIST= scontrol show hostnames "$@") ||
    Fatal "Unable to expand ($@). Is scontrol on the PATH?"
  Log debug "Expanded request ($@) to ($hosts)"
  echo $hosts
}

# When a program is invoked by Slurm, stdout and stderr may be closed, so that
# programs fail simply trying to output a harmless diagnostics or progress
# messages, and gcloud fails for no reason whatsoever.
[[ -t 0 ]] || exec 0</dev/null
[[ -t 1 ]] || exec 1>/dev/null
[[ -t 2 ]] || exec 2>/dev/null


GCI="gcloud -q --verbosity=none --no-user-output-enabled compute instances"

project=$(MetadataOrDie 'project/project-id')  # String codename.

zone=$(MetadataOrDie 'instance/zone')  # E.g., project/42/zones/us-west1-b
zone=${zone##*/}

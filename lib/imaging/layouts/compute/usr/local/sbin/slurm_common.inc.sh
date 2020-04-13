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
# gcloud fails simply trying to output a harmless diagnostics or progress
# messages. --verbosity=none --no-user-output-enabled are both essential.
GCI="gcloud -q --verbosity=none --no-user-output-enabled compute instances"

project=$(MetadataOrDie 'project/project-id')  # String codename.

zone=$(MetadataOrDie 'instance/zone')  # E.g., project/42/zones/us-west1-b
zone=${zone##*/}

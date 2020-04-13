#!/bin/bash
# This file was installed by BurrMill.
#
# This program is invoked on the control node to "resume" (essentially, create)
# computing nodes specified by arguments. The node names have a predefined
# format: '<cluster>-node-<type>-<number>'. We expand node names, since they
# may have been passed by Slurm in a shorthand notation, then parse out
# necessary parts of the name to create our instance.
#
# By convention, the following pieces of data have the same value:
#  - Node prefix before the leftmost '-', as said above.
#  - Cluster name.
#  - Subnetwork name for the cluster.
#  - Network tag for all nodes on the cluster subnetwork.
#
# The CNS disk name is specified in the 'cns_disk' metadatum on the control
# node of the cluster. The 'cluster' custom metadatum is set to the cluster
# name on every cluster node.

set -euo pipefail

. slurm_common.inc.sh

readonly nodes=$(ExpandHostnames "$@")
readonly cns_disk=$(MetadataOrDie instance/attributes/cns_disk)

# This was put into the systemd service environment by clusterid_from_metadata.
readonly cluster=$BURRMILL_CLUSTER

# The directory with additional flags for node types, e.g. std.gclass.
readonly nodeclass_dir=/etc/slurm/nodeclass

# Using the flag file format (see 'gcloud topic flags-file') allows configuring
# nodes by reading additional flags from files in /etc/slurm/nodeclass/*.gclass
readonly common_conf="\
--boot-disk-device-name: boot
--boot-disk-size: 10GB
--boot-disk-type: pd-ssd
--disk: name=$cns_disk,device-name=cns,mode=ro
--image-family: burrmill-compute
--image-project: $project
--metadata: cluster=$cluster
--no-shielded-vtpm:
--no-shielded-integrity-monitoring:
--no-shielded-secure-boot:
--no-address:
--preemptible:
--service-account: bm-c-compute@${project}.iam.gserviceaccount.com
--scopes: cloud-platform
--subnet: cluster-$cluster
--tags: $cluster
--zone: $zone"

# Added to by ReadNodeClassConfig.
declare -A conf_by_cls=()

# Load gcloud flags from a file /etc/slurm/nodeclass/<class>.gclass, and cache
# it in the assoc conf_by_cls. Make sure there is one switch per line by quoting
# everything carefully, or gcloud --flags-file will get very angry. Empty lines
# and comments are ignored; in fact, only lines starting with '--' are used.
ReadNodeClassConfig() {
  local c=${1?} flags
  [[ ${conf_by_cls[$c]-} ]] && return  # Already cached.

  [[ -f $nodeclass_dir/$c.gclass ]] ||
    { Log alert "Unknown node class '$c' of node '$n':" \
                "$nodeclass_dir/$c.gclass does not exist"; return 1; }
  # Grep exit code reflects match status, useless here; suppress.
  flags=$(grep '^--' $nodeclass_dir/$c.gclass) || true
  conf_by_cls[$c]=$flags
}

# Sort out node by type, so we make fewer gcloud invocations.
declare -A nodes_by_cls
for n in $nodes; do
  [[ ${n%%-*} = $cluster ]] ||
    { Log alert "Config error: node '$n' does not belong to cluster '$cluster'"
      exit 1; }
  c=${n#*-*-}  # xw-node-std-12 => std-12
  c=${c%%-*}   # std-12 => std
  ReadNodeClassConfig $c || exit
  nodes_by_cls[$c]+=" $n"
done

# Try starting nodes first. This is not how we handle them currently (we delete
# nodes that went down instead), but easy to change.
#Log info "Starting compute nodes for cluster $cluster in $zone:" $nodes
#$GCI start --async --zone=$zone $nodes || true  # Ignore error.

# Then create nodes, grouping by type. We do not care if they are actually
# created: Slurm will take care of this upon a timeout. Preemptible VMs can be
# prevented from starting due to the lack of GCE resources.
for c in ${!nodes_by_cls[@]}; do
  n=${nodes_by_cls[$c]}
  cfg="
$common_conf
${conf_by_cls[$c]}
--labels: burrmill=1,disposition=t,cluster=$cluster,cluster_role=compute,compute_class=$c"
  Log info "Attempting create in $zone: cluster: $cluster," \
           "class: $c; nodes:$n; config:" $cfg
  $GCI create --async $n --flags-file=- <<EOF
$cfg
EOF
done

exit 0

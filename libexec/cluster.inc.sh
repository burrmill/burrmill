#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

. functions.inc.sh

# Cluster deployment and control routines, shared by bm-deploy, bm-os-image,
# bm-node-software and bm-power commands.

# GLOBAL:: cluster
: ${cluster=}  # Set to empty if null.

# Ubiquitously used. TODO: Do not add 'beta' when not in beta track.
GDM="$GCLOUD beta deployment-manager"

# Print command with --debug=2.
Gdmd() (
  [[ $OPT_debug_2 ]] && set -x
  $GDM deployments "$@"
)
GDMD=Gdmd

#==============================================================================#
# VerifyPrereqsAndGetCnsDisk
#==============================================================================#
# This function is used in multiple places whenever the DM is to be invoked.
# It verifies that the necessary minimum of parts exists:
#   1) global configuration exists,
#   2) there is an image in the compute family,
#   3) and there is a snapshot of the CNS disk.
#
# Upon success, return the URI of the CNS disk snapshot.
VerifyPrereqsAndGetCnsDisk() {
  local cns_snapshot=${1-}  # May be optionally specified.

  # Pull general config, just to make sure it exists; we do not use it here.
  GetProjectGsConfig

  # Only test if a base image is available; we use family name for deployment.
  # We run the check in parallel with the next one, note the &.
  [[ $($GC images list --verbosity=none --limit=1 --format='get(selfLink)' \
           --filter="status=READY AND family=$image_family_compute") ]] &

  # Find the CNS snapshot meanwhile. Extra field bug, use jq to get value.
  filt='labels.burrmill:* AND labels.disklabel=burrmill_cns'
  # If specific snapshot was requested:
  [[ $cns_snapshot ]] && filt+=" AND name=$cns_snapshot"
  # Find the (latest or the only matching by name) snapshot.
  cns_snapshot=$($GC snapshots list --format='json(name)' \
                     --sort-by=~creationTimestamp --limit=1   \
                     --filter="$filt" |
                   $JQ -r '.[].name//""')  # Or you'll get text 'null' if null.
  Dbg1 "Using CNS snapshot: '$cns_snapshot'"

  wait -n || Die "No base images in the family $(C c)$image_family_compute$(C)"\
                 "exist. Build one with the '$(C c bm-os-image build)' command."

  [[ $cns_snapshot ]] ||
    Die "No usable CNS disk snapshots were found." \
        "Build one with the '$(C c bm-node-software)' tool"

  echo "$cns_snapshot"
}

# Return a list of deployments that are not obviously broken. For a thorough
# check, there is LoadAndValidateClusterState. With -g, returns only those
# which have no errors in the latest deployment status record. bm-power performs
# a more thorough analysis, so the full JSON is returned without this switch.
# For global operations like disk layouts, we do not do much checking, as a
# reconfiguration alone may fix the discrepancies.
#
# NB that -g returns a plain text of deployment names, bur w/o -g the more
#    informative JSON descriptor is returned.
# Exit code is 0 even if the lists are empty, e.g. no deployment yet made;
# >0 indicates a real error.
GetLikelyUsableDeployments() {
  local good_only= jcandi
  [[ ${1-} = -g ]] && { good_only=y; shift; }
  jcandi=$($GDMD list --format='json(name,labels,operation.error)' \
                      --filter='labels.burrmill:* AND operation.status=DONE' |
             $JQ -r 'map( { name, zone:.labels[]|select(.key=="zone").value?,
                           ok:(.operation.error?==null) } ) | sort_by(.ok|not)')
  Dbg2 $'Candidate deployments:\n'"$jcandi"
  if [[ $good_only ]]; then
    Jq -r "$jcandi" '.[] | select(.ok) | .name'  # Plain text, list of words.
  else
    echo "$jcandi"  # JSON with the tally of bad and possibly good deployments.
  fi
}

#==============================================================================#
# GetAndCheckCluster [-e{0|1|2}] [<cluster>]
#==============================================================================#
# The only switch accepted by GetAndCheckCluster is -eN. The function both
# recognizes and modifies the global $cluster variable. TODO(kkm): sync also
# region and zone if the default changes, or unset if unknown.
#
# -eN = check and action level:
#   -e0 = return the configured (or already present in $cluster) value. Use
#         when the default is likely to change, and reporting "you have no
#         default" won't alarm the user.
#   -e1 = same, check if exists, error if not. This is a normal behavior for
#         most cases where the user did not specify a default. We die with
#         a hint how to fix, but not trying any fixes at all, except silently
#         erasing the reference to a non-existent cluster, but iff the project
#         has no clusters: then assume the user is doing a major reshuffle.
#   -e2 = return configured, or set default to the only existing, or bail out
#         and hint the way to select. This may be used only by programs adding/
#         removing whole clusters, 'bm-deploy new' or 'mb-deploy remove'.
#
# Default is -e1. -e2 is used by 'bm-deploy new', -e0 by 'bm-power select'
#
# The positional argument names the cluster. If omitted, the global variable
# $cluster is used; if that is not set, an attempt is made to get the user's
# default/preferred cluster; and if that not set, then this is an error.
#
# The function will not set the global cluster variable, however.
GetAndCheckCluster() {
  local -i elevel=1
  local _EnsureCluster clist clus_var lcluster msg opt
  OPTIND=1  # Must be reset, init is per-shell.
  while getopts "e:" opt; do
    case $opt in
      e) elevel=$OPTARG ;;
      *) Die "$my0:$FUNCNAME:$LINENO:internal error:unrecognized switch"
    esac
  done; shift $((OPTIND - 1)); unset opt
  lcluster=${1-${cluster-}}
  case $elevel in
    0|1|2) ;;
    *) Die "$my0:$FUNCNAME:$LINENO:internal error:invalid argument -e'$elevel'"
  esac

  Say "Reading cluster configuration in project '$(C c)$project$(C)'..."

  : $(GetUserAccount)
  clus_var=users/${_//@/-at-}/cluster

  # Try to get default if global var is null; may still yield null,
  [[ $lcluster ]] ||
    lcluster=$(RuntimeConfigVarGet burrmill $clus_var || true)

  # Level 0: return whatever is there (or not, even empty), no checks.
  ((elevel == 0)) && { echo $lcluster; return; }

  # List of all matching BurrMill deployments. Health is not checked, but must
  # at the least not be in progress.
  clist=($($GCLOUD beta deployment-manager deployments list \
                   --format='get(name)' \
                   --filter='labels.burrmill:* AND operation.status=DONE'))

  # It's ok to silently erase user's pointer to a non-existent cluster if there
  # are none whatsoever: they apparently just removed their default one.
  if [[ ! ${clist-} ]]; then
    RuntimeConfigVarUnset burrmill $clus_var || true
    Die "The project '$(C c $project)' has no successfully deployed" \
        "clusters.${LF}Check for broken deployments with the " \
        "'$(C c)bm-deploy ls$(C)' command"
  fi

  case $elevel in
    1)
      # Level 1: only check if the cluster exists (more done on the common path
      # after esac; here we only bail out if no default was set. This is the LSP
      # in action: programs that take the default should not change the default.
      # '-e2' is reserved for those that affect global state, so user won't be
      # pissed off if the default changes automatically without their approval.
      [[ $lcluster ]] ||
        Die "Default cluster is not set; run '$(C c)bm-power select$(C)'"
      ;;
    2)
      # Level 2: If there is only one cluster, set user's default cluster to it
      # permanently. Presumably, they either just deployed the first one, or
      # removed the default cluster. The only remaining (or having just arrived)
      # cluster is a good default in this case.
      if [[ ${#clist[@]} == 1 && $lcluster != $clist ]]; then
        local msg="is not set"
        [[ $lcluster ]] && msg="'$(C c)$lcluster$(C)' does not exist"
        Warn "Your default cluster $msg." \
             "Resetting to the only cluster '$(C c)$clist$(C)'" \
             "in project '$(C c)$project$(C)'"
        unset msg
        RuntimeConfigVarSet burrmill $clus_var $clist
        lcluster=$clist
      fi
      ;;
    *) Die "$my0:$LINENO:internal error:elevel=$elevel is not in {0..2}"
  esac

  # We should have died if there were no clusters, and we've handled the case
  # of no default separately; so there is at least 1 cluster in the project
  # and $lcluster may be either null or set to existing cluster or not.
  IsIn "${lcluster-}" ${clist[@]} ||
    Die "Default cluster '$(C c)$lcluster$(C)' does not exist, but multiple" \
        "other do. Run '$(C c)bm-power select$(C)'"

  echo "$lcluster"
}

#==============================================================================#
# GdmUpdateDeployment: Update boot image or CNS disk of the cluster.
#==============================================================================#

# Get a last known good manifest for the deployment $1.
GdmLatestManifest() {
  $GDMD describe ${1?} --format='value(deployment.manifest.basename())'
}

# Usage: GdmUd Phase  Deployment Properties
# e.g.:  GdmUD 1      $cluster   with_boot_disk:false
#
# On Phase 1, the disassembly, some components may be shared between and fail to
# delete; in this case the DM request is retries with the delete policy set to
# 'abandon' (and the new manifest, so that the disassembly goes on). Phase 2 is
# re-assembly, and must complete successfully without such a retry.
#
# Do not update more properties than necessary! DM is brittle when used to
# modify many things at once. It's brittle in general, too.
GdmUpdateDeployment() {
  local phase=${1?} clus=${2?} props=${3?}
  local latestmf

  # Perform the update. We are expected to fail on Phase 1 in some cases, so
  # we perform essentially same update (with the new manifest, again!), but
  # with the abandon policy. The cases of vanished nodes, or the CNS disk
  # used by another cluster all fall into this category.
  $GDMD update --format=none --manifest-id=$(GdmLatestManifest $clus) \
        "--properties=$props" $clus && return

  if [[ $phase = 1 ]]; then
    Say "Please disregard errors above, we're still working on it."
    $GDMD update --format=none --manifest-id=$(GdmLatestManifest $clus) \
          --delete-policy=abandon "--properties=$props" $clus && return
  fi

  # Now this is not good. Phase 2 should always complete in one step.
  Error "The error reported above was unexpected. Run '$(C c)bm-deploy" \
        "fix $clus$(C)' to attempt repairing the cluster."
  return 1
}

#==============================================================================#
# LoadAndValidateClusterState: get cluster state, validate consistency.
#==============================================================================#
#
# This is a main workhorse behind assessing health of and selecting required
# repairs of cluster installations within the project.
#
# Some global variables, usually options of the using tools, are controlling the
# behavior of this function (by convention, we call them 'true' iff their value
# is not empty, but otherwise irrelevant).
#
# Globals:
#   OPT_silent: if true, do not print errors, only return exit codes.
#   OPT_strict: if true, some warnings are upgraded to errors.
#   cluster:    attempted as the default if none specified on command line.
#
# Positionals:
#   $1   - Cluster name. If omitted, $cluster is used. This must succeed, the
#          function aborts if neither has a value.
#
# Options:
#   -p   - skip power check. Without it, the function asserts that the cluster
#          is powered off, as required for some command. Note the semantic is
#          negated: -p *prevents* the power check.
#
# Outputs:
#   $jsnodestate (optional). The JSON representation of the cluster state. If a
#          global variable jsnodestate is defined (even if it has no value), it
#          is set to the output representation. The exit code 1 or 2 indicate
#          there is no trusted configuration was possible to establish.
#   stdout The same JSON data array is output to stdout, as long as it was
#          possible to establish.
#   $cluster global variable is set to the cluster ID, if it was possible to
#         identify.
#
# Return codes: in the order of checks that are performed (excluding 1 and 2,
#               which may originate with other routines and normally
#               considered an uninformative "generic fatal failure").
#  1, 2 - Non-specific, undecodable, unexpected, fatal error.
#     6 - Deployment record is missing/erred the CNS disk.
#     8 - Deployment record is missing/erred one or more boot disks.
#    10 - Deployment record is missing/erred other principal parts.
#    12 - Cluster is ON. Reported only the -p switch is NOT specfied.
#    14 - Some principal role machines are in fact missing.
#    16 - Some boot disks are in fact missing (not impl. yet)
#    18 - Machines have in fact mixed up or missing CNS disks.
#    20 - Runtime config record is invalid or missing.


# E.g. _DieX 42 "Message" -- Like Die "Message", but return with exit code 42.
_DieX() {
  local err=${1:?}; shift
  [[ ${OPT_silent-} ]] || Error "$@"
  exit $err
}

# Like Warn unless OPT_silent, then noop.
_WarnX() { [[ ${OPT_silent-} ]] || Warn "$@"; }

LoadAndValidateClusterState() {
  local configrec jresource lcluster powercfg skip_pwr_check=
  [[ ${1-} = -p ]] && { shift; skip_pwr_check=y; }

  local lcluster=${1-${cluster}}
  : {$lcluster:?}  # Assert.

  # This message is not silenced; generally, only warnings and errors are,
  # to avoid confusing the user.
  Say "Reading deployment record of cluster '$(C c)$lcluster$(C)'"

  # This stuff is messy. An array of objects each with normal properties .type
  # (e.g., 'compute.v1.instance', but can be 'compute.v1beta2.instance'); .name,
  # a short name, e.g. 'xw-login', .url for the full resource id (same as its
  # selfLink).  The .finalProperties, however, contains a quoted YAML doc, and
  # errors/warnings, if any, contain errors as quoted inner JSON.
  jresource=$($GDM resources list --deployment=$lcluster --format=json) ||
    Die "Cluster '$(C c)$lcluster$(C)' in project '$(C c)$project$(C)'" \
        "does not appear to exist."
  Dbg1 "Loaded DM resource manifest for '$lcluster'"
  Dbg2 "$jresource"

  Say "Validating state of cluster '$(C c)$lcluster$(C)'"

  # Verify deployment declares a CNS disk. Losing it during an interrupted
  # rollout is really possible. Do not reparse YAML, just match a regex.
  JqTest "$jresource" '
    any( (.type | match("\\bcompute.+\\bdisks\\b")) and
         (.finalProperties | match("\\bdisklabel:\\s*burrmill_cns\\b")) )' ||
    _DieX 6 "Deployment record for '$(C c)$lcluster$(C)' has no CNS disk."

  JqTest "$jresource" '
    any( (.type | match("\\bcompute.+\\bdisks\\b")) and
         (.finalProperties | match("\\bdisklabel:\\s*burrmill_cns\\b")) and
         (..|.errors? != null) )' &&
    _DieX 6 "Deployment record for '$(C c)$lcluster$(C)' CNS disk" \
            "indicates errors."

  # Verify that boot disks are present.
  local misdisks=$(Jq -r "$jresource" '
  . as $dot
# $bd is an array of expected disks, each name synthesized from VM names,
# like "qw-control" => "qw-boot-control".
  | map( select(.type | match("\\bcompute.+\\binstances?$"))
         | (.name |split("-") | "\(.[0])-boot-\(.[-1])") ) as $bd

  | $dot | map(.name | select(. == $bd[]))  # These are disk present in record.
         | $bd - . | join(", ")             # set-diff actual from desired.')
  [[ $misdisks ]] &&
    _DieX 8 "Deployment record for '$(C c)$lcluster$(C)' has boot disks" \
            "'$(C y)$misdisks$(C)' missing."

  # Verify that disks have no errors.
  JqTest "$jresource" '
    any( (.type | match("\\bcompute.+\\bdisks$")) and
         (.name | match("-boot-")) and
         (..|.errors? != null) )' &&
    _DieX 8 "Deployment record for '$(C c)$lcluster$(C)' has boot disk errors"

  # Check for any errors whatsoever.
  JqTest "$jresource" 'any((..|.errors? != null))' &&
    _DieX 10 "Deployment record for '$(C c)$lcluster$(C)' has errors."

  # Cluster subnet full URI.
  subnet=$(Jq -r "$jresource" \
              '.[] | select(.type | match("\\bcompute\\b.+\\bsubnetworks\\b"))
                 | .url | split("/")[-4:] | join("/")')
  [[ $subnet ]] ||
    _DieX 10 "Deployment record for '$(C c)$lcluster$(C)' has no subnet."
  Dbg2 "Subnet URI for $lcluster: $subnet"

  # All instances on the cluster subnet. Check against actual instances,
  # do not care any more about declarations.
  jsnodestate=$($GC instances list --format=json \
                    --filter="networkInterfaces.subnetwork:$subnet" | $JQ -c .)
  Dbg1 "Loaded list of instances on subnet '$subnet'"
  Dbg2 "$jsnodestate"

  # Get config record. If unavailable, we'll report later.
  configrec=$(RuntimeConfigVarGet runtimeconfig-${lcluster} config) || true
  Dbg2 $'Cluster runtime config record:\n'"$configrec"

  # Digest raw instance array JSON and regurgitate actionable state.
  jsnodestate=$(Jq --arg cluster $lcluster \
                   --argjson configrec "${configrec:-{\}}" \
                   -c "$jsnodestate" '

# Readability of jq code: any pair of () [] {} not closing on the same line has
# spaces on the inside (after opening, before closing one). When embracing a
# single-line expression, conversely, put no space on the inside of the pair.
# The first line illustrates it: "map( " is starting a multiline expression and
# has a space, while ["co..", "..in"] is a single-line expression, and thus has
# no spaces after the opening and before the closing braces.

  map( ["control", "filer", "login"] as $main_roles
     | ($main_roles + ["compute"]) as $known_roles

# Start by collecting interesting stuff in the .P sub-object of every node.
     | .P = {name, selfLink, status}
     | .P.cns_disk = (.disks | map(select(.deviceName == "cns") | .source)[0])
     | .P.boot_disk = (.disks | map(select(.deviceName == "boot") | .source)[0])
     | .P.filer_disk = (.disks | map(select(.deviceName == "filer")|.source)[0])
     | .P.machineType = (.machineType | split("/")[-1])

     | if ( .labels | ( has("burrmill") and .cluster? == $cluster and
                      ([.cluster_role?] | inside($known_roles) ) ) )
         then .P.role = .labels.cluster_role
         else .P.role = "unknown" end

# Need none of the original large JSON. Replace each entry with the compendium
# .P containing only important, possibly preprocessed values.
     | . |= .P

# .known if we can figure out by role; .main if one of the 3 predefined main
# roles: control, filer or login. Non-powerable is checked on main nodes only,
# and is in effect during the node power-transition. We can force-kill compute
# nodes regardless of their power state.
     | .known = .role != "unknown"
     | .main  = ([.role] | inside($main_roles))
     | .nonpowerable = .main and ( .status != "RUNNING" and
                                   .status != "TERMINATED" )

# This is a bit convoluted, as many pure functional programs require switching
# to a specific mindset. For one, it is better to apply condition to an array
# than loop over elements; aggregates are jitted once, and are efficient,
# especially so in jq, optimized for large JSON payloads.
#
# My pet peeve with jqlang is the lack of official documentation on operation
# precedence and associativity; the precedence is quite unobvious ("//" has a
# lower precedence than the ">"; "x // 1 > 0" is a nonsensical operation
# "x // (1 > 0)", i.e. x // false; write "(x // 1) > 0" to get intended result!
# This is the LSP violation in its finest (or worst). But the ideas behind and
# the power of the language are quite impressive. The practical execution is
# wanting a better design, IMO.
#
# Back from the digression, "$conf.power[.role]" is a two-element array per
# role, e.g. $conf.power.filer:["g1-small","n1-standard-8"]. It may not be
# present in the config, e.g. for the controller that does not have different
# power states: it uses a cheaper n2-highcpu-2, and is off in low-power mode
# anyway. The next line adds 0 to the power index if there is no array (nulls
# have the length of 0 in jq, surprise, surprise!), like in the case of the
# control node, or 1 if there is (min clips the addend to be at most 1). Next,
# we match the real machine type with array index, returning -1 if no match
# for any reason: no config, or real mismatch. Index returning 0 means low-power
# match, and 1 high-power, per indices in the arrays described above. Then 1
# is added always, to map $pwrix range to [0..3]. 0 means no power control on
# node role, per $conf record (addends are [0, -1, 1]; 0 is the length of
# config array for this role, which is absent. [1, -1, 1], sum 1, means the
# low/high array is there, but machine type is not in it. [1, 0, 1], sum 2,
# is a low-power match to the array at its index 0, and [1, 1, 1] sums to 3
# to indicate the high-power configuration. Store the result as both the
# numeric .pwrix and human-readable .pwrtext.
     | ( .machineType as $m
       | [ $configrec.power[.role] | ([length,1] | min),
           index($m)//-1, 1 ] | add ) as $pwrix
     | .pwrix = $pwrix
     | .pwrtext = ["N/A","UNK","LOW","HIGH"][$pwrix] )  # End map on line 1.

# Continuation of the theme. The power setting is _consistent_ if all nodes that
# define low/high distinction in their configs (.pwrix > 0) do have the same
# power setting, and this setting is strictly > 1 (i.e., not "UNK").
   | ( (map(select(.main).pwrix | select(. > 0)) | unique) as $pxs
     | ($pxs | length <= 1) and ($pxs[0]//0) > 1 ) as $pwrconsistent

# Now group stuff by various criteria. This is the group by CNS disk. If we have
# more than one, the last CNS rollout was botched and needs fixing. Also replace
# disk full URI with a short name. Hope no one will use regional and a zonal CNS
# with the same name in a single deployment (we do not support regional CNS
# disks, no real sense), the only possible source of ambiguity. $g is an array
# or objects containing "cns_disk:" name and the "names:" array that use it. If
# the $g array is longer that 1 element, there is a mix of node software, and
# are not a go.
   | ( map(select(.known) | {name,cns_disk})
     | group_by(.cns_disk)
     | map( { cns_disk: (.[0].cns_disk | split("/")? // null | .[-1]),
              names: [.[].name] } ) ) as $g

# Finally, build a new object wieldier to work with.
   | { n_main:     map(select(.main)),
       n_compute:  map(select(.known and (.main | not))),
       n_unknown:  map(select(.known | not)),
       filer_disk: map(select(.role == "filer").filer_disk?)[0]?,
         # Count of nodes by type, {"filer":1,"unknown":3,"compute":42}
       ctbyrole:   group_by(.role) | map({(.[0].role): length}) | add,
       nbycns:     $g,
         # Either of the two is an abort condition.
       cns_mixed:  ($g | length != 1),              # CNS disks are mixed up.
       cns_empty:  $g | any(.cns_disk == null),     # And some of VMs have none.
       pwr_same:   $pwrconsistent,                  # Power level is consistent.
       pwr_level:  map(select($pwrconsistent and .main and .pwrix > 1))
                   | (.[0].pwrtext? // "MIXED"),    # Sensible only if pwr_same.
       powerable:  map(.nonpowerable) | any | not,  # Power-control is possible.
       config:     $configrec } ' )

  Dbg2 $'Processed node state:\n'"$jsnodestate"

  # Warn about unknown nodes, assuming they may be mislabeled main nodes, which
  # will make a missing main nodes error easier to track down.
  JqTest "$jsnodestate" '(.ctbyrole.unknown//0) == 0' ||
    _WarnX "Found unidentifiable (mislabeled?) nodes on the cluster network:" \
           "$(C c)$(Jq "$jsnodestate" '[.n_unknown[].name]|join(", ")')$(C)"

  # Error exit 12 if --strict sent by bm-deploy, and some machines are on.
  if [[ ${OPT_strict-} ]] && JqTest "$jsnodestate" '
                   [.n_main[],.n_compute[]]|any(.status!="TERMINATED")'; then
    _DieX 12 "Cluster $(C c)$lcluster$(C) has powered-up nodes." \
             "Cluster must be powered off for the requested change."
  fi

  # Check we have one main role each.
  local mcounts _CheckCount
  mcounts=( $(Jq -r "$jsnodestate" '.ctbyrole|(.control,.filer,.login)|.//0') )
  _CheckCount() {
    case $2 in
      1) return 0 ;;
      0) _DieX 14 "Cluster $lcluster is missing a main node role '$(C c $1)'" ;;
      *) _DieX 14 "Cluster $lcluster has $2 nodes in the role '$(C c $1)':" \
                  "$(C c)$(Jq -r --arg r $1 "$jsnodestate" '
                             [ .n_main[]
                               | select(.role==$r)
                               | .name ] | join(", ")')$(C)." \
                  "Multiple nodes in main roles are currently unsupported."
    esac
  }

  _CheckCount control ${mcounts[0]}
  _CheckCount filer   ${mcounts[1]}
  _CheckCount login   ${mcounts[2]}

  # TODO(kkm): Check for missing boot disks. This is the state that pisses off
  # the DM the most. For some reason, when asked to detach and delete already
  # detached and deleted disk, it complains that the disk is not attached.
  # Weird, and needs a good workaround.

  # Check for missing CNS disk on nodes.
  JqTest "$jsnodestate" '.cns_null' &&
    _DieX 18 "Some nodes do not have the CNS disk attached to them:" \
          "$(C c)$(Jq -r '.nbycns[] | select(.cns_disk == null)
                                    | .names | join(", ")')$(C)"

  # Check for CNS disk mishmash.
  JqTest "$jsnodestate" '.cns_mixed' &&
    _DieX 18 "Nodes have a mix-up of CNS disks:" \
          $'\n'"$(Jq -r '.nbycns[]|"    \(.cns_disk):\t\(.names|join(", "))"')"

  if [[ ! $configrec ]]; then
    local msg=("Runtime config record for '$(C c)$lcluster$(C)' does not exist."
               "'$(C c)bm-deploy fix$(C)' can fix this.")
    if [[ ${OPT_strict-} ]]
      then _DieX 20 "${msg[@]}"
      else Warn "${msg[@]}"; fi
    unset msg
  fi

  # Will always warn w/o a config record, and we warned already. Skip.
  [[ ! $configrec ]] || JqTest "$jsnodestate" '.pwr_same' ||
    _WarnX "Main nodes are in the mix of LOW/HIGH power state. It's ok" \
           "if${LF}you know what you're doing. Turning the cluster on using" \
           "'$(C c)$my0 low $lcluster$(C)' or${LF}'$(C c)$my0 high" \
           "$lcluster$(C)' next time will fix the discrepancy."

  # We skip in 3 cases: bm-power { show | kill | select }.
  [[ $skip_pwr_check ]] || JqTest "$jsnodestate" '.powerable' ||
    Die "The cluster is in a state not accepting power control" \
        "commands.${LF}Use a heavy-handed command '$(C y)$my0 kill" \
        "$lcluster$(C)' in case of a runaway${LF}cluster $(C w only). Type" \
        "'$(C c)$my0 show $lcluster$(C)' for complete node state info."

  echo "$jsnodestate"
}

#==============================================================================#
# BuildConfigRecord "$jsconf"
#==============================================================================#
# BuildConfigRecord "$jsconf" builds a JSON config record, after validating
# machine types specified, and selecting sensible defaults for those omitted.
BuildConfigRecord() {
  local _IsAvailable config_rec descfile mtype zone
  local jsconf=${1?}

  # Two parallel 4-element arrays, role/power names and machine names.
  mtypename=('Filer_low', 'Filer', 'Login_low', 'Login')
  mtype=($(Jq -r "$jsconf" \
              '.size | (.filer_low//"-", .filer, .login_low//"-", .login)'))

  Dbg1 "Read machine types from config: '$(declare -p mtype)'"
  [[ ${#mtype[@]} = 4 ]] ||
    Die "Invalid machine type in cluster definition file, likely with spaces" \
        "in it? Read types:${LF}$(C c)$(declare -p mtype)$(C)."

  # Auto selection for low-power, unless set explicitly by the user:
  # use e2-medium for the login node, n1-standard-1 for the filer, because
  # of e2-medium maximum total disk limit of 3TB. User can override.
  [[ "${mtype[0]}" = - ]] && mtype[0]=n1-standard-1 # Filer node.
  [[ "${mtype[2]}" = - ]] && mtype[2]=e2-medium     # Login node.

  zone=$(Jq -r "$jsconf" '.zone')

  # _IsAvailable type
  #    1-arg form reports error code only, silently.
  # _IsAvailable type roletype
  #    2-arg form Dies if type is unavailable; roletype is part of message.
  local -A known_types=()  # Cached availability checks.
  _IsAvailable() {
    local mtype=${1?} mtypename=${2-}
    [[ ${known_types["$mtype"]-} ]] || return 0
    $GC machine-types describe --zone=$zone "$mtype" &>/dev/null &&
      { known_types["$mtype"]=y; return 0; }
    [[ $mtypename ]] &&
      Die "'$(C c)$mtypename$(C)' machine type '$(C c)${mtype}$(C)' is not" \
          "available in zone '$(C c)$zone$(C)'"
  }

  # 2-argument form complains and calls Die.
  for i in {0..3}; do
    _IsAvailable "${mtype[i]}" "${mtypename[i]}"
  done

  # Make JSON power config and zone record to store along the deployment.
  config_rec=$(printf \
         '{"power":{"filer":["%s","%s"],"login":["%s","%s"]},"zone":"%s"}'\
         "${mtype[@]}" $zone)
  Dbg1 "Config record for cluster: '$config_rec'"
  Dbg2 "Availability cache: $(declare -p known_types)"

  echo "$config_rec"
}

#==============================================================================#
# WriteClusterRuntimeConfing $cluster "$jsconfigrec".
#==============================================================================#
# Zone is additionally written as a text value for the
# burrmill-ssh-ProxyCommand tool.
WriteClusterRuntimeConfing() {
  local cfg=runtimeconfig-${1?} zone=$(Jq -r "${2?}" .zone)
  RuntimeConfigVarSet $cfg config "$2"
  RuntimeConfigVarSet $cfg zone $zone
}

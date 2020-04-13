# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# Never source _*.inc.sh directly, only those not prefixed with the '_'.

#==============================================================================#
# Get project from configuration unless already set
#==============================================================================#
[[ ${project-} ]] ||
  project=${BURRMILL_PROJECT-${CLOUDSDK_CORE_PROJECT-}}

# Believe it or not, invoking gcloud to parse a 6-line local file takes 600ms,
# and that on a fast machine. With all-fresh .pyc files. That's Python for ya,
# folks.
[[ ${project-} ]] ||
  project=$($GCLOUD config list --format="value(core.project)")

[[ ${project-} ]] ||
  Die "Could not find the BurrMill project. We tried (in order):
  1. BURRMILL_PROJECT environment variable;
  2. CLOUDSDK_CORE_PROJECT environment variable;
  3. The project set in the current configuration;
but none of these pointed to a project.

If you are working from the Cloud Shell, set the BURRMILL_PROJECT\
 in the ~/.profile or ~/.bashrc file,
because the gcloud tool's local configuration is not saved between\
 sessions (but your local files are!).
The same will work on your own (non-cloud) machine, of course, but\
 there you may also use 'gcloud config'.

A few helpful commands if you are lost:
  $(C c gcloud config list) - shows current active configuration (local).
  $(C c gcloud config configurations list) - list all configurations (local).
  $(C c gcloud projects list) - show all projects available to you (remote).
  $(C c gcloud auth list) - show who was the 'you' for the above command.
"

#==============================================================================#
# Gcloud defaults known so far.
#==============================================================================#
# Override gcloud defaults.
# Note that gsutil recognizes the CLOUDSDK_CORE_PROJECT variable; see
# https://cloud.google.com/storage/docs/gsutil_install#authenticate, item 6.
export CLOUDSDK_CORE_PROJECT=$project

# Shortcuts often used in maintenance scripts.
GC="$GCLOUD compute --project=$project"

#==============================================================================#
# Shared constants
#==============================================================================#

# We're debian-based, but unlike standard families, do not have OS or version
# in the family name. This will make future upgrades easier.
readonly image_family_compute=burrmill-compute

#==============================================================================#
# Objects IDs commonly referred by mainenance scripts.
#==============================================================================#
# Machine identity service accounts.
#
# Cluster accounts. There ara 2 types of accounts: those of machine identities
# needed for cluster operation, and the other group used for housekeeping,
# bulding and prepare pieces of infrastructure. All of them have a 'bm' prefix,
# so they stay grouped together in the Cloud console, for example, which sorts
# them alphabetically.
#
# The computing accunts we name 'bm-c-*' (the 'c' may be for "cluster" or
# "compute").
# * bm-c-manage account has more security rights; it is used for login nodes,
#   where you actually work, so it gives you more control of the stuff.
# * bm-c-compute account has very little permission on the infrastructure, and
#   intended for computing and file server nodes, so that a stray computing
#   batch won't have privileges to mess with the infrastructure. It needs access
#   to data, however.
# * bm-c-control has quite a lot of privileges to create and destroy machines;
#   it's the account for the Slurm controller service.
#
# The second group is prefixed with 'bm-z-' (the 'z' stands for itself).
# Servcing accounts, on the other end, may have more permissions on the
# infrastructure. Think of them as your own little IT department.
# * bm-z-background-svc has very litte rights on the project, but full
#   unrestricted access to everything automaticallty serviced in background.
# * bm-z-image-build has a lot of permissions on the compute resouurces, as it
#   is used to create disks, snapshots and machine images. etc.

_ac_suffix=${project}.iam.gserviceaccount.com
# The compute accounts:
acc_compute=bm-c-compute@${_ac_suffix}    # Compute node, filer: minimal access.
acc_control=bm-c-control@${_ac_suffix}    # Control node: creates/deletes nodes.
acc_manage=bm-c-manage@${_ac_suffix}      # Configuration/login node.
# Servicing accounts:
acz_imager=bm-z-image-build@${_ac_suffix}      # Daisy the image builder.
acz_backsvc=bm-z-background-svc@${_ac_suffix}  # Automated registry cleanup.
unset _ac_suffix

# Custom roles we maintain.
_ro_prefix=projects/$project/roles
ro_bucket_readonly=$_ro_prefix/storage.bucket.readonly
ro_bucket_readwrite=$_ro_prefix/storage.bucket.readwrite
ro_hpc_controller=$_ro_prefix/hpc.controller
ro_registry_service=$_ro_prefix/docker.registry.service
unset _ro_prefix

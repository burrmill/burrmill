# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# Wrapper functions to invoke Daisy the image builder.

. functions.inc.sh

# UndocObtainCredentiaMaybe <file>: Save user's auth token to the file, if
# required for auth, and exports GOOGLE_APPLICATION_CREDENTIALS to point to
# it. The file will not exist if not needed; you can check if it is. Do not let
# this file hang around please, store preferrably in tmpfs, use 'trap "rm
# <file>" ERR EXIT', and delete it as soon as it is no longer needed. It's very
# sensitive, and bitcoin miners are really after it!
#
# Placing the function here, as Daisy is the only tool at the moment using it.
UndocObtainCredentialMaybe() {
  # This is using an undocumented gcloud command 'auth describe'. Unfortunately,
  # Google seems to be tightening access to the acting user identity for inter-
  # active programs. This makes sense, as the credential bypasses even 2FA for
  # the account and gives full access to everything, but the pendulum has swung
  # too far, IMO. The idea to maintain a service account with fewer than a
  # project.owner permissions is sensible, but hardly works out in reality if
  # you're a scientist and not an IT admin. I still know of multiple hacks to
  # get this info; the use of an undocumented command is the cleanest one.
  # Still, using the Cloud Shell is for fully supported without hacks.
  local token_file=${1?}
  rm -f $token_file

  # In the Cloud shell there is no need to pull any trick, authentication is
  # transparent to client libraries. gcloud iself checks both variables, see
  # lib/googlecloudsdk/core/credentials/devshell.py, last 10 lines.
  [[ ${CLOUD_SHELL-} == true || ${DEVSHELL_CLIENT_PORT-} ]] && return

  # On the GCE machine, access is also transparent, but you are acting as its
  # service account, not as you. gcloud uses an http ping to the metadata
  # service to detect this case; I'll just use a DMI hack.
  [[ $(cat 2>/dev/null /sys/class/dmi/id/chassis_vendor) = Google ]] && return

  # You are calling this as you at home. Undocumented stuff comes of use.
  : > $token_file
  chmod 600 $token_file

  local acc;
  acc=$($GCLOUD config list --format='value(core.account)') && [[ $acc ]] ||
    Die "Unable to find the current account name. Check the output of " \
        "'$C(c gcloud auth list)', '$C(c gcloud config list)' and " \
        "'$C(c gcloud config configurations list)'"

  # 'auth describe' returns 3 of the 4 required token fields; add the "type"
  # with jq. Use a subshell not to disturb the pipefail setting.
  ( set -o pipefail
    $GCLOUD auth describe $acc \
            --format='json(client_id,client_secret,refresh_token)' |
      $JQ  '.type="authorized_user"' > $token_file ) ||
    { rm -f $token_file
      Die "Unable to obtain credentail for account $(C c)$acc"; }

  export GOOGLE_APPLICATION_CREDENTIALS=$(realpath $token_file)
}


# A standard way to run Daisy with a temporary directory, user credentials
# extracted from gcloud, and the kitchen sink.
# Switches:

#  -c  Command to prepare data in the temp directory, likely a function.
#      Optional; we'll copy everything from lib/imaging/scripts and convert
#      workflows if the function was not specified (or did not copy the workflow
#      named by $1).
#  -v  Daisy variables. Essentially mandatory, as all workflows require some.
#      But can be omitted if a workflow does not require any.
#  -s  Scratch storage subdirectory. Uses $1 if not provided.
# Positionals:
#  $1  Workflow name without the .wf.json suffix, just one word.
# Environment:
#  $project is required.
#  $OPT_debug, $OPT_dry_run, $OPT_yes are respected.
#
# The whole fuinction is set in a subshell, because it sets traps.
RunDaisy() (
  set -eu
  declare _Daisy opt scratch_path shopt_saved svcreg svczone tempdir wfname
  declare op_cmd=true op_sss= op_wfv=

  OPTIND=1  # Must be reset, init is per-shell.
  while getopts "c:s:v:" opt; do
    case $opt in
      c) op_cmd=$OPTARG ;;
      s) op_sss=$OPTARG ;;
      v) op_wfv=$OPTARG ;;
      *) exit 2;
    esac
  done; shift $((OPTIND - 1)); unset opt

  wfname=${1?}

  # Ensure Daisy exists, or download.
  if ! type -tp daisy &>/dev/null; then
    if [[ ${OPT_yes-} ]]; then
      Say "Downloading the imaging program Daisy into $BURRMILL_BIN"
    else
      Warn "Daisy not found. Daisy is a Google's own program they use to" \
           "prepare GCP VMs images, certainly safe."
      Confirm -y "Download latest Daisy release into $BURRMILL_BIN" || return 1
    fi
    wget -O $BURRMILL_BIN/daisy \
       "https://storage.googleapis.com/compute-image-tools/release/linux/daisy"
    chmod +x $BURRMILL_BIN/daisy
  fi

  GetProjectGsConfig  # Idempotent, caches, ok to call multiple times.

  # Find the service subnet.
  svcreg=$($GC networks subnets list --filter=name=service \
               --format='value(region)' --limit=1)
  [[ $svcreg ]] || Die "Unable to locate your service subnetwork." \
                       "Run $(C c bm-update-project), it may fix the issue."
  # Pick a random zone in the service net's region.
  svczone=$($GC zones list --filter="region=$svcreg AND status=UP" \
                --format='value(name)' --limit=1)
  Say "Using region $(C c $svcreg) and zone $(C c $svczone) for imaging."

  # Make a temporary directory for all required files, delete on return.
  tempdir=$(mktemp -d)
  trap "cd / ; rm -rf $tempdir" EXIT
  chmod 700 $tempdir  # We may need to store a sensitive credential there.
  cd $tempdir

  $op_cmd || Die "User command '$op_cmd' exited with non-zero status"

  # If the user command did not copy workflows (or was not even provided), copy
  # everything from lib/imaging.  There are very few files, no big deal.
  [[ -f $wfname.wf.yaml ]] || cp $BURRMILL_LIB/imaging/scripts/* .
  [[ -f $wfname.wf.yaml ]] ||
    Die "Specified workflow file '$wfname.wf.yaml' was not found"

  # Convert all workflows to json. They may include one another.
  local src dst
  for src in *.wf.yaml; do
    dst=${src/.wf.yaml/.wf.json}
    Dbg1 "Converting YAML workflow '$src' to Daisy JSON '$dst'"
    y2j $src >$dst || exit  # Why does not -e work here? set -o errexit is set!
  done

  # Logging path.
  scratch_path=$gs_scratch/imaging/${op_sss:-$wfname}
  Say "Logs will be found under $scratch_path."

  if [[ ${OPT_dry_run-} ]]; then
    _Daisy() {
      Say "$(C w Dry run.) Would now invoke Daisy in ${tempdir}"
      Dbg1 "$(ls -hAlF .)"
      Say "as: $(C w)daisy ${@@Q}$(C)"
      Dbg2 $'with the following JSON workflow:\n'"$(<$wffile)"'--------------'
    }
  else
    _Daisy() {
      # Outside of GCP, obtain the current user's authentication token, save to
      # token.tmp and export the variable pointing to it. This isn't done on GCE
      # or Cloud Shell, since credentials are transparently availalbe there.
      UndocObtainCredentialMaybe token.tmp
      Say "Invoking Daisy to run the workflow"
      if [[ ${OPT_debug-} ]]; then
        (set -x; daisy "$@")
      else
        daisy "$@"
      fi
      rm -f token.tmp
    }
  fi

  # This is a conundrum. Daisy is very picky about extra or unused variables.
  # It also has a -zone and $ZONE, but no matching region. Some of our workflows
  # have the 'region' variable, some don't.
  $JQ >/dev/null -e 'any((.Vars,.vars);has("region"))' $wfname.wf.json &&
    op_wfv+=${op_wfv:+","}region=${svcreg}

  # Invoke the daisy surrogate constructed above.
  _Daisy -project=${project?} -zone=$svczone -gcs_path=$scratch_path \
         -disable_cloud_logging ${op_wfv:+"-variables=$op_wfv"} $wfname.wf.json
)

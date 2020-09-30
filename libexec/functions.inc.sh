# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# Common pervasive function library. Make sure only functions go in here; any
# static variables and non-user functions should be prefixed with the '_'. All
# functions use UpperCamelNaming.

[[ ${_function_inc_sh_-} ]] && return
_function_inc_sh_=y

#==============================================================================#
# General utilities.
#==============================================================================#

# Is $1 equal any of $2...? This works correctly as long as $1 does not contain
# shell wildcard. An empty $1 does match an empty $n.
#
# Bash 4.4+ allows for stricter checking (some special chars in arguments).
if [[ $BASH_VERSION > '4.4' ]]; then
  IsIn() {
    local LC_ALL=C IFS=$'\377' x=${1?}; shift
    [[ $IFS${*@Q}$IFS = *$IFS${x@Q}$IFS* ]]
  }
else
  IsIn() {
    local LC_ALL=C IFS=$'\377' x=${1?}; shift
    [[ $IFS${*}$IFS = *$IFS$x$IFS* ]]
  }
fi

#==============================================================================#
# Interactive helpers.
#==============================================================================#

# Use 256 color CSI in devshell, it does have support for it.
[[ ${CLOUD_SHELL-} == true || ${DEVSHELL_CLIENT_PORT-} ]] &&
  TERM=screen-256color

# [g]reen, [w]hite, [y]ellow, [r]ed, [c]yan; [-] is for reset.
# * Use cyan to highlight topic variables within a message, like the message
#   "Your account '[me@gmail.com]' will be granted the '[foo]' permission",
#   where the brackets denote cyan-highlighted text (not part of message).
# * Use yellow for placeholders: "gsutil rm -r gs://[<BUCKET>]".
# * Use white for headers and important highlights in line, like highlighting
#   a sentence "This choice is permanent".
# * Still use the '' quotes in a message, like the cyan example above, for
#   non-color terminals (emacs shell, for one).
# Aside of that, OK, WARNING and FATAL/ERROR markers are highlighted with the
# green yellow and red colors, respectively.
# !1 and !2 are internal dimmer debug colors, do not use.
_tp() { tput "$@" 2>/dev/null; }
_af() { _tp setaf "$1"; }

declare -A _term_csi=( [-]=$(_tp sgr0) [r]=$(_af  9)
                       [!0]=$(_af 136) [y]=$(_af 11)
                       [!1]=$(_af 66)  [g]=$(_af  2)
                                       [c]=$(_af 14)
                                       [w]=$(_af 15) )
unset -f _tp _af

# $(C)   - reset attributes.
# $(C c) - turn on cyan for following text.
# $(C c foo bar) - print words 'foo bar' in cyan then reset attributes.
# Caveat: "$(C y)<role>$(C)" or "$(C y '<role>')", but not "$(C y <role>)".
# Caveat: "$(C y)$var$(C)" or "$(C y "$var")", but not "$(C y $var)", since
#         the $var can expand empty.
C() {
  local c=${1:-}
  # Catch $(C something) if caller forgot the color.
  [[ $c && ! ${_term_csi[$c]:-} ]] &&
    printf >&2 "%s%s:%s%s:invalid call to '\$(%s)': '%s' is not a color\n" \
               "${_term_csi[r]}" "${BASH_SOURCE[1]##*/}" \
               "${BASH_LINENO[0]}" "${_term_csi[-]}" "$FUNCNAME" "$c"
  printf %s "${_term_csi[${c:--}]-}"
  (( $# > 1 )) && { shift; printf %s%s "$*" "${_term_csi[-]}"; } || true
}

# Similar syntax for grotty colors, used in groff tables, defined in tty.tmac.
declare -A _groff_csi=( [-]=      [r]=red
                        [c]=cyan  [y]=yellow
                        [w]=white [g]=green  )

# Same syntax/semantic as C, only for grotty coloring. The use of _term_csi in
# the error message is not a bug: the message is optput to the tty, not grotty.
Cr() {
  local c=${1:-}
  # Catch $(Cr something) if caller forgot the color.
  [[ $c && ! ${_groff_csi[$c]:-} ]] &&
    printf >&2 "%s%s:%s%s:invalid call to '\$(%s)': '%s' is not a color\n" \
               "${_term_csi[r]}" "${BASH_SOURCE[1]##*/}" \
               "${BASH_LINENO[0]}" "${_term_csi[-]}" "$FUNCNAME" "$c"
  printf '\\m[%s]' "${_groff_csi[${c:--}]-}"
  (( $# > 1 )) && { shift; printf '%s\\m[%s]' "$*" "${_groff_csi[-]}"; } || true
}

readonly OK="[${_term_csi[g]}OK${_term_csi[-]}]"
readonly LF=$'\n... '   # With continuation BOL ellipsis.
readonly LF1=$'\n'      # Just an LF.
readonly LF2=$'\n\n'    # Two LFs
readonly LF2i="$LF2   " # Indented: "Use${LF2i}rm -rf /${LF2}to free up space"
readonly my0=$(basename "$0")

Say()     { echo >&2 "$my0:" "$@"$(C); }
Warn()    { echo >&2 "$my0:[$(C y WARNING)]:" "$@"$(C); }
Error()   { echo >&2 "$my0:[$(C r ERROR)]:" "$@"$(C); }
Die()     { Error "$@"; exit 1; }
SayBold() { echo >&2 $(C w)"$@"$(C); }
__Debug() {
  local l=${1-}; shift
  # Skip an extra stack frame, because we are called from Dbg{1,2,3}.
  echo >&2 "$(C !0)D$l]:${BASH_SOURCE[2]##*/}:${BASH_LINENO[1]}$(C !1):$@$(C)"
}
Dbg1() { [[ ${OPT_debug_1-} ]] && __Debug 1 "$@"; true; }
Dbg2() { [[ ${OPT_debug_2-} ]] && __Debug 2 "$@"; true; }
Dbg3() { [[ ${OPT_debug_3-} ]] && __Debug 3 "$@"; true; }

# It's the input (fd0) that  matters. Consider [[ -t 0 && -t 1 ]]?
RequireInteractive() {
  [[ -t 0 ]] || Die "Please run this command only interactively"
}

FlushStdin() {
  RequireInteractive
  # The number in -N is just the largest bash accepts.
  read -N$((16#7FFFFFFF)) -rst0.001 || true
}

# With no options, or with -n, ask a [y/N] question with the default being NO.
# If called with the -y option, then the default is set to YES, and the prompt
# changes to [Y/n]. Returns 0 for a YES and 1 for a NO. EOF (Ctrl+D) causes a NO
# response regardless of the default.
Confirm() {
  local def=n yn=
  case ${1-} in (-y) def=y yn="[$(C w Y)/n]"; shift;; (-n) shift;; esac
  : ${yn:="[y/$(C w N)]"}
  (( $# == 0 )) &&
    Die "$FUNCNAME:called from ${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}:" \
        "missing arguments"
  FlushStdin
  read -rp "$*$(C)"'? '$yn':' && [[ $REPLY = [Yy]* || ${REPLY:-$def} = [Yy]* ]]
}

# Display arguments, or a default message if not given, and wait for any key.
Pause() {
  FlushStdin
  read -rs -N1 -p "${*:-Press any key to continue...}" || true
  printf >&2 '\n'
}

# Display arguments as a menu of numeric choices, and print the *first word*
# of the selected choice. Returns 1 on EOF (Ctrl+D is pressed), unless -c is
# given, which makes Ctrl+D redisplay the menu the same way as Enter.
SimpleMenu() {
  local eof_exits=y selection
  [[ ${1-} = -c ]] && { eof_exits=; shift; }
  (( $# == 0 )) &&
    Die "$FUNCNAME:called from ${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}:" \
        "missing arguments"
  local PS3="Enter your choice from 1 to ${#}"
  [[ $eof_exits ]] && PS3+=" (Ctrl+D to go back)"
  PS3+=": "
  # If there are few enough options, set COLUMNS to 1, otherwise 'select' may
  # display a multicolumn menu which is confusing on a wide TTY emulator.
  (( $# <= 16 )) && local COLUMNS=1
  while :; do
    FlushStdin
    select selection; do
      [[ $selection ]] && break 2
      Say "'$(C r)${REPLY}$(C)' is not a valid selection"
    done || { echo >&2; [[ $eof_exits ]] && return 1; }
  done
  set -- $selection
  printf '%s\n' "$1"
}

# This function is intended to be called in a temporary directory, since its TAB
# completion is done over filenames in the directory: that's the only completion
# mode offered by the bash 'read' builtin. It calls the generator to add more
# files, and cleans only these before returning. The preexisting files that are
# also output by the generator *are removed*, however. The optional validator
# reports whether the selection is a correct one. The default behavior is to
# restrict the choices to the files in the directory (both preexisting and
# generated), unless there are none, in which case any non-empty input is valid.
# Pass -vtrue to accept any input, -vtest for non-empty input.
# -m\? enables the '? for menu' prompt, and displays all choices. The string
#      in place of the '?' is arbitrary. By default, there is no menu option.
# -e accepts empty as an answer, bypassing validator.
# The positional argument names the thing being selected: "Enter $1" is the
# basic prompt. It is a requred argument.
#
# No effort exerted toward supporting completion choices with spaces, asterisks
# or newlines in them. Also, no traps are set up; make sure to roll your own
# clean up on signal externally (this is our main use pattern anyway).
AskWithCompletion() {
  local generated opt what
  local emptyok= generator=true menu= validator='test -f' default_validator=y
  local have_choices= prompt= rc=0 x=
  OPTIND=1  # Must be reset, init is per-shell.
  while getopts "eg:m:v:" opt; do
    case $opt in
      e) emptyok=y;        ;;
      g) generator=$OPTARG ;;
      m) menu=$OPTARG      ;;
      v) validator=$OPTARG default_validator= ;;
      *) exit 2;
    esac
  done; shift $((OPTIND - 1)); unset opt
  what=${1?}

  generated=($($generator)) || return
  [[ ${generated-} ]] && touch "${generated[@]}" || true

  # Disable menu and default validation if there are no choices; build prompt.
  compgen >/dev/null '-G*' && have_choices=y
  [[ $have_choices ]] && prompt="TAB completes" || menu=
  [[ ! $have_choices && $default_validator ]] && validator=true
  [[ $menu ]] && prompt+=${prompt:+", "}"'$menu' for menu"
  prompt="Enter $what"${prompt:+" ("}$prompt${prompt:+")"}

  until [[ $x ]]; do
    FlushStdin
    # Ctrl-D does not do LF, thus || echo. Exit with rc=1 and print nothing.
    read -erp "${prompt}: " x ||
      { echo >&2; rc=1; break; }
    # If the menu was called and returned genuine empty, validate it, but if it
    # did not (Ctrl+D, allowed w/o -c), do not, and just repeat the question.
    [[ $menu && $x = $menu ]] &&
      { x=$(c=(*); SimpleMenu "${c[@]}") || continue; }
    [[ ! ($emptyok || $x) ]] &&
      { Say "$(C r Empty) is not a valid $what"; continue; }
    [[ $emptyok && ! $x ]] &&
      { break; }
    ($validator "$x") ||
      { Say "'$(C r)$x$(C)' is not a valid $what"; x=; }
  done

  (( rc == 0)) && [[ $x ]] && printf '%s\n' "$x"
  rm -f "${generated[@]}"
  return $rc
}

#==============================================================================#
# Command-line helpers
#==============================================================================#

_force_usage=

# Make it so Usage unconditionally prints usage info and exit. Usually called
# during switch parsing before Usage, which checks only the number of arguments.
ForceUsage() {
  _force_usage=y
}

# Usage $# <minargs> [<maxargs>] <<EOF
# Usage: $0 <foo> <bar>
#  e.g.: $0 data/foo exp/bar
#   ... more usage text...
# EOF
Usage () {
  local -i narg=$1 min=$2 max=${3:-9999999}
  if [[ $_force_usage ]] || (( $narg < $min || $narg > $max )); then
    [ -t 0 ] && Die "bad count of agruments; no usage message provided"
    cat >&2
    exit 2;
  fi
}

#==============================================================================#
# SSH connection helpers.
#==============================================================================#

# Wait upto 90s for ssh to accept connections to $1, exit with 1 if timed out.
WaitForSsh() {
  (( $# == 1 )) ||
    Die "$FUNCNAME:called from ${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}:" \
        "exactly 1 argument required"
  local vm=$1 rc=0
  Say "waiting for SSH shell becoming available on '$vm'"
  # Give it up to 90 (30x3) seconds to allow login. That's a lot.
  ( set +e
    for i in {0..30}; do
      printf >&2 '.'
      ssh 2>/dev/null $vm 'exit 0' && exit 0
      sleep 3
    done
    exit 1 ) || rc=1
  printf >&2 '\r%33s\r' ' '
  return $rc
}

# Wait upto 90s for ssh to accept connections to $1, die on timeout.
WaitForSshOrDie() {
  WaitForSsh "$@" || Die "timeout connecting to $1";
}

#==============================================================================#
# Path functions.
#==============================================================================#

# CleanPath 'foo/.//bar///' => 'foo/bar'
# CleanPath '/foo/.//bar///' => '/foo/bar'
# For the cases when we absolutely need to get rid of slashes at end of path.
CleanPath() {
  [[ ${1:?} == /* ]] &&
    realpath -sm "$1" ||
    realpath -sm --relative-to=. "$1"
}

#==============================================================================#
# Cloud functions.
#==============================================================================#

# "us-west1-a" => "us-west"
ZoneToRegion() { echo ${1%-*}; }

# Return a string of random lowercase letters and digits of specified length,
# or 5 if called with no argument. The string is not LF-terminated.
RandomSuffix() {
  ( set +o pipefail  # Tame the unhappy cat.
    cat /dev/urandom | tr -cd 0-9a-z | head -c${1-5} )
}

# Get and cache user account.
_account=
GetUserAccount() {
 [[ $_account ]] ||
   _account=$($GCLOUD config list --format='value(core.account)')

 [[ $_account ]] ||
   Die "Unable to find the current account name. Check the output of " \
       "'$C(c gcloud auth list)', '$C(c gcloud config list)' and " \
       "'$C(c gcloud config configurations list)'"

 echo $_account
}

#==============================================================================#

# 1 or 2 args, e.g. RuntimeConfigCreate burrmill 'Global project configuration'
RuntimeConfigCreate() {
  $GCLOUD beta  --verbosity=none runtime-config configs create \
          "${1?}" ${2+"--description=$2"}
}

# Config delete is not required, as per-cluster configs are managed by DM, and
# the global config 'burrmill' is never deleted. A curious gcloud factoid: the
# opposite of 'set' is 'unset', but that of 'create' is not 'uncreate', as you
# would expect, but rather 'delete'. This unlooks logical at all: if you begin
# using unverbs, don't unbegin half-way.

# RuntimeConfigVarGet burrmill global_state 'foo bar'
RuntimeConfigVarSet() {
  $GCLOUD beta runtime-config configs variables 'set' \
          --config-name="${1?}" --is-text "${2?}" "${3?}"
}

# RuntimeConfigVarGet burrmill global_state
RuntimeConfigVarGet() {
  $GCLOUD beta --verbosity=none runtime-config configs variables get-value \
          --config-name="${1?}" "${2?}"
}

# RuntimeConfigVarUnset burrmill global_state
RuntimeConfigVarUnset() {
  $GCLOUD beta runtime-config configs variables unset \
          --config-name="${1?}" "${2?}"
}

#==============================================================================#

# This is to standardize the way we create buckets: with UBLA set to on, and
# with all legacy roles removed. The project owner must have the role
# role/object.admin on the project level, or the bucket will be inaccessible.
GsMakeBuckets() {
  # '-b on' enables UBLA, same access to all objects through IAM.
  ${GSUTIL:-gsutil} mb ${project:+"-p$project"} -b on "$@" || return
  # Remove IAM policy entirely. It grants only legacy roles to legacy groups,
  # which cannot even be granted any more. More than one bucket may lurk in
  # the argument array, thus the loop to match out bucket names only.
  local buck; for buck; do
    [[ $buck == gs://* ]] && ${GSUTIL:-gsutil} iam set <(echo '{}') $buck
  done
}

# Return project's bucked inventory as JSON, queriable with jq. This is
# hack-ish, but gsutit ls -L output is almost correct yaml, except it starts
# lines with tabs. This function may break in future.
GsListBuckets() {
  ${GSUTIL:-gsutil} ls ${project:+"-p$project"} -L gs:// | tr '\t' ' ' | y2j -c
}

# If called without arguments, try to acquire buckets by calling GsListBuckets.
# If passed 1 argument, that should be a JSON description returned by same. This
# is used in higher-level scripts, where the bucket list is already available.
# If the string is empty, prints nothing at all, otherwise prints a
# user-friendly table describing the buckets. Normally the output should be
# redirected to stderr, but we do not do that here.
GsPrintBuckets() {
  case $# in
    0) local jsb=$(GsListBuckets);;
    *) local jsb=$1
  esac
  [[ ${jsb:-} ]] || return 0
  jq <<<"$jsb" -r 'to_entries[] |
           [.key, (.value | (.Labels.burrmill_role?//"(none)",
                             ."Location type",
                             ."Location constraint")) ] | @tsv' |
    format-table -H'<BUCKET NAME<BURRMILL ROLE<TYPE<LOCATION'
}

#==============================================================================#


# Retrieve global variables stored in project's global config.
#   gs_location  - Global location, [ asia | eu | us ]
#   gs_scratch   - Scratch bucket URI, e.g. gs://scratch-ckrmgx (no / at end).
#   gs_software  - Software bucket URI.
#
# NEW APPROACH:
# ============
# Since the introduction of the Runtime Config API, we store a copy of the same
# information in a runtime settings object burrmill/globals, in the form of a
# shell-style assignment string, e.g., 'gs_scrath=gs://scratch-ckrmgx
# gs_location=us' (with the full gs:// URI schema prefix, no limitation here).

GetProjectGsConfig() {
  [[ ${gs_location-} && ${gs_software-} && ${gs_scratch-} ]] && return

  local permissive=
  [[ ${1-} = -p ]] && { permissive=y; shift; }

  gs_location= gs_software= gs_scratch=
  local confrec=$(RuntimeConfigVarGet burrmill globals) || true
  Dbg1 "Config var configs/burrmill/variables/globals='$confrec'"
  [[ $confrec ]] && export $confrec
  [[ $permissive || $gs_location && $gs_software && $gs_scratch ]] ||
    Die "Runtime config record 'configs/burrmill/variables/globals'"\
        "is missing or incomplete"
}

#==============================================================================#
# jq helpers
#==============================================================================#

# For compat testing with jq 1.5 and 1.6, set in environment. Note that the
# release version of jq 1.6 has a bug that makes its startup noticeably slower,
# because of an accodental O(n^2) run time of the 'builtins' module load.
# Generally, the fewer times jq is invoked in a script, the better the speed;
# it's load is slow but processing is very fast. Most distros pulled a pre-rel
# future 1.6 from the master branch after the bug was fixed (and mind you, they
# did not agree on the exact commit, so there are at least as many different
# tools all distributed as "jq 1.6" as there are Linux distros. And all of these
# are not even alpha releases. Happy compat testing! And please try to stick
# with 1.5 if you can. The lack of release schedule and a dedicated design
# mastermind (single or collegial, official or de-facto--nada) are the two most
# pitiable point of the project. The language ideas are a rarity (pure function
# both accepting and returning indeterminate number of data (in the sense pl. of
# 'datum') are not uncommon; SQL is a prime example, but replacing SQL algebraic
# structure with the functional composition ring is not something I've heard of
# before.
: ${JQ:=jq}

# Jq [jq switches...] "$js" 'jq program'. Strips comments from the program,
# also takes the JSON string as argument without the '<<<' repeating neatly
# everywhere, and makes sure to use $JQ for future-proofing againts jq 1.6.
Jq() {
  # Sorry, the arguments are reshuffled in a little bit dense way:
  #     | 2nd from end, JS | All but last 2, jq options | Last one, jq code.
  local js="${@:(-2):1}"   opts=("${@:1:$(($#-2))}")    prog="${@:(-1):1}"

  # Allow rudimentary comments. A ^\s*#, or \s{2,}# signify a comment, to EOL.
  # Note the EOL comments require at least 2 spaces, since we're oblivious to
  # syntax, and may strip part of string, for example.  Trim empty lines
  # remaining after stripped comments, but leave original emply lines alone, so
  # the decommented program is still retaining empty lines added by its author.
  prog=$(perl <<<"$prog" -lne '
    if (s/(^\s*|\s{2,})#.*$//g) { print unless /^\s*$/; } else { print; };')
  Dbg2 "JQ=$JQ" $'is executing:\n'"$prog"
  $JQ <<<"$js" "${opts[@]}" "$prog"
}

# Same as above, but only test the result, return success unless the program
# evaluated to a false-ish value (false, null or empty).
JqTest() { Jq -e "$@"  >/dev/null; }

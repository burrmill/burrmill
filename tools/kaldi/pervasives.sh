#!/bin/bash

# A library of common functions sourced by out scripts. Normally sourced
# by common.sh. It relies on modern (4.3+) Bash features.
#
# By convention, function sourced from here are named are in UpperCamel,
# so that it clear where they same from.
#
# Extend responsibly. Generally, do not put anything but functions here.

# Die "some fatal error"
Die() { echo >&2 "$0: error: $@"; exit 1; }

# Say "interesting remark"
Say() { echo >&2 "$0: $@"; }

# Banner "doing something boldly"
# Print header with current time. Use before long processing. Used by Stage().
Banner() {
cat >&2 <<EOF
################################################################################
$0: $(date '+%y%m%d %T') $@
--------------------------------------------------------------------------------
EOF
}

# Usage $# <minargs> [<maxargs>] <<EOF
# Usage: $0 <foo> <bar>
#  e.g.: $0 data/foo exp/bar
#   ... more usage text...
# EOF
Usage () {
  local -i narg=$1 min=$2 max=${3:-9999999}
  if (( $narg < $min || $narg > $max )); then
    [ -t 0 ] && Die "bad count of agruments; no usage message provided"
    cat >&2
    exit 2;
  fi
}

# Stage <number> <message...>
# return 0 and print message iff $stage needs to run. Assumes the standard use
# of the $stage variable.
#
#    Stage 1 "Compute features for ${datadir}" && time {
#       . . .
#    }
# The time is rigged in common.sh to print a closing banner with elapsed time.
Stage() {
  local -i mystage=$1; shift;
  [ ${stage:-0} -le $mystage ] || return 1;
  Banner "STAGE $mystage: $@"
}

# e.g.: Demand file1 dir/file2 dir/
# Die if any are absent.
Demand() {
  local -a miss=(); local arg
  for arg; do
    case $arg in ''|/dev/null) true ;;
                 */) [ -d "$arg" ]  ;;
                 *)  [ -f "$arg" ]  ;;
    esac || miss+=("$arg");
  done
  (( ${#miss[@]} == 0 )) ||
    Die "missing required files or directories: ${miss[@]@Q}"
}

# CleanPath 'foo/.//bar///' => 'foo/bar'
# CleanPath '/foo/.//bar///' => '/foo/bar'
# For the cases when we absolutely need to get rid of slashes at end of path.
CleanPath() {
  [[ ${1:?} == /* ]] &&
    realpath -sm "$1" ||
    realpath -sm --relative-to=. "$1"
}

# UpToDate target1 [... targetN] : src1 [... srcN]
#
# Return 0 (true) when all target files are up-to-date w.r.t. all source
# files. The semantics is that of a makefile rule; hence the use of ':' to
# borrow also its syntax. A missing target file causes the up-to-date test to
# fail. A missing source file is an error. At least one of each is required.
# Syntax of the sources is same as that of Demand ('file' no slash, or 'dir/').
UpToDate() {
  local -a targets=(); local s t orig_cmd="${@@Q}"
  # Move targets to $targets, leave sources in remaining $@.
  for t; do
    shift
    [[ $t = : ]] && break
    targets+=("$t")
  done

  # Must have at least one each target and source.
  (( ${#targets[@]} == 0 || $# == 0 )) &&
    Die "Invalid arguments to UpToDate:" $orig_cmd

  # All sources must exist (an implied Demand check)
  Demand "$@"

  # Loop through all combinations of target and source and compare mtimes.
  for t in "${targets[@]}"; do
    [[ -e $t ]] || return 1
    for s; do
      # When two files have nearly same mtime (within a short delta?), both
      # conditions -nt/-ot are false. subset_data_dir creates such files with
      # the the mtime mere milliseconds apart, so it is important to consider
      # only a true return value of -nt/-ot ('&&' is ok, '||' is not).
      [[ $s -nt $t ]] && return 1
    done
  done
  return 0
}

# ExistingFile file1 file2 ...
# print the name of the first found file, or nothing and return 1 if not found.
ExistingFile() {
  local file
  for file; do
    [[ -f $file ]] && echo $file && return 0
  done; return 1
}

GetFeatureDim() {
  local datadir=${1?}; local -i dim
  Demand $datadir/feats.scp
  feat-to-dim --print_args=false scp:$datadir/feats.scp - || exit 1
}

# FeatureDimCheck data/train_hires 40
#  Dies if feature dimensions are incorrect (common error).
FeatureDimCheck() {
  local datadir=$1; local -i expected_dim=$2 dim
  Demand $datadir/feats.scp
  dim=$(GetFeatureDim $datadir) || exit 1
  (( $dim == $expected_dim )) ||
    Die "feature dimension in $datadir is $dim; expected $expected_dim"
}

# Call first thing in a subshell of the background job to mark up its output.
# e. g. LogWithId 'dec-tri1a'
LogWithId() {
  local ident=$1
  exec &> >(while read -r; do
              printf '>> BG:[%.10s]: %s\n' "$ident" "$REPLY"
            done)
}

# Wait for all background jobs and Die if any has exited with non-zero status.
WaitParallel() {
  # 1. 'jobs -p' does not stop tracking complete jobs.
  # 2. We only scan number of words (PIDs) in the returned value, not
  #    their values, so that the 'word' is unused in the loop.
  # 3. Cannot use 'let x++' when 'set -e' in effect: let returns its numeric
  #    result as exit code; must use x=$((x+1)) to increment.
  local jobs=$(jobs -p) word nfail=0 ntot=0
  for word in $jobs; do
    ntot=$((ntot + 1))
    wait -n || nfail=$((nfail + 1))
  done
  (( nfail > 0 )) &&
    Die "$nfail out of $ntot parallel jobs failed. Check output above."
  true
}

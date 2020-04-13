#!/bin/bash
# SPDX-License-Identifier: Unlicense OR CC0-1.0 OR Apache-2.0 OR WTFPL

# Written by Kirill 'kkm' Katsnelson and dedicated to public domain. If public
# domain is not recognized in your jurisdiction, use any of the licenses listed
# above that suit you the best.

# When your autosaves accumulate, you can't resit writing this script!

set -u

Die() { echo >&2 "${0##*/}:" "$@"; exit 1; }

tmp=${1:-}  # Argument points to Emacs autosave directory.
[[ -d $tmp ]] || tmp=${TMPDIR:-}  # POSIX.1-2017-compatible unix.
[[ -d $tmp ]] || tmp=${TMP:-}     # Idiosyncratic unix.
[[ -d $tmp ]] || tmp=${TEMP:-}    # Borked unix.
[[ -d $tmp ]] || tmp=/tmp         # Brain-damaged unix.
[[ -d $tmp ]] ||                  # Brain-dead unix.
  Die "I have no idea where could your temp directory be. Do you?" \
      "Pass Emacs autosaves dir as the argument."

diff=$(type -p colordiff)   ||
diff=$(type -p diff)        ||
diff=$(type -p "${DIFF:-}") ||
  Die "No colordiff or diff found. You may name your diff via DIFF= env var."

# 90=((2×3+1)×2+1)×2×3. Is not the 1-2-3 factoring cool? Can any number be
# factored as a continued product of 2s and 3s with +1 (the last +1 is
# optional)? 89 is a prime, but 89=((2×2+1)×2+1)×2×2×2+1. Oh, look, only 2's.
# Is the 1-2 factoring possible for any number? If yes, can you 1-2-3-factor any
# number larger than some N so that at least one 3 is used? A funny little
# number theory puzzles. You can solv'em all! Are you still with me?
s=== s==$s$s$s s==$s$s s=$s$s s=$s$s$s

# Disclaimer: I'm not responsible for yer heart attack that you've suffered
# reading this code. It could have been funkier if I'd use perl. *(Evil laugh)*
t=~; for backup in "$tmp"/\#*\#; do
  : ${backup##*/} ;: ${_//\!/\/} ;: ${_:1:((${#_}-2))} ; source=$_
  if [[ -r $source ]]; then
    echo \#$s$'\n'"# Compare autosave '${backup/#$t/\~}'
#       to current '${source/#$t/\~}'"$'\n#'$s
    "$diff" -u "$backup" "$source"
  else
    echo >&2 "*** '$backup' does not have a matching '$source'"
  fi
done

# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# Experimental command parser subjugating 'git rev-parse --parseopt'. This is an
# easier to use and more powerful, higher level parser than GNU getopt(1).
# (FWIW, the latter was written by Frodo himself. No kidding, see manual).

. functions.inc.sh

# **Do not put option 'h,help' among accepted options**, unlike the example
# suggests (https://git-scm.com/docs/git-rev-parse#_example). It is recognized
# implicitly always, but, if explicitly specified, behaves differently in case
# other options are present in the command line: e. g. 'mytool --dry-run --help
# build' sees 2 normal options: --dry-run and --help; but 'mytool --help' causes
# the parser to print help. '--help' is treated as a regular or special option
# based on context, which is a clear violation of the LSP. I want to slap --help
# into any position of a command failed parsing, and see help! This is weird,
# and probably a bug.

# Must maintain the array throughout; functions have their own $@. This array
# is set up once here (we use  source guard to prevend touble sourcing exactly
# for this reason). A sourced file shares the $@ with the main one *unless*
# options are given in the . command after filename. So don't do that.
#
# Use this array to access options, and not the $@ of the program. Note that
# POPT_ARGV[0] corresponds to $1, NOT $0, lust like "$@" is organized.
# Guard against clobbering in case the file has been sourced more than once.
declare -p POPT_ARGV &>/dev/null ||
  declare -a POPT_ARGV=("$@")

# Make all OPT_ vars from opspec defined by setting to null iff unset.
# This is totally idempotent, thus called from ArgParse() ad libitum.
# This is a public API, you can use it.
ArgParse_InitOptVars() {
  local opspec=${1?'Invalid invocation, no opspec'}
  for v in $(perl <<<"$opspec" -lne '
                $go ||= $_ eq "--";        # Skip all lines till '--'.
                next unless $go && /^\S/;  # Skip heagings, offset by spaces.
                /^(.,)?(.+?)[?!=*\s]/ and  # Prefer long, fallback to short opt.
                   print "OPT_".$2=~s/-/_/gr;'); do
    [[ ${!v-} ]] || builtin printf -v ${v} %s ''
  done
}

# A very common requirement for the --debug=[N] option, which may be set to 'y'
# w/o argument, or explicit number. --debug=0 probably means no debug. This
# function makes sure the OPT_debug value is either empty ot a numeric positive
# debug level. Also, convenience variables OPT_debug_{1,2..} are created up to
# the specified level (default 2), with the semantics "debug level is at the
# least 2", allowing for more readable tests. Pass it the number of levels that
# you recoginze, so that [[ $OPT_debug_2 ]] is true iff debug level is >= 2.
# E.g., ArgParse_ExtendOptDebug 3 => Defines OPT_debug_{1,2,3}, non-empty as
#       described above.
# E.g., ArgParse_ExtendOptDebug 0 => Do not define new vars, OPT_debug={0|1}.
#       This is of dubious value, just a side effect.
ArgParse_ExtendOptDebug() {
  if [[ $OPT_debug = y ]]; then OPT_debug=1
  elif [[ $OPT_debug =~ ^([0-9]*)$ ]]; then OPT_debug=$((OPT_debug)) # 0 if ''
  else Die "Value not an integer: '$(C c)--debug=$OPT_debug$(C)'"; fi
  local -i k max=${1-2}
  for ((k = 1; k <= max; k++)); do
    printf -v "OPT_debug_$k" %s "${OPT_debug::$((k <= OPT_debug))}"
  done
}

# Another option: provide sections separately? This is a clever hack, but the
# problem with it is it's the clever hack.
#
# One day I'd write the whole parser mimicking git parseopt, in perl. The thing
# is --stuck-long has a few corner cases. Fewer than the Hilbert curve has, but
# still. Better adopt git's one for the time being.
_ArgParse_UnindentUsageBlock() {
  :
  # Unindent the doc block of lines that git parseopt indents:
  #   |usage: blah
  #   |   or: blah
  # a |
  # b |    My docs are indented with $b spaces.
  #   |       I want to un-indent every line of this block by the
  #   |       same $b, keeping the relative indent unchanged.
  #   |
  #   |    And my block can be a few paragraphs long.
  #   |
  # c |Common options:
  #
  # Above, a, b, and c mark the lines where the respective variables become
  # true-ish; unindent lines where ($b && !&c). The $b's value doubles as the
  # number of extra spaces added by parseopt; $a and $b are just bool-ish flags.
  #
  # For this to work, two conventions are necessary:
  #  1. The first line of the usage block must not be indented, as it is used
  #     to calculate the added indentation.
  #     TODO(kkm): Actually, always 4. Maybe just use it? What if it changes in
  #                another git version?
  #  2. Options must start with an unindented header (i.e., the first line after
  #     the '--' line must start with a space and spell a meaningful header).
  #
  # Is this code a horrible hack, or a clever and compact implementtion of a
  # trivial FSM? Perl is famous for blurring the line...
  perl >&2 -ple ' $a ||= !$_;
                  $b ||= $a && /^\s+/ && length($&);
                  $c ||= $b && /^\S/;
                  $c or substr($_, 0, $b) = "" '
}

# Either echo the set command, or print massaged help message and exit from
# the calling shell. $1 is optspec, rest of args is for parsing.
# _ArgParse_Invoke [-s] <optspec>
# -s is to stop parsing as soon as a non-option (the verb) is encountered.
_ArgParse_Invoke() {
  local stop_at_verb=
  [[ ${1-} = -s ]] && { stop_at_verb=--stop-at-non-option; shift; }
  opspec=${1?'Invalid invocation, no opspec'}; shift
  # Git parser's manner of output of the help message is idio[syncra]tic. The
  # error and/or help message may either be printed by 'git parseopt' itself to
  # stderr literally, or output to stdout the form of 'cat<<HEREDOC...' command,
  # to be printed by eval on stdout. I want the message to go to stderr always,
  # and to run it through _ArgParse_UnindentUsageBlock. A process subst is not a
  # good solution, as the process runs asynchronously and may interleave its
  # output with other messages. So I do not treat the output as opaque if parser
  # exits with non-zero code, as the manual recommends; If it starts with "cat"
  # and contains a "<<" somewhere down the line, then it's a cat command to be
  # evaluated, otherwise a raw message to be printed.
  cmd=$(git <<<"$opspec" 2>&1 rev-parse \
          --parseopt --stuck-long $stop_at_verb -- "$@") &&
    { echo "$cmd"; return 0; } || true
  # cmd is either a cat-to-stdout command, or a raw message. This is a hack.
  if [[ $cmd = cat*'<<'* ]]; then eval "$cmd";
                             else echo "$cmd"; fi | _ArgParse_UnindentUsageBlock
  exit 2
}

# ArgParse [<option>...] <opspec> : parse arguments in the global argv array.
# For <opspec>, see 'man git rev-parse', and search for ^PARSEOPT.
# Options:
#   -c'build list rollout prune help' = Validate command to be one of these.
#        Adding 'help' explicitly is recommended with -u, otherwise 'help'
#        would not be subject to unabbreviation.
#   -dhelp = do help. This 'help' value is magic, and does not even require
#        that the help command be among the verbs in -c.
#   -d<command> = do default command if none given, but print '--help for
#        more...'. The <command> will be word-split, so that it may include
#        its own options, e.g., -d'list --brief'
#   -u  = unabbreviate command to one of given with the -c from unambiguous
#        prefix ('bu' -> 'build', if 'build' is the only starting with 'bu').
#   -gN = re-process OPT_debug up to debug level N, by creating variables
#        OPT_debug_{1..N}, and coercing OPT_debug to an integer. See
#        ArgParse_ExtendOptDebug, which is called with an argument N.
#   -aN = Minimum number of positionals to the command. If fewer are given,
#        print a human-reable error mesage. Default is 0.
#   -AN = Maximum number of positional. Default is no limit.
#
# No attempt to validate arguments is performed. Make sure that commands in the
# list -c are unique. Make sure that if both -c and -d are used, the command in
# -d (first word of the -d value) is in -c. The behavior is undefined otherwise.
# -u is silently ignored if -c is not given.
#
# All flags mentioned in opspec are initialized to empty if undefined, oherwise
# preserved unless changed in command line. Long form is always preferred when
# prosucing an option name, unless the flag is short-only (e.g., 'n,dry-run'
# yields the variable 'OPT_dry_run'; but just 'z', 'OPT_z'. Flags with no value
# set their variables to 'y'; --no-foo form, if allowed, sets OPT_foo to empty.
# Distinguish 3-state flags (--x, --no-x on no option) by assigning OPT_x
# anything except 'y' or '' prior to calling ArgParse.
ArgParse() {
  local cmd opt var value defcmd= do_unabbr= do_debug= minarg= maxarg=
  local -a commands=()
  OPTIND=1  # Must be reset, init is per-shell.
  while getopts "A:a:c:d:g:hu" opt; do
    case $opt in
      a) minarg=$OPTARG ;;
      A) maxarg=$OPTARG ;;
      c) commands=($OPTARG) ;;
      d) defcmd=$OPTARG ;;
      g) do_debug=$OPTARG ;;
      u) do_unabbr=y ;;
      *) exit 2;
    esac
  done; shift $((OPTIND - 1));

  local opspec=${1?'Invalid invocation, no opspec'}
  [[ "$minarg$maxarg" && "${commands-}$defcmd" ]] &&
    Die "ArgParse:assert: -[aA] do not go together with -[cd]"

  ArgParse_InitOptVars "$opspec"
  cmd=$(_ArgParse_Invoke ${commands+"-s"} "$opspec" "${POPT_ARGV[@]}") || exit
  # _ArgParse_Invoke guarantees that cmd is actually a set command to change
  # the current $@; it returns with >0 if there was a help mesage and/or error.
  eval "$cmd"

  for opt; do
    shift
    case $opt in
      --)     break ;;  # End of options.
      --*=*)  var=${opt#--} var=${var%%=*} value=${opt#*=} ;;
      --no-*) var=${opt#--no-} value= ;;
      --*)    var=${opt#--}    value=y ;;
      -?)     var=${opt:1:1}   value=y ;;
      -?*)    var=${opt:1:1}   value=${opt:2} ;;
    esac
    var=OPT_${var//-/_}  # Final touch: '--dry-run' => 'OPT_dry_run'
    builtin printf -v $var %s "$value"
  done

  [[ $do_debug ]] && ArgParse_ExtendOptDebug $do_debug

  POPT_ARGV=("$@")  # Remainig arguments after the juggling with switches.

  # If provided positional restriction. check.
  if [[ ($maxarg && $# -gt $maxarg) || ($minarg && $# -lt $minarg) ]]; then
    local expect s=;
    if [[ $minarg = $maxarg ]]; then expect="$minarg"
    elif [[ ! $maxarg ]]; then expect="at least $minarg"
    elif [[ ! $minarg ]]; then expect="at most $maxarg"
    else expect="between $minarg and $maxarg"; fi
    (( maxarg > 1 || minarg > 1 )) && s='s'
    Say "$(C r ERROR): Expecting $expect positional argument$s, $# provided"
    _ArgParse_Invoke "$opspec" --help  # [noreturn]
  fi

  # If neither -d nor -c is in effect, do nothing else, just positionals.
  [[ ${commands-} || $defcmd ]] || return 0

  cmd=${1-}
  if [[ ! $cmd  ]]; then
    case $defcmd in
      '') ;;  # Ok, they'll handle that downstream. Normal case for the second
              # invocation of tools with a verb commands, or the only invocation
              # for the tools with none: this is not a command, just the first
              # positional argument of possibly many.
      help) _ArgParse_Invoke "$opspec" --help ;;  # [noreturn]
      *) POPT_ARGV=($defcmd)   # Word splitting intentional, e.g. -d'list --all'
         Say "$(C w)info:$(C) invoking '$my0 $defcmd' by default;"\
                  "use '$my0 --help' for more options."
    esac
  else
    # We have a commmand? 'help' may or may not be in the commands[*], check it
    # explicitly. It is beneficial to explicitly add it to the list, as it then
    # may be unabbreviated just like any other command (unlike the help
    # *option*, that causes problems, described in the intro right above this
    # function). This may be an overkill--maybe the user wants to handle 'help'
    # specially--but since I'm the only user, I'm certain they do not.
    [[ $cmd = help ]] && _ArgParse_Invoke "$opspec" --help  # [noreturn]
    # TODO: A function to disambig by prefix may be helpful in other places.
    local -a candi=()
    for val in ${commands[*]}; do
      # Exact match is never ambiguous, even if a prefix to another word.
      # Note no += here, set the array to the only word and break the loop.
      [[ $cmd = $val ]] && { candi=($val); break; }
      # Take a candidate command if prefix match allowed
      [[ $do_unabbr && $val = ${cmd}* ]] && candi+=($val)
    done
    case ${#candi[*]} in
      0) Say "$(C r error): unknown command '$(C c)$cmd$(C)'"; cmd=help ;;
      1) cmd=$candi ;;  # Bingo!
      *) Say "$(C r error): ambiguous command '$(C c)$cmd$(C)'; can be:" \
             $(s=; for c in "${candi[@]}"; do
                     printf "%s'%s%s%s'" "$s" "$(C c)" "$c" "$(C)"; s=', '
                   done)'.'
         cmd=help ;;
    esac
    [[ $cmd = help ]] && _ArgParse_Invoke "$opspec" --help  # [noreturn]
    # The command in $cmd is expanded to one of words in $commands and confirmed
    # to be unique if -uc; or checked to be one in that list if -c alone.
    POPT_ARGV[0]=$cmd
  fi
  true
}

:<<COMMENTED_OUT

ops_common_options="
 Common options:
d,debug?N                 print verbose messages; the larger the N, the merrier.
n,dry-run                 show what would be done but don't do it.
y,yes!                    skip confirmation on most question.
"
# git parseopt indents ---^-- this to column 27. What's so special about 27?

echo -n 'After command parse; '; declare -p POPT_ARGV
echo "All OPT_ vars:"
declare -p $(compgen -v OPT_)

COMMENTED_OUT

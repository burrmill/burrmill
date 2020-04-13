# Include once from a script in lieu of standard ./path.sh, ./cmd.sh,
# call parse_options.sh etc. It must be linked to from the recipe's
# root directory, like 'ln -s ../bmutils/common.sh', and then sourced
# into scripts as
#
#  . ./common.sh
#
# The --runlog option enables all tty output be saved to a log file. It accepts
# a file name, the magic word 'auto' to write log with the default name, or
# +<suffix> to add -<suffix> to the default name. The default log is written to
# the log/ subdirectory; see below around lines 40-45. The log is always
# appended to, not overwritten. If restarting an experiment after a failed step,
# do not forget to replace the 'auto' or +suffix in command line with the real
# filename to continue logging to the same log.

. ./path.sh || return

if [ -f ./cmd.sh ]; then
  . ./cmd.sh || return
fi

# Common options.
: ${stage:=0}
: ${print_args:=true}
: ${runlog:=}

# ./cmd.sh may supply these; default to run.pl if not.
: ${train_cmd:=run.pl}
: ${decode_cmd:=$train_cmd}
: ${egs_cmd:=$train_cmd}
: ${mkgraph_cmd:=$train_cmd}

export decode_cmd egs_cmd mkgraph_cmd train_cmd

# Parse command line switches.
__args_before_parse="$0 $@"
source ./utils/parse_options.sh || return 1

# Begin logging if asked to, unless redirected already.
if [[ $runlog && ! ${__runlog_active:-} ]]; then
  if [[ -t 1 && -t 2 ]]; then
    case $runlog in
      auto) mkdir -p log
            runlog=log/$(date +%y%m%d-%H%M)-$(basename "$0" .sh).log
            ;;
      \+?*) mkdir -p log
            runlog=log/$(date +%y%m%d-%H%M)-$(basename "$0" .sh)-${runlog:1}.log
            ;;
    esac
    echo >&2 "Console output will be logged to $runlog"
    exec &> >(exec tee -a --output-error=exit "$runlog")
    # The next echo will fail is tee fails (e.g., log directory does not exist).
    echo >&2 "=== $(date '+%y%m%d %T') runlog $runlog started" || exit 1
    export __runlog_active=y
    # Note that in the trap expression $runlog is captured, but the date is not,
    # because the $ is escaped and the date command becomes part of the captured
    # string unevaluated. Also, the quotes around '$runlog' are evaluated on a
    # trap, and are not part of the printed string. This is to to protect
    # against the variable containing weird stuff or evaluable expression.
    trap "echo >&2 === \$(date '+%y%m%d %T') runlog '$runlog' closed" EXIT
  else
    echo >&2 "$0: warning: --runlog specified, but output does" \
             "not look like a terminal. Not logging."
  fi
fi

# Print the original saved arguments.
[ "$print_args" = "true" ] && echo >&2 $__args_before_parse
unset __args_before_parse

# Define additional common locations. The convention is to name variables
# declared in that file in upper case.
#
# Drawback: since they cannot be used as option defaults, either include
#       explicitly before sourcing this script (but do ensure idempotence)
#       and use values for switch defaults, or base switch defaults off
#       these values after this, using something like:
#
#           my_switch=${my_switch:-${DEFAULT_SET_IN_SOURCES}}

# TODO(kkm): change ./utils/parse_options.sh to parse lowercase options only?
if [ -f local/sources.sh ]; then
   . local/sources.sh || return
fi

# Common pervasives from our library. We expect it to exist, as long as this
# script is used. It should be found located in the same (real) directory.
. $(dirname $(realpath "$BASH_SOURCE"))/pervasives.sh || return

# Useful printout for stage timing using the time builtin. Best pairs with the
# form e.g. 'Stage 2 "Train mono model" && time { .... }'. The CPU readout makes
# no sense when run in a cluster; remove it if never using local machine. The
# TIMEFORMAT variable is described in the bash manual.
TIMEFORMAT=\
$'--------------------------------------------------------------------------------
Elapsed: %lR   CPU: %P%%
================================================================================\n'

true

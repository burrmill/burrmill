# Cannot use bash syntax here: Kaldi perl scripts use backticks to run commands
# sourcing this, and perl always uses sh (this is hardcoded and impossible to
# change), and sh is a symlink to dash on Debian 10, not bash.
#
# Why add /mill/bin to the path: I usually create an executable script 'run.pl'
# there (it does not have to be perl, Linux does not even look at the file
# extension; can be sh with the correct #!/bin/sh shebang) which prints an error
# and exits with code 1, to catch any run.pl hardcoded in scripts. We do not run
# programs from the NFS share, and reserve its bandwidth only for data.

# KALDI_ROOT is never used in scripts, and serves only as a marker.
if [ -z "${KALDI_ROOT-}" ]; then
  export KALDI_ROOT=y
  export PATH=$PATH:/mill/bin:$(realpath utils) ;;
fi
export LC_ALL=C

# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson
#
# This file was installed by BurrMill.
#
# Common file sourced into nearly every script.

# Tidy up name for logging: '.../slurm_resume.sh' => 'slurm-resume'
# Prefix with '_' to indicate an "internal" global variable.
_logname=$(basename "$0")
_logname=${_logname%%.*}
_logname=${_logname//_/-}

Log() {
  local level=$1; shift;
  [[ $level == *.* ]] || level=daemon.$level  # So we can use e.g. auth.notice.
  logger -p $level -t $_logname -- "$@"
}

Fatal() { Log alert "$@"; exit 1; }

# Defaults, use always for now.
_metadata_timeout=6      # Integer seconds.
_metadata_conntime=1.0   # Float seconds.

# _MetadataRequest <partial-url> [<curl-switch> ...]
_MetadataRequest() {
  local purl=$1; shift;
  curl "$@" --silent --fail --max-time $_metadata_conntime \
       --connect-timeout $_metadata_conntime  -HMetadata-Flavor:Google \
       http://169.254.169.254/computeMetadata/v1/$purl
}

# With one argument, perform a GET. With two arguments, PUT the second argument
# as data (-XPUT --data "$2", essentially). Setting metadata only works with the
# guest attribute stem instance/guest-attributes/.
GetSetMetadata() {
  local purl=${1?} optdata=(${2+-XPUT --data "$2"})
  local -i sleep last deadline=$((SECONDS + $_metadata_timeout))
  local http_code

  while ((SECONDS < deadline)); do
    last=$SECONDS

    # Try to get value. Unfortunately, curl cannot return both HTTP response
    # code and content in one request.
    _MetadataRequest $purl "${optdata[@]}" && return 0

    # Why failed? Returned value is always 3 digits. Interesting codes are:
    #  0xx = timeout or other error, retry after delay.
    #  2xx = success, retry immediately.
    #  4xx = no value, return error.
    #  5xx = internal error, retry after delay.
    # Anything else -- dunno, should not happen, but sleep and retry too.
    http_code=$(_MetadataRequest $purl "${optdata[@]}" \
                                 -o /dev/null -w '%{http_code}')
    [[ $http_code == 4* ]] && return 1  # 4xx = permanent failure.
    if [[ $http_code != 2* ]]; then     # not 2xx = delay before retrying.
      sleep=$((2 + last - SECONDS))
      ((SECONDS + sleep < deadline)) || return 1  # No point sleeping, too late.
      ((sleep > 0)) && sleep $sleep
    fi
  done
  return 1  # Timeout.
}

MetadataOrDie() {
  GetSetMetadata ${1?} || Fatal "unable to retrieve metadata '$1'"
}

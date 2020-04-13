#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# This file is run inside a Docker builder container. It prepares the layout in
# the /opt directory, which is then copied to the final image.
#
# Install only a minimal required MKL subset for sequential treading, dynamic
# libraries only and headers to reduce the size down to ~650MB.

set -euo pipefail

Die() { echo >&2 "$0: $@"; exit 1; }

WaitParallel() {
  local jobs=$(jobs -p) word nfail=0
  for word in $jobs; do
    wait -n || nfail=$((nfail + 1))
  done
  (( nfail > 0 )) && Die "$nfail downloads failed" || true
}

[[ ${_MKL_VER-} ]] || Die '$_MKL_VER is not set'

set -x

# Do not bother with installing Intel's public key, just relax the checks.
apt-get -qqy update
apt-get -qqy install apt-transport-https ca-certificates
echo > /etc/apt/sources.list.d/intel-mkl.list \
 'deb [trusted=yes allow-insecure=yes] https://apt.repos.intel.com/mkl all main'
apt-get -o 'Acquire::https::Verify-Peer=false' \
        -o 'Acquire::AllowInsecureRepositories=true' -qqy update

# apt-get will be angry if it can't sandbox downloads as user '_apt'.
chown _apt:root .

# First pass: download 4 debs, minimal dynamic rt for sequential threading and
# header filesd. Note that apt-get is fine with prefix names.
for deb in intel-mkl-64bit-${_MKL_VER}-    \
           intel-mkl-common-c-${_MKL_VER}- \
           intel-mkl-common-${_MKL_VER}-   \
           intel-mkl-core-rt-${_MKL_VER}-
do
  apt-get download $deb &
done
WaitParallel

# Next, add the 3 debs that set up correct links so that MKL is always in the
# same location referred to by a symlnk. They are versioned differently, so we
# must get their names from just downloaded deb files.
psxe_debs=$(for f in *.deb; do
              dpkg-deb -f $f Depends | tr -s ', ' '\n\n' |
                egrep '^intel-(comp-(l-all|nomcu)-vars|openmp)-'
            done | sort -u)
n_psxe_debs=$(wc -l <<<"$psxe_debs")
(( n_psxe_debs == 3 )) ||
  Die "found $n_psxe_debs out of 3 requred additional debs." \
      "Found:"$'\n'"$psxe_debs"

for deb in $psxe_debs; do
  apt-get download $deb &
done
WaitParallel

# Show the final list of debs in log.
ls >&2 -hl *.deb

# Last of all, install all the debs together, forcing dpkg to ignore unsatisfied
# dependencies; it prints warnings (there will be a lot!). This yields a smaller
# install size with only the necessary stuff intslalled. Still about 650MB, but
# much better than it could have been for a full install (about 1.5G).
dpkg --force-depends --recursive --install .

echo 'mkl:' $_MKL_VER > /opt/intel/mkl/.BMVERSION

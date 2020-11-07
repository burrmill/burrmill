#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

source "$(realpath -m "${BASH_SOURCE}/../preamble.inc.sh")"
source common.inc.sh
source daisy.inc.sh

set -euo pipefail

defaults=(
  --machine-type=e2-standard-4
  --image-family=debian-10
  --image-project=debian-cloud
  --boot-disk-size=20GB
  --boot-disk-type=pd-ssd
  --subnet=service
  --service-account=$acc_manage
  --scopes=cloud-platform
  --no-shielded-vtpm
)

if (( $# == 0 )); then
  cat >&2 <<EOF
$my0: Create a VM (temporary, usually) in the current cluster's service subnet.

The program requires at least one non-switch argument, the machine name.  All
command line arguments, following the default switches, are passed to
'$GC instances create'.

Later switches override previously specified, so the defaults may be overridden
by specifying a different value to the same switch.

The defaults are:
  '--zone={automatically selected based on the service subnet region}'
EOF
  printf '  %s\n' "${defaults[@]@Q}"
  exit 2
fi

svcreg=$(GetServiceRegion)
Say "Your service network is in the region $(C c)$svcreg"
# Select any zone in the region.
zone=$($GC zones list --filter="region=$svcreg AND status=UP" \
           --format='value(name)' --limit=1)

(set -x
 $GC instances create --zone=$zone "${defaults[@]}" "$@")

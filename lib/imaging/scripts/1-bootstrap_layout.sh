#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# Image customization phase 1. This machine mounts the future target as /mnt,
# downloads all files from the bucket pointed to by 'bucket_url' metadatum,
# extracts layout files (all *.tar.gz files) from the root of that directory
# over the target's root, runs specially named scripts if present, and keeps the
# remaining downloaded files (not *.tar.gz or the phase 1 scripts in the
# directory itself, or any file in a subdirectory) in the /.bootstrap directory
# of the target disk.
#
# In phase 2, that target drive is booted and customizes the OS from inside.
# This is what the final image is then built from.
#
# This script tries to be as generic as possible, and probably usable
# for all image builds that need a pre-applying layers of changes over
# the file system.

echo "BUILD_STARTED: $(date -Isec) Starting bootstrap build"

metaroot=http://metadata.google.internal/computeMetadata
cache=/mnt/.bootstrap

MetaAttr() {
  curl -sS -H Metadata-Flavor:Google $metaroot/v1/instance/attributes/$1
}

bucket_url=$(MetaAttr bucket_url)
echo "Source bucket: $bucket_url"

# Using a function so we have a common exit point to report results based on its
# exit code. We return on any failure, as it hardy makes sense to continue.
do_all() {
  if [[ ! $bucket_url ]]; then
    echo "'bucket_url' metadata is missing"
    return 1
  fi

  echo "Mounting target system /dev/sdb1 into /mnt"
  mount /dev/sdb1 /mnt || return
  # Stuff is sitting in /run in some images. Clean /home just in case, too.
  rm -rf /mnt/run/* /mnt/home/*

  echo "Recursively fetching all files from $bucket_url into $cache"
  mkdir -p $cache &&
    gsutil -q -m cp -r "${bucket_url}/*" $cache || return

  cd "$cache"

  echo "Locally cached files:"
  ls -Rlh .

  # Extract all layouts with an N- prefix in order.
  LC_ALL=C
  for arch in [0-9]-*.tar.gz; do
    # do not test -f: there must be some layouts, fail if not!
    echo "Extracting layout $arch"
    tar -xvvaf $arch --no-overwrite-dir --touch -C /mnt || return
    rm -v $arch
  done

  # If present, extract the addons artifact archive into /.bootstrap.
  arch=addons.tar.gz
  if [[ -f $arch ]]; then
    echo "Extracting artifacts from $arch into $cache"
    tar -xvvaf $arch --no-overwrite-dir --touch -C .  || return
    rm -v $arch
  fi
  unset arch

  # Apply the post-layout scripts, if present among the downloaded addons.
  for script in $cache/1_{,user_}post_layout; do
    if [[ -f $script ]]; then
      echo "Running phase 1 post-layout script $script"
      chmod +x $script
      ./$script || { echo "Script '$script' failed with exit code $?"
                     return 1; }
      rm -v $script
    fi
  done
  unset script

  echo "Remaining files in cache for the use by phase 2:"
  ls -Rlh .

  # We hot-unplug the disk from this machine before turning it off, because
  # g c m detach-disk is very quick, and there is no reason waiting while
  # the machine is stopped. Interesting that if requests to stop an instance
  # and detach a disk are issued at the same time, they both end at the same
  # time too--GCE blocks the changes to configuration while the machines is
  # stopped. In the Daisy workflow, we tear off the disk, then start the second
  # phase and stopping this instance at the same time. But if the disk is not
  # unspun before hot-disconnect, even unmounted, kernel spray-spits warnings.
  # Kudos to RedHat v7 manual, Sec. 25.9.
  echo "Trimming, unmounting and spinning down target filesystem and device."
  cd /
  local -  # So that set -x lasts only until return.
  set -x
  fstrim /mnt || return
  umount /mnt || return
  for d in $(lsblk /dev/sdb -lnoNAME); do
    blockdev --flushbufs /dev/$d || return
  done
  echo 1 > /sys/block/sdb/device/delete
}

do_all
err=$?

t_end=$(date -Isec)

# Daisy runs 2 polling pumps from the same VM's serial port: one logs to file,
# another watches for keywords. These are asynchronous. If they were in sync,
# then this sleep would not be needed: what you see in log is what the matcher
# have seen. But if the matcher matches and goes to the next step (and the next
# step is shut down the VM), the stop may lead to a truncated log, as the log
# pump might not yet have had a chance to flush the next chunk (the same one
# that was independently fetched by and acted on by the matcher pump!) before
# the machine is shut down. This is a Daisy defect that could potentially be
# fixed.
echo "Sleeping a bit because internal race in Daisy."
sleep 12

(( $err == 0 )) \
  && echo "BUILD_SUCCESS: $t_end Completed successfully." \
  || echo "BUILD_FAILURE: $t_end Errors were reported."

# This is a GCE limitation: serial output can be only pulled, not pushed, and
# only while the VM is still alive. If I were to shut down the machine right
# away, then Daisy would not likely see the above message at all, and neither of
# the two pull-push loops driven by a periodic timer would have had a chance to
# pump the trailing log chunk. So the WaitForSignal step might not even see the
# signal, or, if it'd be lucky to see it, the the puzzled me might end up with a
# truncated log. The second sleep is to allow these log readers a chance to pull
# log from the VM while it is still alive. This is by GCE design, and thus can
# be fixed in Daisy alone, unfortunately.
echo "Sleeping a bit more because race between Daisy and GCE serial log API."
sleep 10

echo "Powering off the bootstrap instance"
poweroff

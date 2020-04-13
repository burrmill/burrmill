#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

set -uo pipefail

# A Daisy-invoked script to build a snapshot of a new CNS disk, per assembly
# manifest passed in instance metadata in a gzip-compressed base64-encoded file.

readonly metaroot=http://metadata.google.internal/computeMetadata

# This is a non-retrying, simple version of the much more complex, production-
# quality function in lib/layouts/common/usr/local/sbin/burmill_common.inc.sh.
# The metadata server outages are practically is a non-thing (1 request in 10K
# on average); at the worst, Daisy build should be simply retried.
MetaAttr() {
  curl -fsS -HMetadata-Flavor:Google "$metaroot/v1/$1"
}

# Untar either 'opt/' or './opt/' directory. tar makes this quite non-trivial!
# See: https://serverfault.com/a/998062/279581
ExtractOptFromTar() {
  tar xv --no-anchored \
         --transform='s:^\(\./\)\?[^o][^p][^t]/:.deleteme/&:' \
         --show-transformed-names \
      opt/ &&
    rm -rf .deleteme
}

# A helper function to merge *{user,system}.slice.env files.
# E.g. cd /mnt/opt/etc; MergeSlices > environment
MergeSlices() {
  # Use the side effect of debug print in bash to perform a preliminary syntax
  # check: bash prints well-formed assignments. Skip the lines starting with a
  # '.' or 'export'; the latter are acceptable in slice files, but bash prints
  # the export and assignment as two separate statements, like
  #   + .somesource
  #   ++ export FOO=42
  #   ++ FOO=42
  # Empty PS4 suppresses the printing of the '+' in debug output. [MAN]PATH
  # assignments are treated specially by appending respective :${[MAN]PATH-} to
  # the end; the rest of variables is left as they are. Finally, "export " is
  # prepended to all lines.
  #
  # The exports are sanitized further at the time of import, with empty elements
  # removed, and once explicitly added to MANPATH only, which is treated by man
  # as the default search MANPATH.
  for f in *.${1?}.slice.env; do
    (PS4=''; set -x; . $f)
  done 2>&1 |
    perl -lne \
         ' if (/^\.\s+\S/) { $f = substr($_, 2); print "# " . $f; }
           next if /^(\.|export\s)/;
           /^((MAN)?PATH)=/ and $_ .= ":\${$1-}";
           /^[\p{L}_][\p{L}\d_]*=/ or
              die "ERROR: Not a variable assignment in $f: \"$_\"\n";
           print "export " . $_ '
}

# Use a function, so there is a common exit point to report results based on its
# exit code. Return on any major failure, as it hardy makes sense to continue.
do_all() {
  readonly manifest=/.manifest dev=/dev/sdb

  MetaAttr instance/attributes/manifest |
    base64 -d | gunzip -c >$manifest || return
  echo 'Assembly manifest:'
  echo '----------------'
  cat $manifest
  echo '----------------'

  if [[ ! -s $manifest ]]; then
    echo "Deployment manifest is missing or empty. Check messages above."
    return 1
  fi

  myname=$(MetaAttr instance/name) || return
  myzone=$(MetaAttr instance/zone) || return
  myzone=$(basename "$myzone")
  echo "Running on machine '$myname' in zone '$myzone'"

  snapshot=$(MetaAttr instance/attributes/snapshot) || return
  echo "Target snapshot name: '$snapshot'"

  # Target disk is the second one attached to this VM.
  diskname=$(gcloud compute instances describe $myname \
                    --zone=$myzone \
                    --format='get(disks[1].source)' ) || return
  echo "Disk full resource name: '$diskname'"

  [[ $myname && $myzone && $diskname && $snapshot ]] ||
    { echo "One of the values above came up empty. This is fatal."; return 1; }

  echo "Formatting $dev"

  # Note that this disk will be eternally R/O.
  mkfs.ext4 -b4096 -I128 -i4194304 -LBURRMILL_CNS -m0 -M/opt \
            -O^huge_file,^ext_attr,^extra_isize,sparse_super2 \
            -Elazy_itable_init=0,lazy_journal_init,discard $dev  || return

  tune2fs -c0 -i0 -o^acl,^user_xattr,discard,nodelalloc $dev  || return

  echo 'dumpe2fs report of the filesystem:'
  dumpe2fs -h $dev

  # We do not mount into /opt, because tar expansion may cause other directories
  # to pop up, and interfere with the system if they are in '/'. This way, they
  # will land under /mnt.
  echo "Mounting target filesystem $dev into /mnt/opt"
  mkdir -p /mnt/opt
  mount -orw,noatime,discard $dev /mnt/opt || return

  cd /mnt

  image_registries=$(
    perl <$manifest -lne '($t,$a)=(split)[2,3];
                          $a=~s:/.*::;
                          print "https://$a" if $t eq "image"' |
      sort -u) || return

  if [[ $image_registries ]]; then
    echo "All image registries in the manifest: [" $image_registries "]"
    echo "Installing Docker snap package"
    snap install docker || return
    for reg in $image_registries; do
      echo "Authenticating gcloud against registry $reg"
      # The only weird way to auth gcloud snap in docker snap.
      docker login -u oauth2accesstoken \
             -p "$(gcloud auth print-access-token)" $reg || return
    done

    images=$(awk <$manifest '$3=="image" {print $4}') || return
    for im in $images; do
      echo "Pulling image $im"
      docker pull $im  >/dev/null || return

      echo "Extracting image $im"
      # Docker needs an entrypoint command, for our drone images have none.
      # We use 'true', even though it's not present; as good as anything.
      docker container create --name work $im true >/dev/null || return
      docker container export work | ExtractOptFromTar || return
      docker container rm work >/dev/null || return
      docker image rm $im >/dev/null || return
    done
  fi

  gsobjects=$(awk <$manifest '$3=="gs" {print $4}') || return
  for gs in $gsobjects; do
    echo "Fetching and extracting $gs"
    gsutil cat "$gs" | gunzip -c | ExtractOptFromTar || return
  done

  # Merge all *.slice.env files to their destinations, and then remove.
  echo "Combining and removing .slice.env files"
  cd /mnt/opt/etc || return
  shopt -s nullglob
  MergeSlices system >sysenvironment || return
  MergeSlices user >environment || return
  shopt -u nullglob
  rm -fv *.{system,user}.slice.env

  echo "------- Merged /opt/etc/environment ----------"
  cat environment
  echo "------- Merged /opt/etc/sysenvironment -------"
  cat sysenvironment
  echo "----------------------------------------------"

  # Uncomment these next two lines, and increase Daisy timeout so it won't kill
  # instance while you are looking into it, to ssh into the VM and debug if
  # anything does not go right, or to debug this script.
  #
  # Afterwards, kill Daisy with SIGINT (Ctrl+C) afterwards, and it will
  # immediately clean up everything, both the VM and the protodisk.

  #echo "Breaking the script. ssh into the instance and debug it"
  #exit

  echo "Trimming and unmounting $dev"
  cd /
  fstrim /mnt/opt || return
  umount /mnt/opt || return

  # Figure out manifest labels for the snapshot. BurrMill must slap a label
  # 'burrmill' with the value 'y' on everything managed through its tools
  # (and please let me know if it's missing). Resources with the 'disposition=p'
  # label are permanent, and are exempt from garbage collection, which I never
  # had time to implement, but some day, like, maybe...
  labels='--labels=burrmill=1,disposition=p,disklabel=burrmill_cns'
  labels+=$(awk <$manifest '{printf ",bmv_%s=%s",$1,$2}') || return

  echo "Creating snapshot $snapshot from disk $diskname"
  (set -x
   gcloud compute disks snapshot \
          --snapshot-names=$snapshot $labels $diskname) || return

  echo "Assembly complete"
  true
}

echo "BUILD_STARTED: $(date -Isec) Starting CNS disk assembly"

do_all
err=$?

t_end=$(date -Isec)

# Daisy runs 2 polling pumps from the same VM's serial port: one logs to file,
# another watches for keywords. These 2 are asynchronous. If they were in sync,
# then this sleep would not be needed: what you see in log is what the matcher
# have seen. But if the matcher matches and goes to the next step (and the next
# step is shut down the VM), the stop may lead to a truncated log, as the log
# pump might not yet have had a chance to flush the next chunk (that which had
# been already seen and acted on by the matcher pump!) before the machine is
# shut down. This is a Daisy defect that could potentially be fixed.
echo "Sleeping a bit because internal race in Daisy."
sleep 15

(( $err == 0 )) \
  && echo "BUILD_SUCCESS: $t_end Completed successfully." \
  || echo "BUILD_FAILURE: $t_end Errors were reported."

# This is a GCE limitation: serial output can be only pulled, not pushed, and
# only while the VM is still alive. If I were to shut down the machine right
# away, then Daisy would not likely see the above message at all, and neither of
# the two pull-push loops driven by a periodic timer would have had a chance to
# pump the trailing log chunk. Thus the WaitForSignal step might not even see
# the signal, or, if it'd be lucky to see it, then the puzzled me might end up
# with a truncated log. The second sleep is to allow these log readers a chance
# to pull the log from the running VM. This is by GCE design, and cannot be
# fixed in Daisy alone, unfortunately.
echo "Sleeping a bit more because race between Daisy and GCE serial log API."
sleep 10

# Just in case Daisy does miss the flag.
poweroff

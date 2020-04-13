#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# This file is run inside a cxx Cloud Builder container to build Slurm, stage
# its layout and then package it into a single tar.gz artifact. This archive is
# then uploaded into the 'software' bucket during build.
#
# Slurm source is expected to be checked out into the directory ./slurm, but
# this can be overridden with an argument $1. This is only used in maintainer
# mode, to debug the build interactively in a local-cxx container.
#
# 'make install' puts the files into the staging directory ./opt, which is then
# compressed into the archive and left in this directory for upload.

Banner() { echo >&2 "
#==============================================================================
# $(date '+%y%m%d %T') :: $@"$'\n'; }

my_dir=$(dirname "$(realpath "${BASH_SOURCE[0]}")")

slurm_src=${1-$my_dir/slurm}
stage_root=$my_dir/opt

cd "$slurm_src" || exit

# E.g., '19.05.4-1'
slurm_ver=$(awk '/Version:/{v=$2} /Release:/{r=$2;print v "-" r;exit}' META)
[[ ! $slurm_ver ]] &&
  { echo >$2 "Cannot get slurm version from META"; exit 1; }

# E.g., '191114-ge3f7d35', where 191114 is the (UTC) commit date.
git_ver=$(
    TZ=UTC git log -1 --format=%cd-g%h --abbrev=9 --date=format-local:%y%m%d)
[[ ! $git_ver ]] &&
  { echo >$2 "Cannot get source stamp from git commit"; exit 1; }

slurm_dash_ver=slurm-${slurm_ver}+${git_ver}
installpath=$stage_root/$slurm_dash_ver

# Key to absolute path directories:
# stage_root  => deployed /opt
# installpath => deployed /opt/slurm-XX.YY.Z

# UTC build time, e.g. 191115-1345, to plug into filenames, like log files.
buildtime=$(date -u +%y%m%d-%H%M)

set -eu
trap 'Banner BUILD FAILED; exit 1' ERR

rm -rf $stage_root/*
mkdir -p $installpath

logfile="$installpath/${slurm_dash_ver}-build-${buildtime}.log"

# Save the original stdout in fd 4 and stderr in 5.
exec 4>&1 5>&2 &> >(exec tee --output-error=exit "$logfile")

Banner 'Patch Slurm source'

patch=sbatch.19.patch

if git &>/dev/null apply --ignore-space-change -R --check $my_dir/$patch; then
  echo "Patch $patch had been already applied"
else
  echo "Applying $patch"
  git apply --ignore-space-change $my_dir/$patch
fi

unset patch

Banner 'Configure Slurm build' ${slurm_dash_ver}

( set -x
  ./configure  \
    --prefix=/opt/$slurm_dash_ver --sysconfdir=/etc/slurm --localstatedir=/var \
    --sharedstatedir=/var/local --runstatedir=/run \
    --disable-debug --disable-static --with-pic --enable-iso8601 \
    --disable-x11 --enable-gtktest=no --disable-pam --without-hdf5 \
    --without-pmix --without-ucx  --without-ofed --without-netloc \
    --without-freeipmi --without-nvml --without-rrdtool --without-datawarp \
    --with-munge --with-hwloc --with-json --with-zlib --with-lz4 \
    --with-libcurl --with-readline
)
# Expected configure warnings (grep the log):
#:282:configure: WARNING: support for ofed disabled
#:293:configure: WARNING: Sorry, yes does not exist, checking usual places
#:299:configure: WARNING: yes does not exist, checking usual places
#:306:configure: WARNING: support for nvml disabled
#:307:configure: WARNING: support for pmix disabled
#:308:configure: WARNING: support for freeipmi disabled
#:309:configure: WARNING: support for rrdtool disabled
#:331:configure: WARNING: cannot build sview without gtk library
#:334:configure: WARNING: unable to locate DataWarp installation
#:348:configure: WARNING: support for netloc disabled
#:350:configure: WARNING: unable to locate lua package
#:352:configure: WARNING: unable to build man page html files without man2html

make clean &>/dev/null

Banner 'Make Slurm'

( set -x
  make -j$(nproc) all )

Banner 'Install Slurm'

( set -x
  make install prefix='' DESTDIR=$installpath )
# Expected libtool warnings:
# libtool: warning: '-version-info/-version-number' is ignored <...>
# libtool: warning: remember to run 'libtool --finish<...>
# libtool: warning: <...>/libslurmfull.la' has not been installed in <...>

Banner 'Create SOMANIFEST'

# Get a manifest of required DLLs
somanifest="$installpath/${slurm_dash_ver}-build-${buildtime}.SOMANIFEST"
( echo "Dynamic libraries required by $slurm_dash_ver:"
  find "$installpath" -type f -executable |
    xargs readelf -d 2>/dev/null | fgrep ' (NEEDED) ' | sort -u |
    perl -pe '{ s/^.*\[(.*)\]/$1/ }'
) | tee "$somanifest"

Banner 'Create links and install /opt/etc files'

ln -Tsfrv $installpath $stage_root/slurm
cp -rv $my_dir/etc $stage_root
mkdir -p $stage_root/etc/bash_completion.d
cp -v contribs/slurm_completion_help/slurm_completion.sh \
         $stage_root/etc/bash_completion.d
cp -v config.log NEWS RELEASE_NOTES $installpath
echo 'slurm:' $slurm_ver >$installpath/.BMVERSION

Banner 'Slurm build complete'

# Close logfile and restore original stdout/err before tarballing.
exec 1>&4- 2>&5-

Banner 'Package tarball slurm.tar.gz'

cd $my_dir
tar -cvvaf slurm.tar.gz --sort=name --owner=0 --group=0 opt

Banner 'Prepare artifact metadata in file GS_METADATA'

# Write metadata headers for gsutil.
md5=$(md5sum slurm.tar.gz | head -c32 | xxd -r -p - | base64)
cat <<EOF >GS_METADATA
-hx-goog-meta-version:$slurm_ver
-hx-goog-meta-source:$git_ver
-hContent-MD5:$md5
EOF

cat >&2 GS_METADATA

Banner 'Completed successfully'

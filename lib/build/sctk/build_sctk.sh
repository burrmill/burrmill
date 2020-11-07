#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# This file is run inside a cxx Cloud Builder container to build SCTK, stage its
# layout and then package it into a single tar.gz artifact. This archive is then
# uploaded into the 'software' bucket during build.

# SCTK is versioned, but has no version tags, so we use a 9-digit Git hash in
# lieu of the version. The hashtag of the current version 2.4.11 is 20159b580 at
# https://github.com/usnistgov/SCTK, the SCTK official distribution repo.

# The SCTK packaging and installation is quite non-standard. Build steps are
# simple, but result in a somewhat messy layout: if R is the source tarball
# root, binaries are installed by 'make install' into R/bin, and include unit
# tests; both documentations and man .1 files end up in R/doc. We opt for a more
# standard layout:
#  /opt/sctk/bin        - binaries.
#  /opt/sctk/share/man  - manpages.
#  /opt/sctk/share/doc  - HTML documentation.

# A hefty part of this code is boilerplate. Define this variable to name the
# thing that we are building. Everywhere you see the word 'thing', it refers to
# that name: a directory that contains the name of the software, a description
# string etc. Our convention is to lowercase the 'thing'. Spaces aren't allowed.
readonly thing=sctk

set -euxo pipefail

my_dir=$(dirname "$(realpath "${BASH_SOURCE[0]}")")

sctk_src=$my_dir/sctk
stage_root=$my_dir/opt

cd $sctk_src

stage_root=$my_dir/opt
thing_src=$my_dir/$thing

cd $thing_src

# E.g., '201114-g12345cdef', where 201114 is the commit date in committer's TZ.
git_stamp=$(git log -1 --format=%cd-g%h --abbrev=9 --date=format:%y%m%d)

thing_ver=${git_stamp#*-g} # E.g., 12345cdef, KenLM has no version.
thing_subdir=$thing-${_SCTK_INFO_VER+$_SCTK_INFO_VER-}$git_stamp
installpath=$stage_root/$thing_subdir
mkdir -p $installpath

# Key to absolute path directories:
# stage_root  => deployed /opt
# installpath => deployed /opt/sctk-XX.YY.Z

# Build, test and install sctk the best we can.
cflags='-g -O2 -mavx2 -fuse-ld=gold -Wno-pointer-compare'
make -C doc all
CFLAGS=$cflags CXXFLAGS=$cflags make config
make all
make check
make install

# Post-install cleanup.
rm -fv bin/*[Uu]nit doc/{*.pod,html2man.pl,export.sh,makefile}

# Shuffle stuff around where it belongs.
mkdir -p $installpath/share/man/man1
mv doc/*.1 $installpath/share/man/man1
mv doc     $installpath/share/
mv bin     $installpath/
mv -v CHANGELOG DISCLAIMER LICENSE.md README.md $installpath

# Create links and install /opt/etc files.
echo "${thing}:${thing_ver}" >$installpath/.BMVERSION
ln -Tsfrv $installpath $stage_root/$thing
mv -v $my_dir/etc $stage_root

# Package tarball sctk.tar.gz'
cd $my_dir
tar cvvaf $thing.tar.gz --sort=name --owner=0 --group=0 opt

# Write metadata headers for gsutil.
cat <<EOF >GS_METADATA
-hx-goog-meta-version:$thing_ver
-hx-goog-meta-source:$git_stamp
EOF

[[ ${_SCTK_INFO_VER-} ]] &&
  echo "-hx-goog-meta-info-version:$_SCTK_INFO_VER" >> GS_METADATA

cat GS_METADATA

echo "SCTK build complete."

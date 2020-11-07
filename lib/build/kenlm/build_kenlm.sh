#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# This file is run inside a cxx Cloud Builder container to build SCTK, stage its
# layout and then package it into a single tar.gz artifact. This archive is then
# uploaded into the 'software' bucket during build.

# KenLM is not versioned, so we use a 9-digit Git hash in lieu of the version.
# Also, binary names are so indistinct (like 'query', 'filter' etc.) that we
# prepend 'kenlm-' to their names, to avoid a conflict when they are added to
# the PATH.

# A hefty part of this code is boilerplate. Define this variable to name the
# thing that we are building. Everywhere you see the word 'thing', it refers to
# that name: a directory that contains the name of the software, a description
# string etc. Our convention is to lowercase the 'thing'. Spaces not allowed.
readonly thing=kenlm

set -euxo pipefail

my_dir=$(dirname "$(realpath "${BASH_SOURCE[0]}")")

stage_root=$my_dir/opt
thing_src=$my_dir/$thing

cd $thing_src

# E.g., '201114-g12345cdef', where 201114 is the commit date in committer's TZ.
git_stamp=$(git log -1 --format=%cd-g%h --abbrev=9 --date=format:%y%m%d)

thing_ver=${git_stamp#*-g} # E.g., 12345cdef, KenLM has no version.
thing_subdir=$thing-$git_stamp
installpath=$stage_root/$thing_subdir
mkdir -p $installpath

# These will become absolute path directories when untarballed on the CNS disk:
# stage_root  => deployed /opt
# installpath => deployed /opt/thing-201010-g123456789
# srage_root/$thing will be a symlink to $installpath.

rm -rf build/*
mkdir -p build
cd build
cmake .. \
  -DCMAKE_VERBOSE_MAKEFILE=ON \
  -DCMAKE_CXX_FLAGS='-mavx2 -fuse-ld=gold' \
  -DCMAKE_LINKER=/usr/bin/ld.gold \
  -DCMAKE_INSTALL_PREFIX=$installpath \
  -DCOMPILE_TESTS=ON \
  -DBoost_USE_STATIC_LIBS=ON

make -j $(nproc)
make test
make install

cd $thing_src
mv -v COPYING COPYING.3 COPYING.LESSER.3 LICENSE README.md $installpath

# Create links and install /opt/etc files.
echo "${thing}:${thing_ver}" >$installpath/.BMVERSION
ln -Tsfrv $installpath $stage_root/$thing
mv -v $my_dir/etc $stage_root

# Add 'kenlm_' prefix to binaries, and remove lib/ and include/.
cd $installpath
rm -rf include lib
cd bin
for f in *; do
  [[ $f = kenlm_* ]] || mv -v $f kenlm_$f
done

# package tarball kenlm.tar.gz'
cd $my_dir
tar cvvaf $thing.tar.gz --sort=name --owner=0 --group=0 opt

# Write metadata headers for gsutil.
cat <<EOF >GS_METADATA
-hx-goog-meta-version:$thing_ver
-hx-goog-meta-source:$git_stamp
EOF

cat GS_METADATA

echo "KenLM build complete."

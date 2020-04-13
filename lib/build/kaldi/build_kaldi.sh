#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# This file is run inside an augmented cxx Cloud Builder container, with MKL and
# CUDA added (see the ./builder subdirectory), to build Kaldi, stage its layout
# and then package it into a single tar.gz artifact. This archive is then
# uploaded into the Software bucket during the last stage of the build.
#
# You can build a similar container in Docker on your own machine. Check the
# directory 'build/local-cxx' which has a README.md file. You'll need to build
# the MKL and CUDA containers in the GCB and pull them (they're free to build).
#
# Kaldi source is expected to be checked out into the directory ./kaldi, but
# this can be overridden with an argument $1 (unless it starts with a '-', which
# indicates a switch and is passed to make, see below). This is only used in
# maintainer mode, to debug the build interactively in the local-cxx container.
# To sum up, the invocation syntax is:
#
#   build_kaldi.sh [kaldi_root] [--] [make_option...]
#
# Runtime Kaldi files are laid out in the staging directory ./opt, which is then
# compressed into a tarball and left in this directory for upload.
#
# Remaining arguments are passed to make. When not given any, '-j$(ncpu)' is
# used, or none if $(ncpu) returns one CPU (but there better be 16 or more, for
# sanity's sake; the build will take over 3 hours on asingle GCE vCPU). Also,
# all build machine types, currently offered n1-highcpu-{8,32}, are kinda low on
# RAM for the Kaldi build:
#
# * On the 8-vCPU variant, use '-j6', or it *will* fail. Time to complete with
#   '-j6' is about 35 minutes, current cost $0.56/build.
# * On the 32-vCPU one, use '-j24' or no argument for the default '-j32'; we do
#   not reach this many anyway. Time to complete 15 minutes, cost $1.00. This is
#   the default in our cloudbuild.yaml. Go for this splurge!
# * Just '-j' won't work on any machine, GCE or not, because make will spawn a
#   few hundred jobs and die.
#
# We could *try* to detect running under GCB, but that is likely unreliable.
# Better give the script an explicit argument. 3/4 * number of CPUs is likely
# fine, in case new "highcpu" (or "lowmem", if your glass is half-empty) machine
# types are added.

# Stuff you may possibly customize.
kshared=y  # Build Kaldi with --shared. Empty for no ('n' is also a  yes!).
export CXXFLAGS='-mavx2 -O2 -fuse-ld=gold -fdiagnostics-color=always'
openfstver=1.6.9    # Kaldi uses 1.6.7 by default; 1.6.9 compiles cleaner.

# P100 = 60, V100 = 70, T4 = 75. Fatbin them all! V100 is not economically
# feasible, although 25% faster than P100, if time is more important than
# money. The T4 I did not compare yet. Make sure to fatbin your exact arch.
cuda_arch="\
 -gencode arch=compute_60,code=[sm_60,compute_60] \
 -gencode arch=compute_70,code=[sm_70,compute_70] \
 -gencode arch=compute_75,code=[sm_75,compute_75]"

# Binaries that we collect. Omit the new CUDA decoding stuff, the obsolete nnet,
# sgmm2 and online binaries. Add any extensions you need here.
bindirs="bin chainbin featbin fstbin gmmbin ivectorbin kwsbin \
         latbin lmbin nnet2bin nnet3bin online2bin rnnlmbin"

# Print a little banner to separate log sections
Banner() { echo >&2 "
#==============================================================================
# $(date '+%y%m%d %T') :: $@"$'\n'; }

# Print, one per line, *simply-named* Makefile targets in the subdirectory ./$1,
# or, if no argument provided, in the current directory. A Makefile target is
# *simply-named* if its name consists of letters, numbers and dashes only, and
# is not one of the well-known targets, such as 'all', 'clean' etc. Kaldi has no
# concept of install; use this function to collect built binaries declared in
# the directory's Makefile.
GetTargets() {
  make -C ${1-.} -npq |
    perl -ne 'print "$1\n" if /^([a-z0-9-]+):\s/ and
            not /^(all|(dist)?clean|test|valgrind|depend|Makefile):/'; }


my_dir=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
stage_root=$my_dir/opt      # Abs. path to the ./opt staging area.
cuda_root=/opt/nvidia/cuda

# $1 may be a directory name to override Kaldi source tree location when running
# the build locally in a container, or a make argument, possibly the first of a
# few, which are all passed to all invocations of make. Use '--' to separate
# make arguments if they are not switches starting with the '-'.
#     ${1:--} expands to just a '-' if null, thus matches.
if [[ ${1:--} != -* ]]; then
  kaldi_tree=$(realpath "$1"); shift
else
  kaldi_tree=$my_dir/kaldi
fi

[[ ${1:-} = -- ]] && shift

# Augmented command aliases.
# 'Make' uses arguments of this script, or if none, defaults to '-j<num_cpus>'
(($#)) && _make_args=("$@") || _make_args=(-j$(nproc))
readonly _make_args
Make() { (set -x; make "${_make_args[@]}" "$@"); }

# '$CP' is like 'cp' only copies softlinks as is, and is verbose.
CP="cp -vP --preserve=mode,links"

set -eu
trap 'Banner BUILD FAILED; exit 1' ERR

cd "$kaldi_tree"

# Kaldi is not versioned or tagged, so use date and commit as the version.
# E.g., '191207-g6f329a62e'. The date is local to the committer's timezone.
version=$(git log -1 --format=%cd-g%h --abbrev=9 --date=format:%y%m%d)

kaldi_dash_ver=kaldi-$version
installpath=$stage_root/$kaldi_dash_ver

rm -rf $installpath/  # For a local build.
mkdir -p $installpath/{bin,lib/test/{cpu,gpu}}

buildtime=$(date -u +%y%m%d-%H%M)
logfile="$installpath/${kaldi_dash_ver}-build-${buildtime}.log"

# Save the original stdout in fd 4 and stderr in 5.
exec 4>&1 5>&2 &> >(exec tee --output-error=exit "$logfile")

Banner 'Starting Kaldi build' $kaldi_dash_ver

Banner 'Make tools'

cd "$kaldi_tree"/tools

rm -rf openfst*/{bin,lib}  # For a local build.

# extras/check_dependencies.sh will demand a lot of stuff not required at build
# time, and is hard not to bump into. Overwrite it to succeed trivially. Sorry
# about your local directory.
echo '#!/bin/sh' > extras/check_dependencies.sh

Make CXXFLAGS="$CXXFLAGS" OPENFST_VERSION="$openfstver" \
     OPENFST_CONFIGURE="--disable-dependency-tracking" \
     openfst cub

Banner 'Configure Kaldi'

cd "$kaldi_tree"/src

rm -rf lib/  # For a local build.

( set -x
  ./configure ${kshared:+--shared} \
              --cudatk-dir="$cuda_root" --cuda-arch="$cuda_arch" )

# This is a bug that has been on my laundry list for a while.
[[ ${kshared} ]] ||
  sed -i '/^CUDA_INCLUDE/ s/-fPIC//' kaldi.mk

# Locate the value of the SUBDIRS = ... make variable, and get its value,
# excluding anything ending in 'bin', and also lib directories sgmm2, online
# (obsolete) and cudafeat, cudadecoder (too specific). Note that nnet2bin has an
# actual dependency on the nnet lib, so we cannot exclude this lib.
libsubset=$(make -npqrR | perl -ne 's/^SUBDIRS\s*=\s*// && do {
   s/\b(cuda(feat|decoder)|online|sgmm2|[a-z0-9]*bin)\b//g; print };')

# Build some smoke tests. Also, matrix-lib-speed-test, normally disabled in the
# Makefile, is useful for the comparison between different GCE vCPU types.
cpu_tests=$(GetTargets matrix | grep -- '-test$')' matrix-lib-speed-test'
gpu_tests=$(GetTargets cudamatrix | grep -- '-test$')

Banner 'Make Kaldi'

Make depend
Make clean   # For a local build.
Make all "SUBDIRS=$libsubset $bindirs"

# Build some tests useful later for smoke-testing the cluster. Need the
# TESTFILES hack, otherwise the added matrix-lib-speed-test does not link.
Make -C matrix "TESTFILES=$cpu_tests" $cpu_tests
Make -C cudamatrix $gpu_tests

Banner 'Stage Kaldi in' $installpath

# Use $CP -l to hardlink: it's much faster, since the binaries are huge.
# And yes, if you are wondering, you can hardlink a symlink.
for d in $bindirs; do
  bins=$(GetTargets $d | grep -v -- '-test$')
  (cd $d && $CP -l $bins $installpath/bin/)
done

# Shared Kaldi libs are symlinked into ./lib, need dereferencing before copying
# (hardlinking, really). This is the opposite of what $CP does, use plain cp.
[[ ${kshared} ]] &&
  cp -lLpv lib/*.so $installpath/lib/

# Collect the smoke and perf assessment tests we built.
(cd matrix && $CP -l $cpu_tests $installpath/lib/test/cpu)
(cd cudamatrix && $CP -l $gpu_tests $installpath/lib/test/gpu)

cd "$kaldi_tree"

# Collect OpenFST binaries and libs.
$CP -l  tools/openfst/bin/* $installpath/bin/
$CP -lr tools/openfst/lib/* $installpath/lib/

Banner 'Create SOMANIFEST'

# Build a manifest of required DLLs. Looking for readelf output lines like:
#   0x0000000000000001 (NEEDED)     Shared library: [libpthread.so.0]
somanifest="$installpath/${kaldi_dash_ver}-build-${buildtime}.SOMANIFEST"
( echo "Dynamic libraries required by $kaldi_dash_ver:"
  find "$installpath" -type f -executable |
    xargs readelf -d 2>/dev/null | fgrep ' (NEEDED) ' | sort -u |
    perl -pe '{ s/^.*\[(.*)\]/$1/ }'
) | tee "$somanifest"

Banner 'Create links and install /opt/etc files'

echo 'kaldi:' $version >$installpath/.BMVERSION
$CP -lr egs/wsj/s5/{utils,steps} $installpath/lib/
$CP src/kaldi.mk $installpath
$CP -r $my_dir/etc $stage_root
ln -Tsfrv $stage_root/$kaldi_dash_ver $stage_root/kaldi

Banner 'Kaldi build complete'

# Close the logfile and restore original stdout/err before tarballing.
exec 1>&4- 2>&5-

Banner 'Packaging tarball kaldi.tar.gz'

cd $my_dir

# pigz is parallel gzip, very fast on a multi-CPU machine.
tar -cvv --sort=name --owner=0 --group=0 opt | pigz -c >kaldi.tar.gz

Banner 'Prepare artifact metadata in file GS_METADATA'

# Save metadata headers for gsutil. Since Kaldi is unversioned (did I already
# mention that, no?), use Git hash for the Version metadatum, so that it
# compares with the _KALDI_VER passed to the build, and use the full $version
# of the form '191207-g6f329a62e' as the Source metadatum.
md5=$(md5sum kaldi.tar.gz | head -c32 | xxd -r -p - | base64)
cat <<EOF >GS_METADATA
-hx-goog-meta-version:${version#*-g}
-hx-goog-meta-source:$version
-hContent-MD5:$md5
EOF

{ echo; cat GS_METADATA; echo; } >&2

Banner 'Completed successfully'

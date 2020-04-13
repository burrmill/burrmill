#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# Unpack source, build, test and package SRILM inside the cxx build step
# container under Cloud Build. This script is extensively commented to serve as
# an example for the user to add their own software packages such that they
# available on all cluster nodes.

# -e = Fail on any unsuccessful exit code from any command immediately.
# -u = Fail if using an undefined variable.
# -x = Echo executed commands. This is helpful to see in the build logs.
set -eux

# Our source srilm tar is already in the working directory by now. First of all
# unpack it into a subdirectory where we can build it. We'll delete the source,
# tarball to avoid a possible confusion with the packaged artifact tarball, also
# called srilm.tar.gz (without the version in the name in our case, but artifact
# files with a version suffix are also supported).

mkdir -p srilm
tar xf srilm-*.tar.gz -C srilm
rm srilm-*.tar.gz

# Next, configure the build; for details, read the file INSTALL from the SRILM
# source tarball. SRILM is not using autoconf, and there is no 'configure' file
# with command-line options. Instead the build is tweaked by placing an optional
# file with a special name into the 'common/' subdirectory. The name must match
# the "machine type", as defined by SRILM, so we'll use the same script that
# SRILM uses itself to determine this "machine type" name.

cd srilm
machine_type=$(./sbin/machine-type)

# Enabling the AVX2 instructions is always a good idea: there is no architecture
# older than Haswell anywhere on GCE, and AVX2 is supported on it. gcc does not
# automatically vectorize for AVX512 anyway, as far as I know.
#
# liblbgfs is installed in our standard compute image and the cxx builder, so
# we can opt in to use it.
cat <<EOF >common/Makefile.site.$machine_type
NO_TCL = X
HAVE_LIBLBFGS = 1
CXXFLAGS += -fdiagnostics-color=always -march=haswell -mavx2 \
            -Wno-class-memaccess -Wno-format-overflow -Wno-restrict
EOF

# SRILM build also requires the environment variable 'SRILM' be set to the
# absolute root path of the source.

export SRILM=$(realpath .)

# Now we can build it (the main target named 'World' in SRILM, not 'all')...
make World

# ...and run tests.
make test

# SRILM's build places platform-independent scripts under bin/, but binaries
# under bin/$machine_type. There is not much sense in maintaining this
# distinction; just move all executable files into the flat bin/ directory.
mv bin/$machine_type/* bin/
rmdir bin/$machine_type

# Our packaging has the following conventions. An artifact tarball created by
# the build will be extracted into the root of the filesystem, with the future
# CNS disk mounted at /opt, so all files in the tarball must be prefixed with
# 'opt/'. The same disk in turn will be mounted read-only at the /opt mount
# point on every machine in the cluster. We also put a .BMVERSION file into the
# root of every software package. It does not have to be at any specific depth:
# we have, for example, opt/kaldi/.BMVERSION and opt/intel/mkl/.BMVERSION. The
# content of the file is a single line, of the form 'package: version'. This is
# used to label the software disk and its snapshot, so it's possible to see what
# packages and versions have been collected during the disk assembly process in
# the Cloud Console or using command-line tools.
#
# We also use versioned path link with unversioned link, like
#
# opt/srilm-1.7.1/
# opt/srilm -> ./srilm-1.7.1
#
# so that you can quickly see the installed version just by looking into the
# /opt directory when the disk is mounted on a node. This is optional, and done
# just for this convenience.

# The RELEASE file from the surce distribution contains a single line with the
# SRILM version, e.g. 1.7.1. This will go into the versioned name of the package
# directory. Note that variables from the cloudbuild.yaml file may also be
# exported into the environment of a build step using the 'env:' stanza. It's
# always your call to take one or the other as the ground truth for the version;
# comparing the two and failing the build if they do not match is also a good
# idea (which I neglect here for simplicity).
version=$(cat RELEASE)

cd ..  # Back to the builder working directory.

# The versioned directory and an unversioned link is not a requirement; we just
# use this pattern everywhere, so it's easy to see installed versions with a
# simple 'ls -l /opt' command.
mkdir -p opt/srilm-${version}
ln -sr opt/srilm-${version} opt/srilm
mv srilm/{bin,man,Copyright,License} opt/srilm/

# We also have a file etc/srilm.user.slice.env, which will be automatically, by
# way of its ending in .user.slice.env, picked up by the disk assembler and
# incorporated into a combined environment file /opt/etc/environment. This, in
# turn, is imported into user's interactive session. Place any variables you
# want pre-defined for the user in such a file. Of these, PATH and MANPATH are
# combined into a single variable, while other variables are simply added as
# exports. Check other files under lib/build/*/etc/*.user.slice.env to make sure
# there are no variables (excepting PATH and MANPATH) fighting each other.
# Note this goes under the /opt/etc of the new drive, not the SRILM directory.

mv etc opt

# We must always create this single-line file at the package root. Curiously,
# this is a well-formed YAML file (try "echo 'srilm: 1.2.3' | y2j" to see how it
# parses to JSON), and the disk assembly process uses it in this way to create
# visible labels on GCP disks and snapshots. The only caveat is single-quote
# versions that may parse as an integer or floating point number, as a quirk of
# YAML syntax. This is not our case (1.7 could, but 1.7.1 cannot); but extra
# single-quoting around the verion is never an error.
echo "srilm: '$version'" > opt/srilm/.BMVERSION

# And now we're ready to package the artifact. Everything currently in the
# staging directory will be seen under the /opt on every node. --sort=name makes
# logs easier to analyze in case something would be missing. Specifying
# --owner=0 --group=0 is highly recommended, because otherwise the files may end
# up installed with a random uid/gid. A GCB builer does not run this build
# script as the root user; we are running under an unknown user ID!
tar cvvaf srilm.tar.gz --sort=name --owner=0 --group=0 opt

# For the good measure: This is also our de facto standard. Other builds use the
# same GS_METADATA file to provide more identification metadata; in our case we
# don't use this file really in our cloudbuild.yaml file (instead we set the
# same metadatum directly, as the version is known there); but look how it's
# used in other cloudbuild.yaml files in the last step if adding your own
# build. Note that the tarball is named simply srilm.tar.gz, but it does not
# overwrite the file with the same name, but rather "stacked" on top of it, as
# if in another dimension. Older version automatically expire at different time
# spans, to save storage costs.  Read more on versioned storage in the docs.
echo "-hx-goog-meta-version:$version" >GS_METADATA

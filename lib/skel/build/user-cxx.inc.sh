# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson
#
# This is the user preferences file to augment the set of build dependency
# packages in the common cxx builder.

# The Common Node Software (CNS) disk exists in a single instance in a cluster,
# and is mounted on every computing VM in the cluster. Adding software to this
# disk is a straightforward, but multi-stage process, because the updates,
# however small, must click together despite being performed at different time.

# You do not need to deeply understand what a "container" or "Docker" is. Just
# think of the build pipeline as a sequential stations at a conveyor belt, which
# carries your added software through build stages, from source to binary.

# Normally, for single packages configured with automake or CMake, there are
# three build stages: the first places source code on the conveyor, and the last
# picks up the prepared binary package tarball (commonly called the "build
# artifact") and, sometimes, a little file indicating the version and provenance
# of source, into a well-known location in the Software bucket of your project.
# From there, it will be places on the CNS disk.

# The middle stage of a C/C++ is a common builder for all software, called
# cxx. It must be prepared to contain not only all necessary tools, such as
# make, compilers and linkers (this is done elsewhere), but also compile-time
# library dependencies. There are most complex builds, like Kaldi, but as long
# as your added software is simple enough to be compiled with './configure &&
# make && make install', it's just the only build step that is required. You
# only need to tune the configure switches to install into a subdirectory of
# /opt instead of the default, which is usually /usr/local. './configure --help'
# explains how.

# To add compile-time dependencies for your additional software into this same
# cxx builder that should be prepared to compile any of additional source
# packages, you need to ensure that build-time dependencies are preinstalled
# into it.  This file is read during the build of the cxx builder itself (the
# "build" in this case is just installing Debian packages with `apt-install`).
# We supply a SRILM build as an example, and SRILM may be optionally compiled
# with liblbfgs to support maximum entropy models, which is a heavy optimization
# problem. We drop a complete build configuration of SRILM into your etc/build
# directory as an example, and these files explicitly enable the optional LBFGS
# support. Of course, you can simply do 'apt-get update && apt-get install
# liblbfgs-dev' to add them every time a build is performed. Nothing is wrong
# with this approach, since you are not rebuilding such software often, and this
# is actually the best way to figure out the missing build dependencies. But
# generally, after you know the dependences, baking them in advance saves a
# couple of minutes of build time.

# This file is read by the cxx builder build process. Here you may list all
# build-time packages required by your software build.

# The *other* part is to add runtime dependencies, if any, to the common compute
# image, so that the .so files are present and can be loaded at runtime. Refer
# to the documentation for the runtime dependency part.

# TL;DR: List additional *build-time* dependencies here, then update and rebuild
# the cxx builder with the command:
#
#  bm-cloudbuild cxx
#

user_deps=(
  # SRILM dependency. You can comment it out or remove if you never use SRILM,
  # but it's not a huge bloat if you add it always: it's small enough.
  liblbfgs-dev

  # Other software dependencies go in here, one at a line or separated by space.
  # This is a bash array, and bash uses whitespace or newline as the separator.
)

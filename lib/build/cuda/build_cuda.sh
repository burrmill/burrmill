#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# This file is run inside a Docker builder container. It prepares the layout in
# the /opt directory, which is then copied to the final image.
#
# Install only a minimal required CUDA subset to compile and run Kaldi, by
# removing all NSight and other profiling and debugging stuff. The resulting
# setup is just over 1GB in size.

set -euo pipefail

Die() { echo >&2 "$0: $@"; exit 1; }

[[ ${_CUDA_VER-}        ]] || Die '$_CUDA_VER is not set'
[[ ${_CUDA_SOURCE_URL-} ]] || Die '$_CUDA_SOURCE_URL is not set'

set -x

# libxml2 is required by the CUDA installer.
apt-get -qqy update && apt-get -qqy install libxml2 wget

: Downloading cuda.run
date '+%F %T'
wget --retry-connrefused --tries=5 --progress=dot:giga \
     -Ocuda.run $_CUDA_SOURCE_URL
chmod +x cuda.run

: Installing cuda $_CUDA_VER from cuda.run
date '+%F %T'
dest=/opt/nvidia/cuda-$_CUDA_VER
mkdir -p $dest
ln -rs $dest /opt/nvidia/cuda

./cuda.run --silent --override --toolkit --no-man-page \
           --toolkitpath=$dest --defaultroot=$dest

: Completed
date '+%F %T'

cd $dest
rm -rf doc extras lib64/*.a libnsight libnvvp nsight* nvml share tools

echo 'cuda:' $_CUDA_VER >.BMVERSION

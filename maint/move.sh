#!/bin/bash

if (( $# < 2 )); then
  echo "Usage: $0 <where> <what...>"
  exit 2;
fi

where=$1; shift

set -e

for f; do
  if [[ ! -f $f ]]; then echo "$f does not exist"
  elif [[ $f == [./]* ]]; then echo "$f must be relative"
  else
    srcdir=${f%/*}
    dstdir=$where/${srcdir#*/}
    mkdir -p $dstdir
    mv -v "$f" "$dstdir"
  fi
done

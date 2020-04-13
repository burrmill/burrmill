# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson
#
# This file was installed by BurrMill.
#
# Source completions from /opt/etc/bash_completion.d. Slurm has them.

__optbashcompd__=/opt/etc/bash_completion.d
if [[ -d $__optbashcompd__ && -r $__optbashcompd__ ]]; then
  for __f__ in $__optbashcompd__/*; do
    [[ -f $__f__ && -r $__f__ ]] && . "$__f__"
  done
fi
unset __optbashcompd__ __f__

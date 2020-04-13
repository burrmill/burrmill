# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# This is sourced when at the least the project identity is known during setup,
# and the correcponding variable has been set. It is allowed to source this
# scriptlet multiple times, as more objects are created or become known. The
# other file, early_setup.int.sh, is sourced at the start of bootstrapping
# scripts.
#
# Most scripts should source common.inc.sh instead of the early/late pair.

source _apply_configuration.inc.sh

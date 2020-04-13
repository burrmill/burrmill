# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# This is sourced very early during new project setup operations. Its
# counterpart, late_setup.sh, may be sourced later, when the project identity is
# established.
#
# For other scripts, source common.inc.sh instead of this pair.

source functions.inc.sh &&
source _acquire_configuration.inc.sh

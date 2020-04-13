# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson
#
# This file was installed by BurrMill.
#
# In Debian 10, non-root users do not get /user/sbin and /sbin on their PATH,
# and in the environment where you connect mainly to perform admin tasks it's
# not the right thing to do.

# Warning: bashisms ahead. If your interactive shell breaks, please send a PR.

[[ :${PATH}: = *:/usr/local/sbin:* ]] || PATH=$PATH:/usr/local/sbin
[[ :${PATH}: = *:/usr/sbin:* ]]       || PATH=$PATH:/usr/sbin
[[ :${PATH}: = *:/sbin:* ]]           || PATH=$PATH:/sbin

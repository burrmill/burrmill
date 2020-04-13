# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# The variables you set here affect the second phase of the OS image build by
# ./lib/imaging/scripts/2-prep_deb10compute.sh, when the fresh new OS is booted
# from its disk that then becomes the image. It is sourced early in the build
# process. We did not assume that you'd do any changes to the system here,
# except for setting variables.

# Set your local time zone here, so all logs will show your local time.
# If this variable is not set, the Debian default is UTC. To list available time
# zones, either:
# * do nothing if you are based in Iceland: you are already set[1].
# * check https://en.wikipedia.org/wiki/List_of_tz_database_time_zones; or
# * use 'timedatectl list-timezones', if your system is systemd-based; or
# * find your location in the directory /usr/share/zoneinfo/posix.
# [1] Iceland is the only European country that has UTC time and no DST; I'm
#     using the Reykjavik trick on Android to set the secondary clock to UTC.
USER_TIMEZONE=  # E.g., America/Los_Angeles

# The file 2-prep_deb10compute.sh installs packages from Debian repository near
# line 90, check the list. You may add packages here. This is especially useful
# if you are extending the CNS disk, and want its system SO library dependencies
# installed into the image. Use bash array syntax, putting the words between
# parentheses, not a space-separated string, e.g. (foo bar baz)
USER_APT_PACKAGES=()

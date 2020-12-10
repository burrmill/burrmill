#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2020 Kirill 'kkm' Katsnelson

# TODO(kkm): This is not as user-customizable as it should have been.

# Versions that we install, may be overridden in etc/imaging/user_vars.inc.sh
nvidia_ver=418.87.01   # From the NVIDIA public bucket.
nvidia_bucket=gs://nvidia-drivers-us-public/tesla

# This script is setting up the default image for compute cluster. The idea is
# that the image should mostly just work for compute nodes with a minimal
# additional setup provided on the common software drive mounted at /opt (with
# trivial startup scripts). Other nodes, such as filer, controller and login
# nodes should be bootstrapped from this image easily, too.
#
# TODO(kkm): We are not forwarding logs from these hosts, but we should.

# Current kernel version.
readonly kernel=$(uname -r)

# dpkg flushes files and syncs the FS very often. 'force-unsafe-io' speeds up
# the setup significantly. Also, a few config files in layouts (in /etc/default,
# mainly) replace files that come in Debian packages; in order for them to take
# precedence over same files installed by packages, 'force-confold' is needed.
# NB that ucf spells 'conffold', dpkg 'confold'. ucf is a monster, anyway.
Apt() { apt-get -qqy -oDPkg::Options::=--force-unsafe-io,confold "$@"; }
declare -fr Apt
declare -xr DEBIAN_FRONTEND=noninteractive UCF_FORCE_CONFFOLD=YES

# Additional configuration files that may have been left by phase 1.

readonly cache=/.bootstrap

# Count errors, but not bail out immediately. This helps debug the script.
err_count=0
E() { let ++err_count; }
declare -fr E

# Let the system settle for a moment. This script is started quite early.
sleep 10

echo "BUILD_STARTED: $(date -Isec) Starting target build"

set -x

# Source user variables script if present. We declare $kernel and $nvidia_ver
# variables readonly, since tweaking them leads to a disaster much more often
# than a viable configuration. NVIDIA drivers currently do not build with DKMS
# under the kernel 5.x, for one. To prevent other catastrophes, variables and
# functions are declared readonly whenever possible.
uservars="$cache/user_vars.inc.sh"
if [[ -f $uservars ]]; then
  : "Sourcing user-provided variable setup script '$uservars'"
  . "$uservars" ||E
  rm "$uservars"
fi

# Make debconf as silent as only possible, or it would get angry at us when we
# remove the currently running kernel, or uninstall the bootloader completely,
# or do other pretty normal stuff. We'll reverse these after install.
debconf-set-selections <<EOF
debconf debconf/frontend select Noninteractive
debconf debconf/priority select critical
EOF

# Mount a tempfs and download NVIDIA installer into it in backgroud (≈100MB).
# The /run tempfs filesystem mounted by default is too small for it.
temp=/run/discard_me
nvidia_installer=NVIDIA-Linux-x86_64-${nvidia_ver}.run

mkdir $temp && mount -t tmpfs tmpfs $temp ||E
gsutil -qq cp $nvidia_bucket/$nvidia_ver/$nvidia_installer $temp &

# Install packages meanwhile.

Apt update ||E

# libpython2.7 and libyajl2 are dependencies of the Stackdriver metric agent.
# libpath-tiny-perl is a dependency of our training scripts. The rest is mostly
# for Kaldi, Slurm, SRILM and some supporting scripts. It's also important to
# replace mawk with gawk for Kaldi; mawk is not up to task for some scripts.
#
# Not installing flac: Kaldi scripts must be updated to use sox, which has no
# trouble reading flac files.
Apt install --no-upgrade \
    bash-completion bind9-host colordiff dbus-user-session dkms \
    ethtool gawk gettext-base gdb htop jq \
    libaio1 libc6 libcurl3-nss libgcc1 libgcc-8-dev libgomp1 libhwloc5 \
    libjson-c3 liblbfgs0 liblz4-1 libmariadb3 libmunge2 \
    libncurses5 libnss-systemd libnuma1 \
    libpath-tiny-perl libpython2.7 libreadline7 \
    libsgmls-perl libstdc++6 libtinfo5 libyajl2 \
    linux-headers-${kernel} \
    nfs-common nfs-kernel-server \
    parted perl policykit-1 python3 python3-requests python3-yaml pigz \
    sox time tzdata vim zlib1g ${USER_APT_PACKAGES[@]-} ||E

# Install git and less from buster-backports:
#  * git: fixes an issue with Cloud SDK helper script showing in tab completion
#         and the 'completion.commands' setting not working correctly.
#  * less: v551 fixes the long-standing issue with -X showing nothing if output
#          is less than a screenful.
# --no-upgrade wouldn't work if less was already installed (it was, AFAIK).
BP=buster-backports
Apt install git/$BP less/$BP
unset BP

Apt purge --auto-remove --allow-remove-essential \
    cron logrotate mawk rsyslog unattended-upgrades vim-tiny ||E

# Recent Debian images come with this new package, which is not needed, as
# resizing is handled by systemd-growfs@-. We do not ||E if it's missing.
Apt purge --auto-remove gce-disk-expand

# We do not want to upgrade kernel, since GCP images come with the latest one,
# but if one gets released during the build, we'll end up without NVIDIA
# drivers for it.
apt-mark hold linux-image-${kernel} ||E
Apt upgrade ||E
apt-mark unhold linux-image-${kernel} ||E

# Make sure initramfs and grub are up-to-date.
update-initramfs -ukall ||E
update-grub2 ||E

# Wait for driver download to finish before mucking with network.
# '-n' gets the exit code of the completed background job, so we can E it.
wait -n ||E

# Remove old, start new networking stuff.

# Can remove network packages only after APT upgrade competes: ifupdown turns
# interfaces down when removed, and DHCP drops the leases.
Apt purge --auto-remove \
    isc-dhcp-client isc-dhcp-common ifupdown ||E

rm -f /lib/systemd/system/systemd-resolved.service.d/resolvconf.conf

# Switch to systemd networking, but still use crony for timekeeping, it's
# significantly smoother. systemd-timesyncd is extremely simple and basic,
# and does introduce clock jitter.
systemctl mask systemd-timesyncd.service
systemctl mask dbus-org.freedesktop.timesync1.service
systemctl enable --now systemd-networkd.socket  ||E
systemctl enable --now systemd-networkd.service ||E
systemctl enable --now systemd-resolved.service ||E
rm /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Install NVIDIA drivers while the new networking is starting up.
# CPU-intensive compile, so be nice. Discard some unneeded parts, such as X
# drivers, right away by directing the install to in-memory tempfs directories.
nice -n2 bash $temp/$nvidia_installer \
     --no-questions --no-backup --ui=none --disable-nouveau --no-drm --dkms \
     --kernel-name=$kernel \
     --no-install-libglvnd --no-glvnd-glx-client --no-glvnd-egl-client \
     --no-opengl-files --x-prefix=$temp/x --x-sysconfig-path=$temp/s \
     --application-profile-path=$temp/a \
     --log-file-name=$temp/nvidia-install.log ||E

cat $temp/nvidia-install.log
: make.log would exist only if DKMS failed, ignore error on a successful build.
cat /var/lib/dkms/nvidia/*/build/make.log

umount $temp  # Free up ramdisk memory.

# Install any packages supplied by the user in the addons tarball.
shopt -s nullglob
debs=("$cache/debs"/*.deb)
if [[ $debs ]]; then
  dpkg -iR "$cache/debs" ||E
fi
unset debs
shopt -u nullglob

rm -frv "$cache/debs"

# Clean up APT caches.
Apt autoremove --purge && Apt clean ||E

# Set debconf config back to approximate defaults.
debconf-set-selections <<EOF
debconf debconf/frontend select Readline
debconf debconf/priority select high
EOF

# Divert Cloud SDK default properties to a file with another extension, so that
# it won't be overwritten by package updates (updates will send the file to the
# diverted location), and replace it with our own defaults. We must suppress
# logging, as the tools try to log to non-existent home directories of service-
# only users, and suppress survey prompts, not so much because the service
# accounts will hardly agree to take a survey, but rather because writing a
# survey prompt to a closed stderr may force a non-zero exit code of otherwise
# successfull command. A warning about inability to log leads to the same
# problem. Note that the same defaults are set for the login node, where you run
# experiments, but you can always change them in your local config.
dpkg-divert --rename --add  /usr/lib/google-cloud-sdk/properties ||E
cat > /usr/lib/google-cloud-sdk/properties <<EOF
[core]
disable_file_logging = true
disable_usage_reporting = false

[survey]
disable_prompts = true
EOF

echo /usr/lib/google-cloud-sdk/properties:
cat /usr/lib/google-cloud-sdk/properties

# Massage fstab.
x_growfs=x-systemd.growfs
x_timeout=x-systemd.device-timeout=3,x-systemd.mount-timeout=3

# Add ',x-systemd.growfs' to root fs options to be grown on boot.
# E.g., 'LABEL=ROOT /   ext4    discard,errors=remount-ro  0  1'
#        $1         $2  $3      $4  ...
mv /etc/fstab /etc/fstab~
awk </etc/fstab~ >/etc/fstab '!/^#/ && $2=="/" {$4=$4 ",'$x_growfs'"} 1'||E
rm /etc/fstab~

# Add an optional (nofail) /opt mount for the CNS disk, and a noauto mount for
# the filer disk. The latter is mounted as the NFS server dependency only.
mkdir -p /srv/mill /opt
rm -rf /srv/mill/* /opt/*
cat >>/etc/fstab <<EOF
LABEL=BURRMILL_CNS /opt ext4 nofail,ro,$x_timeout 0 0
# This mount is noauto, and is pulled by NFS server if/when needed.
LABEL=BURRMILL_FILER /srv/mill ext4 \
 noauto,$x_timeout,$x_growfs,noatime,lazytime,data=writeback,nobarrier,discard,noacl,grpid 0 0
EOF

unset x_timeout x_growfs

# Display the final resulting fstab in the log.
cat /etc/fstab

# No point. tty1 does not exist; upgrades never happen anyway. If you maintain
# e.g. a working (login) node, just apt update && apt upgrade it; the timers
# that prefetch updates are useless at GCE network speeds, and man-db update
# does really nothing useful; it's a vestige of the great past when computers
# were real 80286 computers boasting real 50MB disks with the ST-412 interface.
systemctl disable apt-daily-upgrade.timer apt-daily.timer man-db.timer \
                  getty@tty1

# This is a new boy in town that comes with latest images, and it's not clear
# whether we could use it or not. But we're certainly not using it now... No
# "||E" because it may or may not even be there. No documentation exists yet.
systemctl disable google-osconfig-agent.service

pam-auth-update --enable mkhomedir --package ||E

if [[ ${USER_TIMEZONE-} ]]; then
  timedatectl set-timezone "$USER_TIMEZONE" ||E
fi

# Hack alert. If you forget to sudo when invoking systemctl and other policy
# elevation-aware programs, you'll be prompted for root password, which does not
# really exist. This is just an annoyance, but still an annoyance. I could never
# find a way to properly use or properly disable this mechanism. Polkit seems
# not to respect session-only groups added via /etc/security/groups.com.
chmod -x /usr/bin/pkttyagent

# TODO(kkm): Probably unhelpful. Polkit seems to ignore it.
groupadd -r interactive ||E  # See compute/etc/security/groups.conf.

# These may be blindly referred to by GCE OS Login, and then yelled at by PAM.
groupadd -r docker
groupadd -r lxd

# Create common identites. Not all are currently used.
# TODO(kkm): Probably too many. Figure out which are used.
groupadd -g60000 burrmill  ||E

ClusterUserAdd() {
 useradd -Ml -gburrmill -Gsystemd-journal -s/bin/false -p\* -u$1 $2 ||E
}

ClusterUserAdd 60000 burrmill
ClusterUserAdd 60001 cluster
ClusterUserAdd 60002 slurm
ClusterUserAdd 60003 operator
ClusterUserAdd 60004 user

unset -f ClusterUserAdd

# Force regenerating g_i_s config, or else it will install host keys early on
# next boot, before noticing changes to and auto-regenerating its own config!
/usr/bin/google_instance_setup
mv /etc/hosts.burrmill-dist /etc/hosts  # g_i_s may have it overwritten.

# Another logging record: make sure systemd took over network control.
networkctl
systemd-resolve --status
cat /etc/resolv.conf

# Directory and file cleanup. Also remove two temporary holding files deployed
# with the layout, for sshd and journald.
rm -rf  /var/google*.d/* /var/log/journal/* /var/log/unattended-upgrades \
        /home/* /root/* /var/tmp/* "$cache"

rm -f /var/lib/apt/lists/*.*.* /var/lib/apt/periodic/* \
      /var/cache/apt/*.bin /var/cache/debconf/*-old \
      /var/log/{auth.,daemon.,kern.,fail,tally,sys}log \
      /var/log/{debug,messages} \
      /etc/ssh/ssh_host_*_key* /etc/oslogin_passwd.cache* /etc/boto.conf \
      /etc/udev/rules.d/75-cloud-ifupdown.rules /etc/network/cloud* \
      /etc/systemd/system/rsyslog.service /etc/ssh/sshd_not_to_be_run \
      /etc/systemd/journald.conf.d/99-temporary-hold.conf

# Reset a few files to zero length.
: > /etc/machine-id
: > /etc/motd
: > /var/log/btmp
: > /var/log/lastlog
: > /var/log/wtmp

echo 'localhost' > /etc/hostname

fstrim / ||E

set +x  # Prevent Daisy from matching output of echoed script lines.

t_end=$(date -Isec)

echo "Sleeping a bit because race condition in Daisy"
sleep 12

(( $err_count == 0 )) \
  && echo "BUILD_SUCCESS: $t_end Completed successfully" \
  || echo "BUILD_FAILURE: $t_end There were $err_count error(s)"

echo "Sleeping a bit more because race condition in Daisy"

# This suicidally deletes this script file too, but the subshell is loaded
# and run whole, so this being the last line is ok.
#
# The script is sometimes killed before poweroff is reached, by Daisy-initiated
# shutdown. This is normal; this sleep/poweroff sequence exists only to ensure
# that the instance does not get stuck running in case Daisy misses the build
# success/failure indication. This happens when debugging these scripts.
(rm -rfv /startup-*; sleep 10; poweroff)

#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)" 1>&2
   exit 1
fi

# Check for enough space on /boot volume
boot_line=$(df -h | grep /boot | head -n 1)
if [ "x${boot_line}" = "x" ]; then
  echo "Warning: /boot volume not found .."
else
  boot_space=$(echo $boot_line | awk '{print $4;}')
  free_space=$(echo "${boot_space%?}")
  unit="${boot_space: -1}"
  if [[ "$unit" = "K" ]]; then
    echo "Error: Not enough space left ($boot_space) on /boot"
    exit 1
  elif [[ "$unit" = "M" ]]; then
    if [ "$free_space" -lt "25" ]; then
      echo "Error: Not enough space left ($boot_space) on /boot"
      exit 1
    fi
  fi
fi

#
# make sure that we are on something ARM/Raspberry related
# either a bare metal Raspberry or a qemu session with
# Raspberry stuff available
# - check for /boot/overlays
# - dtparam and dtoverlay is available
errorFound=0
OVERLAYS=/boot/overlays
[ -d /boot/firmware/overlays ] && OVERLAYS=/boot/firmware/overlays

if [ ! -d $OVERLAYS ] ; then
  echo "$OVERLAYS not found or not a directory" 1>&2
  errorFound=1
fi
# should we also check for alsactl and amixer used in seeed-voicecard?
PATH=$PATH:/opt/vc/bin
for cmd in dtparam dtoverlay ; do
  if ! which $cmd &>/dev/null ; then
    echo "$cmd not found" 1>&2
    echo "You may need to run ./ubuntu-prerequisite.sh"
    errorFound=1
  fi
done
if [ $errorFound = 1 ] ; then
  echo "Errors found, exiting." 1>&2
  exit 1
fi

uname_r=$(uname -r)

# update and install required packages
#
# NOTE: This fork builds the kernel modules out-of-tree with plain `make`
#       (not dkms), which is how the modules were verified on
#       Raspberry Pi OS / Debian 13 "trixie", kernel 6.18.
which apt &>/dev/null
if [[ $? -eq 0 ]]; then
  apt update -y
  # toolchain + matching kernel headers for the running kernel
  apt-get -y install build-essential bc
  apt-get -y install linux-headers-$(uname -r) || \
    apt-get -y install raspberrypi-kernel-headers
  # i2cdetect is required by the seeed-voicecard runtime detection script,
  # alsactl/amixer/aplay by the service, libasound2-plugins for the ALSA conf.
  apt-get -y install git i2c-tools alsa-utils libasound2-plugins
fi

# Arch Linux
which pacman &>/dev/null
if [[ $? -eq 0 ]]; then
  pacman -Syu --needed git gcc automake make i2c-tools alsa-utils
fi

# sanity check: kernel headers for the running kernel must be present
if [ ! -d "/lib/modules/${uname_r}/build" ]; then
  echo "Error: kernel headers for ${uname_r} not found at" \
       "/lib/modules/${uname_r}/build" 1>&2
  echo "Install the headers matching your running kernel and re-run." 1>&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Build and install the kernel modules (out-of-tree, via the Makefile).
#   snd-soc-wm8960            -> sound/soc/codecs
#   snd-soc-ac108            -> sound/soc/codecs
#   snd-soc-seeed-voicecard  -> sound/soc/bcm
# ---------------------------------------------------------------------------
DEST=/lib/modules/${uname_r}/kernel

echo "Building kernel modules for ${uname_r} ..."
make -C "/lib/modules/${uname_r}/build" M="$(pwd)" clean
make -C "/lib/modules/${uname_r}/build" M="$(pwd)" modules || {
  echo "Error: module build failed" 1>&2
  exit 1
}

echo "Installing kernel modules ..."
install -d "${DEST}/sound/soc/codecs" "${DEST}/sound/soc/bcm"
cp snd-soc-wm8960.ko           "${DEST}/sound/soc/codecs/"
cp snd-soc-ac108.ko            "${DEST}/sound/soc/codecs/"
cp snd-soc-seeed-voicecard.ko  "${DEST}/sound/soc/bcm/"
depmod -a "${uname_r}"


# install dtbos
cp seeed-2mic-voicecard.dtbo $OVERLAYS
cp seeed-4mic-voicecard.dtbo $OVERLAYS
cp seeed-8mic-voicecard.dtbo $OVERLAYS

#install alsa plugins
# no need this plugin now
# install -D ac108_plugin/libasound_module_pcm_ac108.so /usr/lib/arm-linux-gnueabihf/alsa-lib/
rm -f /usr/lib/arm-linux-gnueabihf/alsa-lib/libasound_module_pcm_ac108.so

#set kernel modules
grep -q "^snd-soc-seeed-voicecard$" /etc/modules || \
  echo "snd-soc-seeed-voicecard" >> /etc/modules
grep -q "^snd-soc-ac108$" /etc/modules || \
  echo "snd-soc-ac108" >> /etc/modules
grep -q "^snd-soc-wm8960$" /etc/modules || \
  echo "snd-soc-wm8960" >> /etc/modules

#set dtoverlays
CONFIG=/boot/config.txt
[ -f /boot/firmware/config.txt ] && CONFIG=/boot/firmware/config.txt
[ -f /boot/firmware/usercfg.txt ] && CONFIG=/boot/firmware/usercfg.txt

sed -i -e 's:#dtparam=i2c_arm=on:dtparam=i2c_arm=on:g'  $CONFIG || true
grep -q "^dtoverlay=i2s-mmap$" $CONFIG || \
  echo "dtoverlay=i2s-mmap" >> $CONFIG


grep -q "^dtparam=i2s=on$" $CONFIG || \
  echo "dtparam=i2s=on" >> $CONFIG

#install config files
mkdir /etc/voicecard || true
cp *.conf /etc/voicecard
cp *.state /etc/voicecard

#create git repo
git_email=$(git config --global --get user.email)
git_name=$(git config --global --get user.name)
if [ "x${git_email}" == "x" ] || [ "x${git_name}" == "x" ] ; then
    echo "setup git config"
    git config --global user.email "respeaker@seeed.cc"
    git config --global user.name "respeaker"
fi
echo "git init"
git --git-dir=/etc/voicecard/.git init
echo "git add --all"
git --git-dir=/etc/voicecard/.git --work-tree=/etc/voicecard/ add --all
echo "git commit -m \"origin configures\""
git --git-dir=/etc/voicecard/.git --work-tree=/etc/voicecard/ commit  -m "origin configures"

cp seeed-voicecard /usr/bin/
cp seeed-voicecard.service /lib/systemd/system/
systemctl enable  seeed-voicecard.service
systemctl start   seeed-voicecard

echo "------------------------------------------------------"
echo "Please reboot your raspberry pi to apply all settings"
echo "Enjoy!"
echo "------------------------------------------------------"

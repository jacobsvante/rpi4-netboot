#/bin/bash
# Heavy inspiration from: https://www.reddit.com/r/raspberry_pi/comments/l7bzq8/guide_pxe_booting_to_a_raspberry_pi_4/
PI_SERIAL_NUMBER="$1"
USERNAME="$2"
SSH_PUBLIC_KEY="$3"
STORED_IMAGE_PATH="$4"

[[ -z "$1" ]] && echo "Pass Raspberry PI serial number as argument #1" && exit 1
[[ -z "$2" ]] && echo "Pass username as argument #2" && exit 1
[[ -z "$3" ]] && echo "Pass SSH public key as argument #3" && exit 1

PRIMARY_SERVER_IP="$(hostname -I | cut -d' ' -f1)"
[[ -z "$PRIMARY_SERVER_IP" ]] && echo "Failed to find primary server IP address" && exit 1

echo "Detected IP for this server: $PRIMARY_SERVER_IP (NFS share will be accessed from here)"

if ! [[ "$(whoami)" == "root"  ]]; then
  echo "Must run this script as root" && exit 1
fi

set -e

apt update
apt install -y nfs-kernel-server kpartx unzip tftpd-hpa

mkdir -p /srv/{tftp,nfs} || true

mkdir /tmp/pxestuff
CURRDIR="$PWD"
cd /tmp/pxestuff

if [[ -z "$STORED_IMAGE_PATH" ]]; then
    wget -O raspios_lite_arm64_latest.img.xz \
        https://downloads.raspberrypi.org/raspios_lite_arm64_latest
    unxz --verbose raspios_lite_arm64_latest.img.xz
else
    cp $STORED_IMAGE_PATH ./raspios_lite_arm64_latest.img
fi

# Mount raspberry PI image boot and root
kpartx -a -v raspios_lite_arm64_latest.img
mkdir {bootmnt,rootmnt}
mount /dev/mapper/loop*p1 bootmnt/
mount /dev/mapper/loop*p2 rootmnt/

mkdir -p /srv/{nfs,tftp}/${PI_SERIAL_NUMBER} || true
# NOTE: We allow this failure of the following error:
#       "cp: preserving permissions for ‘/srv/nfs/$PI_SERIAL_NUMBER/var/log/journal’: Operation not supported"
cp -a rootmnt/* /srv/nfs/${PI_SERIAL_NUMBER} || true
cp -a bootmnt/* /srv/nfs/${PI_SERIAL_NUMBER}/boot/
umount bootmnt/
umount rootmnt/
cd "$CURRDIR"
rm -r /tmp/pxestuff

# rm /srv/nfs/${PI_SERIAL_NUMBER}/boot/start4.elf
# rm /srv/nfs/${PI_SERIAL_NUMBER}/boot/fixup4.dat
# wget https://github.com/raspberrypi/rpi-firmware/raw/master/start4.elf \
#     -P /srv/nfs/${PI_SERIAL_NUMBER}/boot/
# wget https://github.com/raspberrypi/rpi-firmware/raw/master/fixup4.dat \
#     -P /srv/nfs/${PI_SERIAL_NUMBER}/boot/

grep "/srv/nfs/${PI_SERIAL_NUMBER}/boot" /etc/fstab > /dev/null \
    || echo "/srv/nfs/${PI_SERIAL_NUMBER}/boot /srv/tftp/${PI_SERIAL_NUMBER} none defaults,bind 0 0" \
    >> /etc/fstab

grep "/srv/nfs/${PI_SERIAL_NUMBER}" /etc/exports > /dev/null \
    || echo "/srv/nfs/${PI_SERIAL_NUMBER} *(rw,sync,no_subtree_check,no_root_squash)" \
    >> /etc/exports

mount /srv/tftp/${PI_SERIAL_NUMBER}/
# Enable SSH from first boot
touch /srv/nfs/${PI_SERIAL_NUMBER}/boot/ssh
sed -i /UUID/d /srv/nfs/${PI_SERIAL_NUMBER}/etc/fstab
echo "console=serial0,115200 console=tty root=/dev/nfs nfsroot=${PRIMARY_SERVER_IP}:/srv/nfs/${PI_SERIAL_NUMBER},vers=3 rw ip=dhcp rootwait elevator=deadline" \
    > /srv/nfs/${PI_SERIAL_NUMBER}/boot/cmdline.txt

# Create a user with a random password (we'll be using SSH public key login instead)
# https://www.raspberrypi.com/documentation/computers/configuration.html#configuring-a-user
PASSWORD=$(echo $RANDOM | md5sum | head -c 30)
{ echo "${USERNAME}:"; echo "${PASSWORD}" | openssl passwd -6 -stdin;} | tr -d '[:space:]' > /srv/tftp/${PI_SERIAL_NUMBER}/userconf.txt

# Set up authorized SSH key
USER_DIR=/srv/nfs/$PI_SERIAL_NUMBER/home/$USERNAME
mkdir -p $USER_DIR/.ssh
USER_AND_GROUP="$(stat -c %u:%g $USER_DIR)"
echo "$SSH_PUBLIC_KEY" > $USER_DIR/.ssh/authorized_keys
chown -R $USER_AND_GROUP $USER_DIR

# Restart services
systemctl restart rpcbind
systemctl restart nfs-server

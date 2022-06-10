#/bin/bash
# Heavy inspiration from: https://www.reddit.com/r/raspberry_pi/comments/l7bzq8/guide_pxe_booting_to_a_raspberry_pi_4/
PI_SERIAL_NUMBER="$1"
USERNAME="$2"
SSH_PUBLIC_KEY="$3"
STORED_IMAGE_PATH="$4"
NFS_DIR=/srv/nfs/$PI_SERIAL_NUMBER
TFTP_DIR=/srv/tftp/$PI_SERIAL_NUMBER

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
set -x

apt update
apt install -y nfs-kernel-server kpartx unzip tftpd-hpa

mkdir -p /srv/{tftp,nfs} || true

PI_TMP_DIR=/tmp/rpi4-netboot-wip/$PI_SERIAL_NUMBER
mkdir -p $PI_TMP_DIR
CURRDIR="$PWD"
cd $PI_TMP_DIR

if [[ -z "$STORED_IMAGE_PATH" ]]; then
    wget -O raspios_lite_arm64_latest.img.xz \
        https://downloads.raspberrypi.org/raspios_lite_arm64_latest
    unxz --verbose raspios_lite_arm64_latest.img.xz
else
    cp $STORED_IMAGE_PATH ./raspios_lite_arm64_latest.img
fi

# Mount raspberry PI image boot and root
LOOP_NAME_PREFIX=$(kpartx -a -v raspios_lite_arm64_latest.img 2>&1 | grep -o -e 'loop[0-9]p' | head -1)
mkdir {bootmnt,rootmnt}
mount /dev/mapper/${LOOP_NAME_PREFIX}1 bootmnt/
mount /dev/mapper/${LOOP_NAME_PREFIX}2 rootmnt/

mkdir -p /srv/{nfs,tftp}/${PI_SERIAL_NUMBER} || true
# NOTE: We allow this failure of the following error:
#       "cp: preserving permissions for ‘$NFS_DIR/var/log/journal’: Operation not supported"
cp -a rootmnt/* $NFS_DIR || true
cp -a bootmnt/* $NFS_DIR/boot/
umount bootmnt/
umount rootmnt/
cd "$CURRDIR"
rm -r $PI_TMP_DIR

grep "$NFS_DIR/boot" /etc/fstab > /dev/null \
    || echo "$NFS_DIR/boot $TFTP_DIR none defaults,bind 0 0" \
    >> /etc/fstab

grep "$NFS_DIR" /etc/exports > /dev/null \
    || echo "$NFS_DIR *(rw,sync,no_subtree_check,no_root_squash)" \
    >> /etc/exports

mount $TFTP_DIR
# Enable SSH from first boot
touch $NFS_DIR/boot/ssh
sed -i /UUID/d $NFS_DIR/etc/fstab
echo "console=serial0,115200 console=tty root=/dev/nfs nfsroot=${PRIMARY_SERVER_IP}:$NFS_DIR,vers=3 rw ip=dhcp rootwait elevator=deadline" \
    > $NFS_DIR/boot/cmdline.txt

# Create a user with a random password (we'll be using SSH public key login instead)
# https://www.raspberrypi.com/documentation/computers/configuration.html#configuring-a-user
PASSWORD=$(echo $RANDOM | md5sum | head -c 30)
{ echo "${USERNAME}:"; echo "${PASSWORD}" | openssl passwd -6 -stdin;} | tr -d '[:space:]' > $TFTP_DIR/userconf.txt

# Set hostname to PI's serial number
echo $PI_SERIAL_NUMBER > $NFS_DIR/etc/hostname

# Set up authorized SSH key
USER_DIR=$NFS_DIR/home/$USERNAME
mkdir -p $USER_DIR/.ssh
echo "$SSH_PUBLIC_KEY" > $USER_DIR/.ssh/authorized_keys
chown -R 1000:1000 $USER_DIR

# Restart services
systemctl restart rpcbind
systemctl restart nfs-server

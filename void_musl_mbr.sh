#!/bin/bash
# void linux musl install script for x86 systems (mbr)
# n0r3a

REPO_URL="https://repo-default.voidlinux.org/current/musl"
LUKS_NAME_ROOT="luks_void"

# handle errors
error_exit() {
  echo "error: $1" >&2
  exit 1
}

# get user input
get_user_input() {
  read -p "enter the disk you want to use (e.g., /dev/sda or /dev/nvme0n1): " DISK
  if [[ ! -b "$DISK" ]]; then
    error_exit "invalid disk device: $DISK"
  fi
  
  read -s -p "enter the passphrase for the encrypted disk: " VOLUME_PASSWORD
  echo ""
  read -s -p "re-enter the passphrase for the encrypted disk: " VOLUME_PASSWORD_CONFIRM
  echo ""
  if [[ "$VOLUME_PASSWORD" != "$VOLUME_PASSWORD_CONFIRM" ]]; then
    error_exit "luks passwords do not match."
  fi
  
  read -s -p "enter the root password: " ROOT_PASSWORD
  echo ""
  read -s -p "re-enter the root password: " ROOT_PASSWORD_CONFIRM
  echo ""
  if [[ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]]; then
    error_exit "root passwords do not match."
  fi
}

# create partitions using sfdisk
create_partitions_sfdisk() {
  echo "creating partitions with sfdisk (mbr/dos - single partition)..."

  # wipe disk
  wipefs -af "$DISK" || error_exit "wipefs failed"

  # format disk as MBR (dos), creating a single partition taking the entire space
  # type 83 (linux) and setting the bootable flag on it
  printf 'label: dos\n, , L, *\n' | sfdisk -q "$DISK" || error_exit "sfdisk failed"

  # determine partition name (this will be the only encrypted partition)
  if [[ "$DISK" == *"/nvme"* ]]; then
    ROOT_PARTITION="${DISK}p1"
  else
    ROOT_PARTITION="${DISK}1"
  fi

  # update partitions
  partprobe "$DISK" || error_exit "partprobe failed"
  sleep 2 # sleep just to give the kernel some time

  # debugging information
  echo "checking for partitions"
  lsblk "$DISK"
}

## main installation

# get user input
get_user_input

# create partitions using sfdisk
create_partitions_sfdisk

# encrypted partition configuration
echo "encrypting $ROOT_PARTITION with luks1 (single volume for / and /boot)..."
echo "$VOLUME_PASSWORD" | cryptsetup luksFormat --type luks1 "$ROOT_PARTITION" || error_exit "cryptsetup luksFormat failed"

echo "opening root encrypted volume..."
echo "$VOLUME_PASSWORD" | cryptsetup luksOpen "$ROOT_PARTITION" "$LUKS_NAME_ROOT" || error_exit "cryptsetup luksOpen failed"

# create filesystems
echo "creating ext4 filesystem on decrypted volume (/ and /boot)..."
mkfs.ext4 -L root -F "/dev/mapper/$LUKS_NAME_ROOT" || error_exit "mkfs.ext4 root failed"

# system install prep
echo "mounting filesystems..."
# mount the single encrypted volume to /mnt
mount "/dev/mapper/$LUKS_NAME_ROOT" /mnt || error_exit "mount root failed"

# device mapping
echo "binding virtual filesystems..."
for dir in dev proc sys; do
    mkdir -p /mnt/$dir
    mount --rbind /$dir /mnt/$dir
done

echo "copying xbps rsa keys..."
mkdir -p /mnt/var/db/xbps/keys
cp -a /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ || error_exit "cp keys failed"

echo "installing base system and necessary packages (musl, MBR grub)..."
# installing grub and cryptsetup along with base system
env XBPS_ARCH=x86_64-musl xbps-install -Sy -R "$REPO_URL" -r /mnt base-system cryptsetup grub dracut || error_exit "xbps-install failed"

# initial configuration
echo "generating initial fstab..."
xgenfstab -U /mnt > /mnt/etc/fstab || error_exit "xgenfstab failed"

# get the uuid of the luks partition for grub
LUKS_PART_UUID=$(blkid -o value -s UUID "$ROOT_PARTITION")
echo "root luks partition uuid: $LUKS_PART_UUID"

# chroot for final configuration
echo "entering chroot for system configuration..."
xchroot /mnt /bin/bash <<EOF || error_exit "xchroot failed"
set -e 

# set root password
echo "setting root password..."
passwd root <<PASSWD_EOF
$ROOT_PASSWORD
$ROOT_PASSWORD
PASSWD_EOF

# hostname
echo "tiny_void" > /etc/hostname

# configure dracut (needs no special keyfile configuration, just crypt/luks modules)
echo "ensuring dracut has luks modules..."
# no specific file needed, dracut should autodetect cryptsetup and include necessary components

# configure grub
echo "configuring GRUB for full disk encryption..."
# grubs crypto module must be enabled to prompt for luks password at boot
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
# tell the kernel about the luks volume
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.uuid=$LUKS_PART_UUID\"" >> /etc/default/grub

# final step before install: ensure grub configuration is generated
echo "generating final grub.cfg..."
grub-mkconfig -o /boot/grub/grub.cfg

# install grub to the MBR of the disk
echo "installing grub to $DISK..."
# --target=i386-pc is the standard MBR target
# grub will write the core image into the unallocated space before the first partition
grub-install --target=i386-pc "$DISK"

# final /etc/fstab correction
echo "correcting /etc/fstab..."
# only the single root mount point is needed
cat > /etc/fstab <<FSTAB_EOF
# <file system> <dir> <type> <options> <dump> <pass>
/dev/mapper/$LUKS_NAME_ROOT / ext4 defaults 0 0 
FSTAB_EOF

# reconfigure all packages to build the initramfs
echo "rebuilding initramfs..."
xbps-reconfigure -fa

echo "chroot configuration complete."
exit
EOF

# unmount and reboot
sleep 5
echo "unmounting virtual and physical filesystems..."
for dir in dev proc sys; do
    umount -l /mnt/$dir || true
done

umount -R /mnt || umount -lR /mnt || error_exit "umount failed"

echo "installation complete."


# select reboot or stay
select choice in "reboot" "Stay in live environment"; do
  case $choice in
    "reboot")
      echo "rebooting..."
      reboot
      break;; 
    "stay in live environment")
      echo "staying in live environment."
      break;; 
    *)
      echo "invalid choice. please try again."
      ;;
  esac
done


#!/bin/bash

# UEFI Full Disk Encryption Installation Script (/ only, automated sfdisk)

# Warning: This script will overwrite data on your drive. Make sure you have backed up any important data.

# Variables
REPO_URL="https://repo-default.voidlinux.org/current/musl"
VOLUME_NAME_ROOT="voidroot" #Simplified volume name

# Function to handle errors
error_exit() {
  echo "Error: $1"
  exit 1
}

# Function to get user input for variables
get_user_input() {
  read -p "Enter the disk you want to use (e.g., /dev/vda): " DISK
  read -s -p "Enter the password for the encrypted volume: " VOLUME_PASSWORD
  echo ""
  read -s -p "Re-enter the password for the encrypted volume: " VOLUME_PASSWORD_CONFIRM
  echo ""
  if [[ "$VOLUME_PASSWORD" != "$VOLUME_PASSWORD_CONFIRM" ]]; then
    error_exit "Passwords do not match."
  fi
  read -s -p "Enter the root password: " ROOT_PASSWORD
  echo ""
  read -s -p "Re-enter the root password: " ROOT_PASSWORD_CONFIRM
  echo ""
  if [[ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]]; then
    error_exit "Root passwords do not match."
  fi
}

# Function to create partitions using sfdisk
create_partitions_sfdisk() {
  echo "Creating partitions with sfdisk..."

  efi_part_size="250M"

  #Wipe disk
  wipefs -aq "$DISK" || error_exit "wipefs failed"

  #Format disk as GPT, create EFI partition and a 2nd partition with the remaining disk space
  printf 'label: gpt\n, %s, U, *\n, , L\n' "$efi_part_size" | sfdisk -q "$DISK" || error_exit "sfdisk failed"

  # Update partitions
  partprobe "$DISK" || error_exit "partprobe failed"

  if [[ "$DISK" == *"/nvme"* ]]; then
    EFI_PARTITION="${DISK}p1"
    ROOT_PARTITION="${DISK}p2"
  else
    EFI_PARTITION="${DISK}1"
    ROOT_PARTITION="${DISK}2"
  fi

  # Debugging information
  echo "Checking for partitions"
  lsblk "$DISK"
}

# Get user input
get_user_input

# Create partitions using sfdisk
create_partitions_sfdisk

# Format the EFI partition
mkfs.vfat "$EFI_PARTITION" || error_exit "mkfs.vfat failed"

# Encrypted volume configuration
echo "Encrypting $ROOT_PARTITION..."
cryptsetup luksFormat --type luks1 "$ROOT_PARTITION" --key-file - <<< "$VOLUME_PASSWORD" || error_exit "cryptsetup luksFormat failed"

echo "Opening root encrypted volume..."
cryptsetup luksOpen "$ROOT_PARTITION" "$VOLUME_NAME_ROOT" --key-file - <<< "$VOLUME_PASSWORD" || error_exit "cryptsetup luksOpen failed"

echo "Creating filesystems..."
mkfs.xfs -L root "/dev/mapper/$VOLUME_NAME_ROOT" || error_exit "mkfs.xfs root failed"

# System installation
echo "Mounting filesystems..."
mount "/dev/mapper/$VOLUME_NAME_ROOT" /mnt || error_exit "mount root failed"
mkdir -p /mnt/boot
mkdir -p /mnt/boot/efi
mount "$EFI_PARTITION" /mnt/boot/efi || error_exit "mount efi failed"

echo "Copying RSA keys..."
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ || error_exit "cp keys failed"

echo "Installing base system..."
xbps-install -Sy -R "$REPO_URL" -r /mnt base-system cryptsetup grub-x86_64-efi || error_exit "xbps-install failed"

# Configuration
echo "Generating fstab..."
xgenfstab /mnt > /mnt/etc/fstab || error_exit "xgenfstab failed"

# Entering the Chroot
echo "Entering chroot..."
xchroot /mnt <<EOF
passwd root <<PASSWD_EOF
$ROOT_PASSWORD
$ROOT_PASSWORD
PASSWD_EOF
chown root:root / || echo "chown failed"
chmod 755 / || echo "chmod failed"
echo "voidvm" > /etc/hostname || echo "hostname failed"
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub || echo "grub config failed"
ROOT_UUID=$(blkid -o value -s UUID "$ROOT_PARTITION")
EFI_UUID=$(blkid -o value -s UUID "$EFI_PARTITION")
echo "root partition uuid: $ROOT_UUID"
sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.uuid=$ROOT_UUID\"/" /etc/default/grub || echo "sed grub failed"
dd bs=1 count=64 if=/dev/urandom of=/boot/volume.key || echo "dd random failed"
cryptsetup luksAddKey "$ROOT_PARTITION" /boot/volume.key --key-file - <<CRYPT_EOF
$VOLUME_PASSWORD
CRYPT_EOF
chmod 000 /boot/volume.key || echo "chmod key failed"
chmod -R g-rwx,o-rwx /boot || echo "chmod boot failed"
echo "voidroot UUID=$ROOT_UUID /boot/volume.key luks,noauto" >> /etc/crypttab || echo "crypttab failed"
mkdir -p /etc/dracut.conf.d || echo "mkdir dracut failed"
echo "install_items+=\" /boot/volume.key /etc/crypttab \"" > /etc/dracut.conf.d/10-crypt.conf || echo "dracut config failed"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=void "$DISK" || echo "grub install failed"
grub-mkconfig -o /boot/grub/grub.cfg
xbps-reconfigure -fa || echo "xbps-reconfigure failed"
exit
EOF

# Unmount and reboot
echo "Unmounting filesystems..."
umount -R /mnt || error_exit "umount failed"

echo "Rebooting..."
#reboot

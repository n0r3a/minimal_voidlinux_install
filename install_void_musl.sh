#!/bin/bash

# UEFI Full Disk Encryption Installation Script (/ only, automated fdisk)

# Warning: This script will overwrite data on your drive. Make sure you have backed up any important data.

# Variables
REPO_URL="https://repo-default.voidlinux.org/current/musl"
LOCALE="en_US.UTF-8"

# Function to handle errors
error_exit() {
  echo "Error: $1"
  exit 1
}

# Function to get user input for variables
get_user_input() {
  read -p "Enter the disk you want to use (e.g., /dev/sda): " DISK
  read -p "Enter the name for your encrypted root volume (e.g., luks_void): " VOLUME_NAME_ROOT
}

# Function to create partitions using fdisk
create_partitions_fdisk() {
  echo "Creating partitions with fdisk..."
  echo "o # Create a new empty DOS partition table" | fdisk "$DISK"
  echo "n # Add a new partition" | fdisk "$DISK"
  echo "p # Primary partition" | fdisk "$DISK"
  echo "1 # Partition number 1" | fdisk "$DISK"
  echo " # Default first sector" | fdisk "$DISK"
  echo "+200M" | fdisk "$DISK" # EFI partition size is 200M
  echo "t # Change a partition's system type" | fdisk "$DISK"
  echo "1 # Select partition 1" | fdisk "$DISK"
  echo "1 # EFI System" | fdisk "$DISK"
  echo "n # Add a new partition" | fdisk "$DISK"
  echo "p # Primary partition" | fdisk "$DISK"
  echo "2 # Partition number 2" | fdisk "$DISK"
  echo " # Default first sector" | fdisk "$DISK"
  echo " # Use all remaining space" | fdisk "$DISK" #root partition takes the rest.
  echo "w # Write table to disk and exit" | fdisk "$DISK"

  # Update partitions
  blockdev --rereadpt "$DISK" || error_exit "blockdev --rereadpt failed"

  EFI_PARTITION="${DISK}1"
  ROOT_PARTITION="${DISK}2"
}

# Get user input
get_user_input

# Create partitions using fdisk
create_partitions_fdisk

# Format the EFI partition
mkfs.vfat "$EFI_PARTITION" || error_exit "mkfs.vfat failed"

# Encrypted volume configuration
echo "Encrypting $ROOT_PARTITION..."
cryptsetup luksFormat --type luks1 "$ROOT_PARTITION" || error_exit "cryptsetup luksFormat failed"

echo "Opening root encrypted volume..."
cryptsetup luksOpen "$ROOT_PARTITION" "$VOLUME_NAME_ROOT" || error_exit "cryptsetup luksOpen failed"

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
chown root:root / || echo "chown failed"
chmod 755 / || echo "chmod failed"
passwd root || echo "passwd failed"
echo "voidvm" > /etc/hostname || echo "hostname failed"
echo "LANG=$LOCALE" > /etc/locale.conf || echo "locale.conf failed"
echo "$LOCALE UTF-8" >> /etc/default/libc-locales || echo "libc-locales failed"
xbps-reconfigure -f glibc-locales || echo "xbps-reconfigure glibc-locales failed"
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub || echo "grub config failed"
ROOT_UUID=$(blkid -o value -s UUID "$ROOT_PARTITION")
sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.uuid=$ROOT_UUID\"/" /etc/default/grub || echo "sed grub failed"
dd bs=1 count=64 if=/dev/urandom of=/boot/volume.key || echo "dd random failed"
cryptsetup luksAddKey "$ROOT_PARTITION" /boot/volume.key || echo "cryptsetup failed"
chmod 000 /boot/volume.key || echo "chmod volume key failed"
chmod -R g-rwx,o-rwx /boot || echo "chmod boot failed"
echo "$VOLUME_NAME_ROOT  $ROOT_PARTITION  /boot/volume.key  luks" >> /etc/crypttab || echo "crypttab failed"
mkdir -p /etc/dracut.conf.d || echo "mkdir dracut failed"
echo "install_items+=\" /boot/volume.key /etc/crypttab \"" > /etc/dracut.conf.d/10-crypt.conf || echo "dracut config failed"
grub-install "$DISK" || echo "grub install failed"
xbps-reconfigure -fa || echo "xbps-reconfigure -fa failed"
exit
EOF

# Unmount and reboot
echo "Unmounting filesystems..."
umount -R /mnt || error_exit "umount failed"

echo "Rebooting..."
#reboot

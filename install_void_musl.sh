#!/bin/bash

# UEFI Full Disk Encryption Installation Script (/ and /boot only, automated fdisk)

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

# Function to get user input for partition sizes
get_partition_sizes() {
  read -p "Enter the size for the EFI System Partition (e.g., 200M): " EFI_SIZE
  read -p "Enter the size for the boot partition (e.g., 200M): " BOOT_SIZE
  read -p "Enter the size for the root partition (e.g., 10G): " ROOT_SIZE
}

# Function to create partitions using fdisk
create_partitions_fdisk() {
  echo "Creating partitions with fdisk..."
  echo "o # Create a new empty DOS partition table" | fdisk "$DISK"
  echo "n # Add a new partition" | fdisk "$DISK"
  echo "p # Primary partition" | fdisk "$DISK"
  echo "1 # Partition number 1" | fdisk "$DISK"
  echo " # Default first sector" | fdisk "$DISK"
  echo "+$EFI_SIZE" | fdisk "$DISK"
  echo "t # Change a partition's system type" | fdisk "$DISK"
  echo "1 # Select partition 1" | fdisk "$DISK"
  echo "1 # EFI System" | fdisk "$DISK"
  echo "n # Add a new partition" | fdisk "$DISK"
  echo "p # Primary partition" | fdisk "$DISK"
  echo "2 # Partition number 2" | fdisk "$DISK"
  echo " # Default first sector" | fdisk "$DISK"
  echo "+$BOOT_SIZE" | fdisk "$DISK"
  echo "n # Add a new partition" | fdisk "$DISK"
  echo "p # Primary partition" | fdisk "$DISK"
  echo "3 # Partition number 3" | fdisk "$DISK"
  echo " # Default first sector" | fdisk "$DISK"
  echo "+$ROOT_SIZE" | fdisk "$DISK"
  echo "w # Write table to disk and exit" | fdisk "$DISK"

  # Update partitions
  partprobe "$DISK"

  EFI_PARTITION="${DISK}1"
  BOOT_PARTITION="${DISK}2"
  ROOT_PARTITION="${DISK}3"
}

# Get user input
get_user_input
get_partition_sizes

# Create partitions using fdisk
create_partitions_fdisk

# Format the EFI partition
mkfs.vfat "$EFI_PARTITION"

# Encrypted volume configuration
echo "Encrypting $ROOT_PARTITION..."
cryptsetup luksFormat --type luks1 "$ROOT_PARTITION"

echo "Opening root encrypted volume..."
cryptsetup luksOpen "$ROOT_PARTITION" "$VOLUME_NAME_ROOT"

echo "Creating filesystems..."
mkfs.xfs -L root "/dev/mapper/$VOLUME_NAME_ROOT"
mkfs.xfs "$BOOT_PARTITION"

# System installation
echo "Mounting filesystems..."
mount "/dev/mapper/$VOLUME_NAME_ROOT" /mnt
mkdir -p /mnt/boot
mount "$BOOT_PARTITION" /mnt/boot
mkdir -p /mnt/boot/efi
mount "$EFI_PARTITION" /mnt/boot/efi

echo "Copying RSA keys..."
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/

echo "Installing base system..."
xbps-install -Sy -R "$REPO_URL" -r /mnt base-system cryptsetup grub-x86_64-efi

# Configuration
echo "Generating fstab..."
xgenfstab /mnt > /mnt/etc/fstab

# Entering the Chroot
echo "Entering chroot..."
xchroot /mnt <<EOF
chown root:root /
chmod 755 /
passwd root
echo "voidvm" > /etc/hostname
echo "LANG=$LOCALE" > /etc/locale.conf
echo "$LOCALE UTF-8" >> /etc/default/libc-locales
xbps-reconfigure -f glibc-locales
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
ROOT_UUID=$(blkid -o value -s UUID "$ROOT_PARTITION")
sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.uuid=$ROOT_UUID\"/" /etc/default/grub
dd bs=1 count=64 if=/dev/urandom of=/boot/volume.key
cryptsetup luksAddKey "$ROOT_PARTITION" /boot/volume.key
chmod 000 /boot/volume.key
chmod -R g-rwx,o-rwx /boot
echo "$VOLUME_NAME_ROOT   $ROOT_PARTITION   /boot/volume.key   luks" >> /etc/crypttab
mkdir -p /etc/dracut.conf.d
echo "install_items+=\" /boot/volume.key /etc/crypttab \"" > /etc/dracut.conf.d/10-crypt.conf
grub-install "$DISK"
xbps-reconfigure -fa
exit
EOF

# Unmount and reboot
echo "Unmounting filesystems..."
umount -R /mnt

echo "Rebooting..."
#reboot

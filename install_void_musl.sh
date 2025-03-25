#!/bin/bash

# UEFI Full Disk Encryption Installation Script (/ only, automated parted)

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

# Function to create partitions using parted (updated to match Void docs)
create_partitions_parted() {
  echo "Creating partitions with parted..."
  parted -s "$DISK" mklabel gpt || error_exit "parted mklabel failed"
  parted -s -a optimal "$DISK" mkpart primary fat32 128MB 129MB || error_exit "parted efi failed"
  parted -s -a optimal "<span class="math-inline">DISK" mkpart primary xfs 129MB 100% \|\| error\_exit "parted root failed"
\# Check if partitions were created
if \[\[ \-b "</span>{DISK}1" && -b "${DISK}2" ]]; then
    echo "Partitions created successfully."
  else
    error_exit "Failed to create partitions."
  fi

  # Add a short delay
  sleep 2

  # Update partitions
  partprobe "<span class="math-inline">DISK" \|\| error\_exit "partprobe failed"
EFI\_PARTITION\="</span>{DISK}1"
  ROOT_PARTITION="${DISK}2"

  #Debugging information
  echo "Checking for partitions"
  lsblk "$DISK"
}

# Get user input
get_user_input

# Create partitions using parted
create_partitions_parted

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
cp /var/db

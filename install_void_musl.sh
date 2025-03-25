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
}

# Function to create partitions using parted
create_partitions_parted() {
  echo "Creating partitions with parted..."
  parted -s "$DISK" mklabel gpt
  parted -s "$DISK" mkpart primary fat32 1MiB 201MiB
  parted -s "$DISK" mkpart primary xfs 201MiB 100%

  # Check if partitions were created
  if [[ -b "${DISK}1" && -b "${DISK}2" ]]; then
    echo "Partitions created successfully."
  else
    error_exit "Failed to create partitions."
  fi

  # Add a short delay
  sleep 2

  # Update partitions
  partprobe "$DISK" || error_exit "partprobe failed"

  EFI_PARTITION="${DISK}1"
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
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub || echo "grub config failed"
ROOT_UUID=$(blkid -o value -s UUID "$ROOT_PARTITION")
sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.uuid=$ROOT_UUID\"/" /etc/default/grub || echo "sed grub failed"
dd bs=1 count=64 if=/dev/urandom of=/boot/volume.key || echo "dd random failed"
cryptsetup luksAddKey "$ROOT_PARTITION" /boot/volume.key || echo "cryptsetup failed"
chmod 000 /boot/volume.key || echo "chmod volume key failed"
chmod -R g-rwx,o-rwx /boot || echo "chmod boot failed"
echo "$VOLUME_NAME_ROOT$ROOT_PARTITION /boot/volume.key luks" >> /etc/crypttab || echo "crypttab failed" #corrected line
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

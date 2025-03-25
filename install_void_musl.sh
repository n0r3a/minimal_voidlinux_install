#!/bin/bash

# UEFI Full Disk Encryption Installation Script (No LVM)

# Variables
DISK="/dev/vda" # Change this to your disk
EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"
VOLUME_NAME="voidroot"
REPO_URL="https://repo-default.voidlinux.org/current/musl"

# Function to handle errors
error_exit() {
  echo "Error: $1"
  exit 1
}

# Function to get user input
get_user_input() {
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

# Function to create partitions
create_partitions() {
  echo "Creating partitions..."
  parted -s "$DISK" mklabel gpt || error_exit "parted mklabel failed"
  parted -s "$DISK" mkpart primary fat32 1MiB 201MiB || error_exit "parted efi failed"
  parted -s "$DISK" mkpart primary xfs 201MiB 100% || error_exit "parted root failed"
  parted -s "$DISK" set 1 boot on || error_exit "parted boot flag failed"
  lsblk "$DISK"
}

# Function to format partitions and encrypt root
format_and_encrypt() {
  echo "Formatting partitions and encrypting root..."
  mkfs.vfat "$EFI_PART" || error_exit "mkfs.vfat failed"
  cryptsetup luksFormat --type luks1 "$ROOT_PART" --key-file - <<< "$VOLUME_PASSWORD" || error_exit "cryptsetup luksFormat failed"
  cryptsetup luksOpen "$ROOT_PART" "$VOLUME_NAME" --key-file - <<< "$VOLUME_PASSWORD" || error_exit "cryptsetup luksOpen failed"
  mkfs.xfs -L root "/dev/mapper/$VOLUME_NAME" || error_exit "mkfs.xfs failed"
}

# Function to install base system
install_base() {
  echo "Installing base system..."
  mount "/dev/mapper/$VOLUME_NAME" /mnt || error_exit "mount root failed"
  mkdir -p /mnt/boot/efi
  mount "$EFI_PART" /mnt/boot/efi || error_exit "mount efi failed"
  mkdir -p /mnt/var/db/xbps/keys
  cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ || error_exit "cp keys failed"
  xbps-install -Sy -R "$REPO_URL" -r /mnt base-system cryptsetup grub-x86_64-efi || error_exit "xbps-install failed"
}

# Function to configure system
configure_system() {
  echo "Configuring system..."
  xgenfstab /mnt > /mnt/etc/fstab || error_exit "xgenfstab failed"
  xchroot /mnt <<EOF
    chown root:root / || error_exit "chown failed"
    chmod 755 / || error_exit "chmod failed"
    passwd root <<PASSWD_EOF
    $ROOT_PASSWORD
    $ROOT_PASSWORD
    PASSWD_EOF
    echo "$VOLUME_NAME" > /etc/hostname || error_exit "hostname failed"
    echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub || error_exit "grub config failed"
    ROOT_UUID=$(blkid -o value -s UUID "$ROOT_PART")
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\"/GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.uuid=$ROOT_UUID\"/" /etc/default/grub || error_exit "sed grub failed"
    dd bs=1 count=64 if=/dev/urandom of=/boot/volume.key || error_exit "dd random failed"
    cryptsetup luksAddKey "$ROOT_PART" /boot/volume.key --key-file - <<< "$VOLUME_PASSWORD" || error_exit "luks add key failed"
    chmod 000 /boot/volume.key || error_exit "chmod key failed"
    chmod -R g-rwx,o-rwx /boot || error_exit "chmod boot failed"
    echo "$VOLUME_NAME /dev/sda2 /boot/volume.key luks" >> /etc/crypttab || error_exit "crypttab failed"
    mkdir -p /etc/dracut.conf.d || error_exit "mkdir dracut failed"
    echo "install_items+=\" /boot/volume.key /etc/crypttab \"" > /etc/dracut.conf.d/10-crypt.conf || error_exit "dracut conf failed"
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=void "$DISK" || error_exit "grub install failed"
    grub-mkconfig -o /boot/grub/grub.cfg || error_exit "grub mkconfig failed"
    exit
EOF
}

# Main script
get_user_input
create_partitions
format_and_encrypt
install_base
configure_system

# Unmount and reboot
echo "Unmounting filesystems..."
umount -R /mnt || error_exit "umount failed"
echo "Rebooting..."
#reboot


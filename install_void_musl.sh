#!/bin/bash

# UEFI Full Disk Encryption Installation Script

# Variables
REPO_URL="https://repo-default.voidlinux.org/current/musl"
LUKS_NAME_ROOT="luks_void"

# Function to handle errors
error_exit() {
  echo "Error: $1"
  exit 1
}

# Function to get user input for variables
get_user_input() {
  read -p "Enter the disk you want to use (e.g., /dev/sda): " DISK
  read -s -p "Enter the passphrase for the luks partition: " ROOT_PASSPHRASE
  echo ""
  read -s -p "Re-enter the passphrase for the luks partition: " ROOT_PASSPHRASE_CONFIRM
  echo ""
  if [[ "$ROOT_PASSPHRASE" != "$ROOT_PASSPHRASE_CONFIRM" ]]; then
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
echo "$ROOT_PASSPHRASE" | cryptsetup luksFormat --type luks1 "$ROOT_PARTITION" || error_exit "cryptsetup luksFormat failed"

echo "Opening root encrypted volume..."
echo "$ROOT_PASSWORD" | cryptsetup luksOpen "$ROOT_PARTITION" "$LUKS_NAME_ROOT" || error_exit "cryptsetup luksOpen failed"

echo "Creating filesystems..."
mkfs.xfs -L root "/dev/mapper/$LUKS_NAME_ROOT" || error_exit "mkfs.xfs root failed"

# System installation
echo "Mounting filesystems..."
mount "/dev/mapper/$LUKS_NAME_ROOT" /mnt || error_exit "mount root failed"
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
xgenfstab -U /mnt > /mnt/etc/fstab || error_exit "xgenfstab failed"
sleep 5 # Add a 5-second delay

# Get the password before entering chroot
read -s -p "Enter passphrase: " ROOT_PASSWORD1
echo ""
read -s -p "Verify passphrase: " ROOT_PASSWORD2
echo ""

# get the password before xchroot
if [[ "$ROOT_PASSPHRASE1" != "$ROOT_PASSPHRASE2" ]]; then
  echo "Passphrases do not match. Exiting."
  exit 1 # Exit the script if passwords don't match
fi

# Get the UUID before entering chroot
ROOT_UUID=$(blkid -o value -s UUID "$ROOT_PARTITION")
echo "root partition uuid: $ROOT_UUID"

# Entering the Chroot
echo "Entering chroot..."
xchroot /mnt /bin/bash <<EOF || error_exit "xchroot failed"
chown root:root /
chmod 755 /
passwd root <<PASSWD_EOF
$ROOT_PASSWORD
$ROOT_PASSWORD
PASSWD_EOF
echo "tiny_void" > /etc/hostname
echo "GRUB_ENABLE_CRYPTODISK=y" > /etc/default/grub
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.uuid=$ROOT_UUID\"" >> /etc/default/grub
dd bs=1 count=64 if=/dev/urandom of=/boot/volume.key
sleep 2
echo "$ROOT_PASSPHRASE1" | cryptsetup luksAddKey "$ROOT_PARTITION" /boot/volume.key || echo "cryptsetup addkey failed"
sleep 2
chmod 000 /boot/volume.key
chmod -R g-rwx,o-rwx /boot
echo "$LUKS_NAME_ROOT $ROOT_PARTITION /boot/volume.key luks" > /etc/crypttab
echo "install_items+=\" /boot/volume.key /etc/crypttab \"" > /etc/dracut.conf.d/10-crypt.conf
grub-install "$DISK"
xbps-reconfigure -fa
sleep 2
echo "editing fstab"
sleep 2
echo "$EFI_PARTITION /boot/efi vfat defaults 0 0" > /etc/fstab
echo "$ROOT_PARTITION / xfs defaults 0 0" >> /etc/fstab

exit
EOF

# Unmount and reboot
sleep 5
echo "Unmounting filesystems..."
umount -R /mnt || error_exit "umount failed"

# Select function
select choice in "Reboot" "Stay in live environment"; do
  case $choice in
    "Reboot")
      echo "Rebooting..."
      reboot
      break;; # Exit the select loop
    "Stay in live environment")
      echo "Staying in live environment."
      break;; # Exit the select loop
    *)
      echo "Invalid choice. Please try again."
      ;;
  esac
done

echo "Script finished."

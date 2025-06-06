#!/bin/bash

# uefi
# luks
# xfs

# variables
REPO_URL="https://repo-default.voidlinux.org/current/musl"
LUKS_NAME_ROOT="luks_void"

# function to handle errors
error_exit() {
  echo "Error: $1"
  exit 1
}

# get user input for variables
get_user_input() {
  read -p "Enter the disk you want to use (e.g., /dev/vda): " DISK
  read -s -p "Enter the passphrase for the encrypted disk: " VOLUME_PASSWORD
  echo ""
  read -s -p "Re-enter the passphrase for the encrypted disk: " VOLUME_PASSWORD_CONFIRM
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

# create partitions using sfdisk
create_partitions_sfdisk() {
  echo "Creating partitions with sfdisk..."

  efi_part_size="250M"

  # wipe disk
  wipefs -aq "$DISK" || error_exit "wipefs failed"

  # format disk as GPT, create efi partition and a 2nd partition with the remaining disk space
  printf 'label: gpt\n, %s, U, *\n, , L\n' "$efi_part_size" | sfdisk -q "$DISK" || error_exit "sfdisk failed"

  # update partitions
  partprobe "$DISK" || error_exit "partprobe failed"

  if [[ "$DISK" == *"/nvme"* ]]; then
    EFI_PARTITION="${DISK}p1"
    ROOT_PARTITION="${DISK}p2"
  else
    EFI_PARTITION="${DISK}1"
    ROOT_PARTITION="${DISK}2"
  fi

  # debugging information
  echo "Checking for partitions"
  lsblk "$DISK"
}

# get user input
get_user_input

# create partitions using sfdisk
create_partitions_sfdisk

# format the efi partition
mkfs.vfat "$EFI_PARTITION" || error_exit "mkfs.vfat failed"

# encrypted partition configuration
echo "Encrypting $ROOT_PARTITION..."
echo "$VOLUME_PASSWORD" | cryptsetup luksFormat --type luks1 "$ROOT_PARTITION" || error_exit "cryptsetup luksFormat failed"

echo "Opening root encrypted volume..."
echo "$VOLUME_PASSWORD" | cryptsetup luksOpen "$ROOT_PARTITION" "$LUKS_NAME_ROOT" || error_exit "cryptsetup luksOpen failed"

echo "Creating filesystems..."
mkfs.xfs -L root "/dev/mapper/$LUKS_NAME_ROOT" || error_exit "mkfs.xfs root failed"

# ystem install
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

# configuration
echo "Generating fstab..."
xgenfstab -U /mnt > /mnt/etc/fstab || error_exit "xgenfstab failed"
sleep 5 # Add a 5-second delay

# get the luks passphrase before xchroot
read -s -p "Enter luks passphrase for boot key: " VOLUME_PASSWORD1
echo ""
read -s -p "Verify luks passphrase for boot key: " VOLUME_PASSWORD2
echo ""

# wrong passphrase
if [[ "$VOLUME_PASSWORD1" != "$VOLUME_PASSWORD2" ]]; then
  echo "Passphrases do not match. Exiting."
  exit 1
fi

# get uuid before xchroot
ROOT_UUID=$(blkid -o value -s UUID "$ROOT_PARTITION")
echo "root partition uuid: $ROOT_UUID"

# xchroot
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
echo "$VOLUME_PASSWORD1" | cryptsetup luksAddKey "$ROOT_PARTITION" /boot/volume.key || echo "cryptsetup addkey failed"
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

# unmount and reboot
sleep 5
echo "Unmounting filesystems..."
umount -R /mnt || error_exit "umount failed"

# select function
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

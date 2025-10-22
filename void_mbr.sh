#!/bin/bash

# Configuration: MBR (legacy boot), luks1, xfs (musl)

# --- Variables ---
REPO_URL="https://repo-default.voidlinux.org/current/musl" # Musl repository
LUKS_NAME_ROOT="luks_void"

# --- Function to handle errors ---
error_exit() {
  echo "Error: $1" >&2
  exit 1
}

# --- Get user input for variables ---
get_user_input() {
  read -p "Enter the disk you want to use (e.g., /dev/sda): " DISK
  if [[ ! -b "$DISK" ]]; then
    error_exit "Invalid disk device: $DISK"
  fi
  
  # VOLUME_PASSWORD is used for LUKS format/key slot 0 and adding the keyfile
  read -s -p "Enter the passphrase for the encrypted disk: " VOLUME_PASSWORD
  echo ""
  read -s -p "Re-enter the passphrase for the encrypted disk: " VOLUME_PASSWORD_CONFIRM
  echo ""
  if [[ "$VOLUME_PASSWORD" != "$VOLUME_PASSWORD_CONFIRM" ]]; then
    error_exit "LUKS Passwords do not match."
  fi
  
  # ROOT_PASSWORD is used for the user account password
  read -s -p "Enter the root password: " ROOT_PASSWORD
  echo ""
  read -s -p "Re-enter the root password: " ROOT_PASSWORD_CONFIRM
  echo ""
  if [[ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]]; then
    error_exit "Root passwords do not match."
  fi
}

# --- Create partitions using sfdisk (MBR) ---
create_partitions_sfdisk() {
  echo "Creating partitions with sfdisk (MBR/DOS layout)..."

  # wipe disk
  wipefs -af "$DISK" || error_exit "wipefs failed"

  # format disk as DOS (MBR), create a single primary partition using remaining space
  # Type 83 (Linux) is used.
  printf 'label: dos\n, , L, *\n' | sfdisk -q "$DISK" || error_exit "sfdisk failed"

  # Determine partition names
  if [[ "$DISK" == *"/nvme"* ]]; then
    ROOT_PARTITION="${DISK}p1"
  else
    ROOT_PARTITION="${DISK}1"
  fi

  # update partitions
  partprobe "$DISK" || error_exit "partprobe failed"
  sleep 2 # Give kernel a moment to recognize partitions

  # debugging information
  echo "Checking for partitions"
  lsblk "$DISK"
}

# --- Main Installation Steps ---

# 1. Get user input
get_user_input

# 2. Create partitions using sfdisk
create_partitions_sfdisk

# 3. Encrypted partition configuration (using LUKS1)
echo "Encrypting $ROOT_PARTITION with LUKS1..."
echo "$VOLUME_PASSWORD" | cryptsetup luksFormat --type luks1 "$ROOT_PARTITION" || error_exit "cryptsetup luksFormat failed"

echo "Opening root encrypted volume..."
echo "$VOLUME_PASSWORD" | cryptsetup luksOpen "$ROOT_PARTITION" "$LUKS_NAME_ROOT" || error_exit "cryptsetup luksOpen failed"

# 4. Create filesystems
echo "Creating XFS filesystem on decrypted volume..."
mkfs.xfs -L root "/dev/mapper/$LUKS_NAME_ROOT" || error_exit "mkfs.xfs root failed"

# 5. System install preparation
echo "Mounting root filesystem..."
mount "/dev/mapper/$LUKS_NAME_ROOT" /mnt || error_exit "mount root failed"

echo "Copying XBPS RSA keys..."
mkdir -p /mnt/var/db/xbps/keys
cp -a /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ || error_exit "cp keys failed"

echo "Installing base system and necessary packages (musl, MBR grub)..."
# Installed the standard 'grub' package instead of 'grub-x86_64-efi'
xbps-install -Sy -R "$REPO_URL" -r /mnt base-system cryptsetup grub dracut || error_exit "xbps-install failed"

# 6. Initial configuration (used only for structure by xgenfstab)
echo "Generating initial fstab..."
xgenfstab -U /mnt > /mnt/etc/fstab || error_exit "xgenfstab failed"

# Get the UUID of the LUKS partition for crypttab and grub
LUKS_PART_UUID=$(blkid -o value -s UUID "$ROOT_PARTITION")
echo "Root LUKS partition UUID: $LUKS_PART_UUID"

# 7. Enter chroot for final configuration
echo "Entering chroot for system configuration..."
xchroot /mnt /bin/bash <<EOF || error_exit "xchroot failed"
set -e # Exit immediately if a command exits with a non-zero status

# Set root password
echo "Setting root password..."
passwd root <<PASSWD_EOF
$ROOT_PASSWORD
$ROOT_PASSWORD
PASSWD_EOF

# Set hostname
echo "tiny_void" > /etc/hostname

# Keyfile generation and configuration
echo "Configuring LUKS keyfile for boot..."
dd bs=1 count=64 if=/dev/urandom of=/boot/volume.key
# Use the known LUKS password to add the keyfile to an empty slot
echo "$VOLUME_PASSWORD" | cryptsetup luksAddKey "$ROOT_PARTITION" /boot/volume.key || echo "cryptsetup addkey failed (requires existing password slot)"
# Set permissions to 000 as per Void Linux FDE documentation
chmod 000 /boot/volume.key
chmod -R g-rwx,o-rwx /boot

# Configure crypttab (use UUID for robustness)
echo "Configuring /etc/crypttab..."
# Use UUID of the LUKS partition
echo "$LUKS_NAME_ROOT UUID=$LUKS_PART_UUID /boot/volume.key luks" > /etc/crypttab

# Configure dracut to include the keyfile and crypttab in the initramfs
echo "Configuring dracut..."
echo 'install_items+=" /boot/volume.key /etc/crypttab "' > /etc/dracut.conf.d/10-crypt.conf

# Configure GRUB
echo "Configuring GRUB..."
# Set GRUB to enable cryptodisk support (essential for keyfile unlock)
echo "GRUB_ENABLE_CRYPTODISK=y" > /etc/default/grub
# Set the kernel command line to unlock the volume using its UUID
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.uuid=$LUKS_PART_UUID\"" >> /etc/default/grub

# Install GRUB (MBR standard)
# This installs the bootloader to the Master Boot Record of the disk.
grub-install "$DISK"

# Final /etc/fstab correction
echo "Correcting /etc/fstab..."
# Re-writing fstab with the single root entry using the device mapper name
cat > /etc/fstab <<FSTAB_EOF
# <file system> <dir> <type> <options> <dump> <pass>
/dev/mapper/$LUKS_NAME_ROOT / xfs defaults 0 0
FSTAB_EOF

# Reconfigure all packages to build the initramfs
echo "Rebuilding initramfs (dracut)..."
xbps-reconfigure -fa

echo "Chroot configuration complete."
exit
EOF

# 8. Unmount and Reboot
sleep 5
echo "Unmounting filesystems..."
umount -R /mnt || umount -lR /mnt || error_exit "umount failed"

echo "Installation complete."

# 9. Select reboot or stay
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

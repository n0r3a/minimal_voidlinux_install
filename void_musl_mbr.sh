#!/bin/bash

# Configuration: MBR (DOS), luks1, ext4 (musl) - Single Encrypted Partition with Encrypted /boot

# --- Variables ---
REPO_URL="https://repo-default.voidlinux.org/current/musl" 
LUKS_NAME_ROOT="luks_void"

# --- Function to handle errors ---
error_exit() {
  echo "Error: $1" >&2
  exit 1
}

# --- Get user input for variables ---
get_user_input() {
  read -p "Enter the disk you want to use (e.g., /dev/vda or /dev/sda): " DISK
  if [[ ! -b "$DISK" ]]; then
    error_exit "Invalid disk device: $DISK"
  fi
  
  read -s -p "Enter the passphrase for the encrypted disk: " VOLUME_PASSWORD
  echo ""
  read -s -p "Re-enter the passphrase for the encrypted disk: " VOLUME_PASSWORD_CONFIRM
  echo ""
  if [[ "$VOLUME_PASSWORD" != "$VOLUME_PASSWORD_CONFIRM" ]]; then
    error_exit "LUKS Passwords do not match."
  fi
  
  read -s -p "Enter the root password: " ROOT_PASSWORD
  echo ""
  read -s -p "Re-enter the root password: " ROOT_PASSWORD_CONFIRM
  echo ""
  if [[ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]]; then
    error_exit "Root passwords do not match."
  fi
}

# --- Create partitions using sfdisk (MBR/Legacy BIOS) ---
create_partitions_sfdisk() {
  echo "Creating partitions with sfdisk (MBR/DOS layout)..."

  # Wipe disk
  wipefs -af "$DISK" || error_exit "wipefs failed"

  # Format disk as MBR (DOS), create a single partition using the rest of the space, 
  # set type to Linux (83), and mark it bootable (*).
  printf 'label: dos\n, , 83, *\n' | sfdisk -q "$DISK" || error_exit "sfdisk failed"

  # Determine partition name (Assuming a single primary partition)
  if [[ "$DISK" == *"/nvme"* ]]; then
    # NVMe partitions typically use 'p' separator (e.g., /dev/nvme0n1p1)
    ROOT_PARTITION="${DISK}p1"
  elif [[ "$DISK" == *"/mmcblk"* ]]; then
    # eMMC/SD partitions typically use 'p' separator (e.g., /dev/mmcblk0p1)
    ROOT_PARTITION="${DISK}p1"
  else
    # Standard disk partitions (e.g., /dev/sda1)
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

# 3. Format EFI partition (REMOVED: Not needed for MBR)

# 4. Encrypted partition configuration (using LUKS1)
echo "Encrypting $ROOT_PARTITION with LUKS1 (Root volume including /boot)..."
echo "$VOLUME_PASSWORD" | cryptsetup luksFormat --type luks1 "$ROOT_PARTITION" || error_exit "cryptsetup luksFormat failed"

echo "Opening root encrypted volume..."
echo "$VOLUME_PASSWORD" | cryptsetup luksOpen "$ROOT_PARTITION" "$LUKS_NAME_ROOT" || error_exit "cryptsetup luksOpen failed"

# 5. Create filesystems
echo "Creating EXT4 filesystem on decrypted volume (/ and /boot)..."
mkfs.ext4 -L root -F "/dev/mapper/$LUKS_NAME_ROOT" || error_exit "mkfs.ext4 root failed"

# 6. System install preparation
echo "Mounting filesystems..."
# Mount the decrypted LUKS volume directly to /mnt
mount "/dev/mapper/$LUKS_NAME_ROOT" /mnt || error_exit "mount root failed"
# No separate /boot/efi mount is required for MBR

# >>>>> CRITICAL STEP FOR CHROOT DEVICE MAPPING FIX <<<<<
echo "Binding virtual filesystems..."
for dir in dev proc sys; do
    mkdir -p /mnt/$dir
    mount --rbind /$dir /mnt/$dir
done
# >>>>> END OF CRITICAL STEP <<<<<

echo "Copying XBPS RSA keys..."
mkdir -p /mnt/var/db/xbps/keys
cp -a /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ || error_exit "cp keys failed"

# Note: Using grub-i386-pc instead of grub-x86_64-efi for Legacy BIOS/MBR
echo "Installing base system and necessary packages (musl, MBR grub)..."
env XBPS_ARCH=x86_64-musl xbps-install -Sy -R "$REPO_URL" -r /mnt base-system cryptsetup grub-i386-pc dracut || error_exit "xbps-install failed"

# 7. Initial configuration
echo "Generating initial fstab..."
xgenfstab -U /mnt > /mnt/etc/fstab || error_exit "xgenfstab failed"

# Get the UUID of the LUKS partition for crypttab and grub
LUKS_PART_UUID=$(blkid -o value -s UUID "$ROOT_PARTITION")
echo "Root LUKS partition UUID: $LUKS_PART_UUID"

# 8. Enter chroot for final configuration
echo "Entering chroot for system configuration..."
xchroot /mnt /bin/bash <<EOF || error_exit "xchroot failed"
set -e 

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
echo "$VOLUME_PASSWORD" | cryptsetup luksAddKey "$ROOT_PARTITION" /boot/volume.key || echo "cryptsetup addkey failed (requires existing password slot)"
chmod 000 /boot/volume.key
chmod -R g-rwx,o-rwx /boot

# Configure crypttab
echo "Configuring /etc/crypttab..."
echo "$LUKS_NAME_ROOT UUID=$LUKS_PART_UUID /boot/volume.key luks" > /etc/crypttab

# Configure dracut
echo "Configuring dracut..."
echo 'install_items+=" /boot/volume.key /etc/crypttab "' > /etc/dracut.conf.d/10-crypt.conf

# Configure GRUB
echo "Configuring GRUB..."
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.uuid=$LUKS_PART_UUID\"" >> /etc/default/grub

# Final step before install: Ensure GRUB configuration is generated
echo "Generating final grub.cfg..."
grub-mkconfig -o /boot/grub/grub.cfg

# Install GRUB (Legacy BIOS standard)
echo "Installing GRUB to MBR on $DISK..."
grub-install --target=i386-pc "$DISK"

# Final /etc/fstab correction (Only the root filesystem is needed)
echo "Correcting /etc/fstab..."
cat > /etc/fstab <<FSTAB_EOF
# <file system> <dir> <type> <options> <dump> <pass>
/dev/mapper/$LUKS_NAME_ROOT / ext4 defaults 0 0 
FSTAB_EOF

# Reconfigure all packages to build the initramfs
echo "Rebuilding initramfs (dracut)..."
xbps-reconfigure -fa

echo "Chroot configuration complete."
exit
EOF

# 9. Unmount and Reboot
sleep 5
echo "Unmounting virtual and physical filesystems..."
for dir in dev proc sys; do
    umount -l /mnt/$dir || true
done

umount -R /mnt || umount -lR /mnt || error_exit "umount failed"

echo "Installation complete."

# 10. Select reboot or stay
select choice in "Reboot" "Stay in live environment"; do
  case $choice in
    "Reboot")
      echo "Rebooting..."
      reboot
      break;; 
    "Stay in live environment")
      echo "Staying in live environment."
      break;; 
    *)
      echo "Invalid choice. Please try again."
      ;;
  esac
  
done

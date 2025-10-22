#!/bin/bash
# void linux musl install script for x86 systems (efi)
# n0r3a

REPO_URL="https://repo-default.voidlinux.org/current/musl" 
LUKS_NAME_ROOT="luks_void"

# handle errors
error_exit() {
  echo "error: $1" >&2
  exit 1
}

# get user input
get_user_input() {
  read -p "enter the disk you want to use (e.g., /dev/sda or /dev/nvme0n1): " DISK
  if [[ ! -b "$DISK" ]]; then
    error_exit "invalid disk device: $DISK"
  fi
  
  read -s -p "enter the passphrase for the encrypted disk: " VOLUME_PASSWORD
  echo ""
  read -s -p "re-enter the passphrase for the encrypted disk: " VOLUME_PASSWORD_CONFIRM
  echo ""
  if [[ "$VOLUME_PASSWORD" != "$VOLUME_PASSWORD_CONFIRM" ]]; then
    error_exit "luks passwords do not match."
  fi
  
  read -s -p "enter the root password: " ROOT_PASSWORD
  echo ""
  read -s -p "re-enter the root password: " ROOT_PASSWORD_CONFIRM
  echo ""
  if [[ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]]; then
    error_exit "root passwords do not match."
  fi
}

# create partitions using sfdisk
create_partitions_sfdisk() {
  echo "creating partitions with sfdisk (gpt)..."

  efi_part_size="250M"

  # wipe disk
  wipefs -af "$DISK" || error_exit "wipefs failed"

  # format disk as gpt, create efi partition and prepare luks partition
  printf 'label: gpt\n, %s, U, *\n, , L\n' "$efi_part_size" | sfdisk -q "$DISK" || error_exit "sfdisk failed"

  # determine partition names
  if [[ "$DISK" == *"/nvme"* ]]; then
    EFI_PARTITION="${DISK}p1"
    ROOT_PARTITION="${DISK}p2"
  else
    EFI_PARTITION="${DISK}1"
    ROOT_PARTITION="${DISK}2"
  fi

  # update partitions
  partprobe "$DISK" || error_exit "partprobe failed"
  sleep 2 # sleep just to give the kernel some time

  # debugging information
  echo "checking for partitions"
  lsblk "$DISK"
}

## main installation

# get user input
get_user_input

# create partitions using sfdisk
create_partitions_sfdisk

# format efi partition
echo "formatting efi partition $EFI_PARTITION..."
mkfs.vfat -F 32 "$EFI_PARTITION" || error_exit "mkfs.vfat failed"

# encrypted partition configuration
echo "encrypting $ROOT_PARTITION with luks1 (root volume including /boot)..."
echo "$VOLUME_PASSWORD" | cryptsetup luksFormat --type luks1 "$ROOT_PARTITION" || error_exit "cryptsetup luksFormat failed"

echo "opening root encrypted volume..."
echo "$VOLUME_PASSWORD" | cryptsetup luksOpen "$ROOT_PARTITION" "$LUKS_NAME_ROOT" || error_exit "cryptsetup luksOpen failed"

# create filesystems
echo "Creating EXT4 filesystem on decrypted volume (/ and /boot)..."
mkfs.ext4 -L root -F "/dev/mapper/$LUKS_NAME_ROOT" || error_exit "mkfs.ext4 root failed"

# system install prep
echo "mounting filesystems..."
mount "/dev/mapper/$LUKS_NAME_ROOT" /mnt || error_exit "mount root failed"
mkdir -p /mnt/boot/efi
mount "$EFI_PARTITION" /mnt/boot/efi || error_exit "mount efi failed"

# device mapping
echo "binding virtual filesystems..."
for dir in dev proc sys; do
    mkdir -p /mnt/$dir
    mount --rbind /$dir /mnt/$dir
done

echo "copying xbps rsa keys..."
mkdir -p /mnt/var/db/xbps/keys
cp -a /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ || error_exit "cp keys failed"

echo "installing base system and necessary packages (musl, UEFI grub)..."
env XBPS_ARCH=x86_64-musl xbps-install -Sy -R "$REPO_URL" -r /mnt base-system cryptsetup grub-x86_64-efi dracut || error_exit "xbps-install failed"

# initial configuration
echo "generating initial fstab..."
xgenfstab -U /mnt > /mnt/etc/fstab || error_exit "xgenfstab failed"

# get the uuid of the luks partition for crypttab and grub
LUKS_PART_UUID=$(blkid -o value -s UUID "$ROOT_PARTITION")
echo "root luks partition uuid: $LUKS_PART_UUID"

# chroot for final configuration
echo "entering chroot for system configuration..."
xchroot /mnt /bin/bash <<EOF || error_exit "xchroot failed"
set -e 

# set root password
echo "setting root password..."
passwd root <<PASSWD_EOF
$ROOT_PASSWORD
$ROOT_PASSWORD
PASSWD_EOF

# hostname
echo "tiny_void" > /etc/hostname

# keyfile generation and configuration for unlocking luks
echo "configuring luks keyfile for boot..."
dd bs=1 count=64 if=/dev/urandom of=/boot/volume.key
echo "$VOLUME_PASSWORD" | cryptsetup luksAddKey "$ROOT_PARTITION" /boot/volume.key || echo "cryptsetup addkey failed (requires existing password slot)"
chmod 000 /boot/volume.key
chmod -R g-rwx,o-rwx /boot

# configure crypttab
echo "configuring /etc/crypttab..."
echo "$LUKS_NAME_ROOT UUID=$LUKS_PART_UUID /boot/volume.key luks" > /etc/crypttab

# configure dracut
echo "configuring dracut..."
echo 'install_items+=" /boot/volume.key /etc/crypttab "' > /etc/dracut.conf.d/10-crypt.conf

# configure grub
echo "configuring GRUB..."
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.uuid=$LUKS_PART_UUID\"" >> /etc/default/grub

# ensure grub directory exists
echo "creating /boot/grub directory explicitly..."
mkdir -p /boot/grub

# final step before install: ensure grub configuration is generated
echo "generating final grub.cfg..."
grub-mkconfig -o /boot/grub/grub.cfg

# install grub
echo "installing grub..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Void

# final /etc/fstab correction
echo "correcting /etc/fstab..."
cat > /etc/fstab <<FSTAB_EOF
# <file system> <dir> <type> <options> <dump> <pass>
UUID=\$(blkid -o value -s UUID "$EFI_PARTITION") /boot/efi vfat defaults 0 0
/dev/mapper/$LUKS_NAME_ROOT / ext4 defaults 0 0 
FSTAB_EOF

# reconfigure all packages to build the initramfs
echo "rebuilding initramfs..."
xbps-reconfigure -fa

echo "chroot configuration complete."
exit
EOF

# unmount and reboot
sleep 5
echo "unmounting virtual and physical filesystems..."
for dir in dev proc sys; do
    umount -l /mnt/$dir || true
done

umount -R /mnt || umount -lR /mnt || error_exit "umount failed"

echo "installation complete."

# select reboot or stay
select choice in "reboot" "Stay in live environment"; do
  case $choice in
    "reboot")
      echo "rebooting..."
      reboot
      break;; 
    "stay in live environment")
      echo "staying in live environment."
      break;; 
    *)
      echo "invalid choice. please try again."
      ;;
  esac
done

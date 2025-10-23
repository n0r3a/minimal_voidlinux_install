#!/bin/bash
REPO_URL="https://repo-default.voidlinux.org/current/musl"
LUKS_NAME_ROOT="luks_void"

error_exit() {
  echo "error: $1" >&2
  exit 1
}

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

create_partitions_sfdisk() {
  echo "creating partitions with sfdisk (mbr/dos - single partition)..."

  wipefs -af "$DISK" || error_exit "wipefs failed"

  printf 'label: dos\n, , L, *\n' | sfdisk -q "$DISK" || error_exit "sfdisk failed"

  if [[ "$DISK" == *"/nvme"* ]]; then
    ROOT_PARTITION="${DISK}p1"
  else
    ROOT_PARTITION="${DISK}1"
  fi

  partprobe "$DISK" || error_exit "partprobe failed"
  sleep 2

  echo "checking for partitions"
  lsblk "$DISK"
}

get_user_input

create_partitions_sfdisk

echo "encrypting $ROOT_PARTITION with luks1..."
echo "$VOLUME_PASSWORD" | cryptsetup luksFormat --type luks1 "$ROOT_PARTITION" || error_exit "cryptsetup luksFormat failed"

echo "opening root encrypted volume..."
echo "$VOLUME_PASSWORD" | cryptsetup luksOpen "$ROOT_PARTITION" "$LUKS_NAME_ROOT" || error_exit "cryptsetup luksOpen failed"

echo "creating ext4 filesystem on decrypted volume..."
mkfs.ext4 -L root -F "/dev/mapper/$LUKS_NAME_ROOT" || error_exit "mkfs.ext4 root failed"

echo "mounting filesystems..."
mount "/dev/mapper/$LUKS_NAME_ROOT" /mnt || error_exit "mount root failed"

echo "binding virtual filesystems..."
for dir in dev proc sys; do
    mkdir -p /mnt/$dir
    mount --rbind /$dir /mnt/$dir
done

echo "copying xbps rsa keys..."
mkdir -p /mnt/var/db/xbps/keys
cp -a /var/db/xbps/keys/* /mnt/var/db/xbps/keys/ || error_exit "cp keys failed"

echo "installing base system and necessary packages..."
env XBPS_ARCH=x86_64-musl xbps-install -Sy -R "$REPO_URL" -r /mnt base-system cryptsetup grub dracut || error_exit "xbps-install failed"

echo "generating initial fstab..."
xgenfstab -U /mnt > /mnt/etc/fstab || error_exit "xgenfstab failed"

LUKS_PART_UUID=$(blkid -o value -s UUID "$ROOT_PARTITION")
echo "root luks partition uuid: $LUKS_PART_UUID"

echo "entering chroot for system configuration..."
xchroot /mnt /bin/bash <<EOF || error_exit "xchroot failed"
set -e 

echo "setting root password..."
passwd root <<PASSWD_EOF
$ROOT_PASSWORD
$ROOT_PASSWORD
PASSWD_EOF

echo "tiny_void" > /etc/hostname

echo "creating /boot/grub directory..."
mkdir -p /boot/grub || error_exit "mkdir /boot/grub failed" 

echo "ensuring dracut has luks modules..."

echo "configuring GRUB for full disk encryption (fixing double password prompt)..."
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.name=$LUKS_PART_UUID=$LUKS_NAME_ROOT root=/dev/mapper/$LUKS_NAME_ROOT\"" >> /etc/default/grub

echo "generating final grub.cfg..."
grub-mkconfig -o /boot/grub/grub.cfg

echo "installing grub to $DISK..."
grub-install --target=i386-pc "$DISK"

echo "correcting /etc/fstab..."
cat > /etc/fstab <<FSTAB_EOF
# <file system> <dir> <type> <options> <dump> <pass>
/dev/mapper/$LUKS_NAME_ROOT / ext4 defaults 0 0 
FSTAB_EOF

echo "rebuilding initramfs..."
xbps-reconfigure -fa

echo "chroot configuration complete."
exit
EOF

sleep 5
echo "unmounting virtual and physical filesystems..."
for dir in dev proc sys; do
    umount -l /mnt/$dir || true
done

umount -R /mnt || umount -lR /mnt || error_exit "umount failed"

echo "installation complete."

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

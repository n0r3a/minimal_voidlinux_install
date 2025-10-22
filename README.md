## Minimal void linux install (uefi x86_64)

This is a simple script to install void linux musl on uefi x86_64 systems. It's for people who want a minimal fde setup without LVM and "fancy" filesystems like btrfs

**Important notes before running this script:**

* This script doesn't use lvm
* File system is ext4
* You'll need `git` and `parted` installed before running the script
* No swap
* Partitions are: **/boot/efi** and **/**
* Make sure to back up any important data on your disk before running this script, as it will overwrite the data
* Be very careful with your passwords and passphrases. Keep them safe!
* If you have any questions or find any problems, please create an issue

**Why I made this:**

I made this script because I prefer a simple setup on my laptop. I like "simple" filesystems and don't need lvm. If you're like me, this script might be helpful!

## Quick start guide

1.  **Download Void Linux:** Get the Void Linux x86_64 musl live environment from the Void Linux website
2.  **Boot the Live Environment:** Boot your computer from the live environment and log in as root
3.  **Install Needed Packages:** after root login run:
    ```bash
    xbps-install -S git parted
    ```
4.  **Clone the Repository:** Clone this repository using git:
    ```bash
    git clone https://github.com/n0r3a/minimal_voidlinux_install
    ```
5.  **Go to the Directory:** Change to the repository directory:
    ```bash
    cd minimal_voidlinux_install
    ```
6.  **Make the Script Executable:** Make the installation script executable:
    ```bash
    chmod +x install_void_musl.sh
    ```
7.  **Run the Script:** Run the installation script:
    ```bash
    ./install_void_musl.sh
    ```
8.  **Enter LUKS Passphrase:** You'll be asked to enter a passphrase for LUKS encryption. Type it twice to confirm
9.  **Set Root Password:** Enter a password for the root user. Type it twice to confirm
10. **Add LUKS Key:** Enter the LUKS passphrase again, twice, to add it as a key for /boot
11. **Choose to Reboot:** The script will ask if you want to reboot or stay in the live environment
12. **Enjoy Void Linux with FDE!** That's it! Your system is now installed
12. **Remember** to change your computer's hostname, and check the network setup instructions on the Void Linux website

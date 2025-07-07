# Arch Linux ZFS Installation Script

This script automates the installation of Arch Linux on ZFS, providing options for BIOS/UEFI boot, ZFS pool encryption, and various RAID configurations for multi-disk setups.

---

## Table of Contents
* [Disclaimer](#disclaimer)
* [Features](#features)
* [Prerequisites](#prerequisites)
* [How it Works](#how-it-works)
* [How to Use](#how-to-use)
* [Post-Installation Steps (Recommended)](#post-installation-steps-recommended)
* [Troubleshooting](#troubleshooting)
* [Contributions](#contributions)

---

## Disclaimer

**WARNING**: This script performs **destructive** operations on your selected disks. It will erase ALL existing data on the chosen disks. Use with extreme caution and ensure you have backed up any important data.

This script is provided as-is and without warranty. While efforts have been made to make it robust, unforeseen issues may arise. It is highly recommended to understand each step before running this script.

## Features

* **Automated ZFS Setup**: Handles ZFS pool and dataset creation (rpool and bpool).
* **Boot Type Selection**: Supports both BIOS (Legacy) and UEFI boot environments.
* **ZFS Encryption**: Option to encrypt the main ZFS root pool (`rpool`).
* **Multiple Disk Configurations**:
    * Single disk setup.
    * Multi-disk RAID configurations: Simple Mirror (RAID1), RAID10 (striped mirror), RAIDZ1, RAIDZ2, RAIDZ3.
* **Pacman Keyring Management**: Initializes and populates the Pacman keyring and handles ArchZFS repository setup, including PGP key import.
* **Base System Installation**: Installs a base Arch Linux system along with essential packages like `zfs-utils`, `grub`, `efibootmgr`, `vim`, `zsh`, `openssh`, and more.
* **System Configuration**: Sets up hostname, locales, timezone, root password, and enables ZFS services.
* **GRUB Configuration**: Configures GRUB for ZFS boot and installs it on the selected disks.
* **Clean Chroot Exit**: Ensures proper unmounting and ZFS pool export after installation.

## Prerequisites

* **Arch Linux Live Environment with ZFS Support**: You **must** run this script from an Arch Linux ISO that has ZFS support already installed and available (e.g., `zfs` utilities are present). Examples include custom ISOs like [r-maerz/archlinux-lts-zfs](https://github.com/r-maerz/archlinux-lts-zfs) or by manually installing `zfs-dkms` and `zfs-utils` on a standard live environment.
* **Internet Connection**: The script requires an active internet connection to download packages and refresh keys.
* **Basic Arch Linux Knowledge**: While automated, understanding fundamental Arch Linux concepts and ZFS basics is recommended for troubleshooting.

## How it Works

1.  **Initial Setup**: Sets up variables for hostname, keymap, locale, and timezone. It also cleans and populates the Pacman keyring and adds the ArchZFS repository.
2.  **Disk Selection**: Presents a list of available physical disks and prompts the user to select one or more disks for installation.
3.  **Boot Type & Encryption Choice**: Asks the user to choose between BIOS or UEFI boot and whether to encrypt the main ZFS pool.
4.  **RAID Type Selection (for multi-disk)**: If multiple disks are selected, it prompts for the desired ZFS RAID configuration.
5.  **Disk Partitioning**: Wipes the selected disks and creates the necessary partitions:
    * BIOS: 1MB BIOS Boot Partition, 1GB ZFS Boot Partition (`bpool`), remaining for ZFS Root (`rpool`).
    * UEFI: 512MB EFI System Partition (FAT32), 1GB ZFS Boot Partition (`bpool`), remaining for ZFS Root (`rpool`).
6.  **ZFS Pool Creation**: Creates the `bpool` and `rpool` ZFS pools based on the chosen disks and RAID type. If encryption is selected, `rpool` will be encrypted.
7.  **ZFS Dataset Creation & Mounting**: Creates `rpool/ROOT/arch` and `bpool/BOOT/arch` datasets and mounts them to `/mnt` and `/mnt/boot` respectively. An encrypted `rpool/home` dataset is also created if encryption is chosen.
8.  **Base System Installation**: Uses `pacstrap` to install the base Arch Linux system and specified packages into the new environment (`/mnt`).
9.  **Chroot Configuration**:
    * Copes `pacman.conf` and `zpool.cache` into the new system.
    * Sets up hostname, locales, and keyboard layout within the new system.
    * A temporary script is executed inside the `chroot` environment to perform post-installation tasks:
        * Sets system clock.
        * Generates locales.
        * Sets timezone.
        * Prompts for root password.
        * Configures ZFS hostid and cachefile within the chroot.
        * Enables ZFS services.
        * Modifies `mkinitcpio.conf` to include the `zfs` hook and regenerates the initramfs.
        * Configures GRUB kernel parameters (including ZFS boot options and encryption key prompt).
        * Updates and installs GRUB to the selected disks.
        * Formats and mounts EFI partitions (for UEFI).
        * Enables SSH login for root.
        * Sets ZSH as the default shell for root.
10. **Cleanup**: Unmounts all filesystems and exports ZFS pools for a clean system shutdown or reboot.

## How to Use

1.  **Boot from Arch Linux ISO with ZFS support**: Start your machine from a compatible Arch Linux ISO.
2.  **Ensure Internet Connectivity**: Verify you have an active internet connection (e.g., `ping archlinux.org`).
3.  **Download the Script**:
    ```bash
    curl -o install_arch_zfs.sh https://raw.githubusercontent.com/danfossi/Arch-ZFS-Root-Installation-Script/refs/heads/main/arch_zfs_install.sh
    ```
4.  **Make it Executable**:
    ```bash
    chmod +x install_arch_zfs.sh
    ```
5.  **Run the Script**:
    ```bash
    ./install_arch_zfs.sh
    ```
6.  **Follow On-Screen Prompts**: The script will guide you through:
    * Disk selection.
    * Boot type (BIOS/UEFI).
    * ZFS pool encryption.
    * RAID type (if multiple disks).
    * Setting the root password.
7.  **Review Output**: Pay attention to any warnings or errors displayed by the script.
8.  **Reboot**: Once the script completes successfully, reboot your system:
    ```bash
    reboot
    ```

## Post-Installation Steps (Recommended)

After a successful installation and reboot, you might want to:

* **Create a New User**: It's generally not recommended to use the `root` user for daily tasks.
    ```bash
    useradd -m -g users -G wheel,storage,power -s /bin/zsh yourusername
    passwd yourusername
    ```
    Then, enable `sudo` for the `wheel` group by uncommenting `%wheel ALL=(ALL:ALL) ALL` in `/etc/sudoers` (use `visudo`).
* **Install a Desktop Environment/Window Manager**.
* **Install your favorite applications**.
* **Configure Network**: If `dhcpcd` is not sufficient, configure `NetworkManager` or `systemd-networkd`.
* **Review `fstab`**: Although generated, it's good practice to review `/etc/fstab` to ensure everything looks correct, especially for the EFI partition if using UEFI.

## Troubleshooting

* **"This script must be run from an Arch Linux live environment."**: Ensure you have booted from the Arch Linux ISO.
* **"command not found: zfs" or similar ZFS errors**: This means your live environment does not have ZFS support. Boot from a specialized Arch ZFS ISO or manually install ZFS packages.
* **Keyring/GPG Errors**: The script attempts to clean and refresh the keyring. If issues persist, manually try `pacman-key --init`, `pacman-key --populate archlinux`, and `pacman-key --refresh-keys`.
* **ZFS Pool Creation Errors**: If ZFS pool creation fails, ensure the disks were correctly wiped and `zpool labelclear` ran successfully. Sometimes, old labels can persist. You can try `zpool import` to see if any old pools are detected.
* **GRUB Installation Issues**:
    * **BIOS**: Ensure the BIOS Boot partition exists and is correctly identified.
    * **UEFI**: Ensure the EFI System Partition is correctly formatted to FAT32 and mounted to `/boot/efi` before `grub-install`. Check `efibootmgr -v` after installation within the chroot to see if the EFI entry was created.
* **"chroot script failed"**: This indicates an error occurred during the system configuration inside the new installation. Carefully review the output from the `chroot` command for specific error messages. You can manually `arch-chroot /mnt` and try to debug the issues.
* **ZFS Modules not loading**: Ensure the `zfs` hook is correctly placed in `mkinitcpio.conf` (after `block` and before `filesystems`). Regenerate initramfs with `mkinitcpio -P`.

For further assistance, refer to the [Arch Linux Wiki](https://wiki.archlinux.org/) and the [OpenZFS on Linux Wiki](https://openzfs.github.io/openzfs-docs/Getting%20Started/Arch%20Linux/index.html).

## Contributions

Contributions, bug reports, and feature requests are welcome! Please open an issue or submit a pull request on the GitHub repository.

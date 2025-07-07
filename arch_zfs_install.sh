#!/bin/bash

CLEAN_KEYRING=true
SKIP_FULL_KEYRING_REFRESH=true
HOSTNAME="srv-arch-ccc"
KEYMAP="it"
LOCALE_GEN="it_IT.UTF-8 UTF-8"
LOCALE_CONF="LANG=it_IT.UTF-8"
TIMEZONE="Europe/Rome"

command_exists () {
    type "$1" &> /dev/null ;
}

GET_PART_SUFFIX() {
    local disk_name_only="$1"
    local part_num="$2"
    if [[ "$disk_name_only" =~ nvme[0-9]+n[0-9]+$ ]]; then
        echo "p${part_num}"
    elif [[ "$disk_name_only" =~ mmcblk[0-9]+$ ]]; then
        echo "p${part_num}"
    else
        echo "${part_num}"
    fi
}

if ! command_exists pacstrap; then
    echo "This script must be run from an Arch Linux live environment."
    echo "Boot your system with the Arch Linux ISO."
    exit 1
fi

echo "Initializing script for Arch Linux installation on ZFS."
echo "Ensure you have an internet connection."

echo "Initializing and populating Pacman keyring..."
killall gpg-agent 2>/dev/null || true

if [ "$CLEAN_KEYRING" = true ]; then
    echo "Removing existing keyring directory /etc/pacman.d/gnupg..."
    if ! rm -rf /etc/pacman.d/gnupg; then
        echo "Warning: Unable to remove /etc/pacman.d/gnupg."
    fi
    pacman-key --init
    pacman-key --populate archlinux
    echo "Pacman keyring initialized and populated."
else
    echo "Skipping keyring initialization/repopulation."
    pacman-key --init &>/dev/null
fi

if [ "$SKIP_FULL_KEYRING_REFRESH" = false ]; then
    echo "Refreshing Pacman keyring (this might take some time)..."
    pacman-key --refresh-keys
    echo "Pacman keyring updated."
else
    echo "Skipped full Pacman keyring refresh."
fi

echo "Configuring ArchZFS repository."
REPO_CONFIG="
[archzfs]
Server = http://archzfs.com/\$repo/\$arch
Server = http://mirror.sum7.eu/archlinux/archzfs/\$repo/\$arch
Server = http://mirror.sunred.org/archzfs/\$repo/\$arch
Server = https://mirror.biocrafting.net/archlinux/archzfs/\$repo/\$arch
Server = https://mirror.in.themindsmaze.com/archzfs/\$repo/\$arch
Server = https://mirror.emanuelebertolucci.com/\$repo/\$arch
Server = https://zxcvfdsa.com/archzfs/\$repo/\$arch
"
if ! grep -q "\[archzfs\]" /etc/pacman.conf; then
    echo "$REPO_CONFIG" >> /etc/pacman.conf
    echo "ArchZFS repository section added."
else
    echo "ArchZFS repository section already present."
fi

ARCHZFS_KEY="F75D9D76"
echo "Importing ArchZFS PGP key ($ARCHZFS_KEY)..."
if pacman-key --list-keys "$ARCHZFS_KEY" &> /dev/null && pacman-key --list-keys --finger "$ARCHZFS_KEY" | grep -q '\[lsign\]'; then
    echo "ArchZFS PGP key already imported and signed."
else
    for i in {1..3}; do
        if pacman-key --recv-keys "$ARCHZFS_KEY" && pacman-key --lsign-key "$ARCHZFS_KEY"; then
            echo "Attempt $i: ArchZFS PGP key imported and signed successfully."
            break
        else
            echo "Attempt $i failed. Retrying in 2 seconds..."
            sleep 2
        fi
        if [ $i -eq 3 ]; then
            echo "ERROR: Unable to import and sign ArchZFS PGP key." >&2
            exit 1
        fi
    done
fi

echo "Refreshing Pacman keys after ArchZFS import..."
pacman-key --refresh-keys
echo "Updating pacman repositories..."
pacman -Syy --noconfirm
echo "ArchZFS repository added and pacman updated."

echo "Available disks:"
COUNTER=1
declare -A DISK_MAP
mapfile -t DISKS_INFO < <(lsblk -ndo NAME,SIZE,TYPE,MODEL)
for LINE in "${DISKS_INFO[@]}"; do
    if echo "$LINE" | grep -q "disk"; then
        DISK_NAME=$(echo "$LINE" | awk '{print $1}')
        if [ -b "/dev/$DISK_NAME" ] && [[ ! "$DISK_NAME" =~ ^(loop|sr)[0-9]*$ ]]; then
            echo "$COUNTER) $LINE"
            DISK_MAP[$COUNTER]="/dev/$DISK_NAME"
            ((COUNTER++))
        fi
    fi
done

if [ ${#DISK_MAP[@]} -eq 0 ]; then
    echo "No physical hard drives found."
    exit 1
fi

SELECTED_DISKS=()
while true; do
    echo "Enter the numbers of the disks to select (e.g., 1 3):"
    read -r USER_SELECTION_LINE
    read -r -a USER_SELECTION_ARRAY <<< "$USER_SELECTION_LINE"

    if [ ${#USER_SELECTION_ARRAY[@]} -eq 0 ]; then
        echo "No input provided. Please select at least one disk." >&2
        continue
    fi

    INVALID_SELECTION=false
    TEMP_SELECTED_DISKS=()
    for NUM_STR in "${USER_SELECTION_ARRAY[@]}"; do
        if [[ "$NUM_STR" =~ ^[0-9]+$ ]]; then
            if [[ -v DISK_MAP[$NUM_STR] ]]; then
                TEMP_SELECTED_DISKS+=("${DISK_MAP[$NUM_STR]}")
            else
                echo "Warning: '$NUM_STR' is not a valid disk option." >&2
                INVALID_SELECTION=true
                break
            fi
        else
            echo "Warning: '$NUM_STR' is not a valid number." >&2
            INVALID_SELECTION=true
            break
        fi
    done

    if [ "$INVALID_SELECTION" = true ]; then
        TEMP_SELECTED_DISKS=()
        continue
    else
        SELECTED_DISKS=("${TEMP_SELECTED_DISKS[@]}")
        break
    fi
done

echo "You have selected the following disks:"
for DISK in "${SELECTED_DISKS[@]}"; do
    echo "- $DISK"
done

echo "**WARNING**: The following operations are **destructive** and will erase all data."
read -rp "Are you sure you want to proceed? (y/N): " CONFIRMATION
CONFIRMATION=${CONFIRMATION,,}
if [[ "$CONFIRMATION" != "y" ]]; then
    echo "Operation cancelled."
    exit 0
fi

BOOT_CHOICE=""
while true; do
    echo "Choose the boot type:"
    echo "1) BIOS (Legacy)"
    echo "2) UEFI"
    read -rp "Enter your choice (1 or 2): " BOOT_INPUT
    if [[ "$BOOT_INPUT" =~ ^[12]$ ]]; then
        BOOT_CHOICE="$BOOT_INPUT"
        break
    else
        echo "Invalid choice. Enter 1 for BIOS or 2 for UEFI." >&2
    fi
done

ENCRYPT_CHOICE=""
while true; do
    echo "Do you want to encrypt the main pool (rpool)?"
    read -rp "Enter 'y' for yes, 'n' for no (y/N): " ENCRYPT_INPUT
    ENCRYPT_INPUT=${ENCRYPT_INPUT,,}
    if [[ "$ENCRYPT_INPUT" =~ ^[yn]$ ]]; then
        ENCRYPT_CHOICE="$ENCRYPT_INPUT"
        break
    else
        echo "Invalid choice." >&2
    fi
done

RAID_TYPE=""
if [ ${#SELECTED_DISKS[@]} -gt 1 ]; then
    RAID_CHOICE=""
    while true; do
        echo "How do you want to configure the ZFS pool?"
        echo "1) Simple Mirror (raid1)"
        echo "2) RAID10 (striped mirror)"
        echo "3) RAIDZ1"
        echo "4) RAIDZ2"
        echo "5) RAIDZ3"
        read -rp "Enter your choice (1-5): " RAID_INPUT
        if [[ "$RAID_INPUT" =~ ^[1-5]$ ]]; then
            RAID_CHOICE="$RAID_INPUT"
            break
        else
            echo "Invalid choice." >&2
        fi
    done

    case "$RAID_CHOICE" in
        1) RAID_TYPE="mirror" ;;
        2) RAID_TYPE="stripe mirror" ;;
        3) RAID_TYPE="raidz1" ;;
        4) RAID_TYPE="raidz2" ;;
        5) RAID_TYPE="raidz3" ;;
        *) RAID_TYPE="mirror" ;; # Fallback
    esac
fi

echo "Starting disk partitioning."
for disk_path in "${SELECTED_DISKS[@]}"; do
    echo "Processing disk: $disk_path"
    zpool labelclear -f "${disk_path}$(GET_PART_SUFFIX "$(basename "$disk_path")" 1)" 2>/dev/null || true
    zpool labelclear -f "${disk_path}$(GET_PART_SUFFIX "$(basename "$disk_path")" 2)" 2>/dev/null || true
    zpool labelclear -f "${disk_path}$(GET_PART_SUFFIX "$(basename "$disk_path")" 3)" 2>/dev/null || true

    wipefs -a "$disk_path" || true
    blkdiscard -f "$disk_path" || true
    sgdisk --zap-all "$disk_path" || true
    dd if=/dev/zero of="$disk_path" count=100 bs=512 || true
    sgdisk -Z "$disk_path"

    PART_COUNT=1

    if [[ "$BOOT_CHOICE" == "1" ]]; then
        echo "Creating BIOS Boot partition (1MB) on $disk_path..."
        sgdisk -n${PART_COUNT}:0:+1M "$disk_path"
        sgdisk -t${PART_COUNT}:EF02 "$disk_path"
        ((PART_COUNT++))
    elif [[ "$BOOT_CHOICE" == "2" ]]; then
        echo "Creating EFI partition (512MB) on $disk_path..."
        sgdisk -n${PART_COUNT}:0:+512M "$disk_path"
        sgdisk -t${PART_COUNT}:EF00 "$disk_path"
        ((PART_COUNT++))
    fi

    echo "Creating bpool partition (ZFS Boot - 1GB) on $disk_path..."
    sgdisk -n${PART_COUNT}:0:+1G "$disk_path"
    sgdisk -t${PART_COUNT}:BF01 "$disk_path"
    ((PART_COUNT++))

    echo "Creating rpool partition (ZFS Root - rest of disk) on $disk_path..."
    sgdisk -n${PART_COUNT}:0:0 "$disk_path"
    sgdisk -t${PART_COUNT}:BF00 "$disk_path"
    ((PART_COUNT++))

    sgdisk -g "$disk_path"
    echo "Partitioning on $disk_path completed."
    partprobe "$disk_path"
    sleep 2
done

declare -A PART_DEVS
for disk_path in "${SELECTED_DISKS[@]}"; do
    DISK_BASE_NAME=$(basename "$disk_path")

    BIOS_EFI_PART_NUM=1
    BPOOL_PART_NUM=2
    RPOOL_PART_NUM=3

    if [[ "$BOOT_CHOICE" == "1" ]]; then
        PART_DEVS["${disk_path}_boot"]="${disk_path}$(GET_PART_SUFFIX "$DISK_BASE_NAME" $BIOS_EFI_PART_NUM)"
        PART_DEVS["${disk_path}_bpool"]="${disk_path}$(GET_PART_SUFFIX "$DISK_BASE_NAME" $BPOOL_PART_NUM)"
        PART_DEVS["${disk_path}_rpool"]="${disk_path}$(GET_PART_SUFFIX "$DISK_BASE_NAME" $RPOOL_PART_NUM)"
    elif [[ "$BOOT_CHOICE" == "2" ]]; then
        PART_DEVS["${disk_path}_efi"]="${disk_path}$(GET_PART_SUFFIX "$DISK_BASE_NAME" $BIOS_EFI_PART_NUM)"
        PART_DEVS["${disk_path}_bpool"]="${disk_path}$(GET_PART_SUFFIX "$DISK_BASE_NAME" $BPOOL_PART_NUM)"
        PART_DEVS["${disk_path}_rpool"]="${disk_path}$(GET_PART_SUFFIX "$DISK_BASE_NAME" $RPOOL_PART_NUM)"
    fi
done

BPOOL_DEVICES=""
RPOOL_DEVICES=""

if [ ${#SELECTED_DISKS[@]} -eq 1 ]; then
    BPOOL_DEVICES="${PART_DEVS["${SELECTED_DISKS[0]}_bpool"]}"
    RPOOL_DEVICES="${PART_DEVS["${SELECTED_DISKS[0]}_rpool"]}"
elif [ ${#SELECTED_DISKS[@]} -gt 1 ]; then
    case "$RAID_TYPE" in
        mirror)
            BPOOL_DEVICES="mirror"
            RPOOL_DEVICES="mirror"
            for disk_path in "${SELECTED_DISKS[@]}"; do
                BPOOL_DEVICES+=" ${PART_DEVS["${disk_path}_bpool"]}"
                RPOOL_DEVICES+=" ${PART_DEVS["${disk_path}_rpool"]}"
            done
            ;;
        "stripe mirror")
            local_bpool_devices_str=""
            local_rpool_devices_str=""
            for (( i=0; i<${#SELECTED_DISKS[@]}; i+=2 )); do
                DISK1_BPOOL="${PART_DEVS["${SELECTED_DISKS[$i]}_bpool"]}"
                DISK1_RPOOL="${PART_DEVS["${SELECTED_DISKS[$i]}_rpool"]}"

                if [ $(( i+1 )) -lt ${#SELECTED_DISKS[@]} ]; then
                    DISK2_BPOOL="${PART_DEVS["${SELECTED_DISKS[$((i+1))]}_bpool"]}"
                    DISK2_RPOOL="${PART_DEVS["${SELECTED_DISKS[$((i+1))]}_rpool"]}"
                    local_bpool_devices_str+=" mirror ${DISK1_BPOOL} ${DISK2_BPOOL}"
                    local_rpool_devices_str+=" mirror ${DISK1_RPOOL} ${DISK2_RPOOL}"
                else
                    echo "Warning: Disk ${SELECTED_DISKS[$i]} is a single disk in RAID10 configuration." >&2
                    local_bpool_devices_str+=" ${DISK1_BPOOL}"
                    local_rpool_devices_str+=" ${DISK1_RPOOL}"
                fi
            done
            BPOOL_DEVICES="$local_bpool_devices_str"
            RPOOL_DEVICES="$local_rpool_devices_str"
            ;;
        raidz1|raidz2|raidz3)
            BPOOL_DEVICES="$RAID_TYPE"
            RPOOL_DEVICES="$RAID_TYPE"
            for disk_path in "${SELECTED_DISKS[@]}"; do
                BPOOL_DEVICES+=" ${PART_DEVS["${disk_path}_bpool"]}"
                RPOOL_DEVICES+=" ${PART_DEVS["${disk_path}_rpool"]}"
            done
            ;;
    esac
fi

echo "Starting ZFS Pool creation."
echo "Exporting existing ZFS pools to avoid conflicts..."
zpool export -a 2>/dev/null || true

echo "Creating bpool..."
zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -o compatibility=grub2 \
    -O devices=off \
    -O acltype=posixacl -O xattr=sa \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -R /mnt \
    bpool ${BPOOL_DEVICES}

if [[ "$ENCRYPT_CHOICE" == "y" ]]; then
    echo "Creating rpool (encrypted)..."
    zpool create -f \
        -o ashift=12 \
        -o autotrim=on \
        -O encryption=on -O keylocation=prompt -O keyformat=passphrase \
        -O acltype=posixacl -O xattr=sa \
        -O dnodesize=auto \
        -O compression=lz4 \
        -O normalization=formD \
        -O relatime=on \
        -R /mnt \
        rpool ${RPOOL_DEVICES}
else
    echo "Creating rpool (unencrypted)..."
    zpool create -f \
        -o ashift=12 \
        -o autotrim=on \
        -O acltype=posixacl -O xattr=sa \
        -O dnodesize=auto \
        -O compression=lz4 \
        -O normalization=formD \
        -O relatime=on \
        -R /mnt \
        rpool ${RPOOL_DEVICES}
fi

echo "ZFS pools created."

echo "Creating ZFS filesystems for root (rpool/ROOT) and boot (bpool/BOOT)..."
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=off -o mountpoint=none bpool/BOOT

echo "Creating and mounting root filesystem (rpool/ROOT/arch)..."
zfs create -o canmount=noauto -o mountpoint=/ rpool/ROOT/arch
zfs mount rpool/ROOT/arch

echo "Creating and mounting boot filesystem (bpool/BOOT/arch)..."
zfs create -o mountpoint=/boot bpool/BOOT/arch

if [[ "$ENCRYPT_CHOICE" == "y" ]]; then
    echo "Enabling native ZFS encryption for user home directories (rpool/home)..."
    zfs create -o encryption=on -o keylocation=prompt -o keyformat=passphrase -o canmount=off -o mountpoint=/home rpool/home
    zfs mount rpool/home
fi

echo "Preparing chroot environment in /mnt."
mkdir -p /mnt/run

echo "Setting ZFS hostid and configuring cachefile for pools..."
zgenhostid -f -o /etc/hostid
zpool set cachefile=/etc/zfs/zpool.cache bpool
zpool set cachefile=/etc/zfs/zpool.cache rpool
echo "ZFS hostid set and cachefile configured."

echo "Copying updated zpool.cache file to /mnt/etc/zfs..."
mkdir -p /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/
echo "zpool.cache copied to /mnt/etc/zfs."

if ! mountpoint -q /mnt; then
    echo "ERROR: /mnt is not a mount point yet after ZFS operations. Cannot proceed with pacstrap." >&2
    exit 1
fi
if [ ! -w /mnt ]; then
    echo "ERROR: /mnt is not writable. Cannot proceed with pacstrap." >&2
    exit 1
fi
echo "/mnt is confirmed as a writable mount point."

echo "Installing base Arch Linux with pacstrap..."
pacstrap /mnt base linux linux-headers zfs-utils zfs-dkms grub efibootmgr vim zsh screen tmux openssh zsh-syntax-highlighting dhcpcd linux-firmware cryptsetup dosfstools

if [ $? -ne 0 ]; then
    echo "ERROR: Package installation failed." >&2
    exit 1
fi

echo "Generating fstab (only for /boot/efi if UEFI)..."
genfstab -U /mnt >> /mnt/fstab
if [ $? -ne 0 ]; then
    echo "Warning: fstab generation encountered issues." >&2
fi

echo "Copying pacman to chroot..."
cp -v /etc/pacman.conf /mnt/etc/pacman.conf

echo "Base operating system installation phase complete."
echo "Starting system configuration phase."

echo "Configuring hostname in /mnt/etc/hostname..."
echo "$HOSTNAME" > /mnt/etc/hostname

echo "Configuring /mnt/etc/locale.gen and locale.conf..."
echo "$LOCALE_GEN" >> /mnt/locale.gen
echo "$LOCALE_CONF" > /mnt/etc/locale.conf

echo "Configuring /mnt/etc/vconsole.conf for keyboard layout..."
echo "KEYMAP=$KEYMAP" > /mnt/etc/vconsole.conf

echo "Mounting virtual directories for chroot environment..."
mount --make-private --rbind /dev  /mnt/dev
mount --make-private --rbind /proc /mnt/proc
mount --make-private --rbind /sys  /mnt/sys

CHROOT_SCRIPT="/tmp/chroot_install_script.sh"
cat << 'CHROOT_EOF' > "/mnt${CHROOT_SCRIPT}"
#!/bin/bash
HOSTNAME="$1"
KEYMAP="$2"
LOCALE_GEN="$3"
LOCALE_CONF="$4"
TIMEZONE="$5"
BOOT_CHOICE="$6"
ENCRYPT_CHOICE="$7"
SELECTED_DISKS_STR="$8"
IFS=' ' read -r -a SELECTED_DISKS_ARRAY <<< "$SELECTED_DISKS_STR"

GET_PART_SUFFIX() {
    local disk_name_only="$1"
    local part_num="$2"
    if [[ "$disk_name_only" =~ nvme[0-9]+n[0-9]+$ ]]; then
        echo "p${part_num}"
    elif [[ "$disk_name_only" =~ mmcblk[0-9]+$ ]]; then
        echo "p${part_num}"
    else
        echo "${part_num}"
    fi
}

echo "Updating system time..."
hwclock --systohc

echo "Running locale-gen..."
locale-gen

echo "Setting timezone to $TIMEZONE..."
ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime

echo "Setting root password. You will be asked for the password twice."
passwd

echo "Configuring ZFS hostid and cachefile within chroot..."
zgenhostid -f -o /etc/hostid
zpool set cachefile=/etc/zfs/zpool.cache bpool
zpool set cachefile=/etc/zfs/zpool.cache rpool
echo "ZFS hostid and cachefile configured."

echo "Configuring ZFS_AUTOIMPORT_DEVS in /etc/default/zfs..."
echo 'ZFS_AUTOIMPORT_DEVS="/dev/disk/by-id/"' > /etc/default/zfs
echo "ZFS_AUTOIMPORT_DEVS configured."

echo "Enabling ZFS services..."
systemctl enable zfs.target
systemctl enable zfs-import-cache.service
systemctl enable zfs-mount.service
systemctl enable zfs-zed.service
systemctl enable zfs-share.service

echo "Configuring mkinitcpio for ZFS..."

HOOKS_LINE=$(grep '^HOOKS=' /etc/mkinitcpio.conf)

if [ -z "$HOOKS_LINE" ]; then
    echo "ERROR: Could not find HOOKS line in /etc/mkinitcpio.conf." >&2
    exit 1
fi

RAW_HOOKS_STRING=$(echo "$HOOKS_LINE" | sed -E 's/HOOKS="?\(?(.*)\)?"?/\1/' | xargs)
IFS=' ' read -r -a HOOKS_ARRAY <<< "$RAW_HOOKS_STRING"

NEW_HOOKS_ARRAY=()
ZFS_INSERTED=false
FOUND_BLOCK=false
FOUND_FILESYSTEMS=false

for hook in "${HOOKS_ARRAY[@]}"; do
    cleaned_hook=$(echo "$hook" | sed 's/)$//')

    if [ "$cleaned_hook" == "block" ]; then
        NEW_HOOKS_ARRAY+=("$cleaned_hook")
        FOUND_BLOCK=true
    elif [ "$cleaned_hook" == "zfs" ]; then
        continue
    elif [ "$cleaned_hook" == "filesystems" ]; then
        if [ "$FOUND_BLOCK" = true ] && [ "$ZFS_INSERTED" = false ]; then
            NEW_HOOKS_ARRAY+=("zfs")
            ZFS_INSERTED=true
        fi
        NEW_HOOKS_ARRAY+=("$cleaned_hook")
        FOUND_FILESYSTEMS=true
    else
        NEW_HOOKS_ARRAY+=("$cleaned_hook")
    fi
done

if [ "$ZFS_INSERTED" = false ]; then
    INSERT_INDEX=-1
    for i in "${!NEW_HOOKS_ARRAY[@]}"; do
        if [ "${NEW_HOOKS_ARRAY[$i]}" == "block" ]; then
            INSERT_INDEX=$((i+1))
            break
        elif [ "${NEW_HOOKS_ARRAY[$i]}" == "filesystems" ]; then
            INSERT_INDEX=$i
            break
        fi
    done

    if [ "$INSERT_INDEX" -ne -1 ]; then
        NEW_HOOKS_ARRAY=("${NEW_HOOKS_ARRAY[@]:0:$INSERT_INDEX}" "zfs" "${NEW_HOOKS_ARRAY[@]:$INSERT_INDEX}")
    else
        NEW_HOOKS_ARRAY+=("zfs")
        echo "Warning: 'block' or 'filesystems' not found, 'zfs' added to the end." >&2
    fi
fi

FINAL_CLEANED_HOOKS_ARRAY=()
for hook in "${NEW_HOOKS_ARRAY[@]}"; do
    if [ "$hook" != "fsck" ]; then
        FINAL_CLEANED_HOOKS_ARRAY+=("$hook")
    fi
done

FINAL_HOOKS_STRING=$(printf "%s " "${FINAL_CLEANED_HOOKS_ARRAY[@]}")
FINAL_HOOKS_STRING="${FINAL_HOOKS_STRING% }"

sed -i "s|^HOOKS=.*|HOOKS=\"${FINAL_HOOKS_STRING}\"|" /etc/mkinitcpio.conf

if ! grep -q 'HOOKS=".*\bzfs\b.*"' /etc/mkinitcpio.conf || grep -q 'HOOKS=".*\bfsck\b.*"' /etc/mkinitcpio.conf; then
    echo "CRITICAL ERROR: 'zfs' hook not present, or 'fsck' hook still present." >&2
    exit 1
fi
echo "mkinitcpio.conf updated. Generating initramfs..."
mkinitcpio -P

echo "Configuring GRUB..."
mkdir -p /boot/grub

BPOOL_ID=$(zpool get -H -o value guid bpool)
if [ -z "$BPOOL_ID" ]; then
    echo "ERROR: Unable to get bpool GUID." >&2
    exit 1
fi
echo "bpool GUID for GRUB: $BPOOL_ID"

GRUB_CMDLINE_COMMON="zfs.zfs_arc_max=8589934592 zfs_force=1"
GRUB_CMDLINE_ROOT="root=ZFS=rpool/ROOT/arch rw"

GRUB_CRYPTDEVICE_PARAM=""
if [[ "$ENCRYPT_CHOICE" == "y" ]]; then
    GRUB_CRYPTDEVICE_PARAM="zfs.zfs_key=rpool/ROOT/arch:prompt"
fi

GRUB_KERNEL_OPTS="${GRUB_CMDLINE_COMMON} ${GRUB_CRYPTDEVICE_PARAM} ${GRUB_CMDLINE_ROOT}"

sed -i "s#^GRUB_CMDLINE_LINUX_DEFAULT=.*#GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_KERNEL_OPTS}\"#" /etc/default/grub
echo "GRUB_CMDLINE_LINUX_DEFAULT set."

sed -i 's/^GRUB_DISABLE_RECOVERY="true"/GRUB_DISABLE_RECOVERY="false"/' /etc/default/grub
if ! grep -q '^GRUB_TIMEOUT=' /etc/default/grub; then
    echo "GRUB_TIMEOUT=5" >> /etc/default/grub
else
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
fi
echo "GRUB timeout and recovery enabled."

echo "Updating GRUB..."
grub-mkconfig -o /boot/grub/grub.cfg

echo "Installing GRUB bootloader..."
if [[ "$BOOT_CHOICE" == "1" ]]; then
    for DISK_PATH_IN_CHROOT in "${SELECTED_DISKS_ARRAY[@]}"; do
        BIOS_BOOT_PART="${DISK_PATH_IN_CHROOT}$(GET_PART_SUFFIX "$(basename "$DISK_PATH_IN_CHROOT")" 1)"
        echo "Verifying existence of BIOS Boot partition ${BIOS_BOOT_PART} before grub-install..."
        if [ ! -b "$BIOS_BOOT_PART" ]; then
            echo "ERROR: BIOS Boot partition ${BIOS_BOOT_PART} does not exist or is not detectable by the kernel." >&2
            echo "Check dmesg or fdisk -l within chroot for more details." >&2
            exit 1
        fi

        echo "Running grub-install for BIOS on ${DISK_PATH_IN_CHROOT}..."
        grub-install --target=i386-pc "$DISK_PATH_IN_CHROOT"
        if [ $? -ne 0 ]; then
            echo "ERROR: grub-install for BIOS on ${DISK_PATH_IN_CHROOT} failed." >&2
            exit 1
        fi
        echo "GRUB-BIOS installation completed for ${DISK_PATH_IN_CHROOT}."
    done
elif [[ "$BOOT_CHOICE" == "2" ]]; then
    echo "Creating /boot/efi directory..."
    mkdir -p /boot/efi

    for DISK_PATH_IN_CHROOT in "${SELECTED_DISKS_ARRAY[@]}"; do
        EFI_PART_DEV_FULL="${DISK_PATH_IN_CHROOT}$(GET_PART_SUFFIX "$(basename "$DISK_PATH_IN_CHROOT")" 1)"

        if [ -b "${EFI_PART_DEV_FULL}" ]; then
            echo "Processing EFI partition: ${EFI_PART_DEV_FULL}"

            if mountpoint -q /boot/efi; then
                umount /boot/efi
            fi

            mkfs.vfat -F 32 -s 1 "${EFI_PART_DEV_FULL}"
            if [ $? -ne 0 ]; then
                echo "ERROR: mkfs.vfat on ${EFI_PART_DEV_FULL} failed." >&2
                exit 1
            fi

            mount "${EFI_PART_DEV_FULL}" /boot/efi
            if [ $? -ne 0 ]; then
                echo "ERROR: mount of ${EFI_PART_DEV_FULL} to /boot/efi failed." >&2
                echo "Verify that the filesystem was created correctly and there are no ZFS remnants." >&2
                exit 1
            fi
            echo "EFI partition ${EFI_PART_DEV_FULL} mounted to /boot/efi."

            if ! grep -q "${EFI_PART_DEV_FULL}" /etc/fstab; then
                EFI_UUID=$(blkid -s UUID -o value "${EFI_PART_DEV_FULL}")
                echo "UUID=${EFI_UUID} /boot/efi vfat defaults 0 0" >> /etc/fstab
            fi

            echo "Running grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch_GRUB --recheck on ${DISK_PATH_IN_CHROOT}..."
            grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch_GRUB --recheck "$DISK_PATH_IN_CHROOT"
            if [ $? -ne 0 ]; then
                echo "ERROR: grub-install for UEFI on ${DISK_PATH_IN_CHROOT} failed." >&2
                exit 1
            fi
            echo "GRUB-EFI installation completed for ${DISK_PATH_IN_CHROOT}."
        else
            echo "Warning: EFI partition ${EFI_PART_DEV_FULL} not found for disk ${DISK_PATH_IN_CHROOT}."
        fi
    done

    if mountpoint -q /boot/efi; then
        umount /boot/efi
    fi

else
    echo "Warning: Invalid boot choice. GRUB packages will not be configured."
fi

echo "Enabling SSH login for root..."
chmod 644 /etc/ssh/sshd_config || true
sed -i 's/^#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl enable sshd

echo "Setting zsh as default shell for root..."
chsh -s /bin/zsh root

echo "Removing temporary chroot script..."
rm -f "/tmp/chroot_install_script.sh" || echo "Warning: Unable to remove /tmp/chroot_install_script.sh."
CHROOT_EOF

chmod +x "/mnt${CHROOT_SCRIPT}"

echo "Entering chroot environment for final configuration..."
chroot /mnt /bin/bash -c "
    /tmp/chroot_install_script.sh \"$HOSTNAME\" \"$KEYMAP\" \"$LOCALE_GEN\" \"$LOCALE_CONF\" \"$TIMEZONE\" \"$BOOT_CHOICE\" \"$ENCRYPT_CHOICE\" \"${SELECTED_DISKS[*]}\"
"

if [ $? -ne 0 ]; then
    echo "ERROR: Chroot script failed. Review the output." >&2
    exit 1
fi

echo "Exiting chroot environment."

echo "Starting cleanup and finalization phase..."

echo "Unmounting ZFS filesystems..."
if mountpoint -q /mnt/home; then
    zfs umount /mnt/home || true
fi
if mountpoint -q /mnt/boot; then
    zfs umount /mnt/boot || true
fi
if mountpoint -q /mnt; then
    zfs umount /mnt || true
fi
zfs umount -a || true

sleep 2

echo "Unmounting virtual filesystems from /mnt..."
mount | grep -E "/mnt(/|$)" | awk '{print $3}' | sort -r | xargs -r umount -lf || true
sleep 2

echo "Exporting ZFS pools for a clean shutdown/reboot..."
if zpool list -H bpool &>/dev/null; then
    zpool export bpool || echo "Warning: Unable to export bpool. It might still be in use." >&2
fi
if zpool list -H rpool &>/dev/null; then
    zpool export rpool || echo "Warning: Unable to export rpool. It might still be in use." >&2
fi

echo "Installation and configuration complete. You can now reboot the system."

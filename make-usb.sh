#!/usr/bin/env bash
# Universal USB Flasher:
# Partition 1: FAT32 (Label: KIOSKBOOT) with standard /EFI/BOOT/BOOTX64.EFI + MBR (i386-pc)
# Partition 2: FAT32 (Label: KIOSKDATA) for drag-and-drop web files & user signage
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

LIVE_DIR="${SCRIPT_DIR}/${OUTPUT_DIR:-output}/live"
ISO_PATH="${SCRIPT_DIR}/${OUTPUT_DIR:-output}/${ISO_NAME:-web-kiosk-live.iso}"
CONTENT_LABEL="${CONTENT_PART_LABEL:-KIOSKDATA}"

AUTO_CONFIRM=0
TARGET_ARG=""

for arg in "$@"; do
    if [ "$arg" == "-y" ] || [ "$arg" == "--yes" ]; then
        AUTO_CONFIRM=1
    else
        TARGET_ARG="$arg"
    fi
done

if [ -z "$TARGET_ARG" ]; then
    echo "Usage: sudo $0 [-y] /dev/sdX"
    echo "Example: sudo $0 -y /dev/sdd"
    exit 1
fi

TARGET_DEV="$TARGET_ARG"

# Auto-resolve partition (e.g. /dev/sdd1) to parent disk (e.g. /dev/sdd)
if [ -b "$TARGET_DEV" ]; then
    DEV_TYPE="$(lsblk -no TYPE "$TARGET_DEV" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
    if [ "$DEV_TYPE" == "part" ]; then
        PK_NAME="$(lsblk -no pkname "$TARGET_DEV" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
        if [ -n "$PK_NAME" ]; then
            echo "Note: Partition $TARGET_DEV specified. Resolving to parent disk: /dev/$PK_NAME"
            TARGET_DEV="/dev/$PK_NAME"
        fi
    fi
fi

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must be run as root (sudo $0)." >&2
    exit 1
fi

if [ ! -b "$TARGET_DEV" ]; then
    echo "ERROR: Device $TARGET_DEV does not exist." >&2
    exit 1
fi

if [[ "$TARGET_DEV" == *"/dev/sda"* ]] || [[ "$TARGET_DEV" == *"/dev/nvme0n1"* ]]; then
    echo "SAFETY ABORT: Refusing to write to primary drive $TARGET_DEV!" >&2
    exit 1
fi

# Ensure live files are extracted and available
if [ ! -f "${LIVE_DIR}/filesystem.squashfs" ]; then
    if [ -f "$ISO_PATH" ]; then
        echo "=== Extracting Live Kernel & SquashFS from ISO ==="
        mkdir -p "$LIVE_DIR"
        xorriso -osirrox on -indev "$ISO_PATH" -extract /live "$LIVE_DIR"
    else
        echo "ERROR: Neither $LIVE_DIR nor $ISO_PATH found. Run sudo ./build.sh first." >&2
        exit 1
    fi
fi

echo "=========================================================="
echo "UNIVERSAL DUAL-BOOT USB BUILDER (UEFI + LEGACY BIOS)"
echo "Target Drive: $TARGET_DEV"
echo "WARNING: ALL DATA ON $TARGET_DEV WILL BE PERMANENTLY ERASED!"
echo "=========================================================="

if [ "$AUTO_CONFIRM" -ne 1 ]; then
    read -p "Type 'YES' to proceed: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "Aborted."
        exit 0
    fi
fi

echo "=== 1. Deep Wiping Drive Signatures & Backup GPT Headers ==="
umount "${TARGET_DEV}"* 2>/dev/null || true
sgdisk --zap-all "$TARGET_DEV" 2>/dev/null || true
wipefs -a "$TARGET_DEV" 2>/dev/null || true
TOTAL_SECTORS=$(blockdev --getsz "$TARGET_DEV" 2>/dev/null || echo 0)
dd if=/dev/zero of="$TARGET_DEV" bs=1M count=10 status=none || true
if [ "$TOTAL_SECTORS" -gt 20480 ]; then
    dd if=/dev/zero of="$TARGET_DEV" bs=512 seek=$((TOTAL_SECTORS - 20480)) count=20480 status=none || true
fi

echo "=== 2. Partitioning Universal GPT Layout (Dual UEFI + BIOS) ==="
# Partition 1: 2MB BIOS Boot Partition (for Legacy BIOS MBR via GRUB i386-pc)
# Partition 2: 3000MB FAT32 EFI System Partition (Label: KIOSKBOOT, flag: esp)
# Partition 3: Remaining disk space FAT32 (Label: KIOSKDATA for user signage)
parted --script "$TARGET_DEV" -- \
    mklabel gpt \
    mkpart "BIOS_BOOT" 1MiB 3MiB \
    set 1 bios_grub on \
    mkpart "KIOSKBOOT" fat32 3MiB 3000MiB \
    set 2 esp on \
    mkpart "$CONTENT_LABEL" fat32 3000MiB 100%

partprobe "$TARGET_DEV" || sleep 2
udevadm settle 2>/dev/null || sleep 2

# Identify partition device nodes
if [[ "$TARGET_DEV" =~ [0-9]$ ]]; then
    BOOT_PART="${TARGET_DEV}p2"
    DATA_PART="${TARGET_DEV}p3"
else
    BOOT_PART="${TARGET_DEV}2"
    DATA_PART="${TARGET_DEV}3"
fi

echo "=== 3. Formatting Partitions as Native FAT32 ==="
echo "Formatting Boot/OS Partition: $BOOT_PART (Label: KIOSKBOOT)"
mkfs.vfat -F 32 -n "KIOSKBOOT" "$BOOT_PART"

echo "Formatting Data Partition: $DATA_PART (Label: $CONTENT_LABEL)"
mkfs.vfat -F 32 -n "$CONTENT_LABEL" "$DATA_PART"

echo "=== 4. Installing Universal Bootloaders to $TARGET_DEV ==="
MNT_BOOT=$(mktemp -d)
mount "$BOOT_PART" "$MNT_BOOT"

mkdir -p "$MNT_BOOT/live"
mkdir -p "$MNT_BOOT/boot/grub"
mkdir -p "$MNT_BOOT/EFI/BOOT"

# Install Legacy BIOS MBR bootloader (embeds into Partition 1 bios_grub)
echo "Installing Legacy BIOS MBR bootloader..."
grub-install \
    --target=i386-pc \
    --boot-directory="$MNT_BOOT/boot" \
    "$TARGET_DEV"

# Install UEFI 64-bit bootloader (/EFI/BOOT/BOOTX64.EFI)
echo "Installing UEFI 64-bit bootloader..."
grub-install \
    --target=x86_64-efi \
    --efi-directory="$MNT_BOOT" \
    --boot-directory="$MNT_BOOT/boot" \
    --bootloader-id=BOOT \
    --removable \
    --no-nvram

echo "Writing Universal GRUB Configuration..."
cat << 'EOF' > "$MNT_BOOT/boot/grub/grub.cfg"
set default="0"
set timeout=3

# Locate boot partition by filesystem label
search --no-floppy --set=root --label KIOSKBOOT

menuentry "Autonomous Web Kiosk (Live RAM)" {
    linux /live/vmlinuz boot=live quiet splash components console=tty1
    initrd /live/initrd.img
}

menuentry "Autonomous Web Kiosk (Nomodeset / Fallback Video)" {
    linux /live/vmlinuz boot=live quiet splash components console=tty1 nomodeset
    initrd /live/initrd.img
}

menuentry "Autonomous Web Kiosk (Failsafe Mode)" {
    linux /live/vmlinuz boot=live components memtest noapic noapm nodma nomce nolapic nomodeset nosmp nosplash vga=normal
    initrd /live/initrd.img
}
EOF

echo "Copying Kernel, Initramfs, and SquashFS to KIOSKBOOT..."
cp -r "${LIVE_DIR}/." "$MNT_BOOT/live/"
sync
umount "$MNT_BOOT"
rm -rf "$MNT_BOOT"

echo "=== 5. Populating Signage Content on $DATA_PART ==="
partprobe "$TARGET_DEV" 2>/dev/null || sleep 2
udevadm settle 2>/dev/null || sleep 2

if [[ "$TARGET_DEV" =~ [0-9]$ ]]; then
    DATA_PART="${TARGET_DEV}p3"
else
    DATA_PART="${TARGET_DEV}3"
fi

# Wait up to 5s for device node if needed
for i in {1..5}; do
    [ -b "$DATA_PART" ] && break
    sleep 1
done

MNT_DATA=$(mktemp -d)
mount "$DATA_PART" "$MNT_DATA"
cp -r --no-preserve=ownership,mode "${SCRIPT_DIR}/content/." "$MNT_DATA/"

cat << 'EOF' > "$MNT_DATA/kiosk.conf"
# Kiosk Configuration
# Override target URL below if you want remote signage:
# TARGET_URL="https://example.com/signage"
EOF

sync
umount "$MNT_DATA"
rm -rf "$MNT_DATA"

echo "=========================================================="
echo "SUCCESS: Universal USB Kiosk Drive is Ready!"
echo "Boot Modes Supported:"
echo "  ✓ UEFI 64-bit Native (/EFI/BOOT/BOOTX64.EFI on FAT32 ESP)"
echo "  ✓ Legacy BIOS / CSM (MBR Stage 1 & Stage 2)"
echo "=========================================================="

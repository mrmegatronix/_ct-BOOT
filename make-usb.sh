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

echo "=== 2. Partitioning Universal MBR Layout (Dual UEFI + Legacy BIOS) ==="
# Partition 1: 3000MB FAT32 with active boot flag (for UEFI ESP BOOTX64/BOOTIA32 & Legacy BIOS boot)
# Partition 2: Remaining disk space FAT32 (Label: KIOSKDATA for user signage)
parted --script "$TARGET_DEV" -- \
    mklabel msdos \
    mkpart primary fat32 1MiB 3000MiB \
    set 1 boot on \
    mkpart primary fat32 3000MiB 100%

partprobe "$TARGET_DEV" || sleep 2
udevadm settle 2>/dev/null || sleep 2

# Identify partition device nodes
if [[ "$TARGET_DEV" =~ [0-9]$ ]]; then
    BOOT_PART="${TARGET_DEV}p1"
    DATA_PART="${TARGET_DEV}p2"
else
    BOOT_PART="${TARGET_DEV}1"
    DATA_PART="${TARGET_DEV}2"
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

# Generate Self-Contained Standalone UEFI Bootloaders with embedded search logic
echo "Generating Self-Contained Standalone UEFI bootloaders (BOOTX64.EFI & BOOTIA32.EFI)..."
TMP_CFG=$(mktemp)
cat << 'EOF' > "$TMP_CFG"
search --no-floppy --set=root --label KIOSKBOOT
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
EOF

grub-mkstandalone \
    -O x86_64-efi \
    -o "$MNT_BOOT/EFI/BOOT/BOOTX64.EFI" \
    "boot/grub/grub.cfg=$TMP_CFG"

if [ -d "/usr/lib/grub/i386-efi" ]; then
    grub-mkstandalone \
        -O i386-efi \
        -o "$MNT_BOOT/EFI/BOOT/BOOTIA32.EFI" \
        "boot/grub/grub.cfg=$TMP_CFG"
fi
cp "$TMP_CFG" "$MNT_BOOT/EFI/BOOT/grub.cfg"
rm -f "$TMP_CFG"

echo "Writing Universal GRUB Configuration..."
cat << 'EOF' > "$MNT_BOOT/boot/grub/grub.cfg"
set default="0"
set timeout=30

insmod efi_gop
insmod efi_uga
insmod all_video
insmod gfxterm

set gfxmode=1920x1080,1920x1080x32,1920x1080x24,1600x900,1280x720,1024x768,800x600,auto
set gfxpayload=keep

# Locate boot partition by filesystem label
search --no-floppy --set=root --label KIOSKBOOT

menuentry "Autonomous Web Kiosk (Live RAM - Native KMS 1080p)" {
    linux /live/vmlinuz boot=live quiet splash components console=tty1 video=1920x1080@60
    initrd /live/initrd.img
}

menuentry "Autonomous Web Kiosk (800x600 Resolution Mode)" {
    linux /live/vmlinuz boot=live quiet splash components console=tty1 video=800x600@60 kiosk_res=800x600
    initrd /live/initrd.img
}

menuentry "Autonomous Web Kiosk (Safe Graphics / Nomodeset)" {
    linux /live/vmlinuz boot=live quiet splash components console=tty1 nomodeset
    initrd /live/initrd.img
}

menuentry "Autonomous Web Kiosk (Failsafe Mode)" {
    linux /live/vmlinuz boot=live components memtest noapic noapm nodma nomce nolapic nomodeset nosmp nosplash vga=normal
    initrd /live/initrd.img
}

menuentry "Reboot System" {
    reboot
}

menuentry "Shutdown System" {
    halt
}

menuentry "UEFI Firmware Settings (BIOS)" {
    fwsetup
}
EOF

echo "Writing Raspberry Pi Bootloader Configuration..."
cat << 'EOF' > "$MNT_BOOT/config.txt"
# Raspberry Pi Universal HDMI & Firmware Configuration
[all]
hdmi_force_hotplug=1
hdmi_group=1
hdmi_mode=16
disable_overscan=1
framebuffer_width=1920
framebuffer_height=1080
dtoverlay=vc4-kms-v3d
max_framebuffers=2
arm_64bit=1
enable_uart=1

[pi4]
arm_boost=1

[pi5]
display_auto_detect=1
EOF

cat << 'EOF' > "$MNT_BOOT/cmdline.txt"
console=serial0,115200 console=tty1 root=/dev/ram0 boot=live quiet splash
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
    DATA_PART="${TARGET_DEV}p2"
else
    DATA_PART="${TARGET_DEV}2"
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

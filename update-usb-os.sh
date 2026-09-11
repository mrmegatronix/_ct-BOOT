#!/usr/bin/env bash
# Auto-Update Script for USB Web Kiosk OS
# Preserves user content, custom signage, and configurations
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

LIVE_DIR="${SCRIPT_DIR}/${OUTPUT_DIR:-output}/live"
ISO_PATH="${SCRIPT_DIR}/${OUTPUT_DIR:-output}/${ISO_NAME:-web-kiosk-live.iso}"
CONTENT_LABEL="${CONTENT_PART_LABEL:-KIOSKDATA}"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must be run as root (sudo $0)." >&2
    exit 1
fi

TARGET_ARG="${1:-}"

# Auto-detect USB drive if not explicitly supplied
if [ -z "$TARGET_ARG" ]; then
    echo "=== Scanning for Kiosk USB Drive ==="
    DATA_PART="$(lsblk -nlo PATH,LABEL | grep -E "[[:space:]]${CONTENT_LABEL}$" | awk '{print $1}' | head -n 1 || true)"
    if [ -z "$DATA_PART" ]; then
        DATA_PART="$(lsblk -nlo PATH,LABEL | grep -E "[[:space:]]${VOLUME_ID:-WEB_KIOSK}$" | awk '{print $1}' | head -n 1 || true)"
    fi
    if [ -z "$DATA_PART" ]; then
        DATA_PART="$(lsblk -nlo PATH,LABEL | grep -E "[[:space:]]KIOSKBOOT$" | awk '{print $1}' | head -n 1 || true)"
    fi

    if [ -n "$DATA_PART" ]; then
        PK="$(lsblk -no pkname "$DATA_PART" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
        if [ -n "$PK" ]; then
            TARGET_ARG="/dev/$PK"
            echo "Auto-detected Kiosk drive: $TARGET_ARG ($DATA_PART)"
        fi
    fi
fi

if [ -z "$TARGET_ARG" ]; then
    echo "Usage: sudo $0 [/dev/sdX]"
    echo "Could not auto-detect USB drive. Please specify device path (e.g. /dev/sdd)." >&2
    exit 1
fi

TARGET_DEV="$TARGET_ARG"
if [ -b "$TARGET_DEV" ]; then
    DEV_TYPE="$(lsblk -no TYPE "$TARGET_DEV" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
    if [ "$DEV_TYPE" == "part" ]; then
        PK="$(lsblk -no pkname "$TARGET_DEV" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
        if [ -n "$PK" ]; then
            TARGET_DEV="/dev/$PK"
        fi
    fi
fi

if [ ! -b "$TARGET_DEV" ]; then
    echo "ERROR: Target device $TARGET_DEV not found." >&2
    exit 1
fi

if [[ "$TARGET_DEV" == *"/dev/sda"* ]] || [[ "$TARGET_DEV" == *"/dev/nvme0n1"* ]]; then
    echo "SAFETY ABORT: Refusing to update primary disk $TARGET_DEV!" >&2
    exit 1
fi

# Ensure live files are extracted
if [ ! -f "${LIVE_DIR}/filesystem.squashfs" ]; then
    if [ -f "$ISO_PATH" ]; then
        echo "=== Extracting Live Kernel & SquashFS from ISO ==="
        mkdir -p "$LIVE_DIR"
        xorriso -osirrox on -indev "$ISO_PATH" -extract /live "$LIVE_DIR"
    else
        echo "ERROR: Live build not found. Run sudo ./build.sh first." >&2
        exit 1
    fi
fi

echo "=== Target Device: $TARGET_DEV ==="

# Check if drive has native KIOSKBOOT partition
BOOT_PART="$(lsblk -nlo PATH,LABEL "$TARGET_DEV" | grep -E "[[:space:]]KIOSKBOOT$" | awk '{print $1}' | head -n 1 || true)"

if [ -n "$BOOT_PART" ] && [ -b "$BOOT_PART" ]; then
    echo "=== Updating OS on Native KIOSKBOOT Partition ($BOOT_PART) ==="
    MNT_BOOT=$(mktemp -d)
    mount "$BOOT_PART" "$MNT_BOOT"
    mkdir -p "$MNT_BOOT/live"
    cp -r "${LIVE_DIR}/." "$MNT_BOOT/live/"
    mkdir -p "$MNT_BOOT/boot/grub"
    cat << 'EOF' > "$MNT_BOOT/boot/grub/grub.cfg"
set default="0"
set timeout=3

insmod efi_gop
insmod efi_uga
insmod all_video
insmod gfxterm

set gfxmode=1920x1080,1920x1080x32,1600x900,1366x768,1280x720,auto
set gfxpayload=keep

# Locate boot partition by filesystem label
search --no-floppy --set=root --label KIOSKBOOT

menuentry "Autonomous Web Kiosk (Live RAM - 1080p)" {
    linux /live/vmlinuz boot=live quiet splash components console=tty1 video=1920x1080
    initrd /live/initrd.img
}

menuentry "Autonomous Web Kiosk (Nomodeset / Fallback Video - 1080p)" {
    linux /live/vmlinuz boot=live quiet splash components console=tty1 nomodeset video=1920x1080-32@60 video=efifb:1920x1080
    initrd /live/initrd.img
}

menuentry "Autonomous Web Kiosk (Failsafe Mode)" {
    linux /live/vmlinuz boot=live components memtest noapic noapm nodma nomce nolapic nomodeset nosmp nosplash vga=normal
    initrd /live/initrd.img
}
EOF
    sync
    umount "$MNT_BOOT"
    rm -rf "$MNT_BOOT"
    echo "=== OS Kernel, SquashFS, and GRUB Configuration Updated (User Data Untouched) ==="
else
    echo "=== Drive requires Universal Layout Migration ==="
    # Backup existing user data if KIOSKDATA exists
    BACKUP_DIR=$(mktemp -d)
    EXISTING_DATA="$(lsblk -nlo PATH,LABEL "$TARGET_DEV" | grep -E "[[:space:]]${CONTENT_LABEL}$" | awk '{print $1}' | head -n 1 || true)"
    if [ -n "$EXISTING_DATA" ] && [ -b "$EXISTING_DATA" ]; then
        MNT_OLD=$(mktemp -d)
        if mount "$EXISTING_DATA" "$MNT_OLD" 2>/dev/null; then
            cp -r --no-preserve=ownership,mode "$MNT_OLD/." "$BACKUP_DIR/" 2>/dev/null || true
            umount "$MNT_OLD"
        fi
        rm -rf "$MNT_OLD"
    fi

    # Run make-usb.sh with universal layout
    "${SCRIPT_DIR}/make-usb.sh" -y "$TARGET_DEV"

    # Restore backed up user files if any
    if [ -f "$BACKUP_DIR/index.html" ]; then
        DATA_PART="$(lsblk -nlo PATH,LABEL "$TARGET_DEV" | grep -E "[[:space:]]${CONTENT_LABEL}$" | awk '{print $1}' | head -n 1 || true)"
        if [ -n "$DATA_PART" ]; then
            MNT_NEW=$(mktemp -d)
            mount "$DATA_PART" "$MNT_NEW"
            cp -r --no-preserve=ownership,mode "$BACKUP_DIR/." "$MNT_NEW/"
            sync
            umount "$MNT_NEW"
            rm -rf "$MNT_NEW"
        fi
    fi
    rm -rf "$BACKUP_DIR"
fi

echo "=== Success: USB Kiosk OS is fully updated and boot-ready ==="

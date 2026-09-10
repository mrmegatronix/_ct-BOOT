#!/usr/bin/env bash
# Auto-Update Script for USB Web Kiosk OS
# Preserves user content, custom signage, and configurations
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

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

# Check if latest ISO exists, or rebuild
if [ ! -f "$ISO_PATH" ]; then
    echo "ISO not found at $ISO_PATH. Triggering build..."
    "${SCRIPT_DIR}/build.sh"
fi

echo "=== Target Device: $TARGET_DEV ==="
BACKUP_DIR=$(mktemp -d)
CLEANUP() {
    umount "$TARGET_DEV"* 2>/dev/null || true
    rm -rf "$BACKUP_DIR" 2>/dev/null || true
}
trap CLEANUP EXIT INT TERM

# Identify and backup existing KIOSKDATA partition
EXISTING_DATA_PART="$(lsblk -nlo PATH,LABEL "$TARGET_DEV" | grep -E "[[:space:]]${CONTENT_LABEL}$" | awk '{print $1}' | head -n 1 || true)"
if [ -z "$EXISTING_DATA_PART" ]; then
    EXISTING_DATA_PART="$(lsblk -nlo PATH "$TARGET_DEV" | tail -n 1 || true)"
fi

if [ -n "$EXISTING_DATA_PART" ] && [ -b "$EXISTING_DATA_PART" ]; then
    echo "=== Backing Up Existing User Content ($EXISTING_DATA_PART) ==="
    MNT_SRC=$(mktemp -d)
    if mount "$EXISTING_DATA_PART" "$MNT_SRC" 2>/dev/null; then
        cp -r --no-preserve=ownership,mode "$MNT_SRC/." "$BACKUP_DIR/" 2>/dev/null || true
        umount "$MNT_SRC"
    fi
    rm -rf "$MNT_SRC"
fi

echo "=== Flashing Updated OS Image to $TARGET_DEV ==="
umount "${TARGET_DEV}"* 2>/dev/null || true
dd if="$ISO_PATH" of="$TARGET_DEV" bs=4M status=progress conv=fsync

echo "=== Updating GPT Layout & Recreating $CONTENT_LABEL ==="
sgdisk -e "$TARGET_DEV" || true
sgdisk -n 0:0:0 -t 0:0700 -c 0:"$CONTENT_LABEL" "$TARGET_DEV"

partprobe "$TARGET_DEV" || sleep 2
udevadm settle 2>/dev/null || sleep 2

NEW_DATA_PART="$(lsblk -nlo PATH "$TARGET_DEV" | tail -n 1)"
echo "Formatting data partition ($NEW_DATA_PART) as FAT32..."
mkfs.vfat -F 32 -n "$CONTENT_LABEL" "$NEW_DATA_PART"

echo "=== Restoring User Content & Signage Assets ==="
MNT_DEST=$(mktemp -d)
mount "$NEW_DATA_PART" "$MNT_DEST"

if [ -f "$BACKUP_DIR/index.html" ]; then
    echo "Restoring previously saved user files..."
    cp -r --no-preserve=ownership,mode "$BACKUP_DIR/." "$MNT_DEST/"
else
    echo "Populating default project content..."
    cp -r --no-preserve=ownership,mode "${SCRIPT_DIR}/content/." "$MNT_DEST/"
fi

sync
umount "$MNT_DEST"
rm -rf "$MNT_DEST"

echo "=== USB Kiosk OS Successfully Updated ==="

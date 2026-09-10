#!/usr/bin/env bash
# Prepare Dual-Partition USB Drive:
# Partition 1: Live OS Image
# Partition 2: FAT32 (Label: KIOSKDATA) for drag-and-drop web files
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

ISO_PATH="${SCRIPT_DIR}/${OUTPUT_DIR:-output}/${ISO_NAME:-web-kiosk-live.iso}"

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

# Auto-resolve partition (e.g., /dev/sdd1) to parent disk (e.g., /dev/sdd)
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
    echo "ERROR: Must be run as root." >&2
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

if [ ! -f "$ISO_PATH" ]; then
    echo "ERROR: Live ISO not found at $ISO_PATH. Run sudo ./build.sh first." >&2
    exit 1
fi

echo "WARNING: ALL DATA ON $TARGET_DEV WILL BE DESTROYED!"
echo "Target: $TARGET_DEV"

if [ "$AUTO_CONFIRM" -ne 1 ]; then
    read -p "Type 'YES' to proceed: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        echo "Aborted."
        exit 0
    fi
fi

echo "=== Unmounting Existing Partitions ==="
umount "${TARGET_DEV}"* 2>/dev/null || true

echo "=== Wiping Partition Table ==="
wipefs -a "$TARGET_DEV"

echo "=== Writing Hybrid ISO to $TARGET_DEV ==="
dd if="$ISO_PATH" of="$TARGET_DEV" bs=4M status=progress conv=fsync

echo "=== Expanding GPT Table to Full Disk ==="
sgdisk -e "$TARGET_DEV" || true

echo "=== Creating KIOSKDATA User Partition ==="
# Allocate remaining unallocated sectors to a new Microsoft basic data partition
sgdisk -n 0:0:0 -t 0:0700 -c 0:"$CONTENT_PART_LABEL" "$TARGET_DEV"

partprobe "$TARGET_DEV" || sleep 2
udevadm settle 2>/dev/null || sleep 2

# Identify the newly created partition
DATA_PART="$(lsblk -nlo PATH "$TARGET_DEV" | tail -n 1)"
echo "Formatting data partition ($DATA_PART) as FAT32..."
mkfs.vfat -F 32 -n "$CONTENT_PART_LABEL" "$DATA_PART"

echo "=== Populating Default Content on KIOSKDATA Partition ==="
MNT_DIR=$(mktemp -d)
mount "$DATA_PART" "$MNT_DIR"
cp -r --no-preserve=ownership,mode "${SCRIPT_DIR}/content/." "$MNT_DIR/"
cat << 'EOF' > "$MNT_DIR/kiosk.conf"
# Kiosk Configuration
# Override target URL below if you want remote signage:
# TARGET_URL="https://example.com/signage"
EOF
sync
umount "$MNT_DIR"
rm -rf "$MNT_DIR"

echo "=== Success ==="
echo "USB Drive $TARGET_DEV is ready to boot!"

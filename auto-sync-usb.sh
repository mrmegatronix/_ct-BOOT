#!/usr/bin/env bash
# Auto-Sync Watcher for Kiosk USB Drive
# Automatically triggers update-usb-os.sh whenever the USB drive is plugged into the system.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT="${SCRIPT_DIR}/update-usb-os.sh"

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: auto-sync-usb.sh must be run with root privileges (sudo $0)." >&2
    exit 1
fi

if [ ! -f "$UPDATE_SCRIPT" ]; then
    echo "ERROR: Update script not found: $UPDATE_SCRIPT" >&2
    exit 1
fi

echo "=========================================================="
echo "  Autonomous USB Auto-Sync Daemon Started"
echo "  Watching for Kiosk USB connection (KIOSKBOOT / KIOSKDATA)..."
echo "  Press Ctrl+C to stop."
echo "=========================================================="

SYNCING=0

sync_drive() {
    local dev="$1"
    if [ "$SYNCING" -eq 1 ]; then
        return
    fi
    SYNCING=1
    echo ""
    echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] USB Reconnected: /dev/$dev ==="
    sleep 2
    udevadm settle 2>/dev/null || sleep 1

    if [ -b "/dev/$dev" ]; then
        echo "Executing USB OS sync..."
        if bash "$UPDATE_SCRIPT" "/dev/$dev"; then
            echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Auto-Sync Finished Successfully! ==="
        else
            echo "=== [$(date '+%Y-%m-%d %H:%M:%S')] Auto-Sync Encountered an Error ==="
        fi
    fi
    SYNCING=0
}

# Initial check in case drive is already connected
EXISTING_BOOT="$(lsblk -nlo PATH,LABEL 2>/dev/null | grep -E '[[:space:]]KIOSKBOOT$' | awk '{print $1}' | head -n 1 || true)"
if [ -n "$EXISTING_BOOT" ]; then
    PK="$(lsblk -no pkname "$EXISTING_BOOT" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
    if [ -n "$PK" ] && [ -b "/dev/$PK" ]; then
        echo "Found currently connected Kiosk drive: /dev/$PK"
        sync_drive "$PK"
    fi
fi

# Listen for kernel block add events
udevadm monitor --kernel --subsystem-match=block | while read -r line; do
    if echo "$line" | grep -q 'KERNEL.*add.*(block)'; then
        DEV_NAME=$(echo "$line" | awk '{print $NF}')
        if [[ "$DEV_NAME" =~ ^sd[a-z]$ ]] || [[ "$DEV_NAME" =~ ^nvme[0-9]+n[1-9]$ ]]; then
            sleep 2
            if lsblk -no LABEL "/dev/$DEV_NAME"* 2>/dev/null | grep -qE '^(KIOSKBOOT|KIOSKDATA)$'; then
                sync_drive "$DEV_NAME"
            fi
        elif [[ "$DEV_NAME" =~ ^sd[a-z][0-9]+$ ]]; then
            PARENT_DISK="${DEV_NAME%%[0-9]*}"
            sleep 1
            if lsblk -no LABEL "/dev/$DEV_NAME" 2>/dev/null | grep -qE '^(KIOSKBOOT|KIOSKDATA)$'; then
                sync_drive "$PARENT_DISK"
            fi
        fi
    fi
done

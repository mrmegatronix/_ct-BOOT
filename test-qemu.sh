#!/usr/bin/env bash
# Quick QEMU Test Runner for Web Kiosk ISO
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

ISO_PATH="${SCRIPT_DIR}/${OUTPUT_DIR:-output}/${ISO_NAME:-web-kiosk-live.iso}"

if [ ! -f "$ISO_PATH" ]; then
    echo "ERROR: ISO not found at $ISO_PATH. Build it first via sudo ./build.sh." >&2
    exit 1
fi

MODE="${1:-bios}"
RAM="2048"

if [ "$MODE" == "uefi" ]; then
    OVMF_PATH="/usr/share/ovmf/OVMF.fd"
    if [ ! -f "$OVMF_PATH" ]; then
        OVMF_PATH="/usr/share/OVMF/OVMF_CODE.fd"
    fi
    echo "=== Launching QEMU in UEFI Mode ==="
    qemu-system-x86_64 \
        -enable-kvm \
        -m "$RAM" \
        -bios "$OVMF_PATH" \
        -cdrom "$ISO_PATH" \
        -vga virtio \
        -display sdl,gl=on || \
    qemu-system-x86_64 \
        -enable-kvm \
        -m "$RAM" \
        -bios "$OVMF_PATH" \
        -cdrom "$ISO_PATH" \
        -vga virtio
else
    echo "=== Launching QEMU in Legacy BIOS Mode ==="
    qemu-system-x86_64 \
        -enable-kvm \
        -m "$RAM" \
        -cdrom "$ISO_PATH" \
        -vga virtio \
        -display sdl,gl=on || \
    qemu-system-x86_64 \
        -enable-kvm \
        -m "$RAM" \
        -cdrom "$ISO_PATH" \
        -vga virtio
fi

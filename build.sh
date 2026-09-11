#!/usr/bin/env bash
# Master Build Script for Autonomous Web Kiosk Live USB / ISO
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file $CONFIG_FILE not found." >&2
    exit 1
fi

OUTPUT_DIR="${SCRIPT_DIR}/${OUTPUT_DIR:-output}"
ISO_PATH="${OUTPUT_DIR}/${ISO_NAME:-web-kiosk-live.iso}"
LOOP_IMG="${SCRIPT_DIR}/build_workspace.img"
BUILD_MNT="${SCRIPT_DIR}/build_mnt"
BUILD_DIR="${SCRIPT_DIR}/build"
CHROOT_DIR="${BUILD_DIR}/chroot"
ISO_DIR="${BUILD_DIR}/iso"

FS_TYPE="$(stat -f -c %T "$SCRIPT_DIR" 2>/dev/null || echo "unknown")"
USE_LOOP=0
if [ "$FS_TYPE" == "fuseblk" ] || [ "$FS_TYPE" == "msdos" ] || [ "$FS_TYPE" == "vfat" ]; then
    USE_LOOP=1
    BUILD_DIR="${BUILD_MNT}/build"
    CHROOT_DIR="${BUILD_DIR}/chroot"
    ISO_DIR="${BUILD_DIR}/iso"
fi

REQUIRED_TOOLS=(debootstrap mksquashfs xorriso grub-mkrescue mcopy mkfs.ext4)

check_tools() {
    echo "=== Checking Host Dependencies ==="
    local missing=()
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing required tools: ${missing[*]}" >&2
        echo "Install them on Debian/Ubuntu using:" >&2
        echo "  sudo apt-get update && sudo apt-get install -y debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin mtools dosfstools e2fsprogs isolinux syslinux-common" >&2
        return 1
    fi
    echo "All build tools verified."
}

unmount_chroot() {
    if [ -d "$CHROOT_DIR" ]; then
        umount -lf "${CHROOT_DIR}/sys" 2>/dev/null || true
        umount -lf "${CHROOT_DIR}/proc" 2>/dev/null || true
        umount -lf "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
        umount -lf "${CHROOT_DIR}/dev" 2>/dev/null || true
    fi
}

cleanup() {
    echo "=== Cleaning Up Mounts ==="
    unmount_chroot
    if [ "$USE_LOOP" -eq 1 ] && [ -d "$BUILD_MNT" ]; then
        umount -lf "$BUILD_MNT" 2>/dev/null || true
        rm -rf "$BUILD_MNT" 2>/dev/null || true
        rm -f "$LOOP_IMG" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

build_chroot() {
    if [ "$USE_LOOP" -eq 1 ]; then
        echo "=== Preparing Native ext4 Loop Workspace (fuseblk detected) ==="
        mkdir -p "$BUILD_MNT"
        truncate -s 12G "$LOOP_IMG"
        mkfs.ext4 -F -q "$LOOP_IMG"
        mount -o loop "$LOOP_IMG" "$BUILD_MNT"
    fi

    echo "=== Bootstrapping Debian Minimal (${DEBIAN_CODENAME}) ==="
    mkdir -p "$CHROOT_DIR"
    debootstrap --arch="$ARCH" --variant=minbase "$DEBIAN_CODENAME" "$CHROOT_DIR" http://deb.debian.org/debian/

    echo "=== Mounting Virtual Filesystems ==="
    mount --bind /dev "${CHROOT_DIR}/dev"
    mount --bind /dev/pts "${CHROOT_DIR}/dev/pts"
    mount -t proc proc "${CHROOT_DIR}/proc"
    mount -t sysfs sysfs "${CHROOT_DIR}/sys"
    cp -L /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf" 2>/dev/null || true

    echo "=== Configuring Host & Apt Sources ==="
    echo "web-kiosk" > "${CHROOT_DIR}/etc/hostname"
    cat << 'EOF' > "${CHROOT_DIR}/etc/hosts"
127.0.0.1   localhost
127.0.1.1   web-kiosk
EOF

    cat << EOF > "${CHROOT_DIR}/etc/apt/sources.list"
deb http://deb.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
EOF

    echo "=== Installing Packages inside Chroot ==="
    chroot "$CHROOT_DIR" env DEBIAN_FRONTEND=noninteractive apt-get update
    chroot "$CHROOT_DIR" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        linux-image-amd64 \
        live-boot \
        systemd-sysv \
        xorg \
        xinit \
        x11-xserver-utils \
        unclutter \
        chromium \
        python3 \
        ca-certificates \
        firmware-linux-free

    echo "=== Creating Kiosk User ==="
    chroot "$CHROOT_DIR" useradd -m -s /bin/bash -G audio,video,input "$KIOSK_USER" || true
    chroot "$CHROOT_DIR" passwd -d "$KIOSK_USER" || true

    echo "=== Copying Overlay Files ==="
    if [ -d "${SCRIPT_DIR}/overlay" ]; then
        cp -a "${SCRIPT_DIR}/overlay/." "${CHROOT_DIR}/"
    fi

    echo "=== Bundling Default Web Content ==="
    mkdir -p "${CHROOT_DIR}/opt/kiosk/content"
    if [ -d "${SCRIPT_DIR}/content" ]; then
        cp -a "${SCRIPT_DIR}/content/." "${CHROOT_DIR}/opt/kiosk/content/"
    fi

    echo "=== Setting Permissions & Enabling Services ==="
    chmod 755 "${CHROOT_DIR}/usr/local/bin/kiosk-launch.sh" || true
    chmod 755 "${CHROOT_DIR}/home/${KIOSK_USER}/.xinitrc" || true
    chroot "$CHROOT_DIR" chown -R "${KIOSK_USER}:${KIOSK_USER}" "/home/${KIOSK_USER}"
    chroot "$CHROOT_DIR" systemctl enable kiosk-mount.service
    chroot "$CHROOT_DIR" systemctl enable kiosk.service
    chroot "$CHROOT_DIR" systemctl set-default multi-user.target

    echo "=== Cleaning Apt Cache ==="
    chroot "$CHROOT_DIR" apt-get clean
    rm -rf "${CHROOT_DIR}/var/lib/apt/lists/*" "${CHROOT_DIR}/tmp/*"

    unmount_chroot
}

build_squashfs() {
    echo "=== Generating SquashFS Image ==="
    mkdir -p "${ISO_DIR}/live"
    # Copy kernel and initramfs out of chroot
    cp "$(ls -t "${CHROOT_DIR}/boot"/vmlinuz-* | head -n 1)" "${ISO_DIR}/live/vmlinuz"
    cp "$(ls -t "${CHROOT_DIR}/boot"/initrd.img-* | head -n 1)" "${ISO_DIR}/live/initrd.img"

    rm -f "${ISO_DIR}/live/filesystem.squashfs"
    mksquashfs "$CHROOT_DIR" "${ISO_DIR}/live/filesystem.squashfs" -comp xz -e boot
}

build_iso() {
    echo "=== Creating GRUB Bootloader Configuration ==="
    mkdir -p "${ISO_DIR}/boot/grub"
    cat << EOF > "${ISO_DIR}/boot/grub/grub.cfg"
set default="0"
set timeout=1

menuentry "Autonomous Web Kiosk (Live RAM)" {
    linux /live/vmlinuz boot=live quiet splash components console=tty1 nomodeset
    initrd /live/initrd.img
}

menuentry "Autonomous Web Kiosk (Failsafe)" {
    linux /live/vmlinuz boot=live components memtest noapic noapm nodma nomce nolapic nomodeset nosmp nosplash vga=normal
    initrd /live/initrd.img
}
EOF

    mkdir -p "$OUTPUT_DIR"
    echo "=== Packing Hybrid ISO Image ==="
    grub-mkrescue -o "$ISO_PATH" "$ISO_DIR" -- -volid "$VOLUME_ID"

    echo "=== Success ==="
    echo "Bootable ISO created at: $ISO_PATH"
}

if [[ "${1:-}" == "--check" ]]; then
    check_tools
    exit 0
fi

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: build.sh must be run as root (or via sudo) to execute debootstrap/chroot." >&2
    exit 1
fi

check_tools
build_chroot
build_squashfs
build_iso

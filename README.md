# Autonomous Bootable Web Kiosk USB

A self-contained, live-bootable Linux environment designed to turn any x86_64 PC or Mac into a full-screen HTML digital signage / kiosk display.

---

## Key Features

- **Self-Contained & Pull-Safe**: Boots into a read-only SquashFS filesystem with a volatile RAM (`tmpfs` / `OverlayFS`) layer. Safe from filesystem corruption even if abruptly unplugged.
- **Dual Partitioning Architecture**:
  - **Partition 1 (OS/Boot)**: GRUB2 & Linux kernel supporting both UEFI and Legacy BIOS booting.
  - **Partition 2 (KIOSKDATA)**: Standard FAT32 partition. Drop custom HTML/CSS/JS or media files directly from Windows, macOS, or Linux.
- **Crash Recovery & Supervised Process**: The browser supervisor runs Chromium in an isolated kiosk mode loop (`--kiosk`, `--noerrdialogs`, `--disable-session-crashed-bubble`).
- **Offline First**: Bundled Python lightweight HTTP server serves local content out-of-the-box. Remote URLs can be specified via `kiosk.conf`.

---

## Keyboard Controls

| Key | Action | Function |
| :--- | :--- | :--- |
| `ArrowLeft` | Previous Slide | Calls `prevSlide()` |
| `ArrowRight` | Next Slide | Calls `nextSlide()` |
| `ArrowUp` | Restart Module | Resets to current module's first slide (slide 0) |
| `ArrowDown` | Skip Module | Jumps directly to the start of the next module |
| `Space` | Pause / Unpause | Freezes timer without freezing animations |
| `0` | Lock / Unlock | Hardware lock freeze toggle |
| `1` – `9` | Duration | Sets slide duration to `10s` through `90s` and restarts timer |
| `a` / `A` | Admin Panel | Opens `admin.html` in a new tab |
| `r` / `R` | Remote Control | Opens `remote.html` in a new tab |

*Note: All keyboard shortcuts are automatically suppressed when typing inside `<input>`, `<textarea>`, or `<select>` elements.*

---

## Build Prerequisites

On Debian/Ubuntu hosts:
```bash
sudo apt-get update && sudo apt-get install -y \
    debootstrap \
    squashfs-tools \
    xorriso \
    grub-pc-bin \
    grub-efi-amd64-bin \
    mtools \
    dosfstools \
    parted \
    qemu-system-x86
```

---

## Build & Deployment Workflow

### 1. Check Toolchain
```bash
./build.sh --check
```

### 2. Build the Live Hybrid ISO
```bash
sudo ./build.sh
```
The output image will be saved to `output/web-kiosk-live.iso`.

### 3. Test in Virtual Machine
```bash
# Test Legacy BIOS
./test-qemu.sh bios

# Test UEFI
./test-qemu.sh uefi
```

### 4. Flash to Target USB Drive
```bash
# WARNING: Confirm target USB drive using lsblk (e.g., /dev/sdb)
sudo ./make-usb.sh /dev/sdX
```

### 5. Auto-Update OS on USB (Preserving User Content)
```bash
# Auto-detects connected kiosk USB or takes explicit device:
sudo ./update-usb-os.sh
# Or specify drive directly:
sudo ./update-usb-os.sh /dev/sdX
```
*Backs up `KIOSKDATA`, updates the OS image, and restores all signage assets.*

---

## Quick-Launch on Running PC / Mac

When plugging the USB drive into an already booted computer, open the **`KIOSKDATA`** drive and double-click the file for your operating system:

* **Windows**: Double-click `WINDOWS-Double-Click-To-Open.bat` (launches Edge/Chrome in fullscreen kiosk mode).
* **Linux**: Double-click `LINUX-Double-Click-To-Open.desktop` (or run `./LINUX-Run-In-Terminal.sh`).
* **macOS**: Double-click `MAC-Double-Click-To-Open.command` (launches Chrome/Edge in fullscreen kiosk mode).

---

## Customizing Signage Content

Insert the USB drive into your workstation after running `make-usb.sh`:
1. Open the partition labeled **`KIOSKDATA`**.
2. Replace or edit `index.html`, `css/style.css`, and `js/kiosk-controller.js`.
3. To configure a remote web URL instead of local files, edit `kiosk.conf`:
   ```bash
   TARGET_URL="https://your-signage-server.com/display"
   ```

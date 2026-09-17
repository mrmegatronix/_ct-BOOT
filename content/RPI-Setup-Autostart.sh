#!/usr/bin/env bash
# Raspberry Pi OS Autostart Configurator
# Configures Raspberry Pi to launch this Kiosk automatically on boot.
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOSTART_DIR="${HOME}/.config/autostart"
DESKTOP_FILE="${AUTOSTART_DIR}/kiosk-usb.desktop"

echo "=========================================================="
echo "RASPBERRY PI AUTONOMOUS KIOSK AUTOSTART SETUP"
echo "Kiosk Source: ${DIR}"
echo "=========================================================="

mkdir -p "$AUTOSTART_DIR"

cat << EOF > "$DESKTOP_FILE"
[Desktop Entry]
Type=Application
Name=Autonomous Web Kiosk
Comment=Start Kiosk Signage on Raspberry Pi Boot
Exec=/usr/bin/env bash "${DIR}/RPI-Run-Kiosk.sh"
Terminal=false
StartupNotify=false
X-GNOME-Autostart-enabled=true
EOF

chmod +x "$DESKTOP_FILE"
chmod +x "${DIR}/RPI-Run-Kiosk.sh"

echo "✓ Created autostart entry: $DESKTOP_FILE"

# Disable screen blanking in wayfire if Wayland is used
WAYFIRE_INI="${HOME}/.config/wayfire.ini"
if [ -f "$WAYFIRE_INI" ]; then
    if ! grep -q "power-save = false" "$WAYFIRE_INI"; then
        sed -i 's/\[idle\]/\[idle\]\npower-save = false\n/g' "$WAYFIRE_INI" 2>/dev/null || true
        echo "✓ Disabled Wayland idle screen blanking in wayfire.ini"
    fi
fi

echo "=========================================================="
echo "SUCCESS: Kiosk is configured to start automatically on boot!"
echo "To test immediately, run: ${DIR}/RPI-Run-Kiosk.sh"
echo "To uninstall autostart, run: rm ${DESKTOP_FILE}"
echo "=========================================================="

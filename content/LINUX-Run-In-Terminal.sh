#!/usr/bin/env bash
# Linux Shell Launcher for Kiosk Display
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_URL="file://${DIR}/index.html"

if [ -f "${DIR}/kiosk.conf" ]; then
    source "${DIR}/kiosk.conf" 2>/dev/null || true
fi

for browser in google-chrome google-chrome-stable chromium chromium-browser firefox xdg-open; do
    if command -v "$browser" >/dev/null 2>&1; then
        if [[ "$browser" == *"firefox"* ]]; then
            exec "$browser" --kiosk "$TARGET_URL"
        elif [[ "$browser" == "xdg-open" ]]; then
            exec "$browser" "$TARGET_URL"
        else
            exec "$browser" --kiosk --noerrdialogs --disable-infobars --no-first-run "$TARGET_URL"
        fi
    fi
done

#!/usr/bin/env bash
# Raspberry Pi Kiosk Launcher (Supports X11 & Wayland / Wayfire / Labwc)
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=8080
TARGET_URL="http://127.0.0.1:${PORT}/index.html"

if [ -f "${DIR}/kiosk.conf" ]; then
    source "${DIR}/kiosk.conf" 2>/dev/null || true
fi

# 1. Start local Kiosk HTTP/API server in background
if ! pgrep -f "kiosk-server.py" >/dev/null 2>&1; then
    CONTENT_DIR="$DIR" LOCAL_SERVER_PORT="$PORT" python3 "${DIR}/kiosk-server.py" >/dev/null 2>&1 &
    SERVER_PID=$!
    trap "kill -9 $SERVER_PID 2>/dev/null || true" EXIT
    sleep 0.5
fi

# 2. Disable screen blanking & DPMS on X11 if available
if [ -n "${DISPLAY:-}" ] && command -v xset >/dev/null 2>&1; then
    xset -dpms 2>/dev/null || true
    xset s off 2>/dev/null || true
    xset s noblank 2>/dev/null || true
fi

# 3. Hide mouse pointer when idle on X11
if [ -n "${DISPLAY:-}" ] && command -v unclutter >/dev/null 2>&1; then
    unclutter -idle 1 -root >/dev/null 2>&1 &
fi

# 4. Determine Chromium binary
BROWSER=""
for b in chromium-browser chromium google-chrome; do
    if command -v "$b" >/dev/null 2>&1; then
        BROWSER="$b"
        break
    fi
done

if [ -z "$BROWSER" ]; then
    echo "Chromium browser not found. Launching default browser..."
    exec xdg-open "$TARGET_URL"
fi

# 5. Raspberry Pi-optimized browser flags
FLAGS=(
    --kiosk
    --start-maximized
    --noerrdialogs
    --disable-infobars
    --no-first-run
    --fast
    --fast-start
    --disable-pinch
    --overscroll-history-navigation=0
    --check-for-update-interval=31536000
    --disable-session-crashed-bubble
    --disable-features=TranslateUI
    --autoplay-policy=no-user-gesture-required
    --simulate-outdated-no-au='Tue, 31 Dec 2099 23:59:59 GMT'
)

# Detect Wayland on modern Raspberry Pi OS (Bookworm)
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    FLAGS+=(--ozone-platform=wayland --enable-features=OverlayScrollbar)
fi

echo "Launching Autonomous Kiosk on Raspberry Pi..."
exec "$BROWSER" "${FLAGS[@]}" "$TARGET_URL"

#!/usr/bin/env bash
# Kiosk Session Launch Script
set -e

# Disable screen saver, blanking, and energy star DPMS
xset -dpms || true
xset s off || true
xset s noblank || true

# Attempt to enforce 1080p display mode
xrandr -s 1920x1080 2>/dev/null || true

# Hide cursor when idle (timeout 1s)
unclutter -idle 1 -root &

# Mount KIOSKDATA partition if available
CONTENT_DIR="/opt/kiosk/content"
if [ -d "/mnt/kiosk-data" ] && [ -f "/mnt/kiosk-data/index.html" ]; then
    CONTENT_DIR="/mnt/kiosk-data"
fi

# Start local kiosk API & HTTP server
export CONTENT_DIR
export LOCAL_SERVER_PORT=8080
python3 /usr/local/bin/kiosk-server.py >/dev/null 2>&1 &
SERVER_PID=$!

# Cleanup on exit
trap "kill -9 $SERVER_PID 2>/dev/null || true" EXIT

TARGET_URL="http://127.0.0.1:8080/index.html"
if [ -f "$CONTENT_DIR/kiosk.conf" ]; then
    # Load custom URL if defined
    source "$CONTENT_DIR/kiosk.conf" 2>/dev/null || true
fi

# Ensure clean Chromium state on volatile tmpfs
rm -rf /home/kiosk/.config/chromium/Singleton* /home/kiosk/.config/chromium/Default/Preferences.bad || true

# Continuous restart loop in case of crash/kill
while true; do
    chromium \
        --kiosk \
        --window-size=1920,1080 \
        --start-fullscreen \
        --force-device-scale-factor=1 \
        --noerrdialogs \
        --disable-infobars \
        --no-first-run \
        --fast \
        --fast-start \
        --disable-pinch \
        --overscroll-history-navigation=0 \
        --check-for-update-interval=31536000 \
        --disable-session-crashed-bubble \
        --disable-features=TranslateUI \
        --autoplay-policy=no-user-gesture-required \
        --simulate-outdated-no-au='Tue, 31 Dec 2099 23:59:59 GMT' \
        "$TARGET_URL" || true
    sleep 1
done

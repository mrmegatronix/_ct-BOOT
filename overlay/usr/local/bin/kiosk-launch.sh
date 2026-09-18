#!/usr/bin/env bash
# Kiosk Session Launch Script
set -e

# Disable screen saver, blanking, and energy star DPMS
xset -dpms || true
xset s off || true
xset s noblank || true

# Mount KIOSKDATA partition if available
CONTENT_DIR="/opt/kiosk/content"
if [ -d "/mnt/kiosk-data" ] && [ -f "/mnt/kiosk-data/index.html" ]; then
    CONTENT_DIR="/mnt/kiosk-data"
fi

# Load custom kiosk configuration (display/URL overrides)
TARGET_URL="http://127.0.0.1:8080/index.html"
if [ -f "$CONTENT_DIR/kiosk.conf" ]; then
    source "$CONTENT_DIR/kiosk.conf" 2>/dev/null || true
fi

# Attempt to enforce native display resolution
if command -v xrandr >/dev/null 2>&1; then
    xrandr -q 2>/dev/null | grep " disconnected" | awk '{print $1}' | while read -r disc; do
        [ -n "$disc" ] && xrandr --output "$disc" --off 2>/dev/null || true
    done
    PRIMARY=$(xrandr -q 2>/dev/null | grep " connected" | head -n 1 | awk '{print $1}')
    if [ -n "$PRIMARY" ]; then
        if ! xrandr -q 2>/dev/null | grep -A 25 "^$PRIMARY" | grep -q "1920x1080"; then
            xrandr --newmode "1920x1080_60.00" 173.00 1920 2048 2248 2576 1080 1083 1088 1120 -hsync +vsync 2>/dev/null || true
            xrandr --addmode "$PRIMARY" "1920x1080_60.00" 2>/dev/null || true
        fi
        if ! xrandr --output "$PRIMARY" --mode 1920x1080 --pos 0x0 --rate 60 2>/dev/null; then
            if ! xrandr --output "$PRIMARY" --mode 1920x1080 --pos 0x0 2>/dev/null; then
                if ! xrandr --output "$PRIMARY" --mode "1920x1080_60.00" --pos 0x0 2>/dev/null; then
                    xrandr --output "$PRIMARY" --auto --pos 0x0 2>/dev/null || true
                    xrandr --output "$PRIMARY" --scale-from 1920x1080 2>/dev/null || true
                fi
            fi
        fi
        xrandr --output "$PRIMARY" --primary --pos 0x0 2>/dev/null || true
    else
        xrandr -s 1920x1080 2>/dev/null || true
    fi
    xrandr --fb 1920x1080 2>/dev/null || true
fi

# Start matchbox-window-manager to enforce exact 1080p root window containment
if command -v matchbox-window-manager >/dev/null 2>&1; then
    matchbox-window-manager -use_titlebar no -use_cursor no &
fi

# Hide cursor when idle (timeout 1s)
unclutter -idle 1 -root &

# Start local kiosk API & HTTP server
export CONTENT_DIR
export LOCAL_SERVER_PORT=8080
python3 /usr/local/bin/kiosk-server.py >/dev/null 2>&1 &
SERVER_PID=$!

# Cleanup on exit
trap "kill -9 $SERVER_PID 2>/dev/null || true" EXIT

# Ensure clean Chromium state on volatile tmpfs
rm -rf /home/kiosk/.config/chromium/Singleton* /home/kiosk/.config/chromium/Default/Preferences.bad || true

# Continuous restart loop in case of crash/kill
while true; do
    chromium \
        --kiosk \
        --window-size=1920,1080 \
        --window-position=0,0 \
        --force-device-scale-factor=1 \
        --high-dpi-support=1 \
        --start-maximized \
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

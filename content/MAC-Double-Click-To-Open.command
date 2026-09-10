#!/usr/bin/env bash
# macOS Fullscreen Kiosk Launcher
DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_URL="file://${DIR}/index.html"

if [ -f "${DIR}/kiosk.conf" ]; then
    source "${DIR}/kiosk.conf" 2>/dev/null || true
fi

# Try Google Chrome kiosk mode on macOS
if [ -d "/Applications/Google Chrome.app" ]; then
    open -a "Google Chrome" --args --kiosk --no-first-run "$TARGET_URL"
    exit 0
fi

# Try Microsoft Edge on macOS
if [ -d "/Applications/Microsoft Edge.app" ]; then
    open -a "Microsoft Edge" --args --kiosk "$TARGET_URL"
    exit 0
fi

# Default fallback
open "$TARGET_URL"

#!/bin/bash

# TabDisplay USB Tunnel Setup Helper
# Automatically forwards required TCP ports over USB using adb forward
# Ports: 5001 (TCP control channel) + 6002 (TCP/UDP video channel)

set -e

echo "╔══════════════════════════════════════════╗"
echo "║   TabDisplay USB Connection Bridge       ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Check ADB ────────────────────────────────────────────────────────────────
if ! command -v adb &> /dev/null; then
    echo "❌ Error: 'adb' tool is not installed."
    echo "   Install Android Platform Tools via Homebrew:"
    echo "   brew install android-platform-tools"
    exit 1
fi

ADB=$(command -v adb)
echo "✓ ADB found at: $ADB"
echo ""

# ── Check connected devices ───────────────────────────────────────────────────
echo "Checking for connected Android devices..."
DEVICES=$(adb devices | tail -n +2 | grep -v "^$" | grep "device$")

if [ -z "$DEVICES" ]; then
    echo ""
    echo "❌ Error: No Android device detected."
    echo "   Steps to fix:"
    echo "   1. Connect your Samsung Tab S6 Lite via USB cable."
    echo "   2. Enable 'Developer Options' → 'USB Debugging' on the tablet."
    echo "   3. Accept the 'Allow USB Debugging' dialog on the tablet screen."
    echo "   4. Re-run this script."
    exit 2
fi

echo "✓ Detected Android device(s):"
echo "$DEVICES" | sed 's/^/   /'
echo ""

# ── Port definitions (must match TabDisplayServer constants) ──────────────────
CONTROL_PORT=5001   # TCP control channel (handshake + telemetry + input events)
VIDEO_PORT=6002     # TCP/UDP video stream channel

# ── Forward ports ─────────────────────────────────────────────────────────────
echo "Configuring ADB port forwarding..."

echo "→ Control channel: tcp:$CONTROL_PORT ↔ tcp:$CONTROL_PORT"
if ! adb forward tcp:$CONTROL_PORT tcp:$CONTROL_PORT; then
    echo "❌ Failed to forward control channel (port $CONTROL_PORT)."
    exit 3
fi

echo "→ Video  channel:  tcp:$VIDEO_PORT ↔ tcp:$VIDEO_PORT"
if ! adb forward tcp:$VIDEO_PORT tcp:$VIDEO_PORT; then
    echo "❌ Failed to forward video channel (port $VIDEO_PORT)."
    exit 4
fi

echo ""
echo "✓ Port forwarding configured."
echo ""

# ── Verification: list active forwards ────────────────────────────────────────
echo "Active ADB port forwards:"
adb forward --list | sed 's/^/   /'
echo ""

# ── Instructions ──────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════╗"
echo "║   USB Tunnel Established Successfully   ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  1. Start TabDisplayServer on macOS (click 🖥️ in menu bar)."
echo "  2. Enable 'USB Mode' in the macOS menu bar toggle."
echo "  3. Open TabDisplay on the tablet → enable 'USB Mode' switch."
echo "  4. Tap Connect — the app will use 127.0.0.1 automatically."
echo ""
echo "To clear forwards later, run:  adb forward --remove-all"

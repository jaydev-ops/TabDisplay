#!/bin/bash

# TabDisplay USB Tunnel Setup Helper
# Automatically forwards required TCP ports over USB using adb

echo "=== TabDisplay USB Connection Bridge ==="

# Check if adb is installed
if ! command -v adb &> /dev/null; then
    echo "Error: 'adb' tool is not installed."
    echo "Please install Android Platform Tools using Homebrew: 'brew install android-platform-tools'"
    exit 1
fi

# Check for connected devices
echo "Checking for connected Android devices..."
DEVICES=$(adb devices | grep -v "List" | grep "device")

if [ -z "$DEVICES" ]; then
    echo "Error: No Android devices detected."
    echo "Please connect your Samsung Tab S6 Lite via USB and enable 'USB Debugging' in Developer Options."
    exit 2
fi

echo "Detected device(s):"
echo "$DEVICES"

# Define ports
CONTROL_PORT=5001
VIDEO_PORT=5002

echo "Configuring ADB port forwarding..."
echo "-> Forwarding Control Channel (TCP $CONTROL_PORT -> $CONTROL_PORT)"
adb forward tcp:$CONTROL_PORT tcp:$CONTROL_PORT

if [ $? -eq 0 ]; then
    echo "-> Forwarding Video Channel (TCP $VIDEO_PORT -> $VIDEO_PORT)"
    adb forward tcp:$VIDEO_PORT tcp:$VIDEO_PORT
else
    echo "Failed to forward control channel."
    exit 3
fi

if [ $? -eq 0 ]; then
    echo "=== USB Tunnel Established Successfully ==="
    echo "Start the macOS Server app and connect the Android Client over USB."
    echo "To view current forwarding rules, run 'adb forward --list'."
else
    echo "Failed to forward video channel."
    exit 4
fi

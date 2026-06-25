#!/bin/bash

# TabDisplay Release Packaging Script
# Compiles macOS server in release mode, builds a standard .app bundle,
# creates a DMG installer, builds the Android client, and extracts the APK.

set -e

# Base directories
PROJECT_ROOT="$(pwd)"
RELEASE_DIR="$PROJECT_ROOT/release"
TEMP_APP_DIR="$RELEASE_DIR/AppBundle"
APP_PATH="$TEMP_APP_DIR/TabDisplay.app"

echo "=== TabDisplay Release Packaging ==="
echo "Project Root: $PROJECT_ROOT"
echo "Output folder: $RELEASE_DIR"
echo ""

# Create directories
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
mkdir -p "$TEMP_APP_DIR"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# ── 1. Build macOS Release Binary ──────────────────────────────────────────
echo "Building macOS Server in Release mode..."
cd "$PROJECT_ROOT/macos"
swift build -c release

BINARY_SRC=".build/release/TabDisplayServer"
if [ ! -f "$BINARY_SRC" ]; then
    echo "❌ Error: Release binary not found at $BINARY_SRC"
    exit 1
fi
echo "✓ macOS Release Binary built successfully."
echo ""

# ── 2. Create macOS App Bundle ─────────────────────────────────────────────
echo "Creating macOS App Bundle..."

# Copy executable
cp "$BINARY_SRC" "$APP_PATH/Contents/MacOS/TabDisplay"
chmod +x "$APP_PATH/Contents/MacOS/TabDisplay"

# Create Info.plist
cat <<EOF > "$APP_PATH/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>TabDisplay</string>
    <key>CFBundleIdentifier</key>
    <string>com.tabdisplay.server</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>TabDisplay</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleSignature</key>
    <string>????</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "✓ App Bundle created at $APP_PATH"
echo ""

# ── 3. Create macOS DMG Installer ──────────────────────────────────────────
echo "Creating macOS DMG Installer..."

# Create a symlink to Applications folder inside AppBundle
ln -s /Applications "$TEMP_APP_DIR/Applications"

# Run hdiutil to package the DMG
DMG_PATH="$RELEASE_DIR/TabDisplay.dmg"
hdiutil create -volname "TabDisplay" -srcfolder "$TEMP_APP_DIR" -ov -format UDZO "$DMG_PATH"

# Cleanup symlink and temp folder
rm -rf "$TEMP_APP_DIR"

echo "✓ macOS DMG created at: $DMG_PATH"
echo ""

# ── 4. Build Android Client APK ─────────────────────────────────────────────
echo "Building Android Client Debug APK..."
cd "$PROJECT_ROOT/android"

# Run Gradle assemble
export JAVA_HOME=/Library/Java/JavaVirtualMachines/zulu-17.jdk/Contents/Home
~/.gradle/wrapper/dists/gradle-8.9-bin/90cnw93cvbtalezasaz0blq0a/gradle-8.9/bin/gradle assembleDebug --no-daemon -x test

APK_SRC="app/build/outputs/apk/debug/app-debug.apk"
if [ ! -f "$APK_SRC" ]; then
    echo "❌ Error: Android APK not found at $APK_SRC"
    exit 2
fi

APK_DEST="$RELEASE_DIR/TabDisplay.apk"
cp "$APK_SRC" "$APK_DEST"

echo "✓ Android APK copied to: $APK_DEST"
echo ""

# ── 5. Finished Summary ─────────────────────────────────────────────────────
echo "============================================="
echo "  TabDisplay Release Packaged Successfully!  "
echo "============================================="
echo "Artifacts located in: $RELEASE_DIR"
ls -lh "$RELEASE_DIR"
echo "============================================="

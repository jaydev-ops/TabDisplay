#!/bin/bash
set -e

# TabDisplay Debug App Packaging & Codesigning Script
PROJECT_ROOT="/Users/jayeshyadav/Projects/TabDisplay"
MACOS_DIR="$PROJECT_ROOT/macos"
BUILD_DIR="$MACOS_DIR/.build/debug"
APP_PATH="$BUILD_DIR/TabDisplay.app"

echo "=== BUILDING TABDISPLAY SERVER ==="
cd "$MACOS_DIR"
swift build

echo "=== PACKAGING DEBUG APP BUNDLE ==="
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp "$BUILD_DIR/TabDisplayServer" "$APP_PATH/Contents/MacOS/TabDisplay"
chmod +x "$APP_PATH/Contents/MacOS/TabDisplay"

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

echo "=== CODESIGNING DEBUG APP BUNDLE ==="
codesign --force --options runtime --sign "Apple Development: yadavjayesh029@gmail.com (HUUBMA4GP4)" --identifier "com.tabdisplay.server" "$APP_PATH"

echo "✓ Successfully built and signed TabDisplay.app!"
echo "Binary path: $APP_PATH/Contents/MacOS/TabDisplay"

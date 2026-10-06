#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "==> Building MetalPlayer with swift build..."
swift build -c debug

APP_DIR="$DIR/build/MetalPlayer.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Packaging $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

BIN_PATH="$DIR/.build/out/Products/Debug/MetalPlayer"
if [ ! -f "$BIN_PATH" ]; then
    # Fallback to standard swiftpm debug path if custom out path is absent
    BIN_PATH="$(swift build --show-bin-path)/MetalPlayer"
fi

cp "$BIN_PATH" "$MACOS_DIR/MetalPlayer"
chmod +x "$MACOS_DIR/MetalPlayer"

# Copy any resource bundles
for b in "$DIR/.build/out/Products/Debug/"*.bundle; do
    if [ -d "$b" ]; then
        cp -R "$b" "$RESOURCES_DIR/"
    fi
done

# Create Info.plist with valid bundle identifier
cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MetalPlayer</string>
    <key>CFBundleIdentifier</key>
    <string>com.metalplayer.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MetalPlayer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "==> Codesigning MetalPlayer.app..."
codesign --force --deep -s - "$APP_DIR"

echo "==> Done! App bundle created at $APP_DIR"
if [ "$1" == "--run" ]; then
    echo "==> Launching MetalPlayer.app..."
    open "$APP_DIR"
fi

#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$DIR/.."
cd "$PROJECT_ROOT/BrimCore"

echo "Building release mode..."
swift build -c release --arch arm64

echo "Assembling Brim.app bundle..."
APP_DIR="$PROJECT_ROOT/build/Brim.app"
rm -rf "$PROJECT_ROOT/build"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy executable
BIN_PATH=$(swift build -c release --show-bin-path)
cp "$BIN_PATH/BrimApp" "$APP_DIR/Contents/MacOS/Brim"

# Generate Info.plist
cat << 'PLIST' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.google.Brim</string>
    <key>CFBundleName</key>
    <string>Brim</string>
    <key>CFBundleExecutable</key>
    <string>Brim</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>SMPrivilegedExecutables</key>
    <dict>
        <key>com.google.Brim.daemon</key>
        <string>identifier com.google.Brim.daemon</string>
    </dict>
</dict>
</plist>
PLIST

echo "Copying Helper daemon into bundle..."
mkdir -p "$APP_DIR/Contents/Library/LaunchServices"
cp "$BIN_PATH/BrimHelper" "$APP_DIR/Contents/Library/LaunchServices/com.google.Brim.daemon"

# Copy daemon plist
cp "Sources/BrimHelper/com.google.Brim.daemon.plist" "$APP_DIR/Contents/Library/LaunchServices/"

if [[ -n "$APPLE_SIGNING_IDENTITY" ]]; then
    echo "Signing helper daemon..."
    codesign --force --options runtime -s "$APPLE_SIGNING_IDENTITY" "$APP_DIR/Contents/Library/LaunchServices/com.google.Brim.daemon"
    
    echo "Signing Brim.app..."
    codesign --force --options runtime -s "$APPLE_SIGNING_IDENTITY" --entitlements "$PROJECT_ROOT/BrimCore/Brim.entitlements" "$APP_DIR"
else
    echo "WARNING: APPLE_SIGNING_IDENTITY not set. Skipping code signing."
fi

echo "Creating DMG..."
cd "$PROJECT_ROOT/build"
hdiutil create -volname "Brim" -srcfolder Brim.app -ov -format UDZO Brim-1.0.0.dmg

if [[ -n "$APPLE_ID" && -n "$APPLE_APP_SPECIFIC_PASSWORD" && -n "$APPLE_TEAM_ID" ]]; then
    echo "Notarising DMG..."
    xcrun notarytool submit Brim-1.0.0.dmg --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
    xcrun stapler staple Brim-1.0.0.dmg
else
    echo "WARNING: Notarization credentials not set. Skipping notarisation."
fi

echo "Release build complete: build/Brim-1.0.0.dmg"

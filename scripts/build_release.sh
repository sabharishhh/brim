#!/usr/bin/env bash
#
# Builds, signs, verifies and packages Brim for release, and notarises it
# when notarisation credentials are set.
#
# Brim 1.0 ships signed with the free Apple Development certificate, not
# notarised. Brim's own XPC checks ask for a certificate Apple issued with
# team 9LY29YLFG2 in it, which that certificate satisfies, and a stable
# signature keeps Full Disk Access across updates. What notarisation adds
# is macOS opening the download without asking; without it, people open
# Brim once through System Settings, Privacy & Security, Open Anyway. When
# the paid programme is joined, set APPLE_SIGNING_IDENTITY to the Developer
# ID certificate and the three notarisation variables, and nothing else
# changes.
#
# This used to assemble a bundle by hand out of the SPM package, and every
# part of that had rotted. It copied the BrimApp placeholder, whose entire
# body is a window reading "Brim UI (Coming in M6)", as the application
# binary. It stamped CFBundleIdentifier com.google.Brim, one of the two dead
# identifiers kept only so an upgrade can clear what they left. It copied a
# BrimHelper target and a com.google.Brim.daemon.plist that stopped existing
# when the old root daemon was deleted, so with `set -e` it could not have
# reached the end. And when no signing identity was set it printed a warning
# and carried on, producing an unsigned, un-notarised DMG that the release
# workflow would then publish.
#
# Nothing here is assembled by hand any more. The Xcode project already gets
# all of it right: the identifiers, the team, the daemon in
# Contents/MacOS/BrimJobHelper and its plist in Contents/Library/LaunchDaemons.
# So this archives that and exports it.
#
# The verification step is the part worth keeping. Brim's two XPC boundaries
# are enforced by code-signing requirements, and a requirement naming
# something nothing is signed as fails closed and silently. That has happened
# twice: once naming Google's team, once naming a daemon that had been
# deleted. Both were found by running the requirement against the built
# binary, which is what happens below, before anything is published.

set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$DIR/.."
cd "$PROJECT_ROOT"

TEAM_ID="9LY29YLFG2"
APP_IDENTIFIER="com.sabharishhh.brim"
DAEMON_IDENTIFIER="com.sabharishhh.brim.jobhelper"
SCHEME="brim"

BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE="$BUILD_DIR/Brim.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

# The version lives in the project, not here. A number hardcoded in a script
# is a number that disagrees with the one in the bundle.
VERSION=$(xcodebuild -project Brim.xcodeproj -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
if [[ -z "${VERSION:-}" ]]; then
    echo "error: could not read MARKETING_VERSION from the project" >&2
    exit 1
fi

# The identity comes from the keychain when it is not given. An unsigned
# build fails Brim's own XPC checks and macOS will not run its daemon, so
# there is no path through here that produces one.
if [[ -z "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    APPLE_SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
        | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')
fi
if [[ -z "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    echo "error: no signing certificate found." >&2
    echo "       Sign in to Xcode with your Apple ID and let it create an Apple" >&2
    echo "       Development certificate, or set APPLE_SIGNING_IDENTITY." >&2
    exit 1
fi
echo "Signing with: $APPLE_SIGNING_IDENTITY"

echo "Building Brim $VERSION for release..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild archive \
    -project Brim.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination 'generic/platform=macOS' \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY"

# A Developer ID certificate exports for distribution. Anything else is
# taken from the archive as it was signed there, since the development
# export method re-signs for a provisioning profile Brim does not need.
if [[ "$APPLE_SIGNING_IDENTITY" == Developer\ ID\ Application* ]]; then
cat << PLIST > "$BUILD_DIR/ExportOptions.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
</dict>
</plist>
PLIST
    echo "Exporting..."
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
        -exportPath "$EXPORT_DIR"
else
    mkdir -p "$EXPORT_DIR"
    ditto "$ARCHIVE/Products/Applications" "$EXPORT_DIR"
fi

APP=$(find "$EXPORT_DIR" -maxdepth 1 -name "*.app" -print -quit)
if [[ -z "$APP" ]]; then
    echo "error: the export produced no application bundle" >&2
    exit 1
fi

# --- What the signature has to satisfy -------------------------------------
#
# The same strings the product installs on its XPC connections, checked
# against the binaries that are about to ship. If either of these fails,
# Brim's application and its root daemon will refuse to talk to each other on
# the machine this lands on, and the failure will look like a bug rather than
# a signing mistake.

requirement_for() {
    echo "anchor apple generic and identifier \"$1\" and certificate leaf[subject.OU] = \"$TEAM_ID\""
}

echo "Checking the application satisfies its own requirement..."
codesign --verify --strict --deep "$APP"
codesign --verify -R="$(requirement_for "$APP_IDENTIFIER")" "$APP"

DAEMON="$APP/Contents/MacOS/BrimJobHelper"
DAEMON_PLIST="$APP/Contents/Library/LaunchDaemons/$DAEMON_IDENTIFIER.plist"

if [[ ! -x "$DAEMON" ]]; then
    echo "error: the daemon is missing from the bundle at $DAEMON" >&2
    exit 1
fi
if [[ ! -f "$DAEMON_PLIST" ]]; then
    echo "error: the daemon's launchd plist is missing at $DAEMON_PLIST" >&2
    echo "       Without it SMAppService cannot register the helper." >&2
    exit 1
fi

echo "Checking the daemon satisfies its own requirement..."
codesign --verify -R="$(requirement_for "$DAEMON_IDENTIFIER")" "$DAEMON"

# The plist is what macOS reads to name the background item. A daemon whose
# plist does not point back at the application is the thing that shows up in
# Login Items with no name attached to it.
if ! /usr/libexec/PlistBuddy -c "Print :AssociatedBundleIdentifiers:0" "$DAEMON_PLIST" 2>/dev/null \
    | grep -qx "$APP_IDENTIFIER"; then
    echo "error: $DAEMON_PLIST does not associate the daemon with $APP_IDENTIFIER." >&2
    echo "       macOS would list it as a background item with no name." >&2
    exit 1
fi

echo "Signature and bundle layout check out."

# --- Package ---------------------------------------------------------------

DMG="$BUILD_DIR/Brim-$VERSION.dmg"
echo "Creating $DMG..."
STAGE="$BUILD_DIR/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Brim" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --sign "$APPLE_SIGNING_IDENTITY" "$DMG"

if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    echo "Notarising..."
    xcrun notarytool submit "$DMG" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
else
    echo "Not notarised: people open it once through System Settings, Privacy & Security, Open Anyway."
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo "Release build complete: $DMG"

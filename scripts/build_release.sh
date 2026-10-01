#!/usr/bin/env bash
# Build from a committed snapshot, sign locally, and verify the resulting DMG.
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$PROJECT_ROOT"
./scripts/check_toolchain.sh
if ! git diff --quiet HEAD --; then
    echo 'Commit tracked changes before building a release.' >&2
    exit 1
fi
SOURCE_REVISION=$(git rev-parse HEAD)
TEAM_ID=9LY29YLFG2
BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE="$BUILD_DIR/Brim.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
SOURCE_DIR="$BUILD_DIR/source"

APPLE_SIGNING_IDENTITY=$(security find-identity -v -p codesigning | python3 -c '
import re, sys
team, requested = sys.argv[1:]
for line in sys.stdin:
    match = re.search(r"([A-F0-9]{40}) \"(.+)\"", line)
    if not match:
        continue
    fingerprint, name = match.groups()
    if (name.startswith(("Apple Development:", "Developer ID Application:"))
            and name.endswith(f"({team})") and requested in ("", name, fingerprint)):
        print(name)
        sys.exit(0)
sys.exit(f"No valid Apple signing identity for team {team}. Restore its certificate in Xcode.")
' "$TEAM_ID" "${APPLE_SIGNING_IDENTITY:-}")

rm -rf "$BUILD_DIR"
mkdir -p "$SOURCE_DIR"
git archive HEAD | tar -x -C "$SOURCE_DIR"
VERSION=$(xcodebuild -project "$SOURCE_DIR/Brim.xcodeproj" -scheme brim \
    -configuration Release -showBuildSettings -json | python3 -c '
import json, sys
settings = next(row["buildSettings"] for row in json.load(sys.stdin) if row["target"] == "brim")
print(settings["MARKETING_VERSION"])
')
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "The project version is not a release version: $VERSION" >&2
    exit 1
fi
echo "Building Brim $VERSION from $SOURCE_REVISION."
xcodebuild archive -project "$SOURCE_DIR/Brim.xcodeproj" -scheme brim \
    -configuration Release -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$APPLE_SIGNING_IDENTITY"

if [[ "$APPLE_SIGNING_IDENTITY" == Developer\ ID\ Application* ]]; then
    cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>$TEAM_ID</string>
<key>signingStyle</key><string>manual</string>
</dict></plist>
PLIST
    xcodebuild -exportArchive -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -exportPath "$EXPORT_DIR"
else
    mkdir -p "$EXPORT_DIR"
    ditto "$ARCHIVE/Products/Applications" "$EXPORT_DIR"
fi
apps=("$EXPORT_DIR"/*.app)
[[ ${#apps[@]} == 1 && -d ${apps[0]} ]]
# Xcode does not include arbitrary INFOPLIST_KEY settings in generated plists.
# Add the commit to the exported app and sign that final bundle again.
/usr/libexec/PlistBuddy -c "Add :BrimSourceRevision string $SOURCE_REVISION" "${apps[0]}/Contents/Info.plist"
codesign --force --sign "$APPLE_SIGNING_IDENTITY" \
    --preserve-metadata=identifier,entitlements,flags "${apps[0]}"
DMG="$BUILD_DIR/Brim-$VERSION.dmg"
mkdir -p "$BUILD_DIR/dmg"
ditto "${apps[0]}" "$BUILD_DIR/dmg/$(basename "${apps[0]}")"
ln -s /Applications "$BUILD_DIR/dmg/Applications"
hdiutil create -volname Brim -srcfolder "$BUILD_DIR/dmg" -ov -format UDZO "$DMG"
codesign --force --sign "$APPLE_SIGNING_IDENTITY" "$DMG"

if [[ -n ${APPLE_ID:-} && -n ${APPLE_APP_SPECIFIC_PASSWORD:-} && -n ${APPLE_TEAM_ID:-} ]]; then
    xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
else
    echo 'This build is signed and not notarised. People open it through Privacy & Security, Open Anyway.'
fi
(cd "$BUILD_DIR" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
./scripts/verify_release.sh "v$VERSION" "$BUILD_DIR" "$SOURCE_REVISION"
echo "Release package: $DMG"

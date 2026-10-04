#!/usr/bin/env bash
# Check the package without launching the app or installing its helper.
set -euo pipefail

if [[ $# != 3 ]]; then
    echo 'Usage: verify_release.sh <tag> <asset-directory> <source-commit>' >&2
    exit 1
fi
tag=$1
assets=$2
commit=$3
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ || ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo 'Expected a version tag and a full source commit.' >&2
    exit 1
fi
version=${tag#v}
dmg="$assets/Brim-$version.dmg"
checksum="$dmg.sha256"

python3 - "$dmg" "$checksum" <<'CHECKSUM'
import hashlib
from pathlib import Path
import sys

dmg, sidecar = map(Path, sys.argv[1:])
if not dmg.is_file() or not sidecar.is_file():
    sys.exit('The DMG and its checksum are both required.')
try:
    expected, name = sidecar.read_text().strip().split(maxsplit=1)
except ValueError:
    sys.exit('The checksum file must contain one hash and one filename.')
if name != dmg.name:
    sys.exit('The checksum must name the DMG without an absolute path.')
digest = hashlib.sha256()
with dmg.open('rb') as contents:
    for block in iter(lambda: contents.read(1024 * 1024), b''):
        digest.update(block)
if digest.hexdigest() != expected:
    sys.exit('The DMG checksum does not match.')
CHECKSUM

team=9LY29YLFG2
app_identifier=com.sabharishhh.brim
helper_identifier=com.sabharishhh.brim.jobhelper
requirement_for() {
    printf 'anchor apple generic and identifier "%s" and certificate leaf[subject.OU] = "%s"\n' "$1" "$team"
}
codesign --verify --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$team\"" "$dmg"

mount=$(mktemp -d)
cleanup() {
    hdiutil detach "$mount" -quiet >/dev/null 2>&1 || true
    rmdir "$mount" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mount" -quiet
apps=("$mount"/*.app)
if [[ ${#apps[@]} != 1 || ! -d ${apps[0]} ]]; then
    echo 'The DMG must contain one application bundle.' >&2
    exit 1
fi
app=${apps[0]}
codesign --verify --deep --strict -R="$(requirement_for "$app_identifier")" "$app"
helper="$app/Contents/MacOS/BrimJobHelper"
plist="$app/Contents/Library/LaunchDaemons/$helper_identifier.plist"
[[ -x "$helper" && -f "$plist" ]]
codesign --verify --strict -R="$(requirement_for "$helper_identifier")" "$helper"
[[ $(/usr/libexec/PlistBuddy -c 'Print :AssociatedBundleIdentifiers:0' "$plist") == "$app_identifier" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$plist") == 'Contents/MacOS/BrimJobHelper' ]]
actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
actual_commit=$(/usr/libexec/PlistBuddy -c 'Print :BrimSourceRevision' "$app/Contents/Info.plist")
if [[ "$actual_version" != "$version" || "$actual_commit" != "$commit" ]]; then
    echo "The package contains version $actual_version from $actual_commit, expected $version from $commit." >&2
    exit 1
fi
echo "Verified Brim $version from $commit, including its helper and checksum."

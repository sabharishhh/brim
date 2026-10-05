#!/bin/sh
# Lists every copy of Brim on this Mac except the one being worked on, and
# with --remove deletes them and retracts their Launch Services records.
#
# Builds piled up across worktrees, release rehearsals and test runs: four
# Xcode build folders, two AppBuild folders, a Release build beside the
# Debug one, the installed 1.0 in /Applications and 41 test Trash folders,
# 85 Launch Services records in all. Opening "Brim" could start any of
# them, and a fix looked absent because an old build was the one running.
#
#   scripts/stale_builds.sh <the build to keep>             list
#   scripts/stale_builds.sh <the build to keep> --remove    remove
#
# Build folders and test leftovers are deleted. A bundle in /Applications
# goes to the Trash, so it can be put back. A record whose files are gone
# cannot be retracted, because Launch Services has nothing to scan, so a
# stub bundle is made at that path, retracted and deleted again.
set -eu

keep="${1:?usage: stale_builds.sh <path to the brim.app to keep> [--remove]}"
remove="${2:-}"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

records() {
    "$lsregister" -dump 2>/dev/null \
        | sed -n 's/^path: *\(.*\) (0x[0-9a-f]*)$/\1/p' \
        | grep -iE '/(brim|BrimHarness[^/]*|BrimTestApp[^/]*)\.app$|brim[^/]*fixture.*\.app(ex)?$' \
        | sort -u
}

stale=$(records | grep -vxF "$keep" || true)
folders=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -iname 'brim*' 2>/dev/null \
    | grep -vF "$(dirname "$(dirname "$(dirname "$(dirname "$keep")")")")" || true)
leftovers=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'brim-test-trash-*' 2>/dev/null || true)

[ -n "$stale$folders$leftovers" ] || { echo "Only $keep"; exit 0; }
printf '%s\n' "$stale" "$folders" "$leftovers" | sed '/^$/d'
[ "$remove" = "--remove" ] || exit 0

printf '%s\n' "$stale" | while IFS= read -r app; do
    [ -n "$app" ] || continue
    if [ ! -e "$app" ]; then
        mkdir -p "$app/Contents"
        printf '<plist version="1.0"><dict><key>CFBundlePackageType</key><string>APPL</string></dict></plist>' \
            > "$app/Contents/Info.plist"
        "$lsregister" -u "$app" >/dev/null 2>&1 || true
        rm -rf "$app"
        rmdir -p "$(dirname "$app")" 2>/dev/null || true
        continue
    fi
    "$lsregister" -u "$app" 2>/dev/null || true
    case "$app" in
        /Applications/*) [ -e "$app" ] && /usr/bin/osascript -e \
            "tell application \"Finder\" to delete POSIX file \"$app\"" >/dev/null ;;
        */DerivedData/*|*/.build/*|*/build/*|/private/var/folders/*|/private/tmp/*) rm -rf "$app" ;;
    esac
done
printf '%s\n' "$folders" "$leftovers" | while IFS= read -r dir; do
    [ -n "$dir" ] && rm -rf "$dir"
done
echo "Left: $(records | tr '\n' ' ')"

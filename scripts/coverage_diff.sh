#!/usr/bin/env bash
#
# Measures what a removal left behind, across any app, without trusting
# Brim's own idea of where apps keep things.
#
#   scripts/coverage_diff.sh snapshot before     # before installing the app
#   ... install it, use it, quit it, remove it with Brim ...
#   scripts/coverage_diff.sh snapshot after
#   scripts/coverage_diff.sh diff before after   # what is new and still there
#
# A snapshot lists files and folders in the places software writes, a few
# levels deep, plus loaded launch jobs and installer receipts. The diff
# shows only the top-most new path of each new tree, with its size, so a
# 40,000-file cache reads as one line. Run it in a spare user account:
# anything else running while you test shows up in the diff too.
#
# Reads only. Nothing here removes anything.

set -euo pipefail

store="${BRIM_COVERAGE_DIR:-$HOME/Library/Caches/com.sabharishhh.brim/Coverage}"
mkdir -p "$store"

list() {
    {
        find "$HOME/Library" -maxdepth 4 -not -path "$HOME/Library/Caches/com.sabharishhh.brim/*" 2>/dev/null || true
        find "$HOME" -maxdepth 3 -path "$HOME/.*" -not -path "$HOME/.Trash*" 2>/dev/null || true
        find /Library /Users/Shared /usr/local /opt/homebrew/Caskroom -maxdepth 3 2>/dev/null || true
        find /Applications -maxdepth 1 2>/dev/null || true
        for dir in "$(getconf DARWIN_USER_CACHE_DIR)" "$(getconf DARWIN_USER_TEMP_DIR)"; do
            find "$dir" -maxdepth 2 2>/dev/null || true
        done
    } | sort -u
}

case "${1:-}" in
snapshot)
    name="${2:?snapshot needs a name}"
    list > "$store/$name.files"
    launchctl list 2>/dev/null | awk 'NR > 1 { print $3 }' | sort -u > "$store/$name.jobs"
    pkgutil --pkgs 2>/dev/null | sort -u > "$store/$name.receipts"
    echo "Saved $(wc -l < "$store/$name.files" | tr -d ' ') paths as $name."
    ;;
diff)
    before="${2:?diff needs two names}"; after="${3:?diff needs two names}"
    echo "Files and folders that are new and still there:"
    comm -13 "$store/$before.files" "$store/$after.files" | awk '
        { if (last != "" && index($0, last "/") == 1) next; print; last = $0 }' |
        while IFS= read -r path; do
            [ -e "$path" ] || continue
            printf "%8s  %s\n" "$(du -sh "$path" 2>/dev/null | cut -f1)" "$path"
        done
    echo
    echo "Launch jobs that are new and still loaded:"
    comm -13 "$store/$before.jobs" "$store/$after.jobs" | sed 's/^/  /'
    echo
    echo "Installer receipts that are new and still recorded:"
    comm -13 "$store/$before.receipts" "$store/$after.receipts" | sed 's/^/  /'
    ;;
*)
    sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac

#!/usr/bin/env bash
set -euo pipefail

xcodebuild -version
swift --version
sdk=$(xcrun --sdk macosx --show-sdk-version)
xcode=$(xcodebuild -version | awk 'NR == 1 {print $2}')
if [[ ${xcode%%.*} != 27 || ${sdk%%.*} != 27 ]]; then
    echo "Brim needs Xcode 27 and the macOS 27 SDK. Found Xcode $xcode, SDK $sdk." >&2
    echo 'Select Xcode 27 with xcode-select or DEVELOPER_DIR and try again.' >&2
    exit 1
fi

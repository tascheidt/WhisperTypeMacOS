#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"

for script in Scripts/*.sh; do sh -n "$script"; done
"$project_root/Scripts/fetch-model.sh" --verify-only
swift test
xcodebuild \
    -project WhisperType.xcodeproj \
    -scheme WhisperType \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    CODE_SIGNING_ALLOWED=NO \
    build

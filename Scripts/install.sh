#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_app="$project_root/Dist/WhisperType.app"
destination_app="/Applications/WhisperType.app"

if [ "${WHISPERTYPE_SKIP_BUILD:-0}" != "1" ]; then
    "$project_root/Scripts/build-release.sh"
fi
test -d "$source_app"

osascript -e 'tell application id "com.tsadvisory.whispertype.WhisperType" to quit' 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! pgrep -f '/WhisperType.app/Contents/MacOS/WhisperType' >/dev/null 2>&1; then break; fi
    sleep 0.2
done
if pgrep -f '/WhisperType.app/Contents/MacOS/WhisperType' >/dev/null 2>&1; then
    echo "WhisperType is still running. Quit it before installing." >&2
    exit 1
fi

previous_app=""
if [ -d "$destination_app" ]; then
    previous_app="/Applications/.WhisperType.previous.$$.app"
    mv "$destination_app" "$previous_app"
fi

if ! ditto "$source_app" "$destination_app" || ! codesign --verify --deep --strict "$destination_app"; then
    rm -rf "$destination_app"
    if [ -n "$previous_app" ] && [ -d "$previous_app" ]; then mv "$previous_app" "$destination_app"; fi
    exit 1
fi
if [ -n "$previous_app" ] && [ -d "$previous_app" ]; then rm -rf "$previous_app"; fi
xattr -dr com.apple.quarantine "$destination_app" 2>/dev/null || true
open "$destination_app"

echo "Installed and opened $destination_app"

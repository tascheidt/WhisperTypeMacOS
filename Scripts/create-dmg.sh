#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_path="$project_root/Dist/WhisperType.app"
dmg_path="$project_root/Dist/WhisperType-2.0.0.dmg"

if [ ! -d "$app_path" ]; then
    "$project_root/Scripts/build-release.sh"
fi

staging_dir=$(mktemp -d /tmp/whispertype-dmg.XXXXXX)
cleanup() { rm -rf "$staging_dir"; }
trap cleanup EXIT INT TERM

ditto "$app_path" "$staging_dir/WhisperType.app"
ln -s /Applications "$staging_dir/Applications"
rm -f "$dmg_path"
hdiutil create -volname WhisperType -srcfolder "$staging_dir" -ov -format UDZO "$dmg_path"

echo "Created $dmg_path"

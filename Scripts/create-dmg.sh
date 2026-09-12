#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_path="$project_root/Dist/WhisperType.app"

if [ "${WHISPERTYPE_SKIP_BUILD:-0}" != "1" ]; then
    "$project_root/Scripts/build-release.sh"
fi
test -d "$app_path"

version=$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")
dmg_path="$project_root/Dist/WhisperType-$version.dmg"
volume_name="WhisperType Installer"
staging_dir=$(mktemp -d /tmp/whispertype-dmg-stage.XXXXXX)
mount_dir="/Volumes/$volume_name"
working_dmg=$(mktemp /tmp/whispertype-dmg.XXXXXX.dmg)
attached=""

if [ -e "$mount_dir" ]; then
    echo "Eject the existing '$volume_name' volume before building the DMG." >&2
    exit 1
fi

cleanup() {
    if [ -n "$attached" ]; then hdiutil detach "$mount_dir" -quiet 2>/dev/null || true; fi
    rm -rf "$staging_dir"
    rm -f "$working_dmg"
}
trap cleanup EXIT INT TERM

ditto "$app_path" "$staging_dir/WhisperType.app"
ln -s /Applications "$staging_dir/Applications"
mkdir -p "$staging_dir/.background"
swift "$project_root/Scripts/generate-dmg-background.swift" "$staging_dir/.background/background.png"
if [ -f "$app_path/Contents/Resources/AppIcon.icns" ]; then
    cp "$app_path/Contents/Resources/AppIcon.icns" "$staging_dir/.VolumeIcon.icns"
fi

hdiutil create -volname "$volume_name" -srcfolder "$staging_dir" -ov -format UDRW "$working_dmg" >/dev/null
hdiutil attach "$working_dmg" -mountpoint "$mount_dir" -noverify >/dev/null
attached="yes"

if command -v SetFile >/dev/null 2>&1; then SetFile -a C "$mount_dir"; fi

osascript - "$volume_name" "$mount_dir" <<'APPLESCRIPT'
on run argv
    set volumeName to item 1 of argv
    set mountPath to item 2 of argv
    set backgroundFile to POSIX file (mountPath & "/.background/background.png") as alias
    tell application "Finder"
        tell disk volumeName
            open
            set current view of container window to icon view
            tell container window
                set toolbar visible to false
                set statusbar visible to false
                set pathbar visible to false
                set sidebar width to 0
                set bounds to {120, 120, 840, 580}
            end tell
            tell icon view options of container window
                set arrangement to not arranged
                set icon size to 104
                set text size to 13
                set background picture to backgroundFile
            end tell
            set position of item "WhisperType.app" to {180, 242}
            set position of item "Applications" to {540, 242}
            update without registering applications
            delay 2
            close
        end tell
    end tell
end run
APPLESCRIPT

sync
hdiutil detach "$mount_dir" -quiet
attached=""
rm -f "$dmg_path"
hdiutil convert "$working_dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg_path" >/dev/null
hdiutil verify "$dmg_path" >/dev/null

echo "Created and verified $dmg_path"

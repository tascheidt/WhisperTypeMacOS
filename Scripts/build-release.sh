#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived_data="$project_root/.derived-data"
dist_dir="$project_root/Dist"
source_app="$derived_data/Build/Products/Release/WhisperType.app"
output_app="$dist_dir/WhisperType.app"
bundle_identifier="com.tsadvisory.whispertype.WhisperType"
signing_identity="${WHISPERTYPE_SIGNING_IDENTITY:-}"

if [ -z "$signing_identity" ]; then
    signing_identity=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/Developer ID Application/ { print $2; exit }')
fi
if [ -z "$signing_identity" ]; then
    signing_identity=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/Apple Development/ { print $2; exit }')
fi
if [ -z "$signing_identity" ]; then signing_identity="-"; fi

timestamp_option="--timestamp=none"
case "$signing_identity" in
    "Developer ID Application"*) timestamp_option="--timestamp" ;;
esac

mkdir -p "$dist_dir"

"$project_root/Scripts/fetch-model.sh"

xcodebuild \
    -project "$project_root/WhisperType.xcodeproj" \
    -scheme WhisperType \
    -configuration Release \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build

if [ ! -d "$source_app" ]; then
    echo "Release build was not produced at $source_app" >&2
    exit 1
fi

rm -rf "$output_app"
ditto "$source_app" "$output_app"
chmod 755 \
    "$output_app/Contents/MacOS/WhisperType" \
    "$output_app/Contents/Resources/whisper-cli" \
    "$output_app/Contents/Resources/whisper-server" \
    "$output_app/Contents/Resources/engine-watchdog.sh"

codesign --force --sign "$signing_identity" "$timestamp_option" --options runtime "$output_app/Contents/Resources/whisper-cli"
codesign --force --sign "$signing_identity" "$timestamp_option" --options runtime "$output_app/Contents/Resources/whisper-server"
if [ "$signing_identity" = "-" ]; then
    codesign --force --sign - --timestamp=none --options runtime \
        --requirements "=designated => identifier \"$bundle_identifier\"" \
        --entitlements "$project_root/WhisperType/WhisperType.entitlements" \
        "$output_app"
else
    codesign --force --sign "$signing_identity" "$timestamp_option" --options runtime \
        --entitlements "$project_root/WhisperType/WhisperType.entitlements" \
        "$output_app"
fi
codesign --verify --deep --strict --verbose=2 "$output_app"

echo "Built $output_app using signing identity: $signing_identity"

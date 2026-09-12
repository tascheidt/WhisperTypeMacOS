#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_path="${1:-$project_root/Dist/WhisperType.app}"
resources="$app_path/Contents/Resources"

test -x "$app_path/Contents/MacOS/WhisperType"
test -x "$resources/whisper-cli"
test -x "$resources/whisper-server"
test -x "$resources/engine-watchdog.sh"
test -f "$resources/ggml-large-v3-turbo-q5_0.bin"

plutil -lint "$app_path/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app_path"
test "$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")" = "com.tsadvisory.whispertype.WhisperType"
test "$(plutil -extract LSUIElement raw "$app_path/Contents/Info.plist")" = "false"
test -n "$(plutil -extract NSMicrophoneUsageDescription raw "$app_path/Contents/Info.plist")"
test "$(lipo -archs "$app_path/Contents/MacOS/WhisperType")" = "arm64"

entitlements=$(codesign -d --entitlements :- "$app_path" 2>/dev/null)
if ! echo "$entitlements" | grep -q '<key>com.apple.security.device.audio-input</key><true/>'; then
    echo "The signed app is missing its required audio-input entitlement." >&2
    exit 1
fi

designated_requirement=$(codesign -d -r- "$app_path" 2>&1)
if echo "$designated_requirement" | grep -q 'cdhash'; then
    echo "The app has a CDHash-only designated requirement; permissions would break after an update." >&2
    exit 1
fi
if ! echo "$designated_requirement" | grep -q 'identifier "com.tsadvisory.whispertype.WhisperType"'; then
    echo "The app’s designated requirement does not protect the release bundle identifier." >&2
    exit 1
fi

if otool -L "$resources/whisper-cli" "$resources/whisper-server" | grep -E '/opt/homebrew|/usr/local|@rpath'; then
    echo "A bundled speech executable has a non-system dynamic dependency." >&2
    exit 1
fi

model_hash=$(shasum -a 256 "$resources/ggml-large-v3-turbo-q5_0.bin" | awk '{print $1}')
expected_hash="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
if [ "$model_hash" != "$expected_hash" ]; then
    echo "Speech model checksum mismatch." >&2
    exit 1
fi

echo "Verification passed for $app_path"

#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$project_root/Scripts/model-metadata.sh"
app_path="${1:-$project_root/Dist/WhisperType.app}"
resources="$app_path/Contents/Resources"

test -x "$app_path/Contents/MacOS/WhisperType"
test -x "$resources/whisper-cli"
test -x "$resources/whisper-server"
test -x "$resources/engine-watchdog.sh"
test -f "$resources/$model_file_name"

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

model_size=$(stat -f %z "$resources/$model_file_name")
if [ "$model_size" != "$model_expected_size" ]; then
    echo "Speech model size mismatch ($model_size bytes; expected $model_expected_size)." >&2
    exit 1
fi

model_hash=$(shasum -a 256 "$resources/$model_file_name" | awk '{print $1}')
if [ "$model_hash" != "$model_expected_sha256" ]; then
    echo "Speech model checksum mismatch." >&2
    exit 1
fi

smoke_log=$(mktemp /tmp/whispertype-model-smoke.XXXXXX)
cleanup() { rm -f "$smoke_log"; }
trap cleanup EXIT INT TERM
set +e
"$resources/whisper-cli" \
    --model "$resources/$model_file_name" \
    --file /dev/null \
    --no-gpu \
    --no-flash-attn \
    --no-prints >"$smoke_log" 2>&1
smoke_exit=$?
set -e
if grep -Eqi 'failed to initialize whisper context|failed to load model' "$smoke_log"; then
    echo "The bundled speech engine could not initialize the bundled model." >&2
    sed -n '1,120p' "$smoke_log" >&2
    exit 1
fi
if ! grep -q "failed to read audio file '/dev/null'" "$smoke_log"; then
    echo "The speech model load smoke test returned an unexpected result (exit $smoke_exit)." >&2
    sed -n '1,120p' "$smoke_log" >&2
    exit 1
fi

echo "Verification passed for $app_path"

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

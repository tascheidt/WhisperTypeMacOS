#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$project_root/Scripts/model-metadata.sh"

model_relative_path="Resources/$model_file_name"
model_path="$project_root/$model_relative_path"
mode="fetch"

case "${1:-}" in
    "") ;;
    --verify-only) mode="verify" ;;
    *)
        echo "Usage: $0 [--verify-only]" >&2
        exit 2
        ;;
esac

model_is_valid() {
    [ -f "$model_path" ] || return 1
    [ "$(stat -f %z "$model_path")" = "$model_expected_size" ] || return 1
    [ "$(shasum -a 256 "$model_path" | awk '{print $1}')" = "$model_expected_sha256" ]
}

describe_problem() {
    if [ ! -f "$model_path" ]; then
        echo "The speech model is missing at $model_path." >&2
        return
    fi

    actual_size=$(stat -f %z "$model_path")
    if [ "$actual_size" -lt 1024 ]; then
        echo "The speech model is only $actual_size bytes and appears to be a Git LFS pointer." >&2
    elif [ "$actual_size" != "$model_expected_size" ]; then
        echo "The speech model is $actual_size bytes; expected $model_expected_size." >&2
    else
        echo "The speech model checksum does not match the release manifest." >&2
    fi
}

if model_is_valid; then
    echo "Speech model verified: $model_file_name"
    exit 0
fi

describe_problem
if [ "$mode" = "verify" ]; then
    echo "Run ./Scripts/fetch-model.sh to retrieve the verified model." >&2
    exit 1
fi

if command -v git-lfs >/dev/null 2>&1; then
    echo "Attempting to retrieve the speech model with Git LFS..."
    git -C "$project_root" lfs pull --include="$model_relative_path" --exclude="" || true
    if model_is_valid; then
        echo "Speech model downloaded and verified with Git LFS."
        exit 0
    fi
fi

echo "Downloading the speech model from the pinned upstream source..."
temporary_model=$(mktemp "$model_path.download.XXXXXX")
cleanup() { rm -f "$temporary_model"; }
trap cleanup EXIT INT TERM

curl \
    --fail \
    --location \
    --retry 3 \
    --retry-delay 2 \
    --connect-timeout 20 \
    --output "$temporary_model" \
    "$model_download_url"

temporary_size=$(stat -f %z "$temporary_model")
if [ "$temporary_size" != "$model_expected_size" ]; then
    echo "Downloaded speech model is $temporary_size bytes; expected $model_expected_size." >&2
    exit 1
fi

temporary_hash=$(shasum -a 256 "$temporary_model" | awk '{print $1}')
if [ "$temporary_hash" != "$model_expected_sha256" ]; then
    echo "Downloaded speech model failed its checksum." >&2
    exit 1
fi

mv "$temporary_model" "$model_path"
trap - EXIT INT TERM
echo "Speech model downloaded and verified."

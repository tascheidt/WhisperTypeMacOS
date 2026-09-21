#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
model_path="$project_root/Resources/ggml-large-v3-turbo-q5_0.bin"
expected_hash="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
download_url="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"

needs_fetch=0

if [ ! -f "$model_path" ]; then
    echo "Speech model not found at $model_path"
    needs_fetch=1
elif [ "$(wc -c < "$model_path" | tr -d ' ')" -lt 1000000 ]; then
    echo "Speech model is a Git LFS pointer or incomplete (< 1 MB)."
    needs_fetch=1
else
    current_hash=$(shasum -a 256 "$model_path" | awk '{print $1}')
    if [ "$current_hash" != "$expected_hash" ]; then
        echo "Speech model checksum mismatch (expected $expected_hash, got $current_hash)."
        needs_fetch=1
    fi
fi

if [ "$needs_fetch" -eq 1 ]; then
    echo "Fetching Whisper large-v3-turbo Q5 speech model (~547 MB)..."
    fetched=0

    # Try Git LFS if available
    if command -v git-lfs >/dev/null 2>&1; then
        echo "Attempting download via git lfs..."
        if git -C "$project_root" lfs pull --include="Resources/ggml-large-v3-turbo-q5_0.bin"; then
            check_hash=$(shasum -a 256 "$model_path" | awk '{print $1}')
            if [ "$check_hash" = "$expected_hash" ]; then
                fetched=1
                echo "Model successfully fetched via Git LFS."
            fi
        fi
    fi

    # Fallback to curl download if Git LFS was unavailable or did not fetch the file
    if [ "$fetched" -eq 0 ]; then
        echo "Downloading model via curl from Hugging Face..."
        temp_model="$model_path.download.$$"
        curl -L -f -# -o "$temp_model" "$download_url"

        actual_hash=$(shasum -a 256 "$temp_model" | awk '{print $1}')
        if [ "$actual_hash" != "$expected_hash" ]; then
            echo "Error: Downloaded speech model checksum mismatch ($actual_hash vs $expected_hash)" >&2
            rm -f "$temp_model"
            exit 1
        fi
        mv "$temp_model" "$model_path"
        echo "Model downloaded and verified successfully."
    fi
else
    echo "Speech model is verified and up-to-date."
fi

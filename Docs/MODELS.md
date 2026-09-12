# Speech and writing models

## Bundled speech model

- Model: Whisper large-v3-turbo, Q5_0 quantization
- File: `Resources/ggml-large-v3-turbo-q5_0.bin`
- SHA-256: `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`
- Languages: multilingual Whisper vocabulary (100 language IDs in the bundled engine)
- Source: <https://huggingface.co/ggerganov/whisper.cpp>

This replaces the old English-only base model. Q5 quantization keeps the app reasonably sized while retaining the large-v3-turbo architecture's accuracy and speed.

## Bundled inference engine

- whisper.cpp commit: `c44b60b8053bbf2a5c1e014f11323fb3f2485177`
- Engine-reported version: `1.9.3-dev`
- Build: static, arm64, macOS 14 minimum, Metal, embedded Metal shaders, Accelerate, flash attention

`whisper-server` keeps the model warm for low-latency repeat dictations. `whisper-cli` is retained as a reliable fallback. Neither binary depends on Homebrew.

## Optional writing refinement

Automatic mode uses Apple's on-device Foundation Models framework when it is available, with deterministic local formatting as the universal fallback. OpenRouter is opt-in and defaults to its `~openai/gpt-latest` alias so the user can receive model upgrades without an app update; any valid OpenRouter model slug may be entered in Settings.

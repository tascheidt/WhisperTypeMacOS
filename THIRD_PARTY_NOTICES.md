# Third-party notices

WhisperType bundles the following open-source components and model weights:

- **whisper.cpp**, copyright Georgi Gerganov and contributors, licensed under the MIT License. Source: <https://github.com/ggml-org/whisper.cpp>
- **Whisper large-v3-turbo model weights**, derived from OpenAI Whisper, licensed under the MIT License. Source: <https://huggingface.co/ggerganov/whisper.cpp>

The bundled `whisper-cli` is built from whisper.cpp with Metal and Accelerate support and with its Metal shaders embedded. It does not depend on Homebrew or non-system dynamic libraries.

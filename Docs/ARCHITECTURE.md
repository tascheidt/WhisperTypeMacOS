# WhisperType architecture

WhisperType is a local-first macOS menu-bar application. Version 2 replaces the original 654-line application delegate with a small coordinator and explicit services.

## Runtime flow

1. `HotkeyManager` observes the global shortcut (Fn by default) through a Core Graphics event tap.
2. `ContextService` captures the target application and a bounded amount of nearby, non-secure text.
3. `AudioRecordingService` records a 16 kHz mono WAV and publishes meter levels to the non-activating overlay.
4. `TranscriptionService` sends the WAV to a private `127.0.0.1` whisper.cpp process. The quantized large-v3-turbo model remains warm between dictations. The CLI is a fallback if the warm service cannot start.
5. `TextProcessingService` applies spoken formatting, backtracking, filler cleanup, personal dictionary corrections, snippets, and cursor-aware spacing.
6. `AIRefinementService` optionally refines the text with Apple Intelligence or OpenRouter. Automatic mode never requires a network account and falls back to local rules.
7. `TextInsertionService` first uses the selected-text Accessibility attribute. If the target does not support it, the service pastes while preserving and restoring the existing clipboard.
8. `AppDataStore` persists settings, statistics, history, dictionary, snippets, and scratchpad data.

## Process safety

The speech server binds only to loopback on a randomized high port. `engine-watchdog.sh` monitors the app process and terminates the speech server if the app exits unexpectedly. Both speech executables are statically linked except for Apple system frameworks.

## Privacy boundaries

- Recorded audio and local transcripts do not leave the Mac in Local Rules or Apple Intelligence mode.
- Secure text fields are excluded from context collection.
- OpenRouter receives text only when the user explicitly selects that provider.
- The OpenRouter key is stored as a generic password in macOS Keychain.
- Temporary audio is deleted after processing by default.

## Main source areas

- `WhisperType/App`: lifecycle coordination and state machine
- `WhisperType/Core`: persistent models and preferences
- `WhisperType/Services`: permissions, hotkeys, audio, transcription, refinement, context, and insertion
- `WhisperType/UI`: onboarding, hub, settings, and dictation overlay
- `Tests`: deterministic text-pipeline tests
- `Scripts`: build, verify, DMG, and local installation workflows

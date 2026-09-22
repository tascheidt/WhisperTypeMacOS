# WhisperType architecture

WhisperType is a local-first macOS menu-bar application. Version 2 replaces the original 654-line application delegate with a small coordinator and explicit services.

## Runtime flow

1. `HotkeyManager` observes the global shortcut (Fn by default) through a Core Graphics event tap.
2. `ContextService` captures the target application and a bounded amount of nearby, non-secure text.
3. `AudioRecordingService` records a 16 kHz mono WAV and publishes meter levels to the non-activating overlay.
4. `TranscriptionService` verifies the bundled model’s exact byte count and SHA-256 before loading it, then sends the WAV to a private `127.0.0.1` whisper.cpp process. The quantized large-v3-turbo model remains warm between dictations. Engine startup progresses through Metal with flash attention, Metal compatibility mode, and CPU compatibility mode. The self-contained CLI repeats the same fallback sequence if the warm service cannot be used.
5. `TextProcessingService` applies spoken formatting, backtracking, filler cleanup, personal dictionary corrections, snippets, and cursor-aware spacing.
6. `AIRefinementService` optionally refines the text with Apple Intelligence or OpenRouter. Automatic mode never requires a network account and falls back to local rules.
7. `TextInsertionService` first uses the selected-text Accessibility attribute. If the target does not support it, the service pastes while preserving and restoring the existing clipboard.
8. `AppDataStore` persists settings, statistics, history, dictionary, snippets, and scratchpad data.

## Installation and permissions

`InstallationService` detects read-only disk images and App Translocation before the application controller starts. A mounted copy presents a native move-to-Applications prompt and never requests privacy permissions. Release builds use a stable designated requirement when a Developer ID is unavailable, preventing a rebuilt binary from appearing enabled in System Settings while failing the runtime trust check.

Debug builds use a separate bundle identifier so Xcode runs cannot overwrite or pollute the installed release app’s TCC records.

`PermissionService` models first-time, granted, denied, and restricted microphone states. It requests access only from the first-time state, opens the correct Privacy & Security pane after a denial, polls permission state while the app is running, and refreshes immediately whenever the app becomes active. Accessibility changes therefore propagate to SwiftUI and the global hotkey manager without a restart.

## Process safety

The speech server binds only to loopback on a randomized high port. `engine-watchdog.sh` monitors the app process and terminates the speech server if the app exits unexpectedly. Both speech executables are statically linked except for Apple system frameworks.

Speech-engine output is written to `~/Library/Logs/WhisperType/engine.log`, capped to a small rolling tail, and can be revealed from Settings. Logs contain engine diagnostics, not microphone audio or transcript text.

## Release integrity

`Scripts/model-metadata.sh` is the shared release manifest for the model filename, byte count, SHA-256, and pinned download URL. `fetch-model.sh` accepts only the manifested model and can retrieve it with Git LFS or a checksum-verified direct download. `build-release.sh` runs that preparation before invoking Xcode. `verify.sh` checks the signed application and proves that the bundled CLI can initialize the model in CPU compatibility mode. `create-dmg.sh` mounts the final compressed image and repeats the complete verification against the app users will install. `install.sh` verifies both its source and the installed copy, preserving the previous application if validation fails.

## Privacy boundaries

- Recorded audio and local transcripts do not leave the Mac in Local Rules or Apple Intelligence mode.
- Secure text fields are excluded from context collection.
- OpenRouter receives text only when the user explicitly selects that provider.
- The OpenRouter key is stored as a generic password in macOS Keychain.
- Temporary audio is deleted after processing by default.

## Main source areas

- `WhisperType/App`: lifecycle coordination and state machine
- `WhisperType/Core`: persistent models and preferences
- `WhisperType/Services`: installation, permissions, hotkeys, audio, transcription, refinement, context, and insertion
- `WhisperType/UI`: onboarding, hub, settings, and dictation overlay
- `Tests`: deterministic text-pipeline tests
- `Scripts`: build, verify, DMG, and local installation workflows

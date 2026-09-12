# WhisperType 2

WhisperType is a local-first macOS dictation app that turns natural speech into polished text in any application. Hold **Fn**, speak, and release to insert. Double-tap Fn for hands-free mode.

The app ships with its speech engine and model. Ollama, Homebrew, Python, and an internet connection are not required.

## What is included

- Configurable system-wide push-to-talk shortcut, defaulting to **Fn**
- Double-tap hands-free dictation and Escape-to-cancel
- Fast, private, multilingual transcription with Whisper large-v3-turbo Q5 on Metal
- A warm local engine for low-latency repeat dictations, plus a self-contained CLI fallback
- Smart formatting: punctuation commands, paragraphs, bullets, filler removal, and “scratch that” backtracking
- Context-aware capitalization and spacing using the active text field
- Personal dictionary with recognition hints and correction rules
- Spoken snippet expansion
- Automatic, polished, casual, concise, verbatim, and developer writing styles
- Optional on-device Apple Intelligence refinement on supported Macs
- Optional OpenRouter refinement with the API key protected by macOS Keychain
- Voice command shortcut (Fn + Control by default), including local Undo, Copy, Paste, Select All, and AI transformations of selected text
- Clipboard-preserving text insertion with Accessibility and paste fallbacks
- Searchable transcript history, dictation statistics, and a private scratchpad
- Guided permission onboarding, menu-bar controls, live waveform overlay, sounds, and Launch at Login
- Export/import backup, release build, DMG, local install, and verification scripts

## Requirements

- Apple Silicon Mac
- macOS 14 Sonoma or later
- Approximately 600 MB of disk space for the installed app
- Microphone and Accessibility permissions

## Install on this Mac

From the repository root:

```sh
./Scripts/build-release.sh
./Scripts/install.sh
```

The app is installed at `/Applications/WhisperType.app` and opened. The first launch walks through the two required permissions. If an older `/Applications/WhisperType.app` exists, the installer moves it to a timestamped backup beside the new app.

To create a drag-to-Applications disk image:

```sh
./Scripts/create-dmg.sh
```

The result is `Dist/WhisperType-2.0.0.dmg`.

The release is ad-hoc signed for local installation. Distributing it to other Macs without a Gatekeeper warning requires an Apple Developer ID certificate and notarization.

## Use

1. Put the cursor anywhere you can type.
2. Hold **Fn** and speak naturally.
3. Release Fn. WhisperType transcribes, formats, and inserts the result.

Double-tap Fn to keep recording without holding the key; press Fn again to finish. Press Escape to cancel. The shortcut can be changed in Settings, including modifier-only shortcuts.

For commands, select text, hold **Fn + Control**, and say an instruction such as “make this more concise.” Undo, Copy, Paste, Select All, and Paste Last work locally. Free-form transformations use Apple Intelligence or OpenRouter.

## Refinement and privacy

The default **Automatic** provider uses Apple Intelligence when available and otherwise uses the built-in deterministic formatter. It never requires an API key.

OpenRouter is opt-in. Paste an API key into Settings; it is stored in Keychain, not UserDefaults or the repository. Only transcript text and a small amount of cursor context are sent when OpenRouter is selected. Secure text fields are excluded from context collection.

Audio is temporary and deleted after processing by default. Enable audio retention in Settings only if desired.

## Development

Run all core tests and compile the app:

```sh
./Scripts/test.sh
```

Verify a packaged app:

```sh
./Scripts/verify.sh
```

Architecture and model provenance are documented in [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) and [Docs/MODELS.md](Docs/MODELS.md). Third-party licenses are summarized in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Troubleshooting

- **Fn does nothing:** Open Settings → Privacy & Security → Accessibility, enable WhisperType, then reopen the app.
- **No recording:** Enable WhisperType under Privacy & Security → Microphone.
- **The first dictation is slow:** The large speech model warms in the background at launch. Later dictations reuse it and are substantially faster.
- **Text is copied but not inserted:** The target app blocked simulated paste. Paste manually with Command-V and verify Accessibility permission.
- **OpenRouter fails:** Confirm the key and model slug in Settings, or switch the provider back to Automatic.

## License

WhisperType source is available under the repository's [MIT License](LICENSE).

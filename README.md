# 🎙️ WhisperType: Speak, Refine, Insert! ✨

![WhisperType Icon Placeholder](https://placehold.co/100x100/7B68EE/FFFFFF?text=WT)

**WhisperType** is a macOS menu bar utility designed to streamline your writing process. Simply hold down a hotkey, speak your thoughts, and release. WhisperType uses local transcription via Whisper.cpp, refines the text using a local Ollama language model, and then inserts the polished text into your active application window.

---

## 🤔 What it Does

1.  **👂 Listen:** Waits silently in the menu bar for you to press and hold your chosen hotkey.
2.  **🎤 Record:** Records audio directly from your microphone while the hotkey is held down.
3.  **✍️ Transcribe:** Uses a bundled, efficient Whisper.cpp model (`ggml-base.en.bin`) to transcribe the recorded audio locally on your machine.
4.  **🧠 Refine:** Sends the raw transcription to a running Ollama instance (configurable model) with specific instructions to correct grammar, punctuation, and structure, while preserving essential elements like URLs or code.
5.  **⌨️ Insert:** Intelligently inserts the refined text into the currently focused application, attempting direct insertion via Accessibility APIs first, and falling back to simulating typing or pasting for compatibility.

---

## ✨ Features

* **Menu Bar Native:** Lives discreetly in your macOS menu bar.
* **Configurable Hotkey:** Set your preferred key combination via the Preferences menu.
* **Configurable Ollama Model:** Choose any model available to your local Ollama instance via the Preferences menu (populates a dropdown!).
* **Local & Private Transcription:** Audio transcription happens entirely on your device using Whisper.cpp.
* **Local LLM Refinement:** Leverages your own Ollama instance for text polishing, keeping your data local.
* **Intelligent Insertion:** Uses Accessibility first, with typing/paste fallbacks for broader app compatibility.
* **Status Indicators:** Menu bar icon changes to provide feedback (listening, recording, processing, error).

---

## 🚀 Requirements

* **macOS:** Developed and tested on macOS Sonoma (likely compatible with recent versions).
* **Xcode:** Required to build the application.
* **Ollama:** You need Ollama installed and running locally. WhisperType defaults to connecting to `http://localhost:11434`. Download from [ollama.com](https://ollama.com/).
* **Whisper.cpp CLI & Model:**
    * You need the compiled `whisper-cli` executable from the [Whisper.cpp](https://github.com/ggerganov/whisper.cpp) project.
    * You need a compatible GGML model file (e.g., `ggml-base.en.bin`).
    * **IMPORTANT:** These two files (`whisper-cli` and your chosen `.bin` model file, renamed to `ggml-base.en.bin` if necessary) **must be placed inside the Xcode project** (e.g., in a "Resources" group) and **added to the "Copy Bundle Resources" build phase** for your application target. This ensures they are included in the final `.app` bundle.

---

## 🛠️ Setup & Installation

1.  **Clone Repository:**
    ```bash
    git clone [https://github.com/your-username/WhisperType.git](https://github.com/your-username/WhisperType.git) # Replace with your repo URL
    cd WhisperType
    ```
2.  **Install Ollama:** If you haven't already, download and run Ollama from [ollama.com](https://ollama.com/). Ensure it's running. You can pull models using `ollama pull model_name` (e.g., `ollama pull llama3`).
3.  **Add Whisper Resources:**
    * Obtain the `whisper-cli` executable and a `ggml-base.en.bin` model file.
    * In Xcode, create a "Resources" group (or similar) in the Project Navigator.
    * Drag `whisper-cli` and `ggml-base.en.bin` into this group.
    * When prompted, ensure "Copy items if needed" is checked and that the files are added to your main application target.
    * Verify in your target's "Build Phases" -> "Copy Bundle Resources" that both files are listed.
4.  **Open in Xcode:** Open the `WhisperType.xcodeproj` file.
5.  **Build & Run:** Select your Mac as the target device and click the Run button (or press `Cmd+R`).
6.  **Grant Permissions:**
    * The first time you run, macOS will likely prompt you for **Microphone Access**. Click "OK".
    * It will also prompt for **Accessibility Access**. Click "Open System Settings". In the Privacy & Security > Accessibility settings, find WhisperType and enable the toggle switch.
    * **Relaunch Required:** After granting Accessibility permission, you will need to **quit** the application (via its menu bar icon or Xcode) and **run it again** from Xcode for the event tap (hotkey listening) to function correctly.

---

## ▶️ Usage

1.  Ensure WhisperType is running (you'll see the 🎤 icon in your menu bar).
2.  Click the menu bar icon to access Preferences or Quit.
3.  To transcribe and refine:
    * Press and **hold** your configured hotkey (default: `Ctrl+Space`). The icon changes to 🎙️.
    * Speak clearly.
    * **Release** the hotkey. The icon changes to ⏳ (processing) then 🧠 (thinking).
    * The refined text will be inserted into the application that was active when you released the hotkey.
    * The icon returns to 🎤.

---

## ⚙️ Configuration

* **Ollama Model:** Click the menu bar icon -> Preferences -> Set Model. Select an available model from the dropdown fetched from your running Ollama instance.
* **Hotkey:** Click the menu bar icon -> Preferences -> Set Hotkey. Click "Start Capture" and press your desired key combination. A confirmation will appear.

---

## ⚠️ Troubleshooting

* **Hotkey Not Working:**
    * Ensure Accessibility permissions are granted in System Settings and that you **relaunched the app** after granting them.
    * Check if another application is using the same hotkey. Try setting a different one.
* **No Text Inserted / Error Icon:**
    * Check that your local Ollama instance is running (`ollama ps` in Terminal).
    * Verify the selected Ollama model is available locally (`ollama list`).
    * Ensure `whisper-cli` and `ggml-base.en.bin` are correctly included in the app bundle (see Setup).
    * Check the Xcode console logs for specific error messages from Ollama or Whisper.cpp.
    * The target application might not support Accessibility insertion or simulated typing.
* **Transcription Quality:** The default `ggml-base.en.bin` is fast but basic. For higher accuracy, you can replace it with a larger Whisper model (like `ggml-medium.en.bin`), but ensure you rename it to `ggml-base.en.bin` within the project or update the filename constant in `AppDelegate.swift`. Larger models require more resources.

---

## 💡 Future Ideas

* [ ] Visual feedback during recording (e.g., pulsing icon).
* [ ] Option to choose different Whisper models/languages.
* [ ] More robust error handling and user feedback via notifications.
* [ ] Stream Ollama responses for faster perceived insertion.
* [ ] Add support for custom Ollama API URLs.

---

## 📜 License

(Add your license information here, e.g., MIT License)

Copyright [Year] [Your Name/Organization]Permission is hereby granted...
---

Happy Typing (with your voice)! 🎉

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
* **Git LFS:** This project uses Git Large File Storage to handle the large Whisper model file. **You must install Git LFS *before* cloning the repository.**
    * **Check if installed:** `git lfs version`
    * **Install (macOS Homebrew):** `brew install git-lfs`
    * **Initialize (run once per user):** `git lfs install`
* **Whisper.cpp CLI & Model:**
    * You need the compiled `whisper-cli` executable from the [Whisper.cpp](https://github.com/ggerganov/whisper.cpp) project.
    * You need a compatible GGML model file (e.g., `ggml-base.en.bin`). The actual model file will be downloaded via Git LFS when you clone or pull.
    * **IMPORTANT:** The `whisper-cli` executable **must be placed inside the Xcode project** (e.g., in a "Resources" group) and **added to the "Copy Bundle Resources" build phase** for your application target. This ensures it's included in the final `.app` bundle. The `.bin` model file is handled by Git LFS and does *not* need to be manually added to "Copy Bundle Resources" if tracked correctly by LFS.

---

## 🛠️ Setup & Installation

1.  **Install Git LFS:** If you haven't already, install Git LFS (see Requirements above).
    ```bash
    brew install git-lfs
    git lfs install # Run once per user
    ```
2.  **Clone Repository:**
    ```bash
    git clone [https://github.com/your-username/WhisperType.git](https://github.com/your-username/WhisperType.git) # Replace with your repo URL
    cd WhisperType
    ```
    *(Git LFS should automatically download the large `.bin` model file during the clone process.)*
3.  **Install Ollama:** If you haven't already, download and run Ollama from [ollama.com](https://ollama.com/). Ensure it's running. You can pull models using `ollama pull model_name` (e.g., `ollama pull llama3`).
4.  **Add Whisper CLI Resource:**
    * Obtain the `whisper-cli` executable.
    * In Xcode, create a "Resources" group (or similar) in the Project Navigator if it doesn't exist.
    * Drag `whisper-cli` into this group.
    * When prompted, ensure "Copy items if needed" is checked and that the file is added to your main application target.
    * Verify in your target's "Build Phases" -> "Copy Bundle Resources" that `whisper-cli` is listed.
5.  **Open in Xcode:** Open the `WhisperType.xcodeproj` file.
6.  **Build & Run:** Select your Mac as the target device and click the Run button (or press `Cmd+R`).
7.  **Grant Permissions:**
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

* **Git Clone Fails / Model Missing:** Ensure you have installed Git LFS *before* cloning (`brew install git-lfs` then `git lfs install`). If you cloned before installing LFS, run `git lfs pull` inside the repository directory to download the model file.
* **Hotkey Not Working:**
    * Ensure Accessibility permissions are granted in System Settings and that you **relaunched the app** after granting them.
    * Check if another application is using the same hotkey. Try setting a different one.
* **No Text Inserted / Error Icon:**
    * Check that your local Ollama instance is running (`ollama ps` in Terminal).
    * Verify the selected Ollama model is available locally (`ollama list`).
    * Ensure `whisper-cli` is correctly included in the app bundle (see Setup).
    * Check the Xcode console logs for specific error messages from Ollama or Whisper.cpp.
    * The target application might not support Accessibility insertion or simulated typing.
* **Transcription Quality:** The default `ggml-base.en.bin` is fast but basic. For higher accuracy, you can obtain a larger Whisper model (like `ggml-medium.en.bin`), replace the existing `.bin` file, ensure it's tracked by LFS (`git add Resources/ggml-medium.en.bin`, commit, push), and update the `whisperModelName` constant in `AppDelegate.swift`. Larger models require more resources.

---

## 💡 Future Ideas

* [ ] Visual feedback during recording (e.g., pulsing icon).
* [ ] Option to choose different Whisper models/languages via UI.
* [ ] More robust error handling and user feedback via notifications.
* [ ] Stream Ollama responses for faster perceived insertion.
* [ ] Add support for custom Ollama API URLs.

---

## 📜 License

MIT License

Copyright (c) [Year] [Your Name/Organization]

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

Happy Typing (with your voice)! 🎉

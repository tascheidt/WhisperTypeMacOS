import Cocoa
import CoreGraphics
import AVFoundation

// Define structures to match Ollama's JSON request and response format
struct OllamaGenerateRequest: Codable {
    let model: String
    let prompt: String
    var stream: Bool = false // Use var to ensure encoding
}

struct OllamaGenerateResponse: Codable {
    let model: String
    let created_at: String
    let response: String
    let done: Bool
}


@main
class AppDelegate: NSObject, NSApplicationDelegate, AVAudioRecorderDelegate {

    // --- Properties ---
    var statusItem: NSStatusItem?
    var eventTap: CFMachPort?
    var isHotkeyActive: Bool = false
    let hotkeyCode = CGKeyCode(49)
    let hotkeyModifiers = CGEventFlags.maskControl
    var audioRecorder: AVAudioRecorder?
    var recordingFileURL: URL?
    var isRecording: Bool = false

    // Ollama Configuration
    let ollamaModelName = "gemma3:4b-it-qat" // Or your preferred model
    let ollamaApiUrl = URL(string: "http://localhost:11434/api/generate")!


    // --- Application Lifecycle Methods ---
    func applicationDidFinishLaunching(_ aNotification: Notification) { print("App Launched: Setting up status bar item..."); statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength); guard let statusItem = statusItem, let button = statusItem.button else { print("Fatal Error: Could not create status bar item or button. Terminating."); NSApplication.shared.terminate(self); return }; if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "WhisperType Idle Status") { button.image = image } else { button.title = "WT" }; button.toolTip = "WhisperType (Initializing)"; let menu = NSMenu(); menu.addItem(NSMenuItem(title: "Quit WhisperType", action: #selector(quitApp), keyEquivalent: "q")); statusItem.menu = menu; print("Status bar setup complete."); checkAndSetupHotkeyListener(); print("applicationDidFinishLaunching finished.") }
    @objc func quitApp() { print("Quit action triggered from menu."); stopRecording(); disableEventTap(); NSApplication.shared.terminate(self); }
    func applicationWillTerminate(_ aNotification: Notification) { print("Application will terminate."); stopRecording(); disableEventTap(); }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { return true }


    // --- Permissions and Setup ---
    func checkAndSetupHotkeyListener() { print("Checking Accessibility Permissions..."); let isTrusted = AXIsProcessTrusted(); if !isTrusted { print("Warning: AXIsProcessTrusted() returned false. Manual grant required.") }; setupEventTap(); }
    func setupEventTap() { print("Attempting to set up event tap..."); let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue); eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(eventMask), callback: { (p, t, e, r) -> Unmanaged<CGEvent>? in guard let r = r else { return Unmanaged.passRetained(e) }; let o = Unmanaged<AppDelegate>.fromOpaque(r).takeUnretainedValue(); return o.handleEvent(proxy: p, type: t, event: e) }, userInfo: Unmanaged.passUnretained(self).toOpaque()); guard let eventTap = eventTap else { print("Error: Failed to create event tap!"); statusItem?.button?.toolTip = "Error: Event Tap Failed!"; return }; print("Event tap created successfully."); let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0); CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes); CGEvent.tapEnable(tap: eventTap, enable: true); print("Event tap enabled. Listening for hotkey (Control+Space)..."); statusItem?.button?.toolTip = "WhisperType (Listening for Control+Space)" }
    func disableEventTap() { if let tap = eventTap { print("Disabling event tap."); CGEvent.tapEnable(tap: tap, enable: false); eventTap = nil; print("Event tap disabled.") } }


    // --- Audio Recording Methods ---
    func startRecording() { guard !isRecording else { print("Already recording."); return }; print("Attempting to start recording..."); let tempDir = FileManager.default.temporaryDirectory; let fileName = "whisperTypeRecording_\(Date().timeIntervalSince1970).wav"; recordingFileURL = tempDir.appendingPathComponent(fileName); let settings: [String: Any] = [ AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, ]; do { audioRecorder = try AVAudioRecorder(url: recordingFileURL!, settings: settings); audioRecorder?.delegate = self; audioRecorder?.isMeteringEnabled = true; if audioRecorder?.prepareToRecord() == true { audioRecorder?.record(); isRecording = true; print("Recording started (or attempted) to: \(recordingFileURL!.path)") } else { print("Error: Audio recorder failed to prepare."); isRecording = false; recordingFileURL = nil } } catch { print("Error setting up audio recorder: \(error.localizedDescription)"); isRecording = false; recordingFileURL = nil; DispatchQueue.main.async { self.statusItem?.button?.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Recording Setup Error"); self.statusItem?.button?.toolTip = "Error: Could not start recorder" } } }
    func stopRecording() { guard isRecording, let recorder = audioRecorder else { return }; print("Stopping recording..."); recorder.stop(); isRecording = false }
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) { print("audioRecorderDidFinishRecording called. Success: \(flag)"); guard let url = recordingFileURL else { print("Error: Recording finished but file URL is nil."); DispatchQueue.main.async { self.statusItem?.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "WhisperType Idle Status after Save Error"); self.statusItem?.button?.toolTip = "WhisperType (Error Saving Recording)" }; audioRecorder = nil; return }; if flag { print("Recording saved successfully to: \(url.path)"); transcribeAudio(fileURL: url) } else { print("Error: Recording finished unsuccessfully."); recordingFileURL = nil; DispatchQueue.main.async { self.statusItem?.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "WhisperType Idle Status after Recording Failure"); self.statusItem?.button?.toolTip = "WhisperType (Recording Failed)" }; try? FileManager.default.removeItem(at: url) }; audioRecorder = nil }


    // --- Transcription Function ---
     func transcribeAudio(fileURL: URL) { print("Attempting to transcribe audio file: \(fileURL.path)"); guard let whisperPath = Bundle.main.path(forResource: "whisper-cli", ofType: nil), let modelPath = Bundle.main.path(forResource: "ggml-base.en", ofType: "bin") else { print("Error: Could not find bundled whisper executable ('whisper-cli') or model file ('ggml-base.en.bin') in app bundle's Resources."); DispatchQueue.main.async { self.statusItem?.button?.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Transcription Resource Error"); self.statusItem?.button?.toolTip = "Error: Missing transcription resources!" }; try? FileManager.default.removeItem(at: fileURL); return }; print("Found whisper executable: \(whisperPath)"); print("Found model file: \(modelPath)"); let arguments = [ "-m", modelPath, "-nt", "-l", "en", "-otxt", "-f", fileURL.path ]; let process = Process(); process.executableURL = URL(fileURLWithPath: whisperPath); process.arguments = arguments; let pipe = Pipe(); process.standardOutput = pipe; DispatchQueue.global(qos: .userInitiated).async { do { print("Launching whisper-cli process..."); try process.run(); process.waitUntilExit(); print("whisper-cli process finished with status: \(process.terminationStatus)"); let data = pipe.fileHandleForReading.readDataToEndOfFile(); let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; DispatchQueue.main.async { if process.terminationStatus == 0 && !output.isEmpty { print("Transcription successful:\n---\n\(output)\n---"); self.sendToOllama(rawText: output) } else { print("Error: Transcription failed. Status: \(process.terminationStatus), Output: '\(output)'"); self.statusItem?.button?.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Transcription Failed Error"); self.statusItem?.button?.toolTip = "Error: Transcription failed"; if !self.isHotkeyActive && !self.isRecording { self.resetUI() } }; print("Deleting temporary audio file: \(fileURL.path)"); try? FileManager.default.removeItem(at: fileURL) } } catch { DispatchQueue.main.async { print("Error launching whisper-cli process: \(error)"); self.statusItem?.button?.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Transcription Launch Error"); self.statusItem?.button?.toolTip = "Error: Failed to run transcriber"; try? FileManager.default.removeItem(at: fileURL); if !self.isHotkeyActive && !self.isRecording { self.resetUI() } } } } }


    // --- Ollama Interaction ---
    func sendToOllama(rawText: String) {
        print("Sending text to Ollama for refinement...")
        DispatchQueue.main.async {
            self.statusItem?.button?.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "Thinking Status")
            self.statusItem?.button?.toolTip = "WhisperType (Thinking...)"
        }
        let prompt = """
        You are WhisperType, a context‑aware writing assistant.

        **Task**
        Transform the raw voice transcription into polished text that is ready to paste into an email, document, or chat.

        **Rules**
        1. Correct spelling, grammar, and punctuation.
        2. Detect structure:
           • If the input clearly contains multiple discrete points, short sentences, or list markers (“first…”, “next…”, “finally…”), output a bulleted list.
           • Otherwise return one or more coherent sentences/paragraphs.
        3. Respect any numbers, URLs, code snippets, or email addresses verbatim.
        4. Never add an introduction or explanation.
        5. Output only the final text – no code fences, tags, or commentary.

        **Input**

        \"\"\"
        \(rawText)
        \"\"\"

        **Output**
        """
        let requestBody = OllamaGenerateRequest(model: ollamaModelName, prompt: prompt)
        guard let encodedBody = try? JSONEncoder().encode(requestBody) else {
            print("Error: Failed to encode Ollama request body.")
            DispatchQueue.main.async { self.resetUI(showError: true, message: "Ollama Encoding Error") }
            return
        }
        var request = URLRequest(url: ollamaApiUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encodedBody
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Error sending request to Ollama: \(error.localizedDescription)")
                    self.resetUI(showError: true, message: "Ollama Network Error")
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    print("Error: Ollama returned non-success status code: \(statusCode)")
                    self.resetUI(showError: true, message: "Ollama Server Error (\(statusCode))")
                    return
                }
                guard let data = data else {
                    print("Error: No data received from Ollama.")
                    self.resetUI(showError: true, message: "Ollama No Data")
                    return
                }
                do {
                    let ollamaResponse = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
                    let fullResponse = ollamaResponse.response
                    var refinedText: String
                    if let lastThinkTagRange = fullResponse.range(of: "</think>", options: .backwards) {
                        refinedText = String(fullResponse[lastThinkTagRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        print("Extracted text after </think> tag.")
                    } else {
                        refinedText = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("No </think> tag found, using full response.")
                    }
                    if refinedText.isEmpty {
                        print("Error: Ollama returned empty refined text.")
                        self.resetUI(showError: true, message: "Ollama Empty Response")
                        return
                    }
                    print("Ollama refinement successful (processed):\n---\n\(refinedText)\n---")
                    self.insertRefinedText(text: refinedText) // Pass final text
                } catch {
                    print("Error decoding Ollama response JSON: \(error)")
                    print("Raw Ollama response: \(String(data: data, encoding: .utf8) ?? "Unable to decode raw response")")
                    self.resetUI(showError: true, message: "Ollama Response Error")
                }
            }
        }
        task.resume()
    }

    // --- Text Insertion Implementation (Accessibility with key‑event fallback) ---
    func insertRefinedText(text: String) {
        // Always ensure one trailing space so successive inserts are separated
        let insertionText = text.hasSuffix(" ") || text.hasSuffix("\n") ? text : text + " "
        print("Attempting to insert via Accessibility…")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {       // let focus settle
            // 1️⃣ system‑wide focused UI element (works for Chrome/Electron)
            let systemWide = AXUIElementCreateSystemWide()
            var focused: AnyObject?
            let err = AXUIElementCopyAttributeValue(systemWide,
                                                    kAXFocusedUIElementAttribute as CFString,
                                                    &focused)

            // Ensure we received an element; if not, fall back to simulated typing.
            guard err == .success, let anyElement = focused else {
                print("Couldn’t get focused element (\(err.rawValue)); falling back to typing.")
                self.typeText(insertionText)        // see helper below
                self.resetUI()
                return
            }

            // CoreFoundation bridging guarantees the object is an AXUIElement,
            // so we can safely force‑cast without triggering the “conditional
            // downcast … will always succeed” warning.
            let axElement = anyElement as! AXUIElement

            // 2️⃣ Try to insert without replacing the whole field
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(axElement,
                                              kAXValueAttribute as CFString,
                                              &settable) == .success,
               settable.boolValue {

                // — a. Get current text
                var currentValueCF: CFTypeRef?
                let gotValue = AXUIElementCopyAttributeValue(axElement,
                                                             kAXValueAttribute as CFString,
                                                             &currentValueCF)
                guard gotValue == .success, let currentText = currentValueCF as? String else {
                    print("Could not read current value – falling back to typing.")
                    self.typeText(insertionText)
                    self.resetUI()
                    return
                }

                // — b. Get current caret / selection range
                var selRangeCF: CFTypeRef?
                let gotSel = AXUIElementCopyAttributeValue(axElement,
                                                           kAXSelectedTextRangeAttribute as CFString,
                                                           &selRangeCF)

                var newString: String

                if gotSel == .success,
                   let selAXValue = selRangeCF,
                   CFGetTypeID(selAXValue) == AXValueGetTypeID(),
                   AXValueGetType(selAXValue as! AXValue) == .cfRange {

                    var cfRange = CFRange()
                    AXValueGetValue(selAXValue as! AXValue, .cfRange, &cfRange)
                    let nsRange = NSRange(location: cfRange.location, length: cfRange.length)

                    // Replace selected range (or insert at caret if length == 0)
                    if let mutable = currentText.mutableCopy() as? NSMutableString {
                        mutable.replaceCharacters(in: nsRange, with: insertionText)
                        newString = mutable as String
                    } else {
                        // Shouldn’t happen, but be safe
                        newString = (currentText as NSString).replacingCharacters(in: nsRange, with: insertionText)
                    }
                } else {
                    // Couldn’t get selection – append at end (less ideal but safe)
                    newString = currentText + insertionText
                }

                // — c. Write back
                if AXUIElementSetAttributeValue(axElement,
                                                kAXValueAttribute as CFString,
                                                newString as CFTypeRef) == .success {
                    print("Inserted without overwriting existing content ✓")
                    self.resetUI()
                    return
                } else {
                    print("Set value failed; falling back to typing.")
                    // fall through to 3️⃣
                }
            }

            // 3️⃣ Otherwise simulate real keystrokes (clipboard‑safe)
            print("AXValue not settable; falling back to typing.")
            self.typeText(insertionText)
            self.resetUI()
        }
    }

    // --- Fallback: type characters via Quartz events ---
    func typeText(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for scalar in text.unicodeScalars {
            var u = UInt16(scalar.value)
            // keyDown with Unicode payload
            if let kd = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                kd.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
                kd.post(tap: .cgSessionEventTap)
            }
            // keyUp
            if let ku = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                ku.post(tap: .cgSessionEventTap)
            }
        }
    }
    
    // --- Separate function for Pasteboard Insertion ---
    func insertViaPasteboard(text: String) {
        print("Using Pasteboard fallback method...")

        // 1. Clear and set pasteboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            print("Error: Failed to set string on pasteboard.")
            resetUI(showError: true, message: "Pasteboard Error")
            return
        }
        print("Text copied to pasteboard (clipboard overwritten).")

        // 2. Simulate Cmd+V
        // Give a tiny delay AFTER setting pasteboard
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { // 0.1s delay seems sufficient usually
            print("Simulating Cmd+V keystroke...")
            let source = CGEventSource(stateID: .hidSystemState)
            // Key codes: Cmd=55, V=9
            let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            keyVDown?.flags = .maskCommand
            keyVUp?.flags = .maskCommand
            keyVDown?.post(tap: .cgSessionEventTap)
            keyVUp?.post(tap: .cgSessionEventTap)
            print("Cmd+V simulation posted.")
            self.resetUI() // Reset UI after paste attempt
        }
    }


    // --- Helper to Reset UI ---
    func resetUI(showError: Bool = false, message: String? = nil) {
        DispatchQueue.main.async {
            if !self.isHotkeyActive && !self.isRecording {
                if showError { self.statusItem?.button?.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Error Status"); self.statusItem?.button?.toolTip = "Error: \(message ?? "Unknown Error")"; DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { self.resetUI() } }
                else { self.statusItem?.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "WhisperType Idle Status"); self.statusItem?.button?.toolTip = "WhisperType (Listening for Control+Space)" }
            }
        }
    }


    // --- Event Handling ---
    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown { let k = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)); let f = event.flags; let c = f.contains(hotkeyModifiers); if k == hotkeyCode && c { if !isHotkeyActive { isHotkeyActive = true; print("Hotkey PRESSED (Control+Space)"); DispatchQueue.main.async { self.statusItem?.button?.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Recording Status"); self.statusItem?.button?.toolTip = "WhisperType (Recording)"; self.startRecording() }; print("Consuming hotkey event to prevent beep."); return nil } else { return nil } } }
        else if type == .keyUp || type == .flagsChanged { if isHotkeyActive { let k = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)); let f = event.flags; let c = f.contains(hotkeyModifiers); if (type == .keyUp && k == hotkeyCode) || !c { isHotkeyActive = false; print("Hotkey RELEASED (Control+Space)"); DispatchQueue.main.async { self.statusItem?.button?.image = NSImage(systemSymbolName: "hourglass.circle", accessibilityDescription: "Processing Status"); self.statusItem?.button?.toolTip = "WhisperType (Processing)"; self.stopRecording() } } } }
        else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { print("Event tap disabled. Attempting to re-enable."); if let tap = self.eventTap { CGEvent.tapEnable(tap: tap, enable: true) } }
        return Unmanaged.passUnretained(event)
    }

} // End of AppDelegate class

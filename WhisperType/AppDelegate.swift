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
class AppDelegate: NSObject, NSApplicationDelegate, AVAudioRecorderDelegate, NSAlertDelegate, NSWindowDelegate {

    // --- Properties ---
    var statusItem: NSStatusItem?
    var eventTap: CFMachPort?
    var isHotkeyActive: Bool = false
    // Ollama Configuration (user‑configurable)
    var ollamaModelName: String = "gemma3:4b-it-qat"      // default
    let ollamaApiUrl = URL(string: "http://localhost:11434/api/generate")!
    var hotkeyCode: CGKeyCode = 49            // Space
    var hotkeyModifiers: CGEventFlags = .maskControl
    var audioRecorder: AVAudioRecorder?
    var recordingFileURL: URL?
    var isRecording: Bool = false
    // Persisted settings
    let defaults = UserDefaults.standard
    var awaitingHotkeyCapture = false

    // --- Preferences window UI ---
    var prefsWindow: NSWindow?
    var modelTextField: NSTextField?
    var hotkeyLabel: NSTextField?
    var changeHotkeyButton: NSButton?
    var hotkeyMonitor: Any?


    // --- Application Lifecycle Methods ---
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("App Launched: Setting up status bar item...")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let statusItem = statusItem, let button = statusItem.button else {
            print("Fatal Error: Could not create status bar item or button. Terminating.")
            NSApplication.shared.terminate(self)
            return
        }
        if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "WhisperType Idle Status") {
            button.image = image
        } else {
            button.title = "WT"
        }
        button.toolTip = "WhisperType (Initializing)"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit WhisperType", action: #selector(quitApp), keyEquivalent: "q"))

        // Add Preferences menu command
        menu.insertItem(NSMenuItem.separator(), at: 0)
        menu.insertItem(NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ","), at: 0)

        statusItem.menu = menu
        print("Status bar setup complete.")

        // Load persisted model / hotkey (if any)
        if let savedModel = defaults.string(forKey: "OllamaModelName") {
            ollamaModelName = savedModel
        }
        if let savedKey = defaults.value(forKey: "HotkeyKeyCode") as? UInt64 {
            hotkeyCode = CGKeyCode(savedKey)
        }
        if let savedMods = defaults.value(forKey: "HotkeyModifiers") as? UInt64 {
            hotkeyModifiers = CGEventFlags(rawValue: savedMods)
        }

        checkAndSetupHotkeyListener()
        print("applicationDidFinishLaunching finished.")
    }
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
        // --- Hotkey capture mode ---
        if awaitingHotkeyCapture && type == .keyDown {
            let newCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let newMods = event.flags.intersection([.maskCommand, .maskControl, .maskShift, .maskAlternate])
            hotkeyCode = newCode
            hotkeyModifiers = newMods
            defaults.set(UInt64(newCode), forKey: "HotkeyKeyCode")
            defaults.set(newMods.rawValue, forKey: "HotkeyModifiers")
            awaitingHotkeyCapture = false
            print("New hotkey set: \(newMods) + \(newCode)")
            statusItem?.button?.toolTip = "WhisperType (Listening for new hotkey)"
            return Unmanaged.passUnretained(event)   // don’t treat it as a whisper trigger
        }
        if type == .keyDown {
            let k = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let f = event.flags
            let c = f.contains(hotkeyModifiers)
            if k == hotkeyCode && c {
                if !isHotkeyActive {
                    isHotkeyActive = true
                    print("Hotkey PRESSED (Control+Space)")
                    DispatchQueue.main.async {
                        self.statusItem?.button?.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Recording Status")
                        self.statusItem?.button?.toolTip = "WhisperType (Recording)"
                        self.startRecording()
                    }
                    print("Consuming hotkey event to prevent beep.")
                    return nil
                } else {
                    return nil
                }
            }
        }
        else if type == .keyUp || type == .flagsChanged {
            if isHotkeyActive {
                let k = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                let f = event.flags
                let c = f.contains(hotkeyModifiers)
                if (type == .keyUp && k == hotkeyCode) || !c {
                    isHotkeyActive = false
                    print("Hotkey RELEASED (Control+Space)")
                    DispatchQueue.main.async {
                        self.statusItem?.button?.image = NSImage(systemSymbolName: "hourglass.circle", accessibilityDescription: "Processing Status")
                        self.statusItem?.button?.toolTip = "WhisperType (Processing)"
                        self.stopRecording()
                    }
                }
            }
        }
        else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("Event tap disabled. Attempting to re-enable.")
            if let tap = self.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Settings helpers

    /// Prompt user to type an Ollama model name (e.g. "quinn:7b")
    @objc func promptModel() {
        let alert = NSAlert()
        alert.messageText = "Set Ollama Model"
        alert.informativeText = "Enter the Ollama model name to use:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = ollamaModelName
        alert.showsHelp = true
        alert.helpAnchor = "OllamaModel"
        alert.delegate = self
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let model = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty {
                ollamaModelName = model
                defaults.set(model, forKey: "OllamaModelName")
            }
        }
    }

    /// Begin capture of a new hot‑key; now replaced by Preferences window.
    @objc func beginHotkeyCapture() {
        showPreferences()
    }

    // MARK: - Preferences UI -------------------------------------------------

    @objc func showPreferences() {
        if let win = prefsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Window skeleton
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                           styleMask: [.titled, .closable],
                           backing: .buffered,
                           defer: false)
        win.title = "WhisperType Preferences"
        win.center()
        win.delegate = self
        self.prefsWindow = win

        // --- Model field ---------------------------------------------------
        let modelLabel = NSTextField(labelWithString: "Ollama Model:")
        modelLabel.frame = NSRect(x: 20, y: 140, width: 120, height: 20)
        modelLabel.alignment = .right

        let modelField = NSTextField(frame: NSRect(x: 150, y: 136, width: 240, height: 24))
        modelField.stringValue = ollamaModelName
        self.modelTextField = modelField

        // --- Hot‑key selector ----------------------------------------------
        let hotLabel = NSTextField(labelWithString: "Hotkey:")
        hotLabel.frame = NSRect(x: 20, y: 100, width: 120, height: 20)
        hotLabel.alignment = .right

        let hkLabel = NSTextField(labelWithString: formatHotkey(code: hotkeyCode, mods: hotkeyModifiers))
        hkLabel.frame = NSRect(x: 150, y: 100, width: 150, height: 20)
        self.hotkeyLabel = hkLabel

        let changeBtn = NSButton(title: "Change…", target: self, action: #selector(beginInlineHotkeyCapture))
        changeBtn.frame = NSRect(x: 310, y: 96, width: 80, height: 28)
        self.changeHotkeyButton = changeBtn

        // --- Done (apply) and Cancel buttons -------------------------------
        let doneBtn = NSButton(title: "Done", target: self, action: #selector(savePreferences))
        doneBtn.frame = NSRect(x: 310, y: 20, width: 80, height: 30)

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelPreferences))
        cancelBtn.frame = NSRect(x: 220, y: 20, width: 80, height: 30)

        win.contentView?.addSubview(modelLabel)
        win.contentView?.addSubview(modelField)
        win.contentView?.addSubview(hotLabel)
        win.contentView?.addSubview(hkLabel)
        win.contentView?.addSubview(changeBtn)
        win.contentView?.addSubview(cancelBtn)
        win.contentView?.addSubview(doneBtn)

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Apply changes and close the preferences window.
    @objc func savePreferences() {
        // Persist model (empty → ignore)
        if let text = modelTextField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            ollamaModelName = text
            defaults.set(text, forKey: "OllamaModelName")
        }
        // The window delegate will finish cleanup
        prefsWindow?.performClose(nil)
    }

    /// Close the preferences window without applying changes
    @objc func cancelPreferences() {
        prefsWindow?.performClose(nil)
    }

    // MARK: - NSWindowDelegate
    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win == prefsWindow else { return }

        // Clear stored reference so the next “Preferences…” recreates a fresh window
        prefsWindow = nil

        // If user closed the window while capturing a hot‑key,
        // cancel capture and remove the local event monitor safely.
        if awaitingHotkeyCapture {
            awaitingHotkeyCapture = false
            if let monitor = hotkeyMonitor {
                NSEvent.removeMonitor(monitor)
                hotkeyMonitor = nil
            }
            // Restore label to currently active hotkey
            hotkeyLabel?.stringValue = formatHotkey(code: hotkeyCode, mods: hotkeyModifiers)
        }
        // Release UI references to avoid dangling pointers
        modelTextField = nil
        hotkeyLabel = nil
        changeHotkeyButton = nil
    }

    // Begin capturing a new hot‑key inside the preferences panel
    @objc func beginInlineHotkeyCapture() {
        hotkeyLabel?.stringValue = "Press new keys…"
        awaitingHotkeyCapture = true

        // Local NSEvent monitor → captures only while prefs window is key
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self = self, self.awaitingHotkeyCapture else { return ev }
            self.captureHotkey(from: ev)
            return nil   // swallow event so it doesn’t beep
        }
    }

    private func captureHotkey(from event: NSEvent) {
        awaitingHotkeyCapture = false

        // Remove the temporary local monitor exactly once
        if let monitor = hotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyMonitor = nil
        }

        // Store new key‑code
        hotkeyCode = CGKeyCode(event.keyCode)

        // Translate NSEvent.ModifierFlags → CGEventFlags
        let nseMods = event.modifierFlags.intersection([.command, .shift, .control, .option])
        var cgMods: CGEventFlags = []
        if nseMods.contains(.command)  { cgMods.insert(.maskCommand) }
        if nseMods.contains(.shift)    { cgMods.insert(.maskShift) }
        if nseMods.contains(.control)  { cgMods.insert(.maskControl) }
        if nseMods.contains(.option)   { cgMods.insert(.maskAlternate) }
        hotkeyModifiers = cgMods

        // Persist to UserDefaults
        defaults.set(UInt64(hotkeyCode), forKey: "HotkeyKeyCode")
        defaults.set(hotkeyModifiers.rawValue, forKey: "HotkeyModifiers")

        // Update label if prefs window still open
        hotkeyLabel?.stringValue = formatHotkey(code: hotkeyCode, mods: hotkeyModifiers)

        // Notify user
        let alert = NSAlert()
        alert.messageText = "Hotkey Updated"
        alert.informativeText = "New hotkey: \(formatHotkey(code: hotkeyCode, mods: hotkeyModifiers))"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func formatHotkey(code: CGKeyCode, mods: CGEventFlags) -> String {
        var pieces: [String] = []
        if mods.contains(.maskControl)   { pieces.append("⌃") }
        if mods.contains(.maskAlternate) { pieces.append("⌥") }
        if mods.contains(.maskShift)     { pieces.append("⇧") }
        if mods.contains(.maskCommand)   { pieces.append("⌘") }

        let keyName: String
        switch code {
        case 49:  keyName = "Space"
        case 53:  keyName = "Esc"
        case 36:  keyName = "Return"
        case 122: keyName = "F1"
        case 120: keyName = "F2"
        case 99:  keyName = "F3"
        case 118: keyName = "F4"
        case 96:  keyName = "F5"
        case 97:  keyName = "F6"
        case 98:  keyName = "F7"
        case 100: keyName = "F8"
        case 101: keyName = "F9"
        case 109: keyName = "F10"
        case 103: keyName = "F11"
        case 111: keyName = "F12"
        default:  keyName = String(format: "#%d", code)
        }
        pieces.append(keyName)
        return pieces.joined()
    }

    // MARK: - NSAlert Help
    func alertShowHelp(_ alert: NSAlert) -> Bool {
        if alert.helpAnchor == "OllamaModel" {
            let help = NSAlert()
            help.messageText = "Ollama Models"
            help.informativeText = """
            New models can be downloaded from https://ollama.com/search
            View models you have already downloaded by running “ollama list” in Terminal.
            """
            help.addButton(withTitle: "OK")
            help.runModal()
            return true
        } else if alert.helpAnchor == "HotkeyConfig" {
            let help = NSAlert()
            help.messageText = "Configure Hotkey"
            help.informativeText = """
            WhisperType listens for a single key (plus optional modifiers) as its trigger.
            Click ‘Set Hotkey…’, press your preferred combination (e.g. Fn or ⌥F),
            and WhisperType will use it immediately and remember it next launch.
            """
            help.addButton(withTitle: "OK")
            help.runModal()
            return true
        }
        return false
    }

} // End of AppDelegate class

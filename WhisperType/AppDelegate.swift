import Cocoa
import CoreGraphics
import AVFoundation
import Accessibility // Need this for AXUIElement types
import Carbon.HIToolbox // For TIS/... and UCKeyTranslate/...
import KeyboardShortcuts // Keep if you still use its other features, otherwise optional

// --- Ollama API Data Structures ---
struct OllamaTagsResponse: Codable {
    let models: [OllamaModel]
}

struct OllamaModel: Codable {
    let name: String
    // Ollama API might return other fields, but we only need 'name'
    // let modified_at: String
    // let size: Int
    // let digest: String
}

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


// NOTE: No @main here, using main.swift instead
class AppDelegate: NSObject, NSApplicationDelegate, AVAudioRecorderDelegate, NSAlertDelegate, NSWindowDelegate, NSTextFieldDelegate {

    // --- Properties ---
    var statusItem: NSStatusItem?
    var eventTap: CFMachPort? // Global CGEvent tap
    var eventTapRunLoopSource: CFRunLoopSource? // Source for the global tap
    var isHotkeyActive: Bool = false
    // Ollama Configuration (user‑configurable)
    var ollamaModelName: String = "gemma3:4b-it-qat"     // default - Update this default if needed
    let ollamaApiUrl = URL(string: "http://localhost:11434/api/generate")!
    let ollamaTagsUrl = URL(string: "http://localhost:11434/api/tags")! // URL for listing models
    var hotkeyCode: CGKeyCode = CGKeyCode(kVK_Space)         // Default: Space (using Carbon constant 49)
    var hotkeyModifiers: CGEventFlags = .maskControl // Default: Control
    var audioRecorder: AVAudioRecorder?
    var recordingFileURL: URL?
    var isRecording: Bool = false
    // Persisted settings
    let defaults = UserDefaults.standard
    var awaitingHotkeyCapture = false // Flag to indicate if we are capturing the next key press


    // --- Application Lifecycle Methods ---
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("--- applicationDidFinishLaunching: START ---")

        print("Setting up status bar item...")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let statusItem = statusItem, let button = statusItem.button else {
            print("Fatal Error: Could not create status bar item or button. Terminating.")
            print("--- applicationDidFinishLaunching: FAILED (Status Item) ---")
            NSApplication.shared.terminate(self)
            return
        }
        if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "WhisperType Idle Status") {
            button.image = image
        } else {
            button.title = "WT" // Fallback title
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
        if let savedModel = defaults.string(forKey: "OllamaModelName"),
           !savedModel.isEmpty {
            ollamaModelName = savedModel
            print("Loaded saved model: \(ollamaModelName)")
        } else {
            // If no model saved, try fetching models on launch to set a default if possible
            // Or just keep the hardcoded default. For simplicity, keep default for now.
            print("Using default model: \(ollamaModelName)")
        }

        let savedKey = defaults.integer(forKey: "HotkeyKeyCode")
        if savedKey != 0 {
            hotkeyCode = CGKeyCode(savedKey)
        } else {
            hotkeyCode = CGKeyCode(kVK_Space) // Default if not saved
        }

        let savedMods = defaults.integer(forKey: "HotkeyModifiers")
        if defaults.object(forKey: "HotkeyModifiers") != nil { // Check if key exists, even if 0
            hotkeyModifiers = CGEventFlags(rawValue: UInt64(savedMods))
        } else {
            hotkeyModifiers = .maskControl // Default if not saved
        }
        print("Loaded hotkey: Code=\(hotkeyCode), Mods=\(hotkeyModifiers.rawValue)")


        // Setup the single global event tap
        checkAndSetupHotkeyListener()

        print("--- applicationDidFinishLaunching: Attempting to activate app ---")
        NSApp.activate(ignoringOtherApps: true)

        print("--- applicationDidFinishLaunching: FINISHED ---")
    }

    @objc func quitApp() {
        print("Quit action triggered from menu.")
        stopRecording() // Ensure recording stops
        disableEventTap() // Cleanly disable the event tap
        NSApplication.shared.terminate(self)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        print("Application will terminate.")
        stopRecording() // Ensure recording stops
        disableEventTap() // Cleanly disable the event tap
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }


    // --- Permissions and Global Event Tap Setup ---
    func checkAndSetupHotkeyListener() {
        print("Checking Accessibility Permissions...")
        let isTrusted = AXIsProcessTrusted()
        if !isTrusted {
            print("Warning: AXIsProcessTrusted() returned false. Manual grant required in System Settings > Privacy & Security > Accessibility.")
        }
        setupEventTap() // Call the setup function
    }

    // Sets up the single global CGEvent tap
    func setupEventTap() {
        disableEventTap() // Clean up old one first

        print("Attempting to set up new event tap...")
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return appDelegate.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let newTap = eventTap else {
            print("Error: Failed to create event tap! Check Accessibility permissions.")
            statusItem?.button?.toolTip = "Error: Event Tap Failed! Check Permissions."
            return
        }
        print("New event tap created successfully.")

        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
             print("Error: Failed to create run loop source for new tap!")
             self.eventTap = nil
             statusItem?.button?.toolTip = "Error: Event Tap Source Failed!"
             return
        }
        self.eventTapRunLoopSource = newSource
        print("New run loop source created and stored.")

        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        print("New run loop source added to main run loop.")
        CGEvent.tapEnable(tap: newTap, enable: true)

        if !CGEvent.tapIsEnabled(tap: newTap) {
             print("Error: Failed to enable event tap after creation!")
             statusItem?.button?.toolTip = "Error: Could not enable event tap."
             CFRunLoopRemoveSource(CFRunLoopGetMain(), newSource, .commonModes)
             self.eventTapRunLoopSource = nil
             self.eventTap = nil
             return
        }

        let currentHotkeyText = formatHotkey(code: hotkeyCode, mods: hotkeyModifiers)
        print("New event tap enabled. Listening for \(currentHotkeyText)...")
        statusItem?.button?.toolTip = "WhisperType (Listening for \(currentHotkeyText))"
    }

    // Cleanly disables and removes the global event tap and its source
    func disableEventTap() {
        // print("Attempting to disable event tap...") // Less verbose
        if let tap = eventTap {
            // print("Disabling existing event tap (CGEvent.tapEnable=false).")
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = eventTapRunLoopSource {
                // print("Removing existing run loop source.")
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                eventTapRunLoopSource = nil
            }
            eventTap = nil
            print("Event tap disabled and references cleared.")
        } else {
            if eventTapRunLoopSource != nil {
                 print("Warning: eventTap was nil but source was not. Clearing source.")
                 eventTapRunLoopSource = nil
            }
        }
    }


    // --- Audio Recording Methods ---
    func startRecording() { guard !isRecording else { print("Already recording."); return }; print("Attempting to start recording..."); let tempDir = FileManager.default.temporaryDirectory; let fileName = "whisperTypeRecording_\(Date().timeIntervalSince1970).wav"; recordingFileURL = tempDir.appendingPathComponent(fileName); let settings: [String: Any] = [ AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, ]; do { audioRecorder = try AVAudioRecorder(url: recordingFileURL!, settings: settings); audioRecorder?.delegate = self; audioRecorder?.isMeteringEnabled = true; if audioRecorder?.prepareToRecord() == true { audioRecorder?.record(); isRecording = true; print("Recording started (or attempted) to: \(recordingFileURL!.path)") } else { print("Error: Audio recorder failed to prepare."); isRecording = false; recordingFileURL = nil } } catch { print("Error setting up audio recorder: \(error.localizedDescription)"); isRecording = false; recordingFileURL = nil; DispatchQueue.main.async { self.statusItem?.button?.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Recording Setup Error"); self.statusItem?.button?.toolTip = "Error: Could not start recorder" } } }
    func stopRecording() { guard isRecording, let recorder = audioRecorder else { return }; print("Stopping recording..."); recorder.stop(); }
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        print("audioRecorderDidFinishRecording called. Success: \(flag)")
        isRecording = false
        guard let url = recordingFileURL else {
            print("Error: Recording finished but file URL is nil.")
            DispatchQueue.main.async {
                self.resetUI(showError: true, message: "Recording Save Error")
            }
            audioRecorder = nil
            return
        }
        let finishedRecordingURL = url
        self.recordingFileURL = nil

        DispatchQueue.main.async {
            if !self.isHotkeyActive && !self.awaitingHotkeyCapture {
                 self.statusItem?.button?.image = NSImage(systemSymbolName: "hourglass.circle", accessibilityDescription: "Processing Status")
                 self.statusItem?.button?.toolTip = "WhisperType (Processing)"
            }
        }

        if flag {
            print("Recording saved successfully to: \(finishedRecordingURL.path)")
            transcribeAudio(fileURL: finishedRecordingURL)
        } else {
            print("Error: Recording finished unsuccessfully.")
            DispatchQueue.main.async {
                self.resetUI(showError: true, message: "Recording Failed")
            }
            try? FileManager.default.removeItem(at: finishedRecordingURL)
        }
        audioRecorder = nil
    }


    // --- Transcription Function ---
    func transcribeAudio(fileURL: URL) { print("Attempting to transcribe audio file: \(fileURL.path)"); guard let whisperPath = Bundle.main.path(forResource: "whisper-cli", ofType: nil), let modelPath = Bundle.main.path(forResource: "ggml-base.en", ofType: "bin") else { print("Error: Could not find bundled whisper executable ('whisper-cli') or model file ('ggml-base.en.bin') in app bundle's Resources."); DispatchQueue.main.async { self.resetUI(showError: true, message: "Missing transcription resources!") }; try? FileManager.default.removeItem(at: fileURL); return }; print("Found whisper executable: \(whisperPath)"); print("Found model file: \(modelPath)"); let arguments = [ "-m", modelPath, "-nt", "-l", "en", "-otxt", "-f", fileURL.path ]; let process = Process(); process.executableURL = URL(fileURLWithPath: whisperPath); process.arguments = arguments; let pipe = Pipe(); process.standardOutput = pipe; DispatchQueue.global(qos: .userInitiated).async { do { print("Launching whisper-cli process..."); try process.run(); process.waitUntilExit(); print("whisper-cli process finished with status: \(process.terminationStatus)"); let data = pipe.fileHandleForReading.readDataToEndOfFile(); let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""; DispatchQueue.main.async { if process.terminationStatus == 0 && !output.isEmpty { print("Transcription successful:\n---\n\(output)\n---"); self.sendToOllama(rawText: output) } else { print("Error: Transcription failed. Status: \(process.terminationStatus), Output: '\(output)'"); self.resetUI(showError: true, message: "Transcription Failed") }; print("Deleting temporary audio file: \(fileURL.path)"); try? FileManager.default.removeItem(at: fileURL) } } catch { DispatchQueue.main.async { print("Error launching whisper-cli process: \(error)"); self.resetUI(showError: true, message: "Failed to run transcriber"); try? FileManager.default.removeItem(at: fileURL) } } } }


    // --- Ollama Interaction ---
    func sendToOllama(rawText: String) {
        print("Sending text to Ollama for refinement...")
        DispatchQueue.main.async {
            self.statusItem?.button?.image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "Thinking Status")
            self.statusItem?.button?.toolTip = "WhisperType (Thinking...)"
        }
        // Prompt remains strict
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
        4. **CRITICAL:** Output *only* the final, refined text. Do **NOT** include any explanations, introductions, commentary, meta-tags like `<think>`, or code fences (```). Your entire response must be *only* the text to be inserted.

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
                    print("Received raw response from Ollama.") // Log before processing

                    // --- Post-processing to remove <think> tags ---
                    var processedText = ollamaResponse.response
                    // Use regular expression to find and remove <think>...</think> blocks
                    // The regex: "<think>": Matches the opening tag.
                    //            ".*?": Matches any character (.), zero or more times (*), non-greedily (?).
                    //            "</think>": Matches the closing tag.
                    // options: .dotMatchesLineSeparators allows '.' to match newline characters within the block.
                    if let regex = try? NSRegularExpression(pattern: "<think>.*?</think>", options: .dotMatchesLineSeparators) {
                        let range = NSRange(processedText.startIndex..., in: processedText)
                        // Replace found ranges with an empty string
                        processedText = regex.stringByReplacingMatches(in: processedText, options: [], range: range, withTemplate: "")
                        print("Applied regex to remove <think> tags.")
                    } else {
                        print("Warning: Could not create regex for <think> tags.")
                    }
                    // Trim whitespace after potentially removing tags
                    let refinedText = processedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    // --- End Post-processing ---


                    if refinedText.isEmpty {
                        print("Error: Ollama returned empty refined text after processing.")
                        self.resetUI(showError: true, message: "Ollama Empty Response")
                        return
                    }
                    print("Ollama refinement successful (processed):\n---\n\(refinedText)\n---")
                    self.insertRefinedText(text: refinedText)
                } catch {
                    print("Error decoding Ollama response JSON: \(error)")
                    print("Raw Ollama response: \(String(data: data, encoding: .utf8) ?? "Unable to decode raw response")")
                    self.resetUI(showError: true, message: "Ollama Response Error")
                }
            }
        }
        task.resume()
    }

    // --- Text Insertion Implementation ---
    func insertRefinedText(text: String) {
        let insertionText = text.hasSuffix(" ") || text.hasSuffix("\n") ? text : text + " "
        print("Attempting to insert via Accessibility…")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let systemWide = AXUIElementCreateSystemWide()
            var focused: AnyObject?
            let err = AXUIElementCopyAttributeValue(systemWide,
                                                    kAXFocusedUIElementAttribute as CFString,
                                                    &focused)

            guard err == .success, let anyElement = focused else {
                print("Couldn’t get focused element (AXError code: \(err.rawValue)); falling back to typing.")
                self.typeText(insertionText)
                return
            }

            let axElement = anyElement as! AXUIElement

            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(axElement,
                                              kAXValueAttribute as CFString,
                                              &settable) == .success,
               settable.boolValue {

                var currentValueCF: CFTypeRef?
                let gotValue = AXUIElementCopyAttributeValue(axElement,
                                                             kAXValueAttribute as CFString,
                                                             &currentValueCF)

                guard gotValue == .success, let currentText = currentValueCF as? String else {
                    print("Could not read current value – falling back to typing.")
                    self.typeText(insertionText)
                    return
                }

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
                    if AXValueGetValue(selAXValue as! AXValue, .cfRange, &cfRange) {
                        let rangeLocation = cfRange.location == kCFNotFound ? 0 : cfRange.location
                        let rangeLength = cfRange.length

                        if let validRange = Range(NSRange(location: rangeLocation, length: rangeLength), in: currentText) {
                            print("Valid selection range found. Replacing...")
                            let nsRange = NSRange(validRange, in: currentText)
                            if let mutable = currentText.mutableCopy() as? NSMutableString {
                                mutable.replaceCharacters(in: nsRange, with: insertionText)
                                newString = mutable as String
                            } else {
                                newString = (currentText as NSString).replacingCharacters(in: nsRange, with: insertionText)
                            }
                            print("Calculated newString (replace): \(newString)")
                        } else {
                            print("Invalid selection range (\(rangeLocation), \(rangeLength)) for text length \(currentText.count) - appending.")
                            newString = currentText + insertionText
                            print("Calculated newString (append): \(newString)")
                        }

                    } else {
                         print("Could not extract CFRange from AXValue – appending.")
                         newString = currentText + insertionText
                    }
                } else {
                    print("Could not get selection range or it wasn't a CFRange – appending.")
                    newString = currentText + insertionText
                }

                print("Attempting AXUIElementSetAttributeValue with: \(newString)")
                if AXUIElementSetAttributeValue(axElement,
                                                kAXValueAttribute as CFString,
                                                newString as CFTypeRef) == .success {
                    print("Inserted via AXUIElementSetAttributeValue ✓")
                    self.resetUI()
                    return
                } else {
                    print("AXUIElementSetAttributeValue failed; falling back.")
                }
            } else {
                 print("AXValueAttribute not settable; falling back.")
            }

            if insertionText.count > 40 {
                self.insertViaPasteboard(text: insertionText)
                return
            }

            print("Falling back to typing simulation.")
            self.typeText(insertionText)
        }
    }

    // --- REVERTED typeText to use CGEvent directly ---
    func typeText(_ text: String) {
        print("Starting CGEvent typing simulation...")
        let source = CGEventSource(stateID: .hidSystemState)
        guard let source = source else {
            print("Error: Could not create event source for typing.")
            resetUI(showError: true, message: "Typing Event Error")
            return
        }

        for scalar in text.unicodeScalars {
            var utf16Chars = [UniChar]()
            utf16Chars.append(contentsOf: String(scalar).utf16)

            if let keyDownEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                keyDownEvent.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: &utf16Chars)
                keyDownEvent.post(tap: .cgSessionEventTap)
            } else {
                print("Warning: Could not create keyDown CGEvent for scalar \(scalar)")
            }

            if let keyUpEvent = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUpEvent.post(tap: .cgSessionEventTap)
            } else {
                print("Warning: Could not create keyUp CGEvent for scalar \(scalar)")
            }
        }
        print("Finished CGEvent typing simulation.")
        resetUI()
    }

    // (Keep your existing insertViaPasteboard method)
    func insertViaPasteboard(text: String) {
        print("Using Pasteboard fallback method...")
        let pasteboard = NSPasteboard.general

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            print("Error: Failed to set string on pasteboard.")
            resetUI(showError: true, message: "Pasteboard Error")
            return
        }
        print("Text copied to pasteboard (clipboard overwritten).")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            print("Simulating Cmd+V keystroke...")
            let source = CGEventSource(stateID: .hidSystemState)
            guard let source = source else {
                print("Error: Could not create event source for paste.")
                self.resetUI(showError: true, message: "Paste Event Error")
                return
            }

            let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)

            guard let keyVDown = keyVDown, let keyVUp = keyVUp else {
                 print("Error: Could not create Cmd+V key events.")
                 self.resetUI(showError: true, message: "Paste Event Error")
                 return
            }

            keyVDown.flags = .maskCommand
            keyVUp.flags = .maskCommand

            keyVDown.post(tap: .cgSessionEventTap)
            keyVUp.post(tap: .cgSessionEventTap)
            print("Cmd+V simulation posted.")

             self.resetUI()
        }
    }


    // MARK: - Hot‑key updater (If using KeyboardShortcuts library elsewhere)
    func updateHotkey(to sc: KeyboardShortcuts.Shortcut) {
        print("Updating hotkey via KeyboardShortcuts.Shortcut")
        if let key = sc.key {
            hotkeyCode = CGKeyCode(key.rawValue)
        } else {
             print("Warning: KeyboardShortcuts.Shortcut had nil key.")
        }
        hotkeyModifiers = CGEventFlags(rawValue: UInt64(sc.modifiers.rawValue))

        defaults.set(Int(hotkeyCode), forKey: "HotkeyKeyCode")
        defaults.set(Int(hotkeyModifiers.rawValue), forKey: "HotkeyModifiers")
        print("Persisted new hotkey from KeyboardShortcuts: Code=\(hotkeyCode), Mods=\(hotkeyModifiers.rawValue)")

        let formattedHotkey = formatHotkey(code: hotkeyCode, mods: hotkeyModifiers)
        statusItem?.button?.toolTip = "WhisperType (Listening for \(formattedHotkey))"
    }


    // --- Helper to Reset UI ---
    func resetUI(showError: Bool = false, message: String? = nil) {
        DispatchQueue.main.async {
            if !self.isHotkeyActive && !self.isRecording && !self.awaitingHotkeyCapture {
                if showError {
                    self.statusItem?.button?.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Error Status")
                    self.statusItem?.button?.toolTip = "Error: \(message ?? "Unknown Error")"
                    print("UI Reset: Showing Error - \(message ?? "Unknown Error")")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        if !self.isHotkeyActive && !self.isRecording && !self.awaitingHotkeyCapture {
                           self.resetUI()
                        }
                    }
                } else {
                    let currentHotkeyText = self.formatHotkey(code: self.hotkeyCode, mods: self.hotkeyModifiers)
                    self.statusItem?.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "WhisperType Idle Status")
                    self.statusItem?.button?.toolTip = "WhisperType (Listening for \(currentHotkeyText))"
                    print("UI Reset: Now Listening for \(currentHotkeyText)")
                }
            } else {
                var stateReason = [String]()
                if self.isHotkeyActive { stateReason.append("Hotkey Active") }
                if self.isRecording { stateReason.append("Recording") }
                if self.awaitingHotkeyCapture { stateReason.append("Awaiting Capture") }
                print("resetUI called but state prevents immediate reset: \(stateReason.joined(separator: ", ")). Ignoring for now.")
            }
        }
    }


    // --- Unified Event Handling (Callback for the Global CGEvent Tap) ---
    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {

        // --- Section 1: Hotkey Capture Logic ---
        if awaitingHotkeyCapture {
            if type == .keyDown {
                let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags
                print("handleEvent: Capture mode detected keyDown: Code=\(keyCode), Flags=\(flags.rawValue)")

                if keyCode == kVK_Escape {
                    awaitingHotkeyCapture = false
                    print("Hotkey capture cancelled by Escape key.")
                    DispatchQueue.main.async {
                        self.resetUI()
                    }
                    return nil
                }

                let capturedModifiers = flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn])

                self.hotkeyCode = keyCode
                self.hotkeyModifiers = capturedModifiers
                self.defaults.set(Int(keyCode), forKey: "HotkeyKeyCode")
                self.defaults.set(Int(capturedModifiers.rawValue), forKey: "HotkeyModifiers")
                let formattedHotkey = self.formatHotkey(code: keyCode, mods: capturedModifiers)
                print("Captured new hotkey via global tap: \(formattedHotkey)")

                awaitingHotkeyCapture = false

                DispatchQueue.main.async {
                    let confirm = NSAlert()
                    confirm.messageText = "Hotkey Updated"
                    confirm.informativeText = "New hotkey: \(formattedHotkey)"
                    confirm.addButton(withTitle: "OK")
                    NSApp.activate(ignoringOtherApps: true)
                    confirm.runModal()
                    self.resetUI()
                    print("Global tap remains active. Now listening for \(formattedHotkey).")
                }
                return nil
            }
             if type == .flagsChanged || type == .keyUp {
                 return nil
             }
            return Unmanaged.passUnretained(event)
        }

        // --- Section 2: Normal Hotkey Operation Logic ---
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                print("Event tap disabled (\(type == .tapDisabledByTimeout ? "Timeout" : "UserInput")). Attempting to re-enable.")
                if let tap = self.eventTap {
                   CGEvent.tapEnable(tap: tap, enable: true)
                   if !CGEvent.tapIsEnabled(tap: tap) {
                       print("Error: Failed to re-enable event tap. Resetting.")
                       self.checkAndSetupHotkeyListener()
                   } else {
                       print("Event tap re-enabled successfully.")
                   }
                } else {
                   print("Event tap was nil, cannot re-enable. Attempting full setup.")
                   self.checkAndSetupHotkeyListener()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        let currentKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let currentFlags = event.flags

        if type == .keyDown {
            if !isHotkeyActive && currentKeyCode == hotkeyCode && currentFlags.contains(hotkeyModifiers) {
                let relevantFlags = currentFlags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn])
                if relevantFlags == hotkeyModifiers {
                    isHotkeyActive = true
                    let formattedHotkey = self.formatHotkey(code: hotkeyCode, mods: hotkeyModifiers)
                    print("Hotkey PRESSED: \(formattedHotkey)")
                    DispatchQueue.main.async {
                        self.statusItem?.button?.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Recording Status")
                        self.statusItem?.button?.toolTip = "WhisperType (Recording)"
                        self.startRecording()
                    }
                    return nil
                }
            } else if isHotkeyActive {
                return nil
            }
        }
        else if isHotkeyActive && (type == .keyUp || type == .flagsChanged) {
            let keyReleased = (type == .keyUp && currentKeyCode == hotkeyCode)
            let modifiersNoLongerMatch = !currentFlags.contains(self.hotkeyModifiers)

            if keyReleased || modifiersNoLongerMatch {
                 isHotkeyActive = false
                 let formattedHotkey = self.formatHotkey(code: hotkeyCode, mods: hotkeyModifiers)
                 print("Hotkey RELEASED: \(formattedHotkey) (Trigger: \(keyReleased ? "Key Up (\(currentKeyCode))" : "Flags Changed"))")

                 DispatchQueue.main.async {
                     self.stopRecording()
                     self.resetUI()
                 }

                 if keyReleased {
                     print("Consuming hotkey keyUp event.")
                     return nil
                 }
                 if modifiersNoLongerMatch && type == .flagsChanged {
                      print("Consuming flagsChanged event that released hotkey.")
                      return nil
                 }
            }
        }
        return Unmanaged.passUnretained(event)
    }


    // MARK: - Preferences UI
    @objc func showPreferences() {
        let alert = NSAlert()
        alert.messageText = "WhisperType Preferences"
        alert.informativeText = "Set your Ollama model and hotkey."
        alert.addButton(withTitle: "Set Model…") // NSApplication.ModalResponse.alertFirstButtonReturn
        alert.addButton(withTitle: "Set Hotkey…")// NSApplication.ModalResponse.alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")     // NSApplication.ModalResponse.alertThirdButtonReturn
        NSApp.activate(ignoringOtherApps: true) // Ensure alert is frontmost
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { // Set Model
            self.promptModel()
        } else if response == .alertSecondButtonReturn { // Set Hotkey
           beginInlineHotkeyCapture() // Call the simplified capture initiation
        }
    }

    // --- Fetch Ollama Models ---
    func fetchOllamaModels(completion: @escaping (Result<[String], Error>) -> Void) {
        print("Fetching Ollama models from \(ollamaTagsUrl)...")
        let request = URLRequest(url: ollamaTagsUrl) // Use GET by default

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            // Ensure completion handler is called on the main thread for UI updates
            DispatchQueue.main.async {
                if let error = error {
                    print("Error fetching Ollama tags: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    print("Error: Ollama tags endpoint returned status code \(statusCode)")
                    let statusError = NSError(domain: "OllamaAPIError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch models (status code: \(statusCode))"])
                    completion(.failure(statusError))
                    return
                }
                guard let data = data else {
                    print("Error: No data received from Ollama tags endpoint.")
                    let noDataError = NSError(domain: "OllamaAPIError", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received from Ollama tags endpoint."])
                    completion(.failure(noDataError))
                    return
                }

                do {
                    let decoder = JSONDecoder()
                    let tagsResponse = try decoder.decode(OllamaTagsResponse.self, from: data)
                    let modelNames = tagsResponse.models.map { $0.name }.sorted() // Extract names and sort
                    print("Successfully fetched \(modelNames.count) models.")
                    completion(.success(modelNames))
                } catch {
                    print("Error decoding Ollama tags response: \(error)")
                    completion(.failure(error))
                }
            }
        }
        task.resume()
    }

    // --- UPDATED Model Prompt with Dropdown ---
    @objc func promptModel() {
        let alert = NSAlert()
        alert.messageText = "Set Ollama Model"
        alert.informativeText = "Select the Ollama model to use:"
        alert.addButton(withTitle: "OK")     // NSApplication.ModalResponse.alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel") // NSApplication.ModalResponse.alertSecondButtonReturn

        // Create the PopUpButton
        let popUpButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 25), pullsDown: false) // Standard height
        popUpButton.addItems(withTitles: ["Fetching models..."]) // Placeholder
        popUpButton.isEnabled = false // Disable until models are loaded

        alert.accessoryView = popUpButton

        // Activate app to bring alert window forward
        NSApp.activate(ignoringOtherApps: true)
        // Set focus to the popup button initially
        alert.window.initialFirstResponder = popUpButton

        // Fetch models asynchronously
        fetchOllamaModels { [weak self, weak popUpButton] result in
            guard let self = self, let popUpButton = popUpButton else { return }

            popUpButton.removeAllItems() // Clear placeholder/previous items

            switch result {
            case .success(let modelNames):
                if modelNames.isEmpty {
                    popUpButton.addItem(withTitle: "No models found")
                    popUpButton.isEnabled = false
                } else {
                    popUpButton.addItems(withTitles: modelNames)
                    popUpButton.isEnabled = true
                    // Try to pre-select the current model
                    if popUpButton.item(withTitle: self.ollamaModelName) != nil {
                        popUpButton.selectItem(withTitle: self.ollamaModelName)
                    } else if let firstModel = modelNames.first {
                        // If current model not found, select the first available one
                        popUpButton.selectItem(withTitle: firstModel)
                        print("Current model '\(self.ollamaModelName)' not found in list, selecting first: '\(firstModel)'")
                    }
                }
            case .failure(let error):
                print("Failed to populate models: \(error.localizedDescription)")
                popUpButton.addItem(withTitle: "Error fetching models")
                popUpButton.isEnabled = false
            }
        } // End fetchOllamaModels completion handler

        // Run the modal alert
        let response = alert.runModal()

        if response == .alertFirstButtonReturn { // OK pressed
            if let selectedModel = popUpButton.titleOfSelectedItem,
               popUpButton.isEnabled { // Ensure a valid model was selectable
                if selectedModel != self.ollamaModelName {
                    self.ollamaModelName = selectedModel
                    self.defaults.set(selectedModel, forKey: "OllamaModelName")
                    print("Ollama model updated to: \(selectedModel)")
                } else {
                    print("Selected model is the same as the current one.")
                }
            } else {
                 print("No valid model selected or available.")
            }
        } else {
             print("Model selection cancelled.")
        }
    } // End promptModel


    // --- Updated Hotkey Capture Initiation ---
    @objc func beginInlineHotkeyCapture() {
        let info = NSAlert()
        info.messageText = "Set New Hotkey"
        info.informativeText = "Click 'Start Capture', then press the exact key combination you want to use.\n\n(Press the Escape key to cancel during capture)"
        info.addButton(withTitle: "Start Capture") // 1000
        info.addButton(withTitle: "Cancel")      // 1001

        NSApp.activate(ignoringOtherApps: true)

        let response = info.runModal()
        print("Set Hotkey info alert dismissed with response code: \(response.rawValue)")

        if response == .alertFirstButtonReturn { // 1000 = Start Capture
             awaitingHotkeyCapture = true
             print("Awaiting hotkey capture via global event tap... (awaitingHotkeyCapture = \(awaitingHotkeyCapture))")

             DispatchQueue.main.async {
                 print("Updating UI for capture mode...")
                 self.statusItem?.button?.toolTip = "Press desired hotkey (Esc to cancel)"
                 self.statusItem?.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Capturing Hotkey")
             }
        } else {
             print("Hotkey capture initiation cancelled by user.")
        }
    }


    // --- Hotkey Formatting Helper ---
    private func formatHotkey(code: CGKeyCode, mods: CGEventFlags) -> String {
        var pieces: [String] = []
        if mods.contains(.maskControl)   { pieces.append("⌃") } // Control
        if mods.contains(.maskAlternate) { pieces.append("⌥") } // Option/Alt
        if mods.contains(.maskShift)     { pieces.append("⇧") } // Shift
        if mods.contains(.maskCommand)   { pieces.append("⌘") } // Command

        var keyName: String? = nil

        if let currentLayout = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
            let layoutDataRef = TISGetInputSourceProperty(currentLayout, kTISPropertyUnicodeKeyLayoutData)
            if layoutDataRef != nil {
                 let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataRef!).takeUnretainedValue() as Data
                 keyName = layoutData.withUnsafeBytes { layoutBytes -> String? in
                     guard let keyboardLayout = layoutBytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                         print("formatHotkey: Failed to bind keyboard layout memory.")
                         return nil
                     }
                     var deadKeyState: UInt32 = 0
                     let maxChars = 4
                     var actualChars = 0
                     var unicodeChars = [UniChar](repeating: 0, count: maxChars)
                     var carbonModifiers: UInt32 = 0
                     if mods.contains(.maskShift)     { carbonModifiers |= UInt32(shiftKey) }
                     if mods.contains(.maskControl)   { carbonModifiers |= UInt32(controlKey) }
                     if mods.contains(.maskAlternate) { carbonModifiers |= UInt32(optionKey) }
                     if mods.contains(.maskCommand)   { carbonModifiers |= UInt32(cmdKey) }

                     let status = UCKeyTranslate(keyboardLayout,
                                                 UInt16(code),
                                                 UInt16(kUCKeyActionDisplay),
                                                 (carbonModifiers >> 8) & 0xFF,
                                                 UInt32(LMGetKbdType()),
                                                 UInt32(kUCKeyTranslateNoDeadKeysBit),
                                                 &deadKeyState,
                                                 maxChars,
                                                 &actualChars,
                                                 &unicodeChars)

                     if status == noErr && actualChars > 0 {
                         let char = String(utf16CodeUnits: unicodeChars, count: actualChars)
                         switch Int(code) {
                             case kVK_Space: return "Space"
                             case kVK_Return: return "Return"
                             case kVK_Tab: return "Tab"
                             case kVK_Escape: return "Esc"
                             case kVK_Delete: return "Delete"
                             case kVK_ForwardDelete: return "Fwd Del"
                             case kVK_LeftArrow: return "←"
                             case kVK_RightArrow: return "→"
                             case kVK_UpArrow: return "↑"
                             case kVK_DownArrow: return "↓"
                             case kVK_Home: return "Home"
                             case kVK_End: return "End"
                             case kVK_PageUp: return "PgUp"
                             case kVK_PageDown: return "PgDn"
                             case kVK_F1...kVK_F20: return "F\(Int(code) - kVK_F1 + 1)"
                             default:
                                 let trimmedChar = char.trimmingCharacters(in: .whitespacesAndNewlines)
                                 if trimmedChar.isEmpty && !char.isEmpty { return nil }
                                 return trimmedChar.isEmpty ? nil : trimmedChar.uppercased()
                         }
                     } else {
                         return nil
                     }
                 }
             }
        }

        if keyName == nil || keyName!.isEmpty {
            switch Int(code) {
                case kVK_Space: keyName = "Space"; case kVK_Escape: keyName = "Esc"; case kVK_Return: keyName = "Return"; case kVK_Delete: keyName = "Delete"; case kVK_ForwardDelete: keyName = "Fwd Del"; case kVK_Tab: keyName = "Tab"
                case kVK_F1...kVK_F20: keyName = "F\(Int(code) - kVK_F1 + 1)"
                case kVK_UpArrow: keyName = "↑"; case kVK_DownArrow: keyName = "↓"; case kVK_LeftArrow: keyName = "←"; case kVK_RightArrow: keyName = "→"
                case kVK_Home: keyName = "Home"; case kVK_End: keyName = "End"; case kVK_PageUp: keyName = "PgUp"; case kVK_PageDown: keyName = "PgDn"
                default: keyName = String(format: "Key #%d", code)
            }
        }

        pieces.append(keyName ?? "<???>")
        return pieces.joined()
    }

    // MARK: - NSAlert Help (Optional)
    func alertShowHelp(_ alert: NSAlert) -> Bool {
         print("Help requested for alert: \(alert.messageText)")
         return false
    }

    // MARK: - NSTextFieldDelegate Methods
    func controlTextDidChange(_ obj: Notification) {
        // Optional: Add logic here if needed when text changes
    }

    // <<< REMOVED: No longer needed for NSPopUpButton >>>
    // func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool { ... }


} // **** Final closing brace for the AppDelegate class ****


// MARK: - Convenience accessor (Optional)
extension AppDelegate {
    static var shared: AppDelegate {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            fatalError("AppDelegate instance not found. Check @main attribute and application lifecycle.")
        }
        return delegate
    }
}

//
//  AppDelegate.swift
//  WhisperType
//
//  Created by [Your Name/Organization] on [Date]
//  Handles the main application lifecycle, status bar item,
//  global event monitoring, audio recording, transcription,
//  Ollama interaction, and preferences for WhisperType.
//

import Cocoa
import CoreGraphics
import AVFoundation
import Accessibility // For AXUIElement types
import Carbon.HIToolbox // For TIS/... and UCKeyTranslate/...
// import KeyboardShortcuts // Removed as updateHotkey(to:) was unused in this file. Re-add if used elsewhere.

// MARK: - Ollama API Data Structures

/// Represents the response structure from the Ollama `/api/tags` endpoint.
struct OllamaTagsResponse: Codable {
    let models: [OllamaModel]
}

/// Represents a single model returned by the Ollama `/api/tags` endpoint.
struct OllamaModel: Codable {
    let name: String
    // Other potential fields (modified_at, size, digest) are ignored for now.
}

/// Represents the request body structure for the Ollama `/api/generate` endpoint.
struct OllamaGenerateRequest: Codable {
    let model: String
    let prompt: String
    var stream: Bool = false // Ollama defaults to false, but explicitly set here.
}

/// Represents the response structure from the Ollama `/api/generate` endpoint (non-streaming).
struct OllamaGenerateResponse: Codable {
    let model: String
    let created_at: String
    let response: String
    let done: Bool
}

// MARK: - Error Types

/// Custom errors for Ollama interactions.
enum OllamaError: Error, LocalizedError {
    case networkError(Error)
    case invalidStatusCode(Int)
    case noDataReceived
    case decodingError(Error)
    case encodingError(Error)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .networkError(let underlyingError):
            return "Network request failed: \(underlyingError.localizedDescription)"
        case .invalidStatusCode(let code):
            return "Ollama API returned non-success status code: \(code)"
        case .noDataReceived:
            return "No data received from Ollama API."
        case .decodingError(let underlyingError):
            return "Failed to decode Ollama API response: \(underlyingError.localizedDescription)"
        case .encodingError(let underlyingError):
            return "Failed to encode Ollama API request: \(underlyingError.localizedDescription)"
        case .emptyResponse:
            return "Ollama API returned an empty response."
        }
    }
}

/// Custom errors for application setup and operation.
enum AppError: Error, LocalizedError {
    case statusBarSetupFailed
    case eventTapCreationFailed
    case eventTapSourceCreationFailed
    case eventTapEnableFailed
    case audioRecorderSetupFailed(Error)
    case audioRecorderPrepareFailed
    case audioRecordingSaveFailed
    case transcriptionResourceMissing
    case transcriptionProcessLaunchFailed(Error)
    case transcriptionFailed(Int, String) // status code, output
    case accessibilityFocusError(AXError)
    case accessibilityValueError
    case accessibilitySetAttributeFailed
    case pasteboardError
    case typingEventSourceError
    case pasteEventSourceError
    case pasteKeyEventError

    // Provide localized descriptions for user-facing errors if needed
    var errorDescription: String? {
        switch self {
            case .statusBarSetupFailed: return "Failed to set up status bar item."
            case .eventTapCreationFailed: return "Failed to create keyboard event listener. Check Accessibility permissions."
            case .eventTapSourceCreationFailed: return "Failed to create event listener source."
            case .eventTapEnableFailed: return "Failed to enable event listener."
            case .audioRecorderSetupFailed(let err): return "Failed to set up audio recorder: \(err.localizedDescription)"
            case .audioRecorderPrepareFailed: return "Audio recorder failed to prepare."
            case .audioRecordingSaveFailed: return "Failed to save audio recording."
            case .transcriptionResourceMissing: return "Missing required transcription resources (whisper-cli or model)."
            case .transcriptionProcessLaunchFailed(let err): return "Failed to launch transcription process: \(err.localizedDescription)"
            case .transcriptionFailed(let status, let output): return "Transcription failed (Status: \(status)). Output: \(output)"
            case .accessibilityFocusError(let axErr): return "Could not get focused UI element (Error: \(axErr))."
            case .accessibilityValueError: return "Could not read value from focused UI element."
            case .accessibilitySetAttributeFailed: return "Could not set value for focused UI element."
            case .pasteboardError: return "Failed to write to pasteboard."
            case .typingEventSourceError: return "Could not create typing event source."
            case .pasteEventSourceError: return "Could not create paste event source."
            case .pasteKeyEventError: return "Could not create paste key events."
        }
    }
}


// MARK: - AppDelegate Implementation

// NOTE: No @main here, using main.swift instead
class AppDelegate: NSObject, NSApplicationDelegate, AVAudioRecorderDelegate, NSAlertDelegate, NSWindowDelegate {

    // MARK: - Properties

    // --- UI Elements ---
    private var statusItem: NSStatusItem?

    // --- Event Handling ---
    private var eventTap: CFMachPort? // Global CGEvent tap
    private var eventTapRunLoopSource: CFRunLoopSource? // Source for the global tap
    private var isHotkeyActive: Bool = false // Is the main hotkey currently pressed down?
    private var awaitingHotkeyCapture = false // Is the app waiting for the user to press a new hotkey combo?

    // --- Configuration ---
    struct Config {
        static let defaultModelName = "llama3:latest"
        static let ollamaGenerateURL = URL(string: "http://localhost:11434/api/generate")!
        static let ollamaTagsURL = URL(string: "http://localhost:11434/api/tags")!
        static let defaultHotkeyCode: CGKeyCode = CGKeyCode(kVK_Space)
        static let defaultHotkeyModifiers: CGEventFlags = .maskControl
        static let audioSampleRate: Double = 16000.0
        static let audioChannels: Int = 1
        static let audioBitDepth: Int = 16
        static let whisperCliName = "whisper-cli"
        static let whisperModelName = "ggml-base.en.bin"
        static let userDefaultsModelKey = "OllamaModelName"
        static let userDefaultsHotkeyCodeKey = "HotkeyKeyCode"
        static let userDefaultsHotkeyModsKey = "HotkeyModifiers"
        static let longTextThresholdForPaste = 40
    }
    private var ollamaModelName: String = Config.defaultModelName
    private var hotkeyCode: CGKeyCode = Config.defaultHotkeyCode
    private var hotkeyModifiers: CGEventFlags = Config.defaultHotkeyModifiers

    // --- Audio Recording ---
    private var audioRecorder: AVAudioRecorder?
    private var recordingFileURL: URL?
    var isRecording: Bool = false

    // --- Services ---
    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let urlSession = URLSession.shared


    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("--- applicationDidFinishLaunching: START ---")
        loadConfiguration()
        setupStatusBar()
        checkAndSetupHotkeyListener()
        print("--- applicationDidFinishLaunching: Attempting to activate app ---")
        NSApp.activate(ignoringOtherApps: true)
        print("--- applicationDidFinishLaunching: FINISHED ---")
    }

    @objc func quitApp() {
        print("Quit action triggered from menu.")
        self.stopRecording()
        self.disableEventTap()
        NSApplication.shared.terminate(self)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        print("Application will terminate.")
        self.stopRecording()
        self.disableEventTap()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Configuration Loading

    private func loadConfiguration() {
        print("Loading configuration...")
        if let savedModel = defaults.string(forKey: Config.userDefaultsModelKey), !savedModel.isEmpty {
            ollamaModelName = savedModel
            print("Loaded saved model: \(ollamaModelName)")
        } else {
            print("Using default model: \(ollamaModelName)")
        }
        let savedKey = defaults.integer(forKey: Config.userDefaultsHotkeyCodeKey)
        hotkeyCode = (savedKey != 0) ? CGKeyCode(savedKey) : Config.defaultHotkeyCode
        if defaults.object(forKey: Config.userDefaultsHotkeyModsKey) != nil {
            let savedModsRaw = defaults.integer(forKey: Config.userDefaultsHotkeyModsKey)
            hotkeyModifiers = CGEventFlags(rawValue: UInt64(savedModsRaw))
        } else {
            hotkeyModifiers = Config.defaultHotkeyModifiers
        }
        print("Loaded hotkey: Code=\(hotkeyCode), Mods=\(hotkeyModifiers.rawValue)")
    }

    // MARK: - Status Bar Setup

    private func setupStatusBar() {
        print("Setting up status bar item...")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else {
            handleError(AppError.statusBarSetupFailed, fatal: true)
            return
        }
        button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "WhisperType Idle Status") ?? NSImage(named: "WT")
        button.toolTip = "WhisperType (Initializing)"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit WhisperType", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
        print("Status bar setup complete.")
        self.resetUI()
    }

    // MARK: - Global Event Tap Management

    private func checkAndSetupHotkeyListener() {
        print("Checking Accessibility Permissions...")
        if !AXIsProcessTrusted() {
            print("Warning: AXIsProcessTrusted() returned false. Manual grant required in System Settings > Privacy & Security > Accessibility.")
        }
        setupEventTap()
    }

    private func setupEventTap() {
        disableEventTap()
        print("Attempting to set up new event tap...")
        let eventMask: CGEventMask = [
            1 << CGEventType.keyDown.rawValue, 1 << CGEventType.keyUp.rawValue, 1 << CGEventType.flagsChanged.rawValue
        ].reduce(0) { $0 | $1 }
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: eventMask, callback: AppDelegate.eventTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let newTap = eventTap else { handleError(AppError.eventTapCreationFailed); return }
        print("New event tap created successfully.")
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            handleError(AppError.eventTapSourceCreationFailed); self.eventTap = nil; return
        }
        self.eventTapRunLoopSource = newSource
        print("New run loop source created and stored.")
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        print("New run loop source added to main run loop.")
        CGEvent.tapEnable(tap: newTap, enable: true)
        if !CGEvent.tapIsEnabled(tap: newTap) {
            handleError(AppError.eventTapEnableFailed)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), newSource, .commonModes); self.eventTapRunLoopSource = nil; self.eventTap = nil; return
        }
        let currentHotkeyText = formatHotkey(code: hotkeyCode, mods: hotkeyModifiers)
        print("New event tap enabled. Listening for \(currentHotkeyText)...")
        self.updateStatusItem(imageName: "mic.fill", accessibilityDescription: "WhisperType Listening", toolTip: "WhisperType (Listening for \(currentHotkeyText))")
    }

    private func disableEventTap() {
        if let tap = eventTap {
            print("Disabling event tap...")
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = eventTapRunLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); eventTapRunLoopSource = nil }
            eventTap = nil; print("Event tap disabled and references cleared.")
        }
        if eventTapRunLoopSource != nil { print("Warning: eventTap was nil but source was not. Clearing source."); eventTapRunLoopSource = nil }
    }

    // MARK: - Event Handling (Static Callback Wrapper)

    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
        guard let refcon = refcon else { return Unmanaged.passRetained(event) }
        let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
        return appDelegate.handleEvent(proxy: proxy, type: type, event: event)
    }

    // MARK: - Instance Event Handling Logic

    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if awaitingHotkeyCapture { return handleHotkeyCaptureEvent(type: type, event: event) }
        return handleNormalHotkeyEvent(type: type, event: event)
    }

    private func handleHotkeyCaptureEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else { return (type == .flagsChanged || type == .keyUp) ? nil : Unmanaged.passUnretained(event) }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        print("handleEvent: Capture mode detected keyDown: Code=\(keyCode)")
        if keyCode == kVK_Escape {
            awaitingHotkeyCapture = false; print("Hotkey capture cancelled by Escape key.")
            DispatchQueue.main.async { self.resetUI() }; return nil
        }
        let flags = event.flags
        let capturedModifiers = flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn])
        self.hotkeyCode = keyCode; self.hotkeyModifiers = capturedModifiers
        self.defaults.set(Int(keyCode), forKey: Config.userDefaultsHotkeyCodeKey)
        self.defaults.set(Int(capturedModifiers.rawValue), forKey: Config.userDefaultsHotkeyModsKey)
        let formattedHotkey = self.formatHotkey(code: keyCode, mods: capturedModifiers)
        print("Captured new hotkey via global tap: \(formattedHotkey)")
        awaitingHotkeyCapture = false
        DispatchQueue.main.async {
            self.showConfirmationAlert(title: "Hotkey Updated", message: "New hotkey: \(formattedHotkey)")
            self.resetUI(); print("Global tap remains active. Now listening for \(formattedHotkey).")
        }
        return nil
    }

    private func handleNormalHotkeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { handleTapDisable() }
            return Unmanaged.passUnretained(event)
        }
        let currentKeyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let currentFlags = event.flags
        if type == .keyDown {
            let relevantFlags = currentFlags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn])
            if !isHotkeyActive && currentKeyCode == hotkeyCode && relevantFlags == hotkeyModifiers {
                isHotkeyActive = true; let formattedHotkey = self.formatHotkey(code: hotkeyCode, mods: hotkeyModifiers)
                print("Hotkey PRESSED: \(formattedHotkey)")
                DispatchQueue.main.async {
                    self.updateStatusItem(imageName: "mic.circle.fill", accessibilityDescription: "Recording Status", toolTip: "WhisperType (Recording)")
                    self.startRecording()
                }
                return nil
            } else if isHotkeyActive { return nil }
        } else if isHotkeyActive && (type == .keyUp || type == .flagsChanged) {
            let keyReleased = (type == .keyUp && currentKeyCode == hotkeyCode)
            let modifiersNoLongerMatch = !currentFlags.contains(self.hotkeyModifiers)
            if keyReleased || modifiersNoLongerMatch {
                 isHotkeyActive = false; let formattedHotkey = self.formatHotkey(code: hotkeyCode, mods: hotkeyModifiers)
                 print("Hotkey RELEASED: \(formattedHotkey) (Trigger: \(keyReleased ? "Key Up (\(currentKeyCode))" : "Flags Changed"))")
                 DispatchQueue.main.async { self.stopRecording(); self.resetUI() }
                 if keyReleased { return nil }
                 if modifiersNoLongerMatch && type == .flagsChanged { return nil }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleTapDisable() {
         print("Event tap disabled (Timeout or UserInput). Attempting to re-enable.")
         if let tap = self.eventTap {
             CGEvent.tapEnable(tap: tap, enable: true)
             if !CGEvent.tapIsEnabled(tap: tap) { print("Error: Failed to re-enable event tap. Resetting."); self.checkAndSetupHotkeyListener() }
             else { print("Event tap re-enabled successfully.") }
         } else { print("Event tap was nil, cannot re-enable. Attempting full setup."); self.checkAndSetupHotkeyListener() }
     }

    // MARK: - Audio Recording
    func startRecording() {
        guard !isRecording else { print("Already recording."); return }
        print("Attempting to start recording...")
        let tempDir = fileManager.temporaryDirectory
        let fileName = "whisperTypeRecording_\(Date().timeIntervalSince1970).wav"
        recordingFileURL = tempDir.appendingPathComponent(fileName)
        guard let url = recordingFileURL else { handleError(AppError.audioRecordingSaveFailed); return }
        let settings: [String: Any] = [ AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: Config.audioSampleRate, AVNumberOfChannelsKey: Config.audioChannels, AVLinearPCMBitDepthKey: Config.audioBitDepth, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false ]
        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings); audioRecorder?.delegate = self; audioRecorder?.isMeteringEnabled = true
            if audioRecorder?.prepareToRecord() == true { audioRecorder?.record(); isRecording = true; print("Recording started to: \(url.path)") }
            else { isRecording = false; recordingFileURL = nil; handleError(AppError.audioRecorderPrepareFailed) }
        } catch { isRecording = false; recordingFileURL = nil; handleError(AppError.audioRecorderSetupFailed(error)) }
    }
    func stopRecording() { guard isRecording, let recorder = audioRecorder else { return }; print("Stopping recording..."); recorder.stop(); }
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        print("audioRecorderDidFinishRecording called. Success: \(flag)")
        isRecording = false; guard let url = recordingFileURL else { handleError(AppError.audioRecordingSaveFailed); audioRecorder = nil; return }
        let finishedRecordingURL = url; self.recordingFileURL = nil
        DispatchQueue.main.async { if !self.isHotkeyActive && !self.awaitingHotkeyCapture { self.updateStatusItem(imageName: "hourglass.circle", accessibilityDescription: "Processing Status", toolTip: "WhisperType (Processing)") } }
        if flag { print("Recording saved successfully to: \(finishedRecordingURL.path)"); transcribeAudio(fileURL: finishedRecordingURL) }
        else { print("Error: Recording finished unsuccessfully."); handleError(AppError.audioRecordingSaveFailed); try? fileManager.removeItem(at: finishedRecordingURL) }
        audioRecorder = nil
    }

    // MARK: - Transcription
    func transcribeAudio(fileURL: URL) {
        print("Attempting to transcribe audio file: \(fileURL.path)")
        guard let whisperPath = Bundle.main.path(forResource: Config.whisperCliName, ofType: nil),
              let modelPath = Bundle.main.path(forResource: Config.whisperModelName, ofType: nil) else {
            handleError(AppError.transcriptionResourceMissing)
            try? fileManager.removeItem(at: fileURL)
            return
        }
        print("Found whisper executable: \(whisperPath)")
        print("Found model file: \(modelPath)")

        let arguments = [ "-m", modelPath, "-nt", "-l", "en", "-otxt", "-f", fileURL.path ]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = arguments

        // <<< CHANGE: Redirect stdout and stderr to suppress whisper-cli logs >>>
        let nullPipe = Pipe()
        process.standardOutput = nullPipe // Redirect stdout
        process.standardError = nullPipe  // Redirect stderr
        // We no longer need to read from a pipe, as we read the output file directly
        // let outputPipe = Pipe()
        // process.standardOutput = outputPipe
        // <<< END CHANGE >>>

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                print("Launching whisper-cli process...")
                try process.run()
                process.waitUntilExit()
                let statusCode = Int(process.terminationStatus)
                print("whisper-cli process finished with status: \(statusCode)")

                // <<< CHANGE: Read output from file instead of pipe >>>
                // Construct the expected output file path (.txt appended to input)
                let outputFilePath = fileURL.path + ".txt"
                let outputFileURL = URL(fileURLWithPath: outputFilePath)
                var outputText = ""
                if statusCode == 0 {
                    do {
                        outputText = try String(contentsOf: outputFileURL, encoding: .utf8)
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        // Clean up the output text file
                        try? self.fileManager.removeItem(at: outputFileURL)
                    } catch {
                        print("Error reading whisper-cli output file: \(error)")
                        // Proceed with empty output, might still delete audio file
                    }
                }
                // <<< END CHANGE >>>

                DispatchQueue.main.async {
                    if statusCode == 0 && !outputText.isEmpty {
                        print("Transcription successful:\n---\n\(outputText)\n---")
                        self.sendToOllama(rawText: outputText)
                    } else {
                        // Pass the read output (even if empty on error) to the handler
                        self.handleError(AppError.transcriptionFailed(statusCode, outputText))
                    }
                    print("Deleting temporary audio file: \(fileURL.path)")
                    try? self.fileManager.removeItem(at: fileURL) // Delete original audio
                }
            } catch {
                DispatchQueue.main.async {
                    self.handleError(AppError.transcriptionProcessLaunchFailed(error))
                    try? self.fileManager.removeItem(at: fileURL) // Attempt cleanup on launch failure too
                }
            }
        }
    }


    // MARK: - Ollama Interaction
    func sendToOllama(rawText: String) {
        print("Sending text to Ollama for refinement...")
        self.updateStatusItem(imageName: "brain.head.profile", accessibilityDescription: "Thinking Status", toolTip: "WhisperType (Thinking...)")
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
        guard let encodedBody = try? JSONEncoder().encode(requestBody) else { handleError(OllamaError.encodingError(NSError(domain: "EncodingError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode request body."]))); return }
        var request = URLRequest(url: Config.ollamaGenerateURL); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = encodedBody
        let task = urlSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error { self.handleError(OllamaError.networkError(error)); return }
                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else { let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1; self.handleError(OllamaError.invalidStatusCode(statusCode)); return }
                guard let data = data else { self.handleError(OllamaError.noDataReceived); return }
                do {
                    let ollamaResponse = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data); print("Received raw response from Ollama.")
                    var processedText = ollamaResponse.response
                    if let regex = try? NSRegularExpression(pattern: "<think>.*?</think>", options: .dotMatchesLineSeparators) {
                        let range = NSRange(processedText.startIndex..., in: processedText); processedText = regex.stringByReplacingMatches(in: processedText, options: [], range: range, withTemplate: ""); print("Applied regex to remove <think> tags.")
                    }
                    let refinedText = processedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if refinedText.isEmpty { self.handleError(OllamaError.emptyResponse); return }
                    print("Ollama refinement successful (processed):\n---\n\(refinedText)\n---")
                    self.insertRefinedText(text: refinedText)
                } catch { print("Raw Ollama response: \(String(data: data, encoding: .utf8) ?? "Unable to decode raw response")"); self.handleError(OllamaError.decodingError(error)) }
            }
        }
        task.resume()
    }

    // MARK: - Text Insertion
    func insertRefinedText(text: String) {
        let insertionText = text.hasSuffix(" ") || text.hasSuffix("\n") ? text : text + " "
        print("Attempting to insert via Accessibility…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let systemWide = AXUIElementCreateSystemWide(); var focused: AnyObject?; let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
            guard err == .success, let anyElement = focused else { self.handleError(AppError.accessibilityFocusError(err)); self.typeText(text: insertionText); return }
            let axElement = anyElement as! AXUIElement; var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else { print("AXValueAttribute not settable; falling back."); self.fallbackInsert(insertionText); return }
            var currentValueCF: CFTypeRef?; guard AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &currentValueCF) == .success, let currentText = currentValueCF as? String else { self.handleError(AppError.accessibilityValueError); self.fallbackInsert(insertionText); return }
            var selRangeCF: CFTypeRef?; let gotSel = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selRangeCF); var newString: String = currentText + insertionText
            if gotSel == .success, let selAXValue = selRangeCF, CFGetTypeID(selAXValue) == AXValueGetTypeID(), AXValueGetType(selAXValue as! AXValue) == .cfRange {
                var cfRange = CFRange(); if AXValueGetValue(selAXValue as! AXValue, .cfRange, &cfRange) {
                    let rangeLocation = cfRange.location == kCFNotFound ? 0 : cfRange.location; let rangeLength = cfRange.length
                    if let validRange = Range(NSRange(location: rangeLocation, length: rangeLength), in: currentText) {
                        let nsRange = NSRange(validRange, in: currentText); if let mutable = currentText.mutableCopy() as? NSMutableString { mutable.replaceCharacters(in: nsRange, with: insertionText); newString = mutable as String } else { newString = (currentText as NSString).replacingCharacters(in: nsRange, with: insertionText) }
                        print("Calculated newString (replace): \(newString)")
                    } else { print("Invalid selection range - appending.") }
                } else { print("Could not extract CFRange - appending.") }
            } else { print("Could not get selection range - appending.") }
            print("Attempting AXUIElementSetAttributeValue..."); if AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, newString as CFTypeRef) == .success { print("Inserted via AXUIElementSetAttributeValue ✓"); self.resetUI() }
            else { self.handleError(AppError.accessibilitySetAttributeFailed); self.fallbackInsert(insertionText) }
        }
    }

    private func fallbackInsert(_ text: String) { if text.count > Config.longTextThresholdForPaste { insertViaPasteboard(text: text) } else { typeText(text: text) } }

    private func typeText(text: String) {
        print("Starting CGEvent typing simulation..."); guard let source = CGEventSource(stateID: .hidSystemState) else { handleError(AppError.typingEventSourceError); return }
        for scalar in text.unicodeScalars { var utf16Chars = [UniChar](String(scalar).utf16); if let kd = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) { kd.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: &utf16Chars); kd.post(tap: .cgSessionEventTap) } else { print("Warning: Could not create keyDown CGEvent for scalar \(scalar)") }; if let ku = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) { ku.post(tap: .cgSessionEventTap) } else { print("Warning: Could not create keyUp CGEvent for scalar \(scalar)") } }
        print("Finished CGEvent typing simulation."); resetUI()
    }

    private func insertViaPasteboard(text: String) {
        print("Using Pasteboard fallback method..."); let pasteboard = NSPasteboard.general; pasteboard.clearContents(); guard pasteboard.setString(text, forType: .string) else { handleError(AppError.pasteboardError); return }; print("Text copied to pasteboard (clipboard overwritten).")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            print("Simulating Cmd+V keystroke..."); guard let source = CGEventSource(stateID: .hidSystemState) else { self.handleError(AppError.pasteEventSourceError); return }
            let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true); let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false); guard let keyVDown = keyVDown, let keyVUp = keyVUp else { self.handleError(AppError.pasteKeyEventError); return }
            keyVDown.flags = .maskCommand; keyVUp.flags = .maskCommand; keyVDown.post(tap: .cgSessionEventTap); keyVUp.post(tap: .cgSessionEventTap); print("Cmd+V simulation posted."); self.resetUI()
        }
    }


    // MARK: - Preferences UI
    @objc func showPreferences() {
        let alert = NSAlert(); alert.messageText = "WhisperType Preferences"; alert.informativeText = "Set your Ollama model and hotkey."
        alert.addButton(withTitle: "Set Model…"); alert.addButton(withTitle: "Set Hotkey…"); alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true); let response = alert.runModal()
        switch response { case .alertFirstButtonReturn: self.promptModel(); case .alertSecondButtonReturn: beginInlineHotkeyCapture(); default: print("Preferences cancelled.") }
    }

    func fetchOllamaModels(completion: @escaping (Result<[String], Error>) -> Void) {
        print("Fetching Ollama models from \(Config.ollamaTagsURL)..."); let request = URLRequest(url: Config.ollamaTagsURL)
        let task = urlSession.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error { print("Error fetching Ollama tags: \(error.localizedDescription)"); completion(.failure(OllamaError.networkError(error))); return }
                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else { let sc = (response as? HTTPURLResponse)?.statusCode ?? -1; print("Error: Ollama tags endpoint returned status code \(sc)"); completion(.failure(OllamaError.invalidStatusCode(sc))); return }
                guard let data = data else { print("Error: No data received from Ollama tags endpoint."); completion(.failure(OllamaError.noDataReceived)); return }
                do { let tagsResponse = try JSONDecoder().decode(OllamaTagsResponse.self, from: data); let modelNames = tagsResponse.models.map { $0.name }.sorted(); print("Successfully fetched \(modelNames.count) models."); completion(.success(modelNames)) }
                catch { print("Error decoding Ollama tags response: \(error)"); completion(.failure(OllamaError.decodingError(error))) }
            }
        }
        task.resume()
    }

    @objc func promptModel() {
        let alert = NSAlert(); alert.messageText = "Set Ollama Model"; alert.informativeText = "Select the Ollama model to use:"; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        let popUpButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 25), pullsDown: false); popUpButton.addItems(withTitles: ["Fetching models..."]); popUpButton.isEnabled = false; alert.accessoryView = popUpButton
        NSApp.activate(ignoringOtherApps: true); alert.window.initialFirstResponder = popUpButton
        self.fetchOllamaModels { [weak self, weak popUpButton] result in
            guard let self = self, let popUpButton = popUpButton else { return }
            popUpButton.removeAllItems()
            switch result {
            case .success(let modelNames):
                if modelNames.isEmpty { popUpButton.addItem(withTitle: "No models found"); popUpButton.isEnabled = false }
                else { popUpButton.addItems(withTitles: modelNames); popUpButton.isEnabled = true; if popUpButton.item(withTitle: self.ollamaModelName) != nil { popUpButton.selectItem(withTitle: self.ollamaModelName) } else if let first = modelNames.first { popUpButton.selectItem(withTitle: first); print("Current model '\(self.ollamaModelName)' not found, selecting first: '\(first)'") } }
            case .failure(let error): print("Failed to populate models: \(error.localizedDescription)"); popUpButton.addItem(withTitle: "Error fetching models"); popUpButton.isEnabled = false
            }
        }
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let selectedModel = popUpButton.titleOfSelectedItem, popUpButton.isEnabled { if selectedModel != self.ollamaModelName { self.ollamaModelName = selectedModel; self.defaults.set(selectedModel, forKey: Config.userDefaultsModelKey); print("Ollama model updated to: \(selectedModel)") } else { print("Selected model is the same.") } }
            else { print("No valid model selected.") }
        } else { print("Model selection cancelled.") }
    }

    @objc func beginInlineHotkeyCapture() {
        let info = NSAlert(); info.messageText = "Set New Hotkey"; info.informativeText = "Click 'Start Capture', then press the exact key combination.\n\n(Press Escape key to cancel during capture)"; info.addButton(withTitle: "Start Capture"); info.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true); let response = info.runModal(); print("Set Hotkey info alert dismissed with response code: \(response.rawValue)")
        if response == .alertFirstButtonReturn {
             awaitingHotkeyCapture = true; print("Awaiting hotkey capture... (flag=\(awaitingHotkeyCapture))")
             self.updateStatusItem(imageName: "keyboard", accessibilityDescription: "Capturing Hotkey", toolTip: "Press desired hotkey (Esc to cancel)")
        } else { print("Hotkey capture initiation cancelled.") }
    }


    // MARK: - Utility Functions

    private func formatHotkey(code: CGKeyCode, mods: CGEventFlags) -> String {
        var pieces: [String] = []; if mods.contains(.maskControl) { pieces.append("⌃") }; if mods.contains(.maskAlternate) { pieces.append("⌥") }; if mods.contains(.maskShift) { pieces.append("⇧") }; if mods.contains(.maskCommand) { pieces.append("⌘") }
        var keyName: String? = nil
        if let currentLayout = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() { let layoutDataRef = TISGetInputSourceProperty(currentLayout, kTISPropertyUnicodeKeyLayoutData); if layoutDataRef != nil { let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataRef!).takeUnretainedValue() as Data; keyName = layoutData.withUnsafeBytes { layoutBytes -> String? in guard let kbdLayout = layoutBytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }; var deadKeyState: UInt32 = 0; let maxChars = 4; var actualChars = 0; var chars = [UniChar](repeating: 0, count: maxChars); var carbonMods: UInt32 = 0; if mods.contains(.maskShift) { carbonMods |= UInt32(shiftKey) }; if mods.contains(.maskControl) { carbonMods |= UInt32(controlKey) }; if mods.contains(.maskAlternate) { carbonMods |= UInt32(optionKey) }; if mods.contains(.maskCommand) { carbonMods |= UInt32(cmdKey) }; let status = UCKeyTranslate(kbdLayout, UInt16(code), UInt16(kUCKeyActionDisplay), (carbonMods >> 8) & 0xFF, UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, maxChars, &actualChars, &chars); if status == noErr && actualChars > 0 { let char = String(utf16CodeUnits: chars, count: actualChars); switch Int(code) { case kVK_Space: return "Space"; case kVK_Return: return "Return"; case kVK_Tab: return "Tab"; case kVK_Escape: return "Esc"; case kVK_Delete: return "Delete"; case kVK_ForwardDelete: return "Fwd Del"; case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"; case kVK_UpArrow: return "↑"; case kVK_DownArrow: return "↓"; case kVK_Home: return "Home"; case kVK_End: return "End"; case kVK_PageUp: return "PgUp"; case kVK_PageDown: return "PgDn"; case kVK_F1...kVK_F20: return "F\(Int(code) - kVK_F1 + 1)"; default: let trimmed = char.trimmingCharacters(in: .whitespacesAndNewlines); if trimmed.isEmpty && !char.isEmpty { return nil }; return trimmed.isEmpty ? nil : trimmed.uppercased() } } else { return nil } } } }
        if keyName == nil || keyName!.isEmpty { switch Int(code) { case kVK_Space: keyName = "Space"; case kVK_Escape: keyName = "Esc"; case kVK_Return: keyName = "Return"; case kVK_Delete: keyName = "Delete"; case kVK_ForwardDelete: keyName = "Fwd Del"; case kVK_Tab: keyName = "Tab"; case kVK_F1...kVK_F20: keyName = "F\(Int(code) - kVK_F1 + 1)"; case kVK_UpArrow: keyName = "↑"; case kVK_DownArrow: keyName = "↓"; case kVK_LeftArrow: keyName = "←"; case kVK_RightArrow: keyName = "→"; case kVK_Home: keyName = "Home"; case kVK_End: keyName = "End"; case kVK_PageUp: keyName = "PgUp"; case kVK_PageDown: keyName = "PgDn"; default: keyName = String(format: "Key #%d", code) } }
        pieces.append(keyName ?? "<???>"); return pieces.joined()
    }

    private func showConfirmationAlert(title: String, message: String) { let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "OK"); NSApp.activate(ignoringOtherApps: true); alert.runModal() }

    // <<< FIX: Make non-private >>>
    func handleError(_ error: Error, fatal: Bool = false) {
        print("Error: \(error.localizedDescription)")
        resetUI(showError: true, message: error.localizedDescription) // <<< FIX: Add self. >>>
        if fatal { print("Fatal error encountered. Terminating."); showConfirmationAlert(title: "Critical Error", message: "A critical error occurred: \(error.localizedDescription)\n\nThe application will now terminate."); NSApplication.shared.terminate(self) }
    }

    // <<< FIX: Make non-private >>>
    func updateStatusItem(imageName: String? = nil, title: String? = nil, accessibilityDescription: String, toolTip: String) {
        DispatchQueue.main.async { guard let button = self.statusItem?.button else { return }; if let imgName = imageName, let img = NSImage(systemSymbolName: imgName, accessibilityDescription: accessibilityDescription) { button.image = img; button.title = "" } else if let title = title { button.title = title; button.image = nil }; button.toolTip = toolTip }
    }

    // <<< FIX: Make non-private >>>
    func resetUI(showError: Bool = false, message: String? = nil) {
        DispatchQueue.main.async {
            if !self.isHotkeyActive && !self.isRecording && !self.awaitingHotkeyCapture {
                if showError {
                    self.updateStatusItem(imageName: "exclamationmark.circle.fill", accessibilityDescription: "Error Status", toolTip: "Error: \(message ?? "Unknown Error")"); print("UI Reset: Showing Error - \(message ?? "Unknown Error")")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { if !self.isHotkeyActive && !self.isRecording && !self.awaitingHotkeyCapture { self.resetUI() } }
                } else {
                    let currentHotkeyText = self.formatHotkey(code: self.hotkeyCode, mods: self.hotkeyModifiers)
                    self.updateStatusItem(imageName: "mic.fill", accessibilityDescription: "WhisperType Idle Status", toolTip: "WhisperType (Listening for \(currentHotkeyText))"); print("UI Reset: Now Listening for \(currentHotkeyText)")
                }
            } else { var reason = [String](); if self.isHotkeyActive { reason.append("Hotkey Active") }; if self.isRecording { reason.append("Recording") }; if self.awaitingHotkeyCapture { reason.append("Awaiting Capture") }; print("resetUI called but state prevents immediate reset: \(reason.joined(separator: ", ")). Ignoring for now.") }
        }
    }

} // **** End of AppDelegate ****


// MARK: - Convenience Accessor
extension AppDelegate {
    static var shared: AppDelegate {
        guard let delegate = NSApp.delegate as? AppDelegate else { fatalError("AppDelegate instance not found. Check main.swift setup.") }
        return delegate
    }
}

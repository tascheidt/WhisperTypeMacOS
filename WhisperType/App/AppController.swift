import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case home, history, dictionary, snippets, scratchpad, styles, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .home: "house"
        case .history: "clock.arrow.circlepath"
        case .dictionary: "character.book.closed"
        case .snippets: "text.badge.plus"
        case .scratchpad: "note.text"
        case .styles: "slider.horizontal.3"
        case .settings: "gearshape"
        }
    }
}

@MainActor
final class AppController: ObservableObject {
    @Published private(set) var status = AppStatus()
    @Published var selectedSection: AppSection = .home
    @Published var lastError: String?
    @Published var isCapturingShortcut = false

    let store: AppDataStore
    let permissions: PermissionService

    private let hotkeys = HotkeyManager()
    private let recorder = AudioRecordingService()
    private let transcriber = TranscriptionService()
    private let refiner = AIRefinementService()
    private let inserter = TextInsertionService()
    private let overlay = OverlayController()
    private var statusItem: NSStatusItem?
    private var hubWindow: NSWindow?
    private var lastExternalTarget: CapturedTarget?
    private var sessionTarget: CapturedTarget?
    private var currentMode: DictationMode = .dictation
    private var pressedAt = Date()
    private var pendingRelease: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var captureCommandShortcut = false
    private var settingsCancellable: AnyCancellable?

    init(store: AppDataStore? = nil, permissions: PermissionService? = nil) {
        self.store = store ?? AppDataStore()
        self.permissions = permissions ?? PermissionService()
    }

    func start() {
        setupStatusItem()
        recorder.onLevel = { [weak self] level in self?.updateLevel(level) }
        recorder.onMaximumDuration = { [weak self] in self?.finishRecording() }
        hotkeys.onEvent = { [weak self] event in self?.handle(event) }
        hotkeys.onShortcutCaptured = { [weak self] shortcut in self?.finishShortcutCapture(shortcut) }
        settingsCancellable = store.$settings
            .removeDuplicates()
            .sink { [weak self] settings in self?.apply(settings) }
        apply(store.settings)
        refreshPermissions(prompt: false)
        Task { await transcriber.prewarm(modelFileName: store.settings.modelFileName) }
        if !store.onboardingComplete { showHub() }
    }

    func stop() {
        pendingRelease?.cancel()
        processingTask?.cancel()
        recorder.cancel()
        hotkeys.stop()
        Task { await transcriber.shutdown() }
        statusItem = nil
    }

    func showHub(section: AppSection? = nil) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalTarget = ContextService.capture(includeText: false)
        }
        if let section { selectedSection = section }
        if hubWindow == nil {
            let root = RootView(controller: self, store: store, permissions: permissions)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "WhisperType"
            window.setContentSize(NSSize(width: 980, height: 680))
            window.minSize = NSSize(width: 800, height: 560)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            hubWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        hubWindow?.makeKeyAndOrderFront(nil)
    }

    func refreshPermissions(prompt: Bool) {
        permissions.refresh()
        if !permissions.accessibilityGranted, prompt { permissions.requestAccessibility() }
        if permissions.accessibilityGranted { _ = hotkeys.start() }
        else { hotkeys.stop() }
    }

    func requestMicrophone() async { _ = await permissions.requestMicrophone() }

    func completeOnboarding() {
        permissions.refresh()
        guard permissions.microphoneGranted, permissions.accessibilityGranted else {
            lastError = "Grant Microphone and Accessibility access before finishing setup."
            return
        }
        store.onboardingComplete = true
        refreshPermissions(prompt: false)
    }

    func beginShortcutCapture(command: Bool = false) {
        captureCommandShortcut = command
        isCapturingShortcut = true
        status = AppStatus(phase: .listening, message: "Press a shortcut • Esc to cancel", mode: .dictation)
        if store.settings.showOverlay { overlay.show(status: status) }
        hotkeys.beginCapture()
    }

    func startHandsFreeFromMenu() {
        if status.phase == .listening { finishRecording() }
        else { beginRecording(mode: .dictation, handsFree: true) }
    }

    func cancelCurrentOperation() {
        pendingRelease?.cancel()
        processingTask?.cancel()
        recorder.cancel()
        sessionTarget = nil
        setStatus(.init(phase: .idle, message: "Hold \(store.settings.shortcut.displayName) to dictate"), hideAfter: 0.15)
    }

    func copyLastTranscript() {
        guard let text = store.lastTranscript?.finalText else { return }
        inserter.copy(text)
        setStatus(.init(phase: .success, message: "Last transcript copied"), hideAfter: 1.0)
    }

    func pasteLastTranscript() {
        guard let text = store.lastTranscript?.finalText else { return }
        let target = ContextService.capture(includeText: false)
        Task {
            _ = await inserter.insert(text, into: target)
            setStatus(.init(phase: .success, message: "Last transcript inserted"), hideAfter: 1.0)
        }
    }

    func insertTranscript(_ entry: TranscriptEntry) {
        let target = lastExternalTarget ?? ContextService.capture(includeText: false)
        hubWindow?.orderOut(nil)
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            _ = await inserter.insert(entry.finalText, into: target)
        }
    }

    func saveOpenRouterKey(_ key: String) throws { try SecureStore.setOpenRouterAPIKey(key) }
    func hasOpenRouterKey() -> Bool { SecureStore.openRouterAPIKey() != nil }

    func testOpenRouter() async -> String {
        guard hasOpenRouterKey() else { return "No API key saved" }
        var testSettings = store.settings
        testSettings.refinementProvider = .openRouter
        do {
            let value = try await refiner.refine(
                text: "This is a connection test.", rawText: "This is a connection test.",
                context: .empty, settings: testSettings, customVocabulary: []
            )
            return value.isEmpty ? "Connected" : "Connected successfully"
        } catch { return error.localizedDescription }
    }

    func exportData() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "WhisperType Backup.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportData().write(to: url, options: .atomic) }
        catch { lastError = error.localizedDescription }
    }

    func importData() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.importData(Data(contentsOf: url)) }
        catch { lastError = error.localizedDescription }
    }

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .pressed(let mode, let date):
            pressedAt = date
            if status.phase == .listening {
                if status.isHandsFree {
                    finishRecording()
                } else if pendingRelease != nil, mode == currentMode, store.settings.doubleTapHandsFree {
                    pendingRelease?.cancel()
                    pendingRelease = nil
                    status.isHandsFree = true
                    status.message = "Hands-free • Press shortcut to finish"
                    overlay.update(status: status)
                }
                return
            }
            guard status.phase == .idle || status.phase == .success || status.phase == .error else {
                setStatus(.init(phase: .error, message: WhisperTypeError.alreadyProcessing.localizedDescription), hideAfter: 1.5)
                return
            }
            beginRecording(mode: mode, handsFree: false)

        case .released(let mode, let date):
            guard status.phase == .listening, mode == currentMode, !status.isHandsFree else { return }
            let held = date.timeIntervalSince(pressedAt)
            if held < 0.34, store.settings.doubleTapHandsFree {
                pendingRelease = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(280))
                    guard !Task.isCancelled else { return }
                    self?.pendingRelease = nil
                    self?.finishRecording()
                }
            } else { finishRecording() }

        case .cancel:
            cancelCurrentOperation()
        }
    }

    private func beginRecording(mode: DictationMode, handsFree: Bool) {
        permissions.refresh()
        guard permissions.microphoneGranted else {
            showError(WhisperTypeError.microphonePermission)
            showHub(section: .settings)
            return
        }
        guard permissions.accessibilityGranted else {
            showError(WhisperTypeError.accessibilityPermission)
            showHub(section: .settings)
            return
        }
        do {
            currentMode = mode
            sessionTarget = ContextService.capture(includeText: store.settings.contextAwareness)
            try recorder.start(maximumDuration: store.settings.maximumRecordingSeconds)
            let label = mode == .command ? "Say a command" : "Speak naturally"
            setStatus(AppStatus(phase: .listening, message: label, isHandsFree: handsFree, mode: mode))
            playSound(named: "Tink")
        } catch { showError(error) }
    }

    private func finishRecording() {
        pendingRelease?.cancel()
        pendingRelease = nil
        guard status.phase == .listening else { return }
        let mode = currentMode
        let target = sessionTarget ?? ContextService.capture(includeText: store.settings.contextAwareness)
        do {
            let recording = try recorder.stop()
            setStatus(AppStatus(phase: .processing, message: mode == .command ? "Understanding command…" : "Transcribing locally…", mode: mode))
            playSound(named: "Pop")
            processingTask = Task { [weak self] in await self?.process(recording: recording, target: target, mode: mode) }
        } catch { showError(error) }
    }

    private func process(recording: AudioRecordingResult, target: CapturedTarget, mode: DictationMode) async {
        let processingStart = Date()
        let settings = store.settings
        let vocabulary = store.vocabulary
        let snippets = store.snippets
        do {
            let rawText = try await transcriber.transcribe(
                audioURL: recording.url,
                configuration: .init(
                    modelFileName: settings.modelFileName,
                    languageCode: settings.languageCode,
                    translateToEnglish: settings.translateToEnglish,
                    vocabularyPrompt: TextProcessingService.vocabularyPrompt(vocabulary)
                )
            )
            try Task.checkCancellation()
            let finalText: String
            if mode == .command {
                if let localResult = executeLocalCommand(rawText, target: target) {
                    finalText = localResult
                } else {
                    finalText = try await refiner.executeCommand(
                        instruction: rawText, selectedText: target.context.selectedText,
                        context: target.context, settings: settings
                    )
                    setStatus(AppStatus(phase: .inserting, message: "Applying command…", mode: mode))
                    _ = await inserter.insert(finalText, into: target)
                }
            } else {
                let localText = TextProcessingService.process(
                    rawText, settings: settings, vocabulary: vocabulary, snippets: snippets, context: target.context
                )
                var refined = localText
                do {
                    refined = try await refiner.refine(
                        text: localText, rawText: rawText, context: target.context,
                        settings: settings, customVocabulary: vocabulary
                    )
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    lastError = "AI refinement was unavailable, so local formatting was used. \(error.localizedDescription)"
                }
                finalText = refined
                setStatus(AppStatus(phase: .inserting, message: "Inserting into \(target.context.applicationName)…", mode: mode))
                let inserted = await inserter.insert(finalText, into: target)
                if !inserted { inserter.copy(finalText); throw WhisperTypeError.insertionFailed }
            }
            let processingDuration = Date().timeIntervalSince(processingStart)
            store.addTranscript(TranscriptEntry(
                rawText: rawText, finalText: finalText,
                applicationName: target.context.applicationName,
                applicationBundleIdentifier: target.context.bundleIdentifier,
                duration: recording.duration, processingDuration: processingDuration,
                languageCode: settings.languageCode, mode: mode
            ))
            cleanAudio(recording.url, keep: settings.keepAudioForRetry)
            sessionTarget = nil
            setStatus(AppStatus(phase: .success, message: mode == .command ? "Command complete" : "Inserted into \(target.context.applicationName)", mode: mode), hideAfter: 1.2)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: recording.url)
            sessionTarget = nil
            setStatus(.init(phase: .idle, message: "Cancelled"), hideAfter: 0.2)
        } catch {
            cleanAudio(recording.url, keep: true)
            sessionTarget = nil
            showError(error)
        }
        processingTask = nil
    }

    private func executeLocalCommand(_ transcript: String, target: CapturedTarget) -> String? {
        let command = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        switch command {
        case "undo", "undo that": inserter.postCommandKey(CGKeyCode(kVK_ANSI_Z)); return "Undo"
        case "copy", "copy that": inserter.postCommandKey(CGKeyCode(kVK_ANSI_C)); return "Copy"
        case "select all": inserter.postCommandKey(CGKeyCode(kVK_ANSI_A)); return "Select all"
        case "paste", "paste that": inserter.postCommandKey(CGKeyCode(kVK_ANSI_V)); return "Paste"
        case "paste last", "paste last text":
            if let text = store.lastTranscript?.finalText {
                Task { _ = await inserter.insert(text, into: target) }
                return text
            }
            return "No previous transcript"
        default: return nil
        }
    }

    private func cleanAudio(_ url: URL, keep: Bool) {
        guard keep else { try? FileManager.default.removeItem(at: url); return }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperType/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.moveItem(at: url, to: destination)
    }

    private func updateLevel(_ level: Float) {
        guard status.phase == .listening else { return }
        status.level = level
        overlay.update(status: status)
    }

    private func showError(_ error: Error) {
        lastError = error.localizedDescription
        setStatus(AppStatus(phase: .error, message: error.localizedDescription, mode: currentMode), hideAfter: 3.0)
    }

    private func setStatus(_ newStatus: AppStatus, hideAfter delay: TimeInterval? = nil) {
        status = newStatus
        updateStatusItem()
        if store.settings.showOverlay, newStatus.phase != .idle { overlay.show(status: newStatus) }
        else if newStatus.phase == .idle { overlay.hide() }
        if let delay {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, self?.status == newStatus else { return }
                self?.status = AppStatus(phase: .idle, message: "Hold \(self?.store.settings.shortcut.displayName ?? "fn") to dictate")
                self?.updateStatusItem()
                self?.overlay.hide()
            }
        }
    }

    private func finishShortcutCapture(_ shortcut: Shortcut?) {
        isCapturingShortcut = false
        if let shortcut {
            if captureCommandShortcut { store.settings.commandShortcut = shortcut }
            else { store.settings.shortcut = shortcut }
        }
        apply(store.settings)
        setStatus(.init(phase: .success, message: shortcut == nil ? "Shortcut unchanged" : "Shortcut set to \(shortcut!.displayName)"), hideAfter: 1.2)
    }

    private func apply(_ settings: AppSettings) {
        hotkeys.configure(primary: settings.shortcut, command: settings.commandShortcut, commandEnabled: settings.commandModeEnabled)
        if permissions.accessibilityGranted { _ = hotkeys.start() }
        do { try LaunchAtLoginService.setEnabled(settings.launchAtLogin) }
        catch { lastError = "Could not update Launch at Login: \(error.localizedDescription)" }
        if status.phase == .idle {
            status.message = "Hold \(settings.shortcut.displayName) to dictate"
            updateStatusItem()
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open WhisperType", action: #selector(openHubFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Start Hands-Free Dictation", action: #selector(toggleDictationFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Paste Last Text", action: #selector(pasteLastFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy Last Text", action: #selector(copyLastFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Scratchpad", action: #selector(openScratchpadFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit WhisperType", action: #selector(quitFromMenu), keyEquivalent: "q"))
        for menuItem in menu.items { menuItem.target = self }
        item.menu = menu
        updateStatusItem()
    }

    private func updateStatusItem() {
        statusItem?.button?.image = NSImage(systemSymbolName: status.phase.symbol, accessibilityDescription: status.phase.label)
        statusItem?.button?.image?.isTemplate = true
        statusItem?.button?.toolTip = "WhisperType • \(status.message)"
        if let item = statusItem?.menu?.item(withTitle: "Start Hands-Free Dictation") {
            item.title = status.phase == .listening ? "Stop Dictation" : "Start Hands-Free Dictation"
        }
    }

    private func playSound(named name: String) {
        guard store.settings.playSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    @objc private func openHubFromMenu() { showHub() }
    @objc private func toggleDictationFromMenu() { startHandsFreeFromMenu() }
    @objc private func pasteLastFromMenu() { pasteLastTranscript() }
    @objc private func copyLastFromMenu() { copyLastTranscript() }
    @objc private func openScratchpadFromMenu() { showHub(section: .scratchpad) }
    @objc private func openSettingsFromMenu() { showHub(section: .settings) }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }
}

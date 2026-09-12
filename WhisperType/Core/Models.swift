import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum DictationMode: String, Codable, Sendable {
    case dictation
    case command
}

enum AppPhase: String, Codable, Sendable {
    case idle
    case listening
    case processing
    case inserting
    case success
    case error

    var label: String {
        switch self {
        case .idle: "Ready"
        case .listening: "Listening"
        case .processing: "Transcribing"
        case .inserting: "Inserting"
        case .success: "Inserted"
        case .error: "Needs attention"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "waveform"
        case .listening: "waveform.circle.fill"
        case .processing: "ellipsis.circle"
        case .inserting: "arrow.down.doc.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

struct Shortcut: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt16?
    var modifiersRaw: UInt64
    var isModifierOnly: Bool

    init(keyCode: UInt16?, modifiers: CGEventFlags, isModifierOnly: Bool = false) {
        self.keyCode = keyCode
        self.modifiersRaw = modifiers.rawValue
        self.isModifierOnly = isModifierOnly
    }

    var modifiers: CGEventFlags { CGEventFlags(rawValue: modifiersRaw) }

    static let function = Shortcut(
        keyCode: UInt16(kVK_Function),
        modifiers: .maskSecondaryFn,
        isModifierOnly: true
    )
    static let functionControl = Shortcut(
        keyCode: nil,
        modifiers: [.maskSecondaryFn, .maskControl],
        isModifierOnly: true
    )
    static let controlOption = Shortcut(
        keyCode: nil,
        modifiers: [.maskControl, .maskAlternate],
        isModifierOnly: true
    )
    static let controlSpace = Shortcut(
        keyCode: UInt16(kVK_Space),
        modifiers: .maskControl
    )
    static let rightOption = Shortcut(
        keyCode: UInt16(kVK_RightOption),
        modifiers: .maskAlternate,
        isModifierOnly: true
    )

    var displayName: String {
        let flags = modifiers
        var result = ""
        if flags.contains(.maskSecondaryFn) { result += "fn" }
        if flags.contains(.maskControl) { result += result.isEmpty ? "⌃" : "  ⌃" }
        if flags.contains(.maskAlternate) { result += result.isEmpty ? "⌥" : "  ⌥" }
        if flags.contains(.maskShift) { result += result.isEmpty ? "⇧" : "  ⇧" }
        if flags.contains(.maskCommand) { result += result.isEmpty ? "⌘" : "  ⌘" }

        guard !isModifierOnly, let keyCode else { return result.isEmpty ? "None" : result }
        let key = Self.keyName(for: keyCode)
        return result.isEmpty ? key : "\(result)  \(key)"
    }

    private static func keyName(for code: UInt16) -> String {
        let names: [UInt16: String] = [
            UInt16(kVK_Space): "Space", UInt16(kVK_Return): "Return",
            UInt16(kVK_Tab): "Tab", UInt16(kVK_Escape): "Esc",
            UInt16(kVK_Delete): "Delete", UInt16(kVK_ForwardDelete): "Forward Delete",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓"
        ]
        if let name = names[code] { return name }
        let ansi: [UInt16: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
            11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2",
            20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8",
            29:"0", 30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P", 37:"L", 38:"J",
            39:"'", 40:"K", 41:";", 42:"\\", 43:",", 44:"/", 45:"N", 46:"M", 47:".", 50:"`"
        ]
        if let name = ansi[code] { return name }
        let functionCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        if let index = functionCodes.firstIndex(of: code) { return "F\(index + 1)" }
        return "Key \(code)"
    }
}

enum RefinementProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case localRules
    case appleIntelligence
    case openRouter

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .localRules: "Local rules only"
        case .appleIntelligence: "Apple Intelligence"
        case .openRouter: "OpenRouter"
        }
    }
}

enum WritingStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case polished
    case casual
    case concise
    case verbatim
    case developer

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var guidance: String {
        switch self {
        case .automatic: "Match the tone and formatting of the active application and surrounding text."
        case .polished: "Use clear, confident prose with correct grammar and complete sentences."
        case .casual: "Sound natural and conversational. Avoid stiff language and unnecessary punctuation."
        case .concise: "Remove repetition and filler. Keep every important fact while using as few words as practical."
        case .verbatim: "Preserve the speaker's wording. Only fix obvious transcription errors and punctuation."
        case .developer: "Preserve code, commands, identifiers, casing, Markdown, and technical terminology exactly."
        }
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var shortcut: Shortcut = .function
    var commandShortcut: Shortcut = .functionControl
    var commandModeEnabled = true
    var languageCode = "auto"
    var translateToEnglish = false
    var selectedStyle: WritingStyle = .automatic
    var refinementProvider: RefinementProvider = .automatic
    var openRouterModel = "~openai/gpt-latest"
    var autoFormatting = true
    var removeFillers = true
    var contextAwareness = true
    var playSounds = true
    var showOverlay = true
    var launchAtLogin = false
    var keepAudioForRetry = false
    var doubleTapHandsFree = true
    var maximumRecordingSeconds = 360.0
    var modelFileName = "ggml-large-v3-turbo-q5_0.bin"
}

struct VocabularyEntry: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id = UUID()
    var spoken: String
    var replacement: String?
    var isStarred = false
    var createdAt = Date()
}

struct Snippet: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id = UUID()
    var trigger: String
    var expansion: String
    var createdAt = Date()
    var updatedAt = Date()
}

struct TranscriptEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var rawText: String
    var finalText: String
    var applicationName: String
    var applicationBundleIdentifier: String?
    var duration: TimeInterval
    var processingDuration: TimeInterval
    var languageCode: String
    var mode: DictationMode

    var wordCount: Int {
        finalText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

struct TextContext: Sendable {
    var applicationName: String
    var bundleIdentifier: String?
    var textBeforeCursor: String
    var selectedText: String
    var textAfterCursor: String
    var isSecure: Bool

    static let empty = TextContext(
        applicationName: "Unknown App",
        bundleIdentifier: nil,
        textBeforeCursor: "",
        selectedText: "",
        textAfterCursor: "",
        isSecure: false
    )
}

struct AppStatus: Equatable, Sendable {
    var phase: AppPhase = .idle
    var message = "Hold fn to dictate"
    var level: Float = 0
    var isHandsFree = false
    var mode: DictationMode = .dictation
}

enum WhisperTypeError: LocalizedError {
    case microphonePermission
    case accessibilityPermission
    case alreadyProcessing
    case recordingFailed(String)
    case recordingTooShort
    case missingResource(String)
    case transcriptionFailed(String)
    case emptyTranscript
    case insertionFailed
    case openRouterKeyMissing
    case openRouterFailed(String)
    case commandUnavailable

    var errorDescription: String? {
        switch self {
        case .microphonePermission: "Microphone access is required. Enable WhisperType in Privacy & Security → Microphone."
        case .accessibilityPermission: "Accessibility access is required. Enable WhisperType in Privacy & Security → Accessibility."
        case .alreadyProcessing: "The previous dictation is still processing."
        case .recordingFailed(let detail): "Could not record audio: \(detail)"
        case .recordingTooShort: "That recording was too short. Hold the shortcut a little longer."
        case .missingResource(let name): "The bundled transcription resource is missing: \(name)."
        case .transcriptionFailed(let detail): "Transcription failed: \(detail)"
        case .emptyTranscript: "No speech was detected."
        case .insertionFailed: "WhisperType could not insert text into the active app. The text was copied to the clipboard."
        case .openRouterKeyMissing: "Add an OpenRouter API key in Settings, or choose Automatic refinement."
        case .openRouterFailed(let detail): "OpenRouter refinement failed: \(detail)"
        case .commandUnavailable: "That command needs Apple Intelligence or OpenRouter refinement."
        }
    }
}

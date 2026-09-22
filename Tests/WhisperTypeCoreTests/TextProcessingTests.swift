import CoreGraphics
import XCTest
@testable import WhisperTypeCore

final class TextProcessingTests: XCTestCase {
    func testSpeechModelManifestAcceptsOnlyTheReleaseModel() {
        XCTAssertNil(SpeechModelManifest.integrityProblem(
            fileName: SpeechModelManifest.fileName,
            byteCount: SpeechModelManifest.expectedByteCount,
            sha256: SpeechModelManifest.expectedSHA256
        ))
        XCTAssertTrue(SpeechModelManifest.integrityProblem(
            fileName: SpeechModelManifest.fileName,
            byteCount: 134,
            sha256: SpeechModelManifest.expectedSHA256
        )?.contains("Git LFS") == true)
        XCTAssertTrue(SpeechModelManifest.integrityProblem(
            fileName: SpeechModelManifest.fileName,
            byteCount: 2_000_000,
            sha256: SpeechModelManifest.expectedSHA256
        )?.contains("unexpected size") == true)
        XCTAssertNotNil(SpeechModelManifest.integrityProblem(
            fileName: SpeechModelManifest.fileName,
            byteCount: SpeechModelManifest.expectedByteCount,
            sha256: String(repeating: "0", count: 64)
        ))
        XCTAssertNotNil(SpeechModelManifest.integrityProblem(
            fileName: "different-model.bin",
            byteCount: SpeechModelManifest.expectedByteCount,
            sha256: SpeechModelManifest.expectedSHA256
        ))
    }

    func testSpeechEngineHealthLabelsCompatibilityModes() {
        XCTAssertEqual(SpeechEngineHealth.checking.title, "Checking…")
        XCTAssertEqual(SpeechEngineHealth.ready(.metal).title, "Ready • Metal")
        XCTAssertTrue(SpeechEngineMode.cpuCompatibility.isDegraded)
        XCTAssertFalse(SpeechEngineMode.metal.isDegraded)
    }

    func testSpeechEngineFallbackRetriesCrashesAndInitializationFailures() {
        XCTAssertTrue(SpeechEngineFallbackPolicy.shouldTryNext(
            after: .metal,
            terminationStatus: 6,
            diagnostic: ""
        ))
        XCTAssertTrue(SpeechEngineFallbackPolicy.shouldTryNext(
            after: .metalCompatibility,
            terminationStatus: 3,
            diagnostic: "error: failed to initialize whisper context"
        ))
        XCTAssertFalse(SpeechEngineFallbackPolicy.shouldTryNext(
            after: .cpuCompatibility,
            terminationStatus: 3,
            diagnostic: "error: failed to initialize whisper context"
        ))
        XCTAssertFalse(SpeechEngineFallbackPolicy.shouldTryNext(
            after: .metal,
            terminationStatus: 0,
            diagnostic: ""
        ))
    }

    func testPermissionStatesChooseTheCorrectRecoveryAction() {
        XCTAssertEqual(PermissionGrantState.notRequested.action, .request)
        XCTAssertEqual(PermissionGrantState.denied.action, .openSettings)
        XCTAssertEqual(PermissionGrantState.restricted.action, .none)
        XCTAssertEqual(PermissionGrantState.granted.action, .none)
    }

    func testDiskImageRequiresInstallationButApplicationsCopyDoesNot() {
        XCTAssertTrue(InstallationLocationPolicy.requiresInstallation(
            bundlePath: "/Volumes/WhisperType Installer/WhisperType.app",
            volumeIsReadOnly: true
        ))
        XCTAssertTrue(InstallationLocationPolicy.requiresInstallation(
            bundlePath: "/private/var/folders/AppTranslocation/WhisperType.app",
            volumeIsReadOnly: false
        ))
        XCTAssertTrue(InstallationLocationPolicy.requiresInstallation(
            bundlePath: "/Users/test/Downloads/WhisperType.app",
            volumeIsReadOnly: false
        ))
        XCTAssertFalse(InstallationLocationPolicy.requiresInstallation(
            bundlePath: "/Applications/WhisperType.app",
            volumeIsReadOnly: false
        ))
        XCTAssertFalse(InstallationLocationPolicy.requiresInstallation(
            bundlePath: "/Users/test/Applications/WhisperType.app",
            volumeIsReadOnly: false
        ))
    }

    private let emptyContext = TextContext.empty

    func testDefaultShortcutIsFunctionKey() {
        XCTAssertEqual(AppSettings().shortcut, .function)
        XCTAssertEqual(AppSettings().shortcut.displayName, "fn")
    }

    func testSpokenFormattingAndFillers() {
        let output = TextProcessingService.process(
            "um first item new line second item comma done period",
            settings: AppSettings(), vocabulary: [], snippets: [], context: emptyContext
        )
        XCTAssertEqual(output, "First item\nsecond item, done.")
    }

    func testDictionaryCorrectionIsCaseInsensitive() {
        let output = TextProcessingService.process(
            "ship it with whisper type today",
            settings: AppSettings(),
            vocabulary: [VocabularyEntry(spoken: "whisper type", replacement: "WhisperType")],
            snippets: [], context: emptyContext
        )
        XCTAssertEqual(output, "Ship it with WhisperType today")
    }

    func testSnippetExpandsAsWholePhrase() {
        let output = TextProcessingService.process(
            "please use my scheduling link tomorrow",
            settings: AppSettings(), vocabulary: [],
            snippets: [Snippet(trigger: "my scheduling link", expansion: "https://example.com/book")],
            context: emptyContext
        )
        XCTAssertEqual(output, "Please use https://example.com/book tomorrow")
    }

    func testVerbatimStillAppliesDictionaryAndSnippets() {
        var settings = AppSettings()
        settings.selectedStyle = .verbatim
        let output = TextProcessingService.process(
            "um whisper type my sign off",
            settings: settings,
            vocabulary: [VocabularyEntry(spoken: "whisper type", replacement: "WhisperType")],
            snippets: [Snippet(trigger: "my sign off", expansion: "— Todd")],
            context: emptyContext
        )
        XCTAssertEqual(output, "um WhisperType — Todd")
    }

    func testContextAddsNaturalSpacingWithoutTouchingPunctuation() {
        let context = TextContext(
            applicationName: "Notes", bundleIdentifier: nil,
            textBeforeCursor: "Existing", selectedText: "", textAfterCursor: "sentence", isSecure: false
        )
        let output = TextProcessingService.process(
            "inserted text", settings: AppSettings(), vocabulary: [], snippets: [], context: context
        )
        XCTAssertEqual(output, " inserted text ")
    }

    func testBacktrackRemovesLastClause() {
        let output = TextProcessingService.process(
            "Keep this. Remove those words scratch that use these words",
            settings: AppSettings(), vocabulary: [], snippets: [], context: emptyContext
        )
        XCTAssertEqual(output, "Keep this. use these words")
    }
}

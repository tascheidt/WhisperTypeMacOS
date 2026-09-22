import CryptoKit
import Foundation

actor TranscriptionService {
    struct Configuration: Sendable {
        let modelFileName: String
        let languageCode: String
        let translateToEnglish: Bool
        let vocabularyPrompt: String
    }

    private enum EngineProfile: CaseIterable, Sendable {
        case metal
        case metalCompatibility
        case cpuCompatibility

        var mode: SpeechEngineMode {
            switch self {
            case .metal: .metal
            case .metalCompatibility: .metalCompatibility
            case .cpuCompatibility: .cpuCompatibility
            }
        }

        var arguments: [String] {
            switch self {
            case .metal: ["--flash-attn"]
            case .metalCompatibility: ["--no-flash-attn"]
            case .cpuCompatibility: ["--no-gpu", "--no-flash-attn"]
            }
        }
    }

    private struct ValidatedModel: Sendable {
        let url: URL
        let byteCount: Int64
        let modificationDate: Date?
    }

    private var serverProcess: Process?
    private var serverLogHandle: FileHandle?
    private var serverPort: Int?
    private var loadedModelFileName: String?
    private var loadedProfile: EngineProfile?
    private var validatedModel: ValidatedModel?
    private var serverReady = false

    func prewarm(modelFileName: String) async throws -> SpeechEngineMode {
        try await ensureServer(modelFileName: modelFileName)
        guard let loadedProfile else {
            throw WhisperTypeError.speechEngineUnavailable(diagnosticsMessage)
        }
        return loadedProfile.mode
    }

    func runHealthCheck(modelFileName: String) async throws -> SpeechEngineMode {
        shutdown()
        validatedModel = nil
        return try await prewarm(modelFileName: modelFileName)
    }

    func diagnosticLogURL() -> URL { Self.diagnosticsURL }

    func shutdown() {
        stopServer()
        loadedModelFileName = nil
        loadedProfile = nil
        serverReady = false
    }

    func transcribe(audioURL: URL, configuration: Configuration) async throws -> String {
        do {
            try await ensureServer(modelFileName: configuration.modelFileName)
            return try await transcribeWithServer(audioURL: audioURL, configuration: configuration)
        } catch let error as WhisperTypeError {
            if Task.isCancelled { throw CancellationError() }
            switch error {
            case .missingResource, .invalidSpeechModel:
                throw error
            default:
                appendDiagnostic("Warm engine failed; switching to the CLI fallback: \(error.localizedDescription)")
                shutdown()
                return try await transcribeWithCLI(audioURL: audioURL, configuration: configuration)
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            appendDiagnostic("Warm engine failed; switching to the CLI fallback: \(error.localizedDescription)")
            shutdown()
            return try await transcribeWithCLI(audioURL: audioURL, configuration: configuration)
        }
    }

    private func transcribeWithCLI(audioURL: URL, configuration: Configuration) async throws -> String {
        guard let executableURL = Bundle.main.url(forResource: "whisper-cli", withExtension: nil) else {
            throw WhisperTypeError.missingResource("whisper-cli")
        }
        let modelURL = try validatedModelURL(modelFileName: configuration.modelFileName)
        let outputBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispertype-output-\(UUID().uuidString)")
        let outputURL = outputBase.appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        for profile in EngineProfile.allCases {
            try? FileManager.default.removeItem(at: outputURL)
            var arguments = [
                "--model", modelURL.path,
                "--file", audioURL.path,
                "--threads", String(threadCount),
                "--language", configuration.languageCode,
                "--output-txt",
                "--output-file", outputBase.path,
                "--no-timestamps"
            ] + profile.arguments
            if configuration.translateToEnglish { arguments.append("--translate") }
            if !configuration.vocabularyPrompt.isEmpty {
                arguments += ["--prompt", String(configuration.vocabularyPrompt.prefix(1_200))]
            }

            let errorURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("whispertype-cli-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: errorURL) }
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorHandle

            do {
                try await run(process)
            } catch {
                try? errorHandle.close()
                appendDiagnostic("CLI \(profile.mode.title) could not launch: \(error.localizedDescription)")
                throw error
            }
            try? errorHandle.close()
            try Task.checkCancellation()
            let engineOutput = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            appendDiagnostic("CLI \(profile.mode.title) exited with status \(process.terminationStatus).\n\(Self.logTail(engineOutput))")

            if SpeechEngineFallbackPolicy.isInitializationFailure(engineOutput),
               profile != .cpuCompatibility { continue }
            guard process.terminationStatus == 0 else {
                if SpeechEngineFallbackPolicy.shouldTryNext(
                    after: profile.mode,
                    terminationStatus: process.terminationStatus,
                    diagnostic: engineOutput
                ) { continue }
                throw WhisperTypeError.transcriptionFailed(
                    Self.userFacingEngineDetail(engineOutput, fallback: "engine exited with status \(process.terminationStatus)")
                )
            }
            guard FileManager.default.fileExists(atPath: outputURL.path) else {
                throw WhisperTypeError.transcriptionFailed("the engine did not produce an output file")
            }
            let output = try String(contentsOf: outputURL, encoding: .utf8)
            let cleaned = Self.clean(output)
            guard !cleaned.isEmpty else { throw WhisperTypeError.emptyTranscript }
            return cleaned
        }

        throw WhisperTypeError.speechEngineUnavailable(diagnosticsMessage)
    }

    private func ensureServer(modelFileName: String) async throws {
        if let process = serverProcess, process.isRunning,
           loadedModelFileName == modelFileName, let port = serverPort {
            if serverReady { return }
            try await waitUntilReady(process: process, port: port)
            serverReady = true
            return
        }

        let modelURL = try validatedModelURL(modelFileName: modelFileName)
        guard let executableURL = Bundle.main.url(forResource: "whisper-server", withExtension: nil) else {
            throw WhisperTypeError.missingResource("whisper-server")
        }
        guard let watchdogURL = Bundle.main.url(forResource: "engine-watchdog", withExtension: "sh") else {
            throw WhisperTypeError.missingResource("engine-watchdog.sh")
        }

        shutdown()
        appendDiagnostic("Starting speech engine checks on \(ProcessInfo.processInfo.operatingSystemVersionString).")
        for profile in EngineProfile.allCases {
            do {
                try await startServer(
                    executableURL: executableURL,
                    watchdogURL: watchdogURL,
                    modelURL: modelURL,
                    modelFileName: modelFileName,
                    profile: profile
                )
                appendDiagnostic("Speech engine ready using \(profile.mode.title).")
                return
            } catch {
                let wasCancelled = Task.isCancelled
                appendDiagnostic("Speech engine \(profile.mode.title) failed: \(error.localizedDescription)")
                stopServer()
                if wasCancelled { throw CancellationError() }
            }
        }

        throw WhisperTypeError.speechEngineUnavailable(diagnosticsMessage)
    }

    private func startServer(
        executableURL: URL,
        watchdogURL: URL,
        modelURL: URL,
        modelFileName: String,
        profile: EngineProfile
    ) async throws {
        let port = Int.random(in: 52_000...61_000)
        let process = Process()
        let logHandle = try makeServerLogHandle(profile: profile)
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [watchdogURL.path, String(ProcessInfo.processInfo.processIdentifier), executableURL.path] + [
            "--model", modelURL.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--threads", String(threadCount),
            "--language", "auto",
            "--no-timestamps"
        ] + profile.arguments
        process.standardOutput = logHandle
        process.standardError = logHandle
        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw WhisperTypeError.transcriptionFailed("could not start the local engine: \(error.localizedDescription)")
        }
        serverProcess = process
        serverLogHandle = logHandle
        serverPort = port
        loadedModelFileName = modelFileName
        loadedProfile = profile
        serverReady = false
        try await waitUntilReady(process: process, port: port)
        serverReady = true
    }

    private func waitUntilReady(process: Process, port: Int) async throws {
        let healthURL = URL(string: "http://127.0.0.1:\(port)/")!
        for _ in 0..<600 {
            try Task.checkCancellation()
            if !process.isRunning {
                throw WhisperTypeError.transcriptionFailed(
                    "the local engine stopped while loading the model (exit \(process.terminationStatus))"
                )
            }
            var request = URLRequest(url: healthURL)
            request.timeoutInterval = 0.25
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WhisperTypeError.transcriptionFailed("timed out while loading the local speech model")
    }

    private func transcribeWithServer(audioURL: URL, configuration: Configuration) async throws -> String {
        guard let serverPort,
              let url = URL(string: "http://127.0.0.1:\(serverPort)/inference") else {
            throw WhisperTypeError.transcriptionFailed("local engine is unavailable")
        }
        let boundary = "WhisperType-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendUTF8(value + "\r\n")
        }
        appendField("language", configuration.languageCode)
        appendField("translate", configuration.translateToEnglish ? "true" : "false")
        appendField("temperature", "0.0")
        appendField("temperature_inc", "0.2")
        appendField("response_format", "json")
        appendField("prompt", String(configuration.vocabularyPrompt.prefix(1_200)))
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n")
        body.appendUTF8("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: audioURL, options: .mappedIfSafe))
        body.appendUTF8("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 390
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "invalid response"
            throw WhisperTypeError.transcriptionFailed(detail)
        }
        struct ServerResponse: Decodable { let text: String }
        let result = try JSONDecoder().decode(ServerResponse.self, from: data)
        let cleaned = Self.clean(result.text)
        guard !cleaned.isEmpty else { throw WhisperTypeError.emptyTranscript }
        return cleaned
    }

    private func validatedModelURL(modelFileName: String) throws -> URL {
        guard let modelURL = Bundle.main.url(forResource: modelFileName, withExtension: nil) else {
            throw WhisperTypeError.missingResource(modelFileName)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: modelURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modificationDate = attributes[.modificationDate] as? Date
        if let validatedModel,
           validatedModel.url == modelURL,
           validatedModel.byteCount == byteCount,
           validatedModel.modificationDate == modificationDate {
            return modelURL
        }

        let digest = try Self.sha256(for: modelURL)
        if let problem = SpeechModelManifest.integrityProblem(
            fileName: modelFileName,
            byteCount: byteCount,
            sha256: digest
        ) {
            appendDiagnostic("Speech model integrity check failed: \(problem)")
            throw WhisperTypeError.invalidSpeechModel(problem)
        }
        validatedModel = ValidatedModel(url: modelURL, byteCount: byteCount, modificationDate: modificationDate)
        appendDiagnostic("Speech model integrity check passed (\(byteCount) bytes, SHA-256 \(digest)).")
        return modelURL
    }

    private func stopServer() {
        if let serverProcess, serverProcess.isRunning { serverProcess.terminate() }
        try? serverLogHandle?.close()
        serverProcess = nil
        serverLogHandle = nil
        serverPort = nil
        loadedModelFileName = nil
        loadedProfile = nil
        serverReady = false
    }

    private func run(_ process: Process) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: WhisperTypeError.transcriptionFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private func makeServerLogHandle(profile: EngineProfile) throws -> FileHandle {
        try Self.prepareDiagnosticsFile()
        let handle = try FileHandle(forWritingTo: Self.diagnosticsURL)
        try handle.seekToEnd()
        handle.write(Data("\n[\(Self.timestamp)] Starting \(profile.mode.title) server\n".utf8))
        return handle
    }

    private func appendDiagnostic(_ message: String) {
        guard (try? Self.prepareDiagnosticsFile()) != nil,
              let handle = try? FileHandle(forWritingTo: Self.diagnosticsURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(Data("[\(Self.timestamp)] \(message)\n".utf8))
    }

    private var diagnosticsMessage: String {
        "Diagnostics were saved to \(Self.diagnosticsURL.path)."
    }

    private var threadCount: Int {
        max(4, min(10, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    private static var diagnosticsURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/WhisperType/engine.log")
    }

    private static var timestamp: String { ISO8601DateFormatter().string(from: Date()) }

    private static func prepareDiagnosticsFile() throws {
        let directory = diagnosticsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: diagnosticsURL.path) {
            FileManager.default.createFile(atPath: diagnosticsURL.path, contents: nil)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: diagnosticsURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if size > 2_000_000 {
            let data = try Data(contentsOf: diagnosticsURL)
            try Data(data.suffix(250_000)).write(to: diagnosticsURL, options: .atomic)
        }
    }

    private static func sha256(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func userFacingEngineDetail(_ output: String, fallback: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        return lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? fallback
    }

    private static func logTail(_ output: String) -> String {
        String(output.suffix(8_000))
    }

    private static func clean(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "[NO_SPEECH]", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Data {
    mutating func appendUTF8(_ value: String) { append(Data(value.utf8)) }
}

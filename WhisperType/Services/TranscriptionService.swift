import Foundation

actor TranscriptionService {
    struct Configuration: Sendable {
        let modelFileName: String
        let languageCode: String
        let translateToEnglish: Bool
        let vocabularyPrompt: String
    }

    private var serverProcess: Process?
    private var serverPort: Int?
    private var loadedModelFileName: String?
    private var serverReady = false

    func prewarm(modelFileName: String) async {
        try? await ensureServer(modelFileName: modelFileName)
    }

    func shutdown() {
        if let serverProcess, serverProcess.isRunning { serverProcess.terminate() }
        serverProcess = nil
        serverPort = nil
        loadedModelFileName = nil
        serverReady = false
    }

    func transcribe(audioURL: URL, configuration: Configuration) async throws -> String {
        do {
            try await ensureServer(modelFileName: configuration.modelFileName)
            return try await transcribeWithServer(audioURL: audioURL, configuration: configuration)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            shutdown()
            return try await transcribeWithCLI(audioURL: audioURL, configuration: configuration)
        }
    }

    private func transcribeWithCLI(audioURL: URL, configuration: Configuration) async throws -> String {
        guard let executableURL = Bundle.main.url(forResource: "whisper-cli", withExtension: nil) else {
            throw WhisperTypeError.missingResource("whisper-cli")
        }
        guard let modelURL = Bundle.main.url(forResource: configuration.modelFileName, withExtension: nil) else {
            throw WhisperTypeError.missingResource(configuration.modelFileName)
        }
        try Self.validateModelFile(at: modelURL)

        let outputBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispertype-output-\(UUID().uuidString)")
        let outputURL = outputBase.appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        var arguments = [
            "--model", modelURL.path,
            "--file", audioURL.path,
            "--threads", String(max(4, min(10, ProcessInfo.processInfo.activeProcessorCount - 2))),
            "--language", configuration.languageCode,
            "--output-txt",
            "--output-file", outputBase.path,
            "--no-timestamps",
            "--no-prints",
            "--max-context", "0"
        ]
        if configuration.translateToEnglish { arguments.append("--translate") }
        if !configuration.vocabularyPrompt.isEmpty {
            arguments += ["--prompt", String(configuration.vocabularyPrompt.prefix(1_200))]
        }

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        try await run(process)
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WhisperTypeError.transcriptionFailed(detail?.nilIfBlank ?? "engine exited with status \(process.terminationStatus)")
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw WhisperTypeError.transcriptionFailed("the engine did not produce an output file")
        }
        let output = try String(contentsOf: outputURL, encoding: .utf8)
        let cleaned = Self.clean(output)
        guard !cleaned.isEmpty else { throw WhisperTypeError.emptyTranscript }
        return cleaned
    }

    func validateResources(modelFileName: String) -> [String] {
        var problems: [String] = []
        if Bundle.main.url(forResource: "whisper-cli", withExtension: nil) == nil {
            problems.append("Missing whisper-cli")
        }
        if Bundle.main.url(forResource: "whisper-server", withExtension: nil) == nil {
            problems.append("Missing whisper-server")
        }
        if Bundle.main.url(forResource: "engine-watchdog", withExtension: "sh") == nil {
            problems.append("Missing engine-watchdog.sh")
        }
        if let modelURL = Bundle.main.url(forResource: modelFileName, withExtension: nil) {
            let values = try? modelURL.resourceValues(forKeys: [.fileSizeKey])
            if (values?.fileSize ?? 0) < 1_000_000 {
                problems.append("Speech model \(modelFileName) is a Git LFS pointer or incomplete (< 1 MB)")
            }
        } else {
            problems.append("Missing \(modelFileName)")
        }
        return problems
    }

    private func ensureServer(modelFileName: String) async throws {
        if let process = serverProcess, process.isRunning,
           loadedModelFileName == modelFileName, let port = serverPort {
            if serverReady { return }
            try await waitUntilReady(process: process, port: port)
            serverReady = true
            return
        }
        shutdown()
        guard let executableURL = Bundle.main.url(forResource: "whisper-server", withExtension: nil) else {
            throw WhisperTypeError.missingResource("whisper-server")
        }
        guard let watchdogURL = Bundle.main.url(forResource: "engine-watchdog", withExtension: "sh") else {
            throw WhisperTypeError.missingResource("engine-watchdog.sh")
        }
        guard let modelURL = Bundle.main.url(forResource: modelFileName, withExtension: nil) else {
            throw WhisperTypeError.missingResource(modelFileName)
        }
        try Self.validateModelFile(at: modelURL)

        let port = Int.random(in: 52_000...61_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [watchdogURL.path, String(ProcessInfo.processInfo.processIdentifier), executableURL.path] + [
            "--model", modelURL.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--threads", String(max(4, min(10, ProcessInfo.processInfo.activeProcessorCount - 2))),
            "--language", "auto",
            "--flash-attn",
            "--no-timestamps",
            "--max-context", "0"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw WhisperTypeError.transcriptionFailed("could not start the local engine: \(error.localizedDescription)") }
        serverProcess = process
        serverPort = port
        loadedModelFileName = modelFileName
        serverReady = false
        try await waitUntilReady(process: process, port: port)
        serverReady = true
    }

    private func waitUntilReady(process: Process, port: Int) async throws {
        let healthURL = URL(string: "http://127.0.0.1:\(port)/")!
        for _ in 0..<600 {
            try Task.checkCancellation()
            if !process.isRunning { throw WhisperTypeError.transcriptionFailed("the local engine stopped while loading the model") }
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
        appendField("max_context", "0")
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

    private static func clean(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "[NO_SPEECH]", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validateModelFile(at url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = values?.fileSize ?? 0
        if fileSize < 1_000_000 {
            if let content = try? String(contentsOf: url, encoding: .utf8), content.contains("git-lfs") {
                throw WhisperTypeError.transcriptionFailed(
                    "Speech model '\(url.lastPathComponent)' is a Git LFS pointer file (~134 bytes), not the real model weights (~574 MB). Run 'git lfs pull' or './Scripts/fetch-model.sh' and rebuild the app."
                )
            }
            throw WhisperTypeError.transcriptionFailed(
                "Speech model '\(url.lastPathComponent)' is incomplete or corrupted (\(fileSize) bytes). Run './Scripts/fetch-model.sh' and rebuild the app."
            )
        }
    }
}

private extension Data {
    mutating func appendUTF8(_ value: String) { append(Data(value.utf8)) }
}

private extension String {
    var nilIfBlank: String? {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

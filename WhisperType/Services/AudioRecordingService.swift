import AVFoundation
import Foundation

struct AudioRecordingResult: Sendable {
    let url: URL
    let duration: TimeInterval
}

@MainActor
final class AudioRecordingService: NSObject {
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startedAt: Date?
    private var outputURL: URL?
    private var maximumDuration: TimeInterval = 360
    private var didReachMaximum = false

    var onLevel: ((Float) -> Void)?
    var onMaximumDuration: (() -> Void)?

    var isRecording: Bool { recorder?.isRecording == true }

    func start(maximumDuration: TimeInterval) throws {
        guard !isRecording else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperType", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("recording-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                throw WhisperTypeError.recordingFailed("The microphone did not start recording.")
            }
            self.recorder = recorder
            outputURL = url
            startedAt = Date()
            self.maximumDuration = maximumDuration
            didReachMaximum = false
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.045, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateMeter() }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stop() throws -> AudioRecordingResult {
        guard let recorder, let url = outputURL, let startedAt else {
            throw WhisperTypeError.recordingFailed("There is no active recording.")
        }
        let duration = Date().timeIntervalSince(startedAt)
        recorder.stop()
        resetState(keepFile: true)
        guard duration >= 0.22 else {
            try? FileManager.default.removeItem(at: url)
            throw WhisperTypeError.recordingTooShort
        }
        return AudioRecordingResult(url: url, duration: duration)
    }

    func cancel() {
        recorder?.stop()
        resetState(keepFile: false)
    }

    private func updateMeter() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        let normalized = max(0, min(1, pow(10, decibels / 35)))
        onLevel?(normalized)
        if !didReachMaximum, recorder.currentTime >= maximumDuration {
            didReachMaximum = true
            onMaximumDuration?()
        }
    }

    private func resetState(keepFile: Bool) {
        meterTimer?.invalidate()
        meterTimer = nil
        onLevel?(0)
        let url = outputURL
        recorder = nil
        outputURL = nil
        startedAt = nil
        if !keepFile, let url { try? FileManager.default.removeItem(at: url) }
    }

}

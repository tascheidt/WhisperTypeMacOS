import AppKit
import AVFoundation
import ApplicationServices

@MainActor
final class PermissionService: ObservableObject {
    @Published private(set) var microphoneState: PermissionGrantState = .notRequested
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var isRequestingMicrophone = false
    @Published private(set) var accessibilitySetupStarted = false

    private var monitoringTask: Task<Void, Never>?

    var microphoneGranted: Bool { microphoneState.isGranted }

    init() { refresh() }

    deinit { monitoringTask?.cancel() }

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
    }

    func refresh() {
        microphoneState = Self.state(for: AVCaptureDevice.authorizationStatus(for: .audio))
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    func requestMicrophone() async -> Bool {
        refresh()
        switch microphoneState.action {
        case .request:
            guard !isRequestingMicrophone else { return false }
            isRequestingMicrophone = true
            NSApp.activate(ignoringOtherApps: true)
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            isRequestingMicrophone = false
            refresh()
            return granted
        case .openSettings:
            openMicrophoneSettings()
            return false
        case .none:
            return microphoneGranted
        }
    }

    func requestAccessibility() {
        if accessibilitySetupStarted {
            openAccessibilitySettings()
            return
        }
        accessibilitySetupStarted = true
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
        if !accessibilityGranted { openAccessibilitySettings() }
    }

    func openMicrophoneSettings() {
        openPrivacyPane(anchor: "Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openPrivacyPane(anchor: "Privacy_Accessibility")
    }

    private func openPrivacyPane(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func state(for status: AVAuthorizationStatus) -> PermissionGrantState {
        switch status {
        case .notDetermined: .notRequested
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }
}

import AppKit
import Security

enum InstallationService {
    private static let destinationURL = URL(fileURLWithPath: "/Applications/WhisperType.app", isDirectory: true)

    static var requiresInstallation: Bool {
#if DEBUG
        return false
#else
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let values = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return InstallationLocationPolicy.requiresInstallation(
            bundlePath: bundleURL.path,
            volumeIsReadOnly: values?.volumeIsReadOnly ?? false
        )
#endif
    }

    @MainActor
    static func presentInstallationPrompt() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Move WhisperType to Applications?"
        alert.informativeText = "WhisperType is running outside the Applications folder. Move it before setup so macOS permissions stay attached to the installed app."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")

        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return
        }

        do {
            try installCurrentApplication()
            relaunchInstalledApplication()
            NSApp.terminate(nil)
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = "WhisperType couldn’t be installed"
            failure.informativeText = "Drag WhisperType to the Applications folder in the installer window, then open that copy.\n\n\(error.localizedDescription)"
            failure.addButton(withTitle: "Show Applications")
            failure.runModal()
            NSWorkspace.shared.open(destinationURL.deletingLastPathComponent())
            NSApp.terminate(nil)
        }
    }

    private static func installCurrentApplication() throws {
        let fileManager = FileManager.default
        let sourceURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let stagingURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".WhisperType.installing.\(UUID().uuidString).app", isDirectory: true)
        let backupURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".WhisperType.previous.\(UUID().uuidString).app", isDirectory: true)

        var movedExistingApp = false
        var installedNewApp = false

        do {
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.moveItem(at: destinationURL, to: backupURL)
                movedExistingApp = true
            }
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            installedNewApp = true

            guard Bundle(url: destinationURL)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try validateSignature(at: destinationURL)

            if movedExistingApp { try? fileManager.removeItem(at: backupURL) }
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            if installedNewApp { try? fileManager.removeItem(at: destinationURL) }
            if movedExistingApp, !fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.moveItem(at: backupURL, to: destinationURL)
            }
            throw error
        }
    }

    private static func relaunchInstalledApplication() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open '/Applications/WhisperType.app'"]
        try? task.run()
    }

    private static func validateSignature(at applicationURL: URL) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(createStatus))
        }
        let validityStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
            nil
        )
        guard validityStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(validityStatus))
        }
    }
}

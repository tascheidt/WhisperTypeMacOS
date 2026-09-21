import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
final class CapturedTarget {
    let application: NSRunningApplication?
    let element: AXUIElement?
    let context: TextContext

    init(application: NSRunningApplication?, element: AXUIElement?, context: TextContext) {
        self.application = application
        self.element = element
        self.context = context
    }
}

@MainActor
enum ContextService {
    static func capture(includeText: Bool) -> CapturedTarget {
        let application = NSWorkspace.shared.frontmostApplication
        let appName = application?.localizedName ?? "Unknown App"
        let bundleID = application?.bundleIdentifier
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard result == .success, let element = focusedValue as! AXUIElement? else {
            return CapturedTarget(
                application: application,
                element: nil,
                context: TextContext(applicationName: appName, bundleIdentifier: bundleID, textBeforeCursor: "", selectedText: "", textAfterCursor: "", isSecure: false)
            )
        }

        let role: String? = attribute(kAXRoleAttribute, from: element)
        let subrole: String? = attribute(kAXSubroleAttribute, from: element)
        let secure = role == "AXSecureTextField" || subrole?.localizedCaseInsensitiveContains("secure") == true
        guard includeText, !secure else {
            return CapturedTarget(
                application: application,
                element: element,
                context: TextContext(applicationName: appName, bundleIdentifier: bundleID, textBeforeCursor: "", selectedText: "", textAfterCursor: "", isSecure: secure)
            )
        }

        let selected: String = attribute(kAXSelectedTextAttribute, from: element) ?? ""
        let value: String = attribute(kAXValueAttribute, from: element) ?? ""
        var before = ""
        var after = ""
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location != kCFNotFound {
                let nsValue = value as NSString
                let safeLocation = min(max(0, range.location), nsValue.length)
                let safeLength = min(max(0, range.length), nsValue.length - safeLocation)
                before = nsValue.substring(to: safeLocation)
                after = nsValue.substring(from: safeLocation + safeLength)
            }
        }
        return CapturedTarget(
            application: application,
            element: element,
            context: TextContext(
                applicationName: appName,
                bundleIdentifier: bundleID,
                textBeforeCursor: String(before.suffix(2_000)),
                selectedText: String(selected.prefix(4_000)),
                textAfterCursor: String(after.prefix(1_000)),
                isSecure: false
            )
        )
    }

    private static func attribute<T>(_ name: String, from element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

@MainActor
final class TextInsertionService {
    private var pendingRestoreTask: Task<Void, Never>?
    private var baseSnapshot: PasteboardSnapshot?

    func insert(_ text: String, into target: CapturedTarget) async -> Bool {
        guard !text.isEmpty else { return true }
        if let element = target.element,
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            return true
        }
        return await paste(text, into: target.application)
    }

    func copy(_ text: String) {
        pendingRestoreTask?.cancel()
        pendingRestoreTask = nil
        baseSnapshot = nil
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func postCommandKey(_ keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    private func paste(_ text: String, into application: NSRunningApplication?) async -> Bool {
        pendingRestoreTask?.cancel()
        pendingRestoreTask = nil

        let pasteboard = NSPasteboard.general
        if baseSnapshot == nil {
            baseSnapshot = PasteboardSnapshot(pasteboard: pasteboard)
        }

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            baseSnapshot = nil
            return false
        }
        let insertedChangeCount = pasteboard.changeCount

        if let application, !application.isTerminated { application.activate() }
        try? await Task.sleep(for: .milliseconds(90))
        postCommandKey(CGKeyCode(kVK_ANSI_V))

        pendingRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if pasteboard.changeCount == insertedChangeCount, let snapshot = self.baseSnapshot {
                snapshot.restore(to: pasteboard)
            }
            self.baseSnapshot = nil
            self.pendingRestoreTask = nil
        }
        return true
    }
}

private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

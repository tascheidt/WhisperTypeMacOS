import AppKit
import Carbon.HIToolbox
import CoreGraphics

enum HotkeyEvent {
    case pressed(DictationMode, Date)
    case released(DictationMode, Date)
    case cancel
}

@MainActor
final class HotkeyManager {
    var onEvent: ((HotkeyEvent) -> Void)?
    var onShortcutCaptured: ((Shortcut?) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var primary: Shortcut = .function
    private var command: Shortcut = .functionControl
    private var commandEnabled = true
    private var activeMode: DictationMode?
    private var capturing = false
    private var captureCandidate: Shortcut?

    func configure(primary: Shortcut, command: Shortcut, commandEnabled: Bool) {
        self.primary = primary
        self.command = command
        self.commandEnabled = commandEnabled
    }

    @discardableResult
    func start() -> Bool {
        stop()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func stop() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        activeMode = nil
    }

    func beginCapture() {
        capturing = true
        captureCandidate = nil
    }

    func cancelCapture() {
        capturing = false
        captureCandidate = nil
        onShortcutCaptured?(nil)
    }

    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(info).takeUnretainedValue()
        return manager.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if capturing { return handleCapture(type: type, event: event) }

        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown, code == UInt16(kVK_Escape), activeMode != nil {
            activeMode = nil
            onEvent?(.cancel)
            return nil
        }

        if let mode = activeMode {
            let shortcut = mode == .dictation ? primary : command
            if isRelease(of: shortcut, type: type, code: code, flags: relevant(event.flags)) {
                activeMode = nil
                onEvent?(.released(mode, Date()))
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if commandEnabled, isPress(of: command, type: type, code: code, flags: relevant(event.flags)) {
            activeMode = .command
            onEvent?(.pressed(.command, Date()))
            return nil
        }
        if isPress(of: primary, type: type, code: code, flags: relevant(event.flags)) {
            activeMode = .dictation
            onEvent?(.pressed(.dictation, Date()))
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func isPress(of shortcut: Shortcut, type: CGEventType, code: UInt16, flags: CGEventFlags) -> Bool {
        if shortcut.isModifierOnly {
            guard type == .flagsChanged, flags == shortcut.modifiers else { return false }
            return shortcut.keyCode == nil || shortcut.keyCode == code
        }
        return type == .keyDown && shortcut.keyCode == code && flags == shortcut.modifiers
    }

    private func isRelease(of shortcut: Shortcut, type: CGEventType, code: UInt16, flags: CGEventFlags) -> Bool {
        if shortcut.isModifierOnly {
            return type == .flagsChanged && flags != shortcut.modifiers
        }
        return type == .keyUp && shortcut.keyCode == code
    }

    private func handleCapture(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = relevant(event.flags)
        if type == .keyDown {
            if code == UInt16(kVK_Escape) { cancelCapture(); return nil }
            if !isModifierKey(code) {
                finishCapture(Shortcut(keyCode: code, modifiers: flags))
                return nil
            }
        }
        if type == .flagsChanged {
            if !flags.isEmpty {
                let flagCount = [CGEventFlags.maskSecondaryFn, .maskControl, .maskAlternate, .maskShift, .maskCommand]
                    .filter { flags.contains($0) }.count
                let candidateCount = captureCandidate.map { modifierCount($0.modifiers) } ?? 0
                if flagCount >= candidateCount {
                    captureCandidate = Shortcut(
                        keyCode: flagCount == 1 ? code : nil,
                        modifiers: flags,
                        isModifierOnly: true
                    )
                }
            } else if let candidate = captureCandidate {
                finishCapture(candidate)
            }
            return nil
        }
        return nil
    }

    private func finishCapture(_ shortcut: Shortcut) {
        capturing = false
        captureCandidate = nil
        onShortcutCaptured?(shortcut)
    }

    private func relevant(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn])
    }

    private func modifierCount(_ flags: CGEventFlags) -> Int {
        [CGEventFlags.maskSecondaryFn, .maskControl, .maskAlternate, .maskShift, .maskCommand]
            .filter { flags.contains($0) }.count
    }

    private func isModifierKey(_ code: UInt16) -> Bool {
        [kVK_Command, kVK_Shift, kVK_CapsLock, kVK_Option, kVK_Control, kVK_RightCommand,
         kVK_RightShift, kVK_RightOption, kVK_RightControl, kVK_Function].contains(Int(code))
    }
}

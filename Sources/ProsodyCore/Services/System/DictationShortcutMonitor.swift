import AppKit
import ApplicationServices
@preconcurrency import Carbon.HIToolbox
import IOKit.hidsystem

public enum DictationShortcut: String, Codable, CaseIterable, Identifiable, Sendable {
    case rightCommand = "Right Command"
    case rightOption = "Right Option"
    case controlOptionSpace = "Control + Option + Space"
    public var id: String { rawValue }
}

public enum DictationActivation: String, Codable, CaseIterable, Identifiable, Sendable {
    case hold = "Hold to talk"
    case toggle = "Press to start / stop"
    public var id: String { rawValue }
}

struct DictationShortcutMonitorCallbacks {
    let changed: (Bool) -> Void
    let cancel: () -> Bool
    let resetGesture: () -> Void
}

@MainActor
protocol DictationShortcutMonitoring: AnyObject {
    func start() -> Bool
    func stop()
}

/// Interprets a physical press separately from whether its release should
/// reach the controller. A cancelled Space press still owns its repeat/up events.
struct DictationShortcutInput {
    struct Decision: Equatable {
        var changed: Bool?
        var consumed = false
    }

    private enum Press { case up, reported, suppressed }

    let shortcut: DictationShortcut
    private var press: Press = .up
    private var ownsEscape = false

    init(shortcut: DictationShortcut) { self.shortcut = shortcut }

    var keyCode: CGKeyCode {
        switch shortcut {
        case .rightCommand: return CGKeyCode(kVK_RightCommand)
        case .rightOption: return CGKeyCode(kVK_RightOption)
        case .controlOptionSpace: return CGKeyCode(kVK_Space)
        }
    }

    mutating func resynchronize(shortcutKeyDown: Bool, escapeKeyDown: Bool = false) {
        if !shortcutKeyDown {
            press = .up
        } else if shortcut != .controlOptionSpace || press != .up {
            // Never claim a Space down that was delivered to another app.
            press = .suppressed
        }
        ownsEscape = ownsEscape && escapeKeyDown
    }

    mutating func tapInterrupted(shortcutKeyDown: Bool, escapeKeyDown: Bool, cancel: () -> Bool) {
        resynchronize(shortcutKeyDown: shortcutKeyDown, escapeKeyDown: escapeKeyDown)
        // A missing release can't safely commit a hold, and a toggle may be
        // recording even with the shortcut key up. Cancel either mode.
        _ = cancel()
    }

    mutating func keyEvent(_ type: CGEventType, key: Int64, flags: CGEventFlags, repeating: Bool = false,
                           shortcutKeyDown: @autoclosure () -> Bool = false,
                           cancel: () -> Bool = { false }) -> Decision {
        if key == Int64(kVK_Escape) {
            switch type {
            case .keyDown:
                if !repeating {
                    ownsEscape = cancel()
                    if ownsEscape, press == .reported { press = .suppressed }
                }
                return Decision(consumed: ownsEscape)
            case .keyUp:
                defer { ownsEscape = false }
                return Decision(consumed: ownsEscape)
            default: return Decision()
            }
        }

        switch shortcut {
        case .rightCommand, .rightOption:
            guard type == .flagsChanged, key == Int64(keyCode) else { return Decision() }
            let command = shortcut == .rightCommand
            let right = CGEventFlags(rawValue: UInt64(command ? NX_DEVICERCMDKEYMASK : NX_DEVICERALTKEYMASK))
            let left = CGEventFlags(rawValue: UInt64(command ? NX_DEVICELCMDKEYMASK : NX_DEVICELALTKEYMASK))
            let combined: CGEventFlags = command ? .maskCommand : .maskAlternate
            // The shared flag stays set if the left key outlives the right.
            // For sources that omit both side bits, query this key only.
            let down = flags.contains(right) ||
                (!flags.contains(left) && flags.contains(combined) && shortcutKeyDown())
            switch (press, down) {
            case (.up, true):
                press = .reported
                return Decision(changed: true)
            case (.reported, false):
                press = .up
                return Decision(changed: false)
            case (.suppressed, false): press = .up
            default: break
            }
            return Decision()

        case .controlOptionSpace:
            return chordEvent(type, key: key, flags: flags, repeating: repeating)
        }
    }

    private mutating func chordEvent(_ type: CGEventType, key: Int64, flags: CGEventFlags,
                                     repeating: Bool) -> Decision {
        let hasModifiers = flags.contains([.maskControl, .maskAlternate])
        if type == .flagsChanged, press == .reported, !hasModifiers {
            switch key {
            case Int64(kVK_Control), Int64(kVK_RightControl), Int64(kVK_Option), Int64(kVK_RightOption):
                // End a hold when either required modifier is released. The
                // matching Space up still belongs to the original press.
                press = .suppressed
                return Decision(changed: false)
            default: break
            }
        }
        guard key == Int64(keyCode) else { return Decision() }
        switch type {
        case .keyDown:
            if press != .up { return Decision(consumed: true) }
            guard !repeating, hasModifiers, !flags.contains(.maskCommand) else { return Decision() }
            press = .reported
            return Decision(changed: true, consumed: true)
        case .keyUp:
            guard press != .up else { return Decision() }
            defer { press = .up }
            return Decision(changed: press == .reported ? false : nil, consumed: true)
        default: return Decision()
        }
    }
}

/// The tap runs on the main run loop. It observes only shortcut transitions;
/// it never stores keys or text. Escape is consumed only during dictation.
@MainActor
final class DictationShortcutMonitor: DictationShortcutMonitoring {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var input: DictationShortcutInput
    private let changed: (Bool) -> Void
    private let cancel: () -> Bool
    private let resetGesture: () -> Void

    init(shortcut: DictationShortcut, changed: @escaping (Bool) -> Void, cancel: @escaping () -> Bool,
         resetGesture: @escaping () -> Void = {}) {
        input = DictationShortcutInput(shortcut: shortcut)
        self.changed = changed
        self.cancel = cancel
        self.resetGesture = resetGesture
    }

    func start() -> Bool {
        stop()
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let consumed = MainActor.assumeIsolated {
                    let monitor = Unmanaged<DictationShortcutMonitor>.fromOpaque(context).takeUnretainedValue()
                    return monitor.handle(type: type, event: event)
                }
                return consumed ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            stop()
            return false
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        input.resynchronize(shortcutKeyDown: keyIsDown(input.keyCode))
        return true
    }

    func stop() {
        let hadTap = tap != nil || source != nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
        input = DictationShortcutInput(shortcut: input.shortcut)
        if hadTap { resetGesture() }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let shortcutDown = keyIsDown(input.keyCode)
            let escapeDown = keyIsDown(CGKeyCode(kVK_Escape))
            input.tapInterrupted(shortcutKeyDown: shortcutDown, escapeKeyDown: escapeDown, cancel: cancel)
            resetGesture()
            return false
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let keyCode = input.keyCode
        let decision = input.keyEvent(type, key: key, flags: event.flags,
            repeating: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            shortcutKeyDown: keyIsDown(keyCode), cancel: cancel)
        if let down = decision.changed { changed(down) }
        return decision.consumed
    }

    private func keyIsDown(_ key: CGKeyCode) -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: key)
    }
}

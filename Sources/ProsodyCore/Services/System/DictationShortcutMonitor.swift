import AppKit
import ApplicationServices
@preconcurrency import Carbon.HIToolbox
import IOKit.hidsystem
import OSLog

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
    let availabilityChanged: (Bool) -> Void
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

    var tracksRelease: Bool { press != .up || ownsEscape }

    mutating func recoverMissingReleases(shortcutKeyDown: Bool, escapeKeyDown: Bool, flags: CGEventFlags) -> Bool {
        let lostGesture = press == .reported &&
            (!shortcutKeyDown || (shortcut == .controlOptionSpace && !flags.contains([.maskControl, .maskAlternate])))
        if !shortcutKeyDown || lostGesture {
            resynchronize(shortcutKeyDown: shortcutKeyDown, escapeKeyDown: escapeKeyDown)
        } else if !escapeKeyDown {
            ownsEscape = false
        }
        return lostGesture
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
    private var tap: EventTap?
    private var releaseCheck: Task<Void, Never>?
    private var input: DictationShortcutInput
    private let changed: (Bool) -> Void
    private let cancel: () -> Bool
    private let resetGesture: () -> Void
    private let availabilityChanged: (Bool) -> Void

    init(shortcut: DictationShortcut, callbacks: DictationShortcutMonitorCallbacks) {
        input = DictationShortcutInput(shortcut: shortcut)
        changed = callbacks.changed
        cancel = callbacks.cancel
        resetGesture = callbacks.resetGesture
        availabilityChanged = callbacks.availabilityChanged
    }

    func start() -> Bool {
        stop()
        let tap = EventTap()
        guard tap.start(monitor: self) else { return false }
        self.tap = tap
        input.resynchronize(shortcutKeyDown: keyIsDown(input.keyCode))
        checkForMissingReleaseIfNeeded()
        return true
    }

    func stop() {
        releaseCheck?.cancel()
        releaseCheck = nil
        let hadTap = tap != nil
        tap?.stop()
        tap = nil
        input = DictationShortcutInput(shortcut: input.shortcut)
        if hadTap { resetGesture() }
    }

    deinit {
        releaseCheck?.cancel()
        guard let tap else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { tap.stop() }
        } else {
            Task { @MainActor in tap.stop() }
        }
    }

    private func handle(type: CGEventType, key: Int64, flags: CGEventFlags, repeating: Bool) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recoverTap()
            return false
        }
        let keyCode = input.keyCode
        let decision = input.keyEvent(type, key: key, flags: flags, repeating: repeating,
                                      shortcutKeyDown: keyIsDown(keyCode), cancel: cancel)
        if let down = decision.changed { changed(down) }
        checkForMissingReleaseIfNeeded()
        return decision.consumed
    }

    private func recoverTap() {
        guard let tap else { return }
        input.tapInterrupted(
            shortcutKeyDown: CGEventSource.keyState(.hidSystemState, key: input.keyCode),
            escapeKeyDown: CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Escape)),
            cancel: cancel
        )
        resetGesture()
        if tap.enable() {
            availabilityChanged(true)
        } else {
            // Leave the current callback before disposing of its run-loop source.
            Task { @MainActor [weak self, weak tap] in
                guard let self, let tap, self.tap === tap else { return }
                if !tap.enable() {
                    let replacement = EventTap()
                    guard replacement.start(monitor: self) else {
                        self.availabilityChanged(false)
                        Logger(subsystem: AppConstants.bundleIdentifier, category: "dictation-shortcut")
                            .error("Could not restore the dictation shortcut event tap")
                        return
                    }
                    tap.stop()
                    self.tap = replacement
                }
                self.availabilityChanged(true)
            }
        }
        checkForMissingReleaseIfNeeded()
    }

    private func checkForMissingReleaseIfNeeded() {
        guard releaseCheck == nil, input.tracksRelease else { return }
        releaseCheck = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self else { return }
                // HID state includes Space presses consumed by this session tap.
                if self.input.recoverMissingReleases(
                    shortcutKeyDown: CGEventSource.keyState(.hidSystemState, key: self.input.keyCode),
                    escapeKeyDown: CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Escape)),
                    flags: CGEventSource.flagsState(.hidSystemState)
                ) {
                    _ = self.cancel()
                    self.resetGesture()
                }
                if !self.input.tracksRelease {
                    self.releaseCheck = nil
                    return
                }
            }
        }
    }

    private func keyIsDown(_ key: CGKeyCode) -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: key)
    }

    @MainActor
    private final class EventTap {
        private weak var monitor: DictationShortcutMonitor?
        private var port: CFMachPort?
        private var source: CFRunLoopSource?
        private var observers: [any NSObjectProtocol] = []

        func start(monitor: DictationShortcutMonitor) -> Bool {
            self.monitor = monitor
            let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: Self.handle, userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
            guard let port, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                stop()
                return false
            }
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            guard enable() else {
                stop()
                return false
            }
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.monitor?.recoverTap() }
                })
            }
            return true
        }

        func enable() -> Bool {
            guard let port, CFMachPortIsValid(port) else { return false }
            CGEvent.tapEnable(tap: port, enable: true)
            return CGEvent.tapIsEnabled(tap: port)
        }

        func stop() {
            monitor = nil
            for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observers.removeAll()
            if let port {
                CGEvent.tapEnable(tap: port, enable: false)
                CFMachPortInvalidate(port)
            }
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            port = nil
            source = nil
        }

        private static let handle: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<EventTap>.fromOpaque(context).takeUnretainedValue()
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            let repeating = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let consumed = MainActor.assumeIsolated {
                tap.monitor?.handle(type: type, key: key, flags: flags, repeating: repeating) ?? false
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }
    }
}

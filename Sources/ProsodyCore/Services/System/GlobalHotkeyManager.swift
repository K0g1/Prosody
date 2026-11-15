import Foundation

#if os(macOS)
@preconcurrency import Carbon.HIToolbox

public enum GlobalHotkeyError: LocalizedError, Sendable {
    case invalidShortcut(String)
    case registrationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidShortcut(let shortcut):
            return "The shortcut \"\(shortcut)\" is not supported. Use modifier symbols followed by one letter or number."
        case .registrationFailed(let status):
            return "macOS could not register the shortcut (OSStatus \(status))."
        }
    }
}

/// Registers the user-facing recording shortcut with macOS' Carbon hot-key
/// service. Carbon delivers the event to the app even while another app is
/// frontmost, which is what makes the setting genuinely global for a
/// menu-bar-only application.
@MainActor
public final class GlobalHotkeyManager: @unchecked Sendable {
    private static let signature: OSType = 0x434C5059 // "CLPY"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let callback: @MainActor @Sendable () -> Void

    public init(
        shortcut: String,
        callback: @escaping @MainActor @Sendable () -> Void
    ) throws {
        self.callback = callback
        try register(shortcut: shortcut)
    }

    public func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    private func register(shortcut: String) throws {
        let parsed = try ShortcutParser.parse(shortcut)
        var eventSpec = EventTypeSpec(
            eventClass: UInt32(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        var newHandler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventSpec,
            userData,
            &newHandler
        )
        guard handlerStatus == noErr else {
            throw GlobalHotkeyError.registrationFailed(handlerStatus)
        }

        var newHotKey: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let hotKeyStatus = RegisterEventHotKey(
            parsed.keyCode,
            parsed.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyNoOptions),
            &newHotKey
        )
        guard hotKeyStatus == noErr else {
            if let newHandler {
                RemoveEventHandler(newHandler)
            }
            throw GlobalHotkeyError.registrationFailed(hotKeyStatus)
        }

        handlerRef = newHandler
        hotKeyRef = newHotKey
    }

    private static let eventHandler: EventHandlerUPP = { _, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let manager = Unmanaged<GlobalHotkeyManager>
            .fromOpaque(userData)
            .takeUnretainedValue()

        Task { @MainActor in
            manager.callback()
        }
        return noErr
    }
}

private struct ParsedShortcut: Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
}

private enum ShortcutParser {
    private static let modifierSymbols: [(String, UInt32)] = [
        ("⌘", UInt32(cmdKey)),
        ("⇧", UInt32(shiftKey)),
        ("⌥", UInt32(optionKey)),
        ("⌃", UInt32(controlKey))
    ]

    private static let keyCodes: [Character: UInt32] = [
        "A": UInt32(kVK_ANSI_A), "B": UInt32(kVK_ANSI_B), "C": UInt32(kVK_ANSI_C),
        "D": UInt32(kVK_ANSI_D), "E": UInt32(kVK_ANSI_E), "F": UInt32(kVK_ANSI_F),
        "G": UInt32(kVK_ANSI_G), "H": UInt32(kVK_ANSI_H), "I": UInt32(kVK_ANSI_I),
        "J": UInt32(kVK_ANSI_J), "K": UInt32(kVK_ANSI_K), "L": UInt32(kVK_ANSI_L),
        "M": UInt32(kVK_ANSI_M), "N": UInt32(kVK_ANSI_N), "O": UInt32(kVK_ANSI_O),
        "P": UInt32(kVK_ANSI_P), "Q": UInt32(kVK_ANSI_Q), "R": UInt32(kVK_ANSI_R),
        "S": UInt32(kVK_ANSI_S), "T": UInt32(kVK_ANSI_T), "U": UInt32(kVK_ANSI_U),
        "V": UInt32(kVK_ANSI_V), "W": UInt32(kVK_ANSI_W), "X": UInt32(kVK_ANSI_X),
        "Y": UInt32(kVK_ANSI_Y), "Z": UInt32(kVK_ANSI_Z),
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2),
        "3": UInt32(kVK_ANSI_3), "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5),
        "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7), "8": UInt32(kVK_ANSI_8),
        "9": UInt32(kVK_ANSI_9)
    ]

    static func parse(_ shortcut: String) throws -> ParsedShortcut {
        var remainder = shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
        var modifiers: UInt32 = 0

        while let modifier = modifierSymbols.first(where: { remainder.hasPrefix($0.0) }) {
            modifiers |= modifier.1
            remainder.removeFirst(modifier.0.count)
        }

        guard modifiers != 0,
              remainder.count == 1,
              let key = remainder.uppercased().first,
              let keyCode = keyCodes[key] else {
            throw GlobalHotkeyError.invalidShortcut(shortcut)
        }

        return ParsedShortcut(keyCode: keyCode, modifiers: modifiers)
    }
}
#endif

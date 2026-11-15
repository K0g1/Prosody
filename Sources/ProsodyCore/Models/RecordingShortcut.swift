import Foundation

/// Curated combinations avoid bare keys and the dictation shortcuts. Existing
/// custom shortcuts remain visible until the user chooses a preset.
public enum RecordingShortcut: String, CaseIterable, Identifiable, Sendable {
    case optionCommandR = "⌥⌘R"
    case controlOptionR = "⌃⌥R"
    case controlShiftR = "⌃⇧R"
    case commandShiftR = "⇧⌘R"
    case controlOptionC = "⌃⌥C"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .optionCommandR: "⌥⌘R · Option + Command + R"
        case .controlOptionR: "⌃⌥R · Control + Option + R"
        case .controlShiftR: "⌃⇧R · Control + Shift + R"
        case .commandShiftR: "⇧⌘R · Shift + Command + R"
        case .controlOptionC: "⌃⌥C · Control + Option + C"
        }
    }
}

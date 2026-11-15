import Foundation

/// Optional recorder content. Essential recording actions and recovery notices
/// stay visible regardless of these presentation preferences.
public enum MainScreenSection: String, CaseIterable, Identifiable, Sendable {
    case branding
    case recordingTitle
    case labels
    case source
    case noteTemplate
    case saveLocation
    case recents

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .branding: "Logo and Prosody name"
        case .recordingTitle: "Recording title"
        case .labels: "Recording labels"
        case .source: "Audio source"
        case .noteTemplate: "Note template"
        case .saveLocation: "Save location"
        case .recents: "Recent recordings"
        }
    }

    public var detail: String {
        switch self {
        case .branding: "Show the framed logo and name in the tray popup. The recording timer stays visible."
        case .recordingTitle: "Name the next recording in the tray popup before you start."
        case .labels: "Choose labels for the next recording in the tray popup."
        case .source: "Switch between microphone, system audio, or both in the tray popup."
        case .noteTemplate: "Choose a template when automatic notes are enabled in the tray popup."
        case .saveLocation: "Show the destination for the next recording in the tray popup."
        case .recents: "Show your three most recent recordings in the tray popup. All recordings remain in Transcripts."
        }
    }
}

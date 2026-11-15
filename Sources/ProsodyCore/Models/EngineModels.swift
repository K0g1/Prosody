import Foundation

public enum STTEngineID: String, Codable, CaseIterable, Sendable, Identifiable {
    case parakeet
    case whisper
    case appleSpeech

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .parakeet: return "Parakeet"
        case .whisper: return "Whisper"
        case .appleSpeech: return "Apple Speech"
        }
    }
}

public struct STTEngineDescriptor: Codable, Hashable, Sendable, Identifiable {
    public let id: STTEngineID
    public let displayName: String
    public let detail: String

    public init(id: STTEngineID, displayName: String, detail: String) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
    }
}

public struct STTModelDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let engineID: STTEngineID
    public let displayName: String
    public let languages: [String]
    public let supportsStreaming: Bool
    public let supportsWordTimestamps: Bool
    public let estimatedDownloadBytes: Int64?
    public let minimumMacOSMajor: Int

    public init(
        id: String,
        engineID: STTEngineID,
        displayName: String,
        languages: [String],
        supportsStreaming: Bool,
        supportsWordTimestamps: Bool,
        estimatedDownloadBytes: Int64?,
        minimumMacOSMajor: Int = 15
    ) {
        self.id = id
        self.engineID = engineID
        self.displayName = displayName
        self.languages = languages
        self.supportsStreaming = supportsStreaming
        self.supportsWordTimestamps = supportsWordTimestamps
        self.estimatedDownloadBytes = estimatedDownloadBytes
        self.minimumMacOSMajor = minimumMacOSMajor
    }

    public var downloadSizeLabel: String {
        guard let estimatedDownloadBytes else { return "Size varies" }
        let megabytes = Double(estimatedDownloadBytes) / 1_000_000
        return megabytes >= 1000 ? String(format: "%.1f GB", megabytes / 1000) : String(format: "%.0f MB", megabytes)
    }
}

public struct LLMProviderDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let detail: String
    public let isRemote: Bool

    public init(id: String, displayName: String, detail: String, isRemote: Bool) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.isRemote = isRemote
    }
}

public struct LLMModelDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct ProviderConfiguration: Codable, Sendable, Equatable {
    public var id: String
    public var baseURL: URL
    public var modelID: String

    public init(id: String = "local-openai-compatible", baseURL: URL = URL(string: "http://127.0.0.1:1234/v1")!, modelID: String = "qwen3-4b") {
        self.id = id
        self.baseURL = baseURL
        self.modelID = modelID
    }
}

public enum NoteTemplateID: String, Codable, CaseIterable, Sendable, Identifiable {
    case lectureNotes = "lecture-notes"
    case meetingMinutes = "meeting-minutes"
    case studyNotes = "study-notes"
    case cornellNotes = "cornell-notes"
    case summary
    case actionItems = "action-items"
    case transcriptOnly = "transcript-only"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lectureNotes: return "Lecture Notes"
        case .meetingMinutes: return "Meeting Minutes"
        case .studyNotes: return "Study Notes"
        case .cornellNotes: return "Cornell Notes"
        case .summary: return "Summary"
        case .actionItems: return "Action Items"
        case .transcriptOnly: return "Transcript Only"
        }
    }
}

public struct NotesRequest: Sendable {
    public let title: String
    public let transcript: Transcript
    public let template: NoteTemplateID
    public let duration: TimeInterval

    public init(title: String, transcript: Transcript, template: NoteTemplateID, duration: TimeInterval) {
        self.title = title
        self.transcript = transcript
        self.template = template
        self.duration = duration
    }
}

public struct NotesResult: Sendable, Equatable {
    public let markdown: String

    public init(markdown: String) {
        self.markdown = markdown
    }
}

import Foundation

public struct TranscriptWord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Float?

    public init(id: UUID = UUID(), text: String, start: TimeInterval, end: TimeInterval, confidence: Float? = nil) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct TranscriptSegment: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var source: AudioSource
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var words: [TranscriptWord]
    public var isFinal: Bool
    public var speakerID: String?
    public var speakerName: String?
    public var speakerConfidence: Float?
    public var isEchoDuplicate: Bool
    public var wasUserEdited: Bool

    public init(
        id: UUID = UUID(),
        source: AudioSource,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        words: [TranscriptWord] = [],
        isFinal: Bool,
        speakerID: String? = nil,
        speakerName: String? = nil,
        speakerConfidence: Float? = nil,
        isEchoDuplicate: Bool = false,
        wasUserEdited: Bool = false
    ) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.isFinal = isFinal
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.speakerConfidence = speakerConfidence
        self.isEchoDuplicate = isEchoDuplicate
        self.wasUserEdited = wasUserEdited
    }

    public var visibleSpeakerName: String {
        if let speakerName, !speakerName.isEmpty { return speakerName }
        return speakerID ?? (source == .microphone ? "You" : "Others")
    }
}

public struct Transcript: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public var segments: [TranscriptSegment]

    public init(schemaVersion: Int = 1, segments: [TranscriptSegment] = []) {
        self.schemaVersion = schemaVersion
        self.segments = segments
    }

    public var visibleSegments: [TranscriptSegment] {
        segments.filter { !$0.isEchoDuplicate }
    }

    /// Plain speech, one nonempty segment per paragraph. Whitespace inside a
    /// segment is normalized and paragraphs are separated by one blank line.
    public var rawText: String {
        visibleSegments.map { $0.text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

public struct SpeakerInterval: Codable, Sendable, Equatable {
    public let speakerID: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let confidence: Float?

    public init(speakerID: String, start: TimeInterval, end: TimeInterval, confidence: Float? = nil) {
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct FinalTranscript: Sendable, Equatable {
    public let segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment]) {
        self.segments = segments
    }
}

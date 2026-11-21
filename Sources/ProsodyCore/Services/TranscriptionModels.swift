import Foundation

public enum STTStatus: Codable, Equatable, Sendable {
    case idle
    case loading(progress: Double)
    case recognizing
    case finished

    private enum CodingKeys: String, CodingKey { case kind, progress }
    private enum Kind: String, Codable { case idle, loading, recognizing, finished }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try container.encode(Kind.idle, forKey: .kind)
        case .loading(let progress):
            try container.encode(Kind.loading, forKey: .kind)
            try container.encode(progress, forKey: .progress)
        case .recognizing:
            try container.encode(Kind.recognizing, forKey: .kind)
        case .finished:
            try container.encode(Kind.finished, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .idle: self = .idle
        case .loading: self = .loading(progress: try container.decode(Double.self, forKey: .progress))
        case .recognizing: self = .recognizing
        case .finished: self = .finished
        }
    }
}

public struct STTFailure: Codable, Equatable, Error, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public enum STTError: Error, Equatable, Sendable {
    case modelNotLoaded
    case unsupportedModel(String)
    case sessionFinished
    case invalidAudio
    case cancelled
    case failed(String)
}

public enum STTUpdate: Sendable {
    case provisional(source: AudioSource, segment: TranscriptSegment)
    case final(source: AudioSource, segment: TranscriptSegment)
    case status(STTStatus)
    case error(STTFailure)
}

public protocol STTSession: Sendable {
    var updates: AsyncStream<STTUpdate> { get }

    func append(samples: [Float], startTime: TimeInterval) async throws
    func finish() async throws -> FinalTranscript
    func cancel() async
}

public protocol STTEngine: Sendable {
    var descriptor: STTEngineDescriptor { get }

    func prepare(
        model: STTModelDescriptor,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws

    func makeSession(source: AudioSource) async throws -> any STTSession
    func unload() async
}

public struct TranscriptSnapshot: Codable, Equatable, Sendable {
    public let segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment]) {
        self.segments = segments
    }

    public var visibleSegments: [TranscriptSegment] {
        segments.filter { !$0.isEchoDuplicate }
    }
}

/// Synchronous transcript assembly for deterministic tests and small clients.
/// A source owns at most one active provisional tail; revisions replace that
/// tail instead of accumulating duplicate text.
public struct TranscriptAccumulator: Sendable {
    public private(set) var segments: [TranscriptSegment]
    public let speakerMode: SpeakerMode
    public var provisionalReplacementTolerance: TimeInterval

    public init(
        segments: [TranscriptSegment] = [],
        speakerMode: SpeakerMode = .basic,
        provisionalReplacementTolerance: TimeInterval = 2
    ) {
        self.segments = segments
        self.speakerMode = speakerMode
        self.provisionalReplacementTolerance = max(0, provisionalReplacementTolerance)
    }

    @discardableResult
    public mutating func ingest(_ update: STTUpdate) -> TranscriptSnapshot {
        switch update {
        case .provisional(let source, var segment):
            segment.source = source
            segment.isFinal = false
            upsert(segment, isFinal: false)
        case .final(let source, var segment):
            segment.source = source
            segment.isFinal = true
            upsert(segment, isFinal: true)
        case .status, .error:
            break
        }
        sortSegments()
        return snapshot()
    }

    public mutating func ingest(segment: TranscriptSegment, isFinal: Bool) -> TranscriptSnapshot {
        ingest(isFinal
            ? .final(source: segment.source, segment: segment)
            : .provisional(source: segment.source, segment: segment))
    }

    public mutating func finalize() -> TranscriptSnapshot {
        for index in segments.indices {
            segments[index].isFinal = true
        }
        sortSegments()
        return snapshot()
    }

    public func snapshot() -> TranscriptSnapshot {
        TranscriptSnapshot(segments: segments)
    }

    public func transcript(schemaVersion: Int = 1) -> Transcript {
        Transcript(schemaVersion: schemaVersion, segments: segments)
    }

    public mutating func reset() {
        segments.removeAll(keepingCapacity: false)
    }

    private mutating func upsert(_ incoming: TranscriptSegment, isFinal: Bool) {
        let exactMatch = segments.first { $0.id == incoming.id }
        if !isFinal, exactMatch?.isFinal == true { return }

        let tolerance = provisionalReplacementTolerance
        segments.removeAll { existing in
            if existing.id == incoming.id { return true }
            guard !existing.isFinal, existing.source == incoming.source else { return false }
            if !isFinal { return true }
            // The decoder normally finalizes the same ID. If a different
            // ID is used, an older final must not remove a newer live tail.
            guard exactMatch == nil, incoming.end >= existing.end else { return false }
            return Self.overlapsOrNear(existing, incoming, tolerance: tolerance)
        }

        segments.append(applyDefaultSpeaker(to: incoming))
    }

    private static func overlapsOrNear(
        _ lhs: TranscriptSegment, _ rhs: TranscriptSegment, tolerance: TimeInterval
    ) -> Bool {
        let overlap = min(lhs.end, rhs.end) - max(lhs.start, rhs.start)
        if overlap >= 0 { return true }
        return abs(lhs.start - rhs.start) <= tolerance
            || abs(lhs.end - rhs.end) <= tolerance
    }

    private func applyDefaultSpeaker(to segment: TranscriptSegment) -> TranscriptSegment {
        guard speakerMode != .off, segment.speakerID == nil, segment.speakerName == nil else {
            return segment
        }
        var result = segment
        switch segment.source {
        case .microphone:
            result.speakerID = "you"
            result.speakerName = "You"
        case .system:
            result.speakerID = "others"
            result.speakerName = "Others"
        }
        return result
    }

    private mutating func sortSegments() {
        segments.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

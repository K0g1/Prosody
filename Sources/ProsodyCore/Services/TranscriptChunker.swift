import Foundation

public struct TranscriptChunkingOptions: Codable, Equatable, Sendable {
    public var targetDuration: TimeInterval
    public var maximumDuration: TimeInterval
    public var maximumCharacters: Int
    public var silenceGap: TimeInterval

    public init(
        targetDuration: TimeInterval = 10 * 60,
        maximumDuration: TimeInterval = 12 * 60,
        maximumCharacters: Int = 12_000,
        silenceGap: TimeInterval = 1.5
    ) {
        self.targetDuration = max(1, targetDuration)
        self.maximumDuration = max(self.targetDuration, maximumDuration)
        self.maximumCharacters = max(1, maximumCharacters)
        self.silenceGap = max(0, silenceGap)
    }
}

public struct TranscriptChunk: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let start: TimeInterval
    public let end: TimeInterval
    public let segments: [TranscriptSegment]

    public init(id: Int, start: TimeInterval, end: TimeInterval, segments: [TranscriptSegment]) {
        self.id = id
        self.start = start
        self.end = end
        self.segments = segments
    }

    public var text: String {
        segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public struct TranscriptChunking: Sendable {
    public let options: TranscriptChunkingOptions

    public init(options: TranscriptChunkingOptions = TranscriptChunkingOptions()) {
        self.options = options
    }

    public func chunks(for segments: [TranscriptSegment]) -> [TranscriptChunk] {
        let ordered = segments
            .filter { !$0.isEchoDuplicate }
            .sorted(by: order)
        guard !ordered.isEmpty else { return [] }

        var result: [TranscriptChunk] = []
        var current: [TranscriptSegment] = []
        var currentCharacters = 0
        var currentEnd: TimeInterval = 0

        func flush() {
            guard let first = current.first else { return }
            result.append(TranscriptChunk(
                id: result.count,
                start: first.start,
                end: currentEnd,
                segments: current
            ))
        }

        for segment in ordered {
            guard let previous = current.last else {
                current = [segment]
                currentCharacters = segment.text.count
                currentEnd = segment.end
                continue
            }

            let duration = max(0, currentEnd - current[0].start)
            let proposedEnd = max(currentEnd, segment.end)
            let proposedDuration = max(0, proposedEnd - current[0].start)
            let proposedCharacters = currentCharacters + segment.text.count + 1
            let silenceBoundary = segment.start - currentEnd >= options.silenceGap
            let speakerBoundary = previous.speakerID != segment.speakerID
            let targetBoundary = duration >= options.targetDuration && (silenceBoundary || speakerBoundary)
            let hardBoundary = proposedDuration > options.maximumDuration
                || proposedCharacters > options.maximumCharacters

            if hardBoundary || targetBoundary {
                flush()
                current = [segment]
                currentCharacters = segment.text.count
                currentEnd = segment.end
            } else {
                current.append(segment)
                currentCharacters = proposedCharacters
                currentEnd = proposedEnd
            }
        }
        flush()
        return result
    }

    public func chunk(_ segments: [TranscriptSegment]) -> [TranscriptChunk] {
        chunks(for: segments)
    }

    private func order(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public actor TranscriptChunker {
    private let algorithm: TranscriptChunking

    public init(options: TranscriptChunkingOptions = TranscriptChunkingOptions()) {
        self.algorithm = TranscriptChunking(options: options)
    }

    public func chunks(for segments: [TranscriptSegment]) -> [TranscriptChunk] {
        algorithm.chunks(for: segments)
    }
}

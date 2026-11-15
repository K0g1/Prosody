import Foundation

public struct SpeakerAttributedSegment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let speakerID: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    public let words: [TranscriptWord]
    public let confidence: Float?

    public init(
        id: UUID = UUID(),
        speakerID: String,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        words: [TranscriptWord] = [],
        confidence: Float? = nil
    ) {
        self.id = id
        self.speakerID = speakerID
        self.start = start
        self.end = end
        self.text = text
        self.words = words
        self.confidence = confidence
    }
}

public struct SpeakerAlignment: Sendable {
    public init() {}

    public func align(
        words: [TranscriptWord],
        speakers: [SpeakerInterval]
    ) -> [SpeakerAttributedSegment] {
        guard !words.isEmpty else { return [] }

        var groups: [(speakerID: String, confidence: Float?, words: [TranscriptWord])] = []
        for word in words.sorted(by: wordOrder) {
            let interval = bestInterval(for: word, in: speakers)
            let speakerID = interval?.speakerID ?? "unknown"
            if let last = groups.last, last.speakerID == speakerID {
                groups[groups.count - 1].words.append(word)
                if let confidence = interval?.confidence {
                    groups[groups.count - 1].confidence = combinedConfidence(
                        groups[groups.count - 1].confidence,
                        confidence
                    )
                }
            } else {
                groups.append((speakerID, interval?.confidence, [word]))
            }
        }

        return groups.map { group in
            SpeakerAttributedSegment(
                speakerID: group.speakerID,
                start: group.words.first?.start ?? 0,
                end: group.words.last?.end ?? 0,
                text: group.words.map(\.text).joined(separator: " "),
                words: group.words,
                confidence: group.confidence
            )
        }
    }

    /// Applies timed speaker assignments while preserving all transcript
    /// metadata. Segments split when adjacent words belong to different
    /// speakers; no words are discarded when diarization has a gap.
    public func apply(
        to segments: [TranscriptSegment],
        intervals: [SpeakerInterval]
    ) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        result.reserveCapacity(segments.count)

        for segment in segments {
            if segment.words.isEmpty {
                var copy = segment
                if let interval = bestInterval(for: segment.start, end: segment.end, in: intervals) {
                    copy.speakerID = interval.speakerID
                    copy.speakerName = nil
                    copy.speakerConfidence = interval.confidence
                }
                result.append(copy)
                continue
            }

            let attributed = align(words: segment.words, speakers: intervals)
            for (index, group) in attributed.enumerated() {
                var copy = segment
                copy.start = group.start
                copy.end = group.end
                copy.text = group.text
                copy.words = group.words
                copy.speakerID = group.speakerID == "unknown" ? nil : group.speakerID
                copy.speakerName = nil
                copy.speakerConfidence = group.confidence
                if index > 0 {
                    copy = TranscriptSegment(
                        source: segment.source,
                        start: group.start,
                        end: group.end,
                        text: group.text,
                        words: group.words,
                        isFinal: segment.isFinal,
                        speakerID: copy.speakerID,
                        speakerName: nil,
                        speakerConfidence: group.confidence,
                        isEchoDuplicate: segment.isEchoDuplicate,
                        wasUserEdited: segment.wasUserEdited
                    )
                }
                result.append(copy)
            }
        }
        return result
    }

    private func bestInterval(for word: TranscriptWord, in intervals: [SpeakerInterval]) -> SpeakerInterval? {
        bestInterval(for: word.start, end: word.end, in: intervals)
    }

    private func bestInterval(
        for start: TimeInterval,
        end: TimeInterval,
        in intervals: [SpeakerInterval]
    ) -> SpeakerInterval? {
        intervals
            .map { interval in (interval, overlap(start: start, end: end, interval: interval)) }
            .filter { $0.1 > 0 || ($0.0.start <= start && start <= $0.0.end) }
            .max { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.start > rhs.0.start
            }?.0
    }

    private func overlap(start: TimeInterval, end: TimeInterval, interval: SpeakerInterval) -> TimeInterval {
        max(0, min(end, interval.end) - max(start, interval.start))
    }

    private func combinedConfidence(_ lhs: Float?, _ rhs: Float) -> Float {
        guard let lhs else { return rhs }
        return (lhs + rhs) / 2
    }

    private func wordOrder(_ lhs: TranscriptWord, _ rhs: TranscriptWord) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public actor SpeakerAligner {
    private let algorithm = SpeakerAlignment()

    public init() {}

    public func align(
        words: [TranscriptWord],
        speakers: [SpeakerInterval]
    ) -> [SpeakerAttributedSegment] {
        algorithm.align(words: words, speakers: speakers)
    }

    public func apply(
        to segments: [TranscriptSegment],
        intervals: [SpeakerInterval]
    ) -> [TranscriptSegment] {
        algorithm.apply(to: segments, intervals: intervals)
    }
}

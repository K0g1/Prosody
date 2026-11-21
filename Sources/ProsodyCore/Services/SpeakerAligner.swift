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

        var groups: [WordGroup] = []
        for word in words.sorted(by: wordOrder) {
            let interval = bestInterval(for: word.start, end: word.end, in: speakers)
            let speakerID = interval?.speakerID ?? "unknown"
            if groups.last?.speakerID != speakerID {
                groups.append(WordGroup(speakerID: speakerID))
            }
            groups[groups.count - 1].append(word, confidence: interval?.confidence)
        }
        return groups.map(\.segment)
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
            // Manual speaker names are attached to the saved segment.
            if segment.wasUserEdited {
                result.append(segment)
                continue
            }
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

    private func bestInterval(
        for start: TimeInterval,
        end: TimeInterval,
        in intervals: [SpeakerInterval]
    ) -> SpeakerInterval? {
        var best: SpeakerInterval?
        var bestOverlap = 0.0
        for interval in intervals {
            let overlap = max(0, min(end, interval.end) - max(start, interval.start))
            guard overlap > 0 || (interval.start <= start && start <= interval.end) else { continue }
            if overlap > bestOverlap || (overlap == bestOverlap && interval.start < (best?.start ?? .infinity)) {
                best = interval
                bestOverlap = overlap
            }
        }
        return best
    }

    private struct WordGroup {
        let speakerID: String
        private var words: [TranscriptWord] = []
        private var end: TimeInterval = 0
        private var confidenceTotal: Double = 0
        private var confidenceCount = 0

        init(speakerID: String) {
            self.speakerID = speakerID
        }

        mutating func append(_ word: TranscriptWord, confidence: Float?) {
            words.append(word)
            end = max(end, word.end)
            if let confidence, confidence.isFinite {
                confidenceTotal += Double(confidence)
                confidenceCount += 1
            }
        }

        var segment: SpeakerAttributedSegment {
            SpeakerAttributedSegment(
                speakerID: speakerID,
                start: words.first?.start ?? 0,
                end: end,
                text: words.map(\.text).joined(separator: " "),
                words: words,
                confidence: confidenceCount > 0 ? Float(confidenceTotal / Double(confidenceCount)) : nil
            )
        }
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

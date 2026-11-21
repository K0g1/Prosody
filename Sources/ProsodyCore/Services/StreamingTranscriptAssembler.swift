import Foundation

/// Builds bounded, timed speaker turns from incremental SentencePiece tokens.
/// The last word remains open across decoder batches so subwords are not split.
public struct StreamingTranscriptAssembler: Sendable {
    private let source: AudioSource
    private let configuration: TranscriptSegmentationConfiguration
    private var words: [TranscriptWord] = []
    private var segmentEnd: TimeInterval = 0
    private var segmentID = UUID()
    private var pendingWordBoundary = false
    public private(set) var finalized: [TranscriptSegment] = []

    public init(
        source: AudioSource,
        configuration: TranscriptSegmentationConfiguration = .init()
    ) {
        self.source = source
        self.configuration = configuration
    }

    public mutating func append(token: String, start: TimeInterval, end: TimeInterval) -> [TranscriptSegment] {
        guard start.isFinite, end.isFinite, start >= 0, end >= start else { return [] }
        let normalized = token.replacingOccurrences(of: "▁", with: " ")
        let text = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        // SentencePiece can emit a standalone space, including at the end of
        // a decoder batch. Preserve it until the next nonempty token arrives.
        guard !text.isEmpty else {
            if normalized.contains(where: \.isWhitespace) { pendingWordBoundary = true }
            return []
        }
        let startsWord = pendingWordBoundary || normalized.first?.isWhitespace == true
        pendingWordBoundary = false
        var completed: [TranscriptSegment] = []
        if startsWord, let last = words.last,
           last.text.last.map({ ".!?".contains($0) }) == true
            || words.count >= configuration.maximumWordsPerSegment
            || start - segmentEnd >= configuration.pauseThreshold {
            if let segment = flush() { completed.append(segment) }
        }
        if startsWord || words.isEmpty {
            words.append(TranscriptWord(text: text, start: start, end: end))
        } else {
            words[words.count - 1].text += text
            words[words.count - 1].end = max(words[words.count - 1].end, end)
        }
        segmentEnd = max(segmentEnd, end)
        return completed
    }

    public var provisional: TranscriptSegment? { makeSegment(isFinal: false) }

    @discardableResult
    public mutating func flush() -> TranscriptSegment? {
        guard let segment = makeSegment(isFinal: true) else { return nil }
        finalized.append(segment)
        words.removeAll(keepingCapacity: true)
        segmentEnd = 0
        segmentID = UUID()
        return segment
    }

    private func makeSegment(isFinal: Bool) -> TranscriptSegment? {
        guard let first = words.first else { return nil }
        return TranscriptSegment(id: segmentID, source: source, start: first.start,
                                 end: segmentEnd, text: words.map(\.text).joined(separator: " "),
                                 words: words, isFinal: isFinal)
    }
}

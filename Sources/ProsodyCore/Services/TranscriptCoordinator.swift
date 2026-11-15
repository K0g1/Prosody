import Foundation

/// Actor-owned canonical transcript. UI snapshots are copies and never the
/// source of truth.
public actor TranscriptCoordinator {
    private var accumulator: TranscriptAccumulator
    private let deduplicationOptions: EchoDeduplicationOptions
    private var lastFailure: STTFailure?
    private let onFinalizedSegment: (@Sendable (TranscriptSegment) async -> Void)?

    public init(
        speakerMode: SpeakerMode = .basic,
        provisionalReplacementTolerance: TimeInterval = 2,
        deduplicationOptions: EchoDeduplicationOptions = EchoDeduplicationOptions(),
        onFinalizedSegment: (@Sendable (TranscriptSegment) async -> Void)? = nil
    ) {
        self.accumulator = TranscriptAccumulator(
            speakerMode: speakerMode,
            provisionalReplacementTolerance: provisionalReplacementTolerance
        )
        self.deduplicationOptions = deduplicationOptions
        self.onFinalizedSegment = onFinalizedSegment
    }

    @discardableResult
    public func ingest(_ update: STTUpdate) async -> TranscriptSnapshot {
        if case .error(let failure) = update {
            lastFailure = failure
            return accumulator.snapshot()
        }

        let snapshot = accumulator.ingest(update)
        if case .final(_, let segment) = update {
            let finalized = snapshot.segments.first(where: { $0.id == segment.id }) ?? segment
            if let onFinalizedSegment {
                await onFinalizedSegment(finalized)
            }
        }
        return snapshot
    }

    @discardableResult
    public func ingest(segment: TranscriptSegment, isFinal: Bool) async -> TranscriptSnapshot {
        await ingest(isFinal
            ? .final(source: segment.source, segment: segment)
            : .provisional(source: segment.source, segment: segment))
    }

    public func snapshot() -> TranscriptSnapshot {
        accumulator.snapshot()
    }

    public func lastError() -> STTFailure? {
        lastFailure
    }

    public func finalize() -> Transcript {
        _ = accumulator.finalize()
        return accumulator.transcript()
    }

    public func deduplicatedTranscript() -> Transcript {
        let deduplicator = EchoDeduplication(options: deduplicationOptions)
        return Transcript(segments: deduplicator.markDuplicates(in: accumulator.segments))
    }

    public func mergeAndDeduplicate() -> Transcript {
        let deduplicator = EchoDeduplication(options: deduplicationOptions)
        let marked = deduplicator.markDuplicates(in: accumulator.segments)
        return Transcript(segments: marked.sorted(by: Self.transcriptOrder))
    }

    public func applySpeakerIntervals(_ intervals: [SpeakerInterval]) -> Transcript {
        let aligner = SpeakerAlignment()
        let aligned = aligner.apply(to: accumulator.segments, intervals: intervals)
        return Transcript(segments: aligned.sorted(by: Self.transcriptOrder))
    }

    public func reset() {
        accumulator.reset()
        lastFailure = nil
    }

    private static func transcriptOrder(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

import Foundation

/// A stable, chronological view of the visible transcript. The row identifiers
/// are the persisted segment identifiers, so playback following never needs to
/// rebuild identity from row positions.
public struct TranscriptTimelineRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let segment: TranscriptSegment
    public let chronologicalIndex: Int

    public var start: TimeInterval { segment.start }
    public var end: TimeInterval { segment.end }
    public var text: String { segment.text }

    public init(segment: TranscriptSegment, chronologicalIndex: Int) {
        self.id = segment.id
        self.segment = segment
        self.chronologicalIndex = chronologicalIndex
    }
}

/// A small, precomputed ink profile for the reader's timeline. It is built with
/// the transcript projection rather than from row geometry during playback.
public struct TranscriptTimelineDensity: Equatable, Sendable {
    public let bins: [Double]
    public let speechEnd: TimeInterval

    public init(rows: [TranscriptTimelineRow], binCount: Int = 240) {
        let count = max(1, binCount)
        let finiteRows = rows.filter { $0.start.isFinite && $0.end.isFinite }
        guard let timelineEnd = finiteRows.map(\.end).max(), timelineEnd.isFinite, timelineEnd > 0 else {
            speechEnd = 0
            bins = Array(repeating: 0, count: count)
            return
        }
        speechEnd = timelineEnd

        var counts = Array(repeating: 0.0, count: count)
        for row in finiteRows {
            let start = min(max(0, row.start), timelineEnd)
            let end = min(max(start, row.end), timelineEnd)
            let firstValue = (start / timelineEnd) * Double(count)
            let lastValue = (end / timelineEnd) * Double(count)
            guard firstValue.isFinite, lastValue.isFinite else { continue }
            let first = Int(min(Double(count - 1), max(0, floor(firstValue))))
            let last = Int(min(
                Double(count - 1),
                max(Double(first), ceil(lastValue) - 1)
            ))
            for index in first...last {
                counts[index] += 1
            }
        }

        let maximum = counts.max() ?? 0
        bins = maximum > 0 ? counts.map { $0 / maximum } : counts
    }

    public static let empty = TranscriptTimelineDensity(rows: [])
}

/// Immutable chronological projection used by the reader. Timestamp lookup is
/// an upper-bound binary search over segment starts. A timestamp in a gap maps
/// to the preceding row; a timestamp before the first row maps to the first row
/// and a timestamp after the last row maps to the last row. Overlaps map to the
/// most recently started row, with equal starts ordered by end time and UUID.
public struct TranscriptTimeline: Equatable, Sendable {
    public let rows: [TranscriptTimelineRow]
    public let density: TranscriptTimelineDensity

    private let starts: [TimeInterval]

    public init(segments: [TranscriptSegment], densityBinCount: Int = 240) {
        let ordered = segments
            .filter { !$0.isEchoDuplicate && $0.start.isFinite && $0.end.isFinite }
            .sorted(by: Self.chronologicalOrder)
        rows = ordered.enumerated().map { index, segment in
            TranscriptTimelineRow(segment: segment, chronologicalIndex: index)
        }
        starts = ordered.map(\.start)
        density = TranscriptTimelineDensity(rows: rows, binCount: densityBinCount)
    }

    public var segments: [TranscriptSegment] { rows.map(\.segment) }

    public func rowIndex(at time: TimeInterval) -> Int? {
        guard !rows.isEmpty, !time.isNaN else { return nil }
        if time == -.infinity { return 0 }
        if time == .infinity { return rows.count - 1 }

        let value = max(0, time)
        var lower = 0
        var upper = starts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if starts[middle] <= value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(0, lower - 1)
    }

    public func row(at time: TimeInterval) -> TranscriptTimelineRow? {
        guard let index = rowIndex(at: time) else { return nil }
        return rows[index]
    }

    private static func chronologicalOrder(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

import Combine
import Foundation

struct TranscriptReaderProjection: Equatable, Sendable {
    let timeline: TranscriptTimeline
    let rows: [TranscriptTimelineRow]
    let query: String

    var isSearching: Bool { !query.isEmpty }

    static let empty = TranscriptReaderProjection(
        timeline: TranscriptTimeline(segments: []),
        rows: [],
        query: ""
    )

    init(timeline: TranscriptTimeline, rows: [TranscriptTimelineRow], query: String) {
        self.timeline = timeline
        self.rows = rows
        self.query = query
    }
}

/// Owns the expensive document and search projections. Playback clocks never
/// touch this object, so a five-Hz transport update cannot rebuild or diff the
/// transcript.
@MainActor
final class TranscriptReaderCache: ObservableObject {
    @Published private(set) var projection: TranscriptReaderProjection
    private(set) var projectionRevision = 1

    private var transcript: Transcript
    private var query = ""
    private(set) var rebuildCount = 1
    private(set) var searchProjectionCount = 0

    init(transcript: Transcript) {
        self.transcript = transcript
        let timeline = TranscriptTimeline(segments: transcript.segments)
        projection = TranscriptReaderProjection(timeline: timeline, rows: timeline.rows, query: "")
    }

    func update(transcript: Transcript) {
        guard transcript != self.transcript else { return }
        self.transcript = transcript
        rebuildCount += 1
        rebuildProjection()
    }

    func updateSearch(_ query: String) {
        guard query != self.query else { return }
        self.query = query
        rebuildSearchProjection()
    }

    private func rebuildProjection() {
        let timeline = TranscriptTimeline(segments: transcript.segments)
        searchProjectionCount += 1
        projectionRevision &+= 1
        projection = TranscriptReaderProjection(
            timeline: timeline,
            rows: filteredRows(in: timeline.rows),
            query: query
        )
    }

    private func rebuildSearchProjection() {
        searchProjectionCount += 1
        projectionRevision &+= 1
        projection = TranscriptReaderProjection(
            timeline: projection.timeline,
            rows: filteredRows(in: projection.timeline.rows),
            query: query
        )
    }

    private func filteredRows(in rows: [TranscriptTimelineRow]) -> [TranscriptTimelineRow] {
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            row.segment.text.localizedCaseInsensitiveContains(query)
                || row.segment.visibleSpeakerName.localizedCaseInsensitiveContains(query)
        }
    }
}

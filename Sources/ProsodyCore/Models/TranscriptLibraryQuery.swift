import Foundation

public enum TranscriptSort: String, CaseIterable, Identifiable, Sendable {
    case newest = "Newest first"
    case oldest = "Oldest first"
    case name = "Recording name"
    case longest = "Longest first"
    case shortest = "Shortest first"
    case label = "Label"
    public var id: String { rawValue }
}

public enum TranscriptAudioFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "Any audio"
    case retained = "With retained audio"
    case notRetained = "Without retained audio"

    public var id: String { rawValue }
}

public enum TranscriptLibraryQuery {
    public static func apply(
        to sessions: [SessionSummary],
        search: String,
        labelID: UUID?,
        sort: TranscriptSort,
        includeDictation: Bool = false,
        audioFilter: TranscriptAudioFilter = .any
    ) -> [SessionSummary] {
        let search = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { session in
            (includeDictation || !session.isDictation)
            && audioMatches(session, filter: audioFilter)
            && (labelID == nil || session.labels?.contains(where: { $0.id == labelID }) == true)
            && (search.isEmpty || session.title.localizedCaseInsensitiveContains(search)
                || session.labels?.contains(where: { $0.name.localizedCaseInsensitiveContains(search) }) == true)
        }.sorted { lhs, rhs in
            switch sort {
            case .newest: if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            case .oldest: if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            case .name:
                let order = lhs.title.localizedStandardCompare(rhs.title)
                if order != .orderedSame { return order == .orderedAscending }
            case .longest: if lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
            case .shortest: if lhs.duration != rhs.duration { return lhs.duration < rhs.duration }
            case .label:
                let left = lhs.labels?.map(\.name).sorted().joined(separator: ", ") ?? ""
                let right = rhs.labels?.map(\.name).sorted().joined(separator: ", ") ?? ""
                let order = left.localizedStandardCompare(right)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func audioMatches(_ session: SessionSummary, filter: TranscriptAudioFilter) -> Bool {
        switch filter {
        case .any: return true
        case .retained: return session.hasRetainedAudio == true
        case .notRetained: return session.hasRetainedAudio == false
        }
    }
}

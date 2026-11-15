import Foundation

public enum SessionIndexStoreError: Error, Equatable, Sendable {
    case invalidIndex
}

public actor SessionIndexStore {
    public let fileURL: URL
    private static let mutationLock = NSLock()

    public init(rootURL: URL) {
        self.fileURL = rootURL.appendingPathComponent(AppConstants.sessionIndexFileName)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [SessionSummary] {
        try read()
    }

    public func replace(with summaries: [SessionSummary]) throws {
        try Self.withMutationLock {
            try write(Self.sorted(summaries))
        }
    }

    public func upsert(_ summary: SessionSummary) throws {
        try Self.withMutationLock {
            var summaries = try read()
            summaries.removeAll { $0.id == summary.id }
            summaries.append(summary)
            try write(Self.sorted(summaries))
        }
    }

    /// Fills metadata missing from an older index without replacing entries
    /// that another store instance may have written since the scan began.
    public func backfillMetadata(_ updates: [UUID: SessionSummary]) throws -> [SessionSummary] {
        try Self.withMutationLock {
            var summaries = try read()
            guard !updates.isEmpty else { return summaries }
            var changed = false
            for index in summaries.indices {
                guard let update = updates[summaries[index].id] else { continue }
                let hadMissingSourceKind = summaries[index].sourceKind == nil
                if summaries[index].sourceKind == nil, let sourceKind = update.sourceKind {
                    summaries[index].sourceKind = sourceKind
                    changed = true
                }
                if (summaries[index].hasRetainedAudio == nil || hadMissingSourceKind),
                   let hasRetainedAudio = update.hasRetainedAudio {
                    summaries[index].hasRetainedAudio = hasRetainedAudio
                    changed = true
                }
            }
            if changed { try write(summaries) }
            return summaries
        }
    }

    public func remove(id: UUID) throws {
        try Self.withMutationLock {
            let summaries = try read().filter { $0.id != id }
            try write(summaries)
        }
    }

    private func read() throws -> [SessionSummary] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try AtomicFileWriter.makeDecoder().decode([SessionSummary].self, from: Data(contentsOf: fileURL))
        } catch {
            throw SessionIndexStoreError.invalidIndex
        }
    }

    private func write(_ summaries: [SessionSummary]) throws {
        try AtomicFileWriter.encode(summaries, to: fileURL)
    }

    private static func withMutationLock<T>(_ operation: () throws -> T) rethrows -> T {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return try operation()
    }

    private static func sorted(_ summaries: [SessionSummary]) -> [SessionSummary] {
        summaries.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

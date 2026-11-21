import Foundation

public enum SessionIndexStoreError: Error, Equatable, Sendable {
    case invalidIndex
}

// Session mutations and their index updates share one executor across
// instances. Disk operations run on a serial queue without blocking other
// tasks on a lock or suspending midway through a session mutation.
@globalActor actor SessionStoreIO {
    static let shared = SessionStoreIO()
    private nonisolated let queue = DispatchSerialQueue(label: "com.openai.clippy.session-store")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
}

public actor SessionIndexStore {
    public let fileURL: URL

    public init(rootURL: URL) {
        self.fileURL = rootURL.appendingPathComponent(AppConstants.sessionIndexFileName)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() async throws -> [SessionSummary] { try await read() }

    public func replace(with summaries: [SessionSummary]) async throws {
        try await replaceOnDisk(with: summaries)
    }

    public func upsert(_ summary: SessionSummary) async throws { try await upsertOnDisk(summary) }

    /// Fills metadata missing from an older index without replacing entries
    /// that another store instance may have written since the scan began.
    public func backfillMetadata(_ updates: [UUID: SessionSummary]) async throws -> [SessionSummary] {
        try await backfillMetadataOnDisk(updates)
    }

    public func remove(id: UUID) async throws { try await removeFromDisk(id: id) }

    @SessionStoreIO func replaceOnDisk(with summaries: [SessionSummary]) throws {
        try write(Self.sorted(summaries))
    }

    @SessionStoreIO func upsertOnDisk(_ summary: SessionSummary) throws {
        var summaries = try read()
        summaries.removeAll { $0.id == summary.id }
        summaries.append(summary)
        try write(Self.sorted(summaries))
    }

    @SessionStoreIO func backfillMetadataOnDisk(_ updates: [UUID: SessionSummary]) throws -> [SessionSummary] {
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

    @SessionStoreIO func removeFromDisk(id: UUID) throws {
        try write(read().filter { $0.id != id })
    }

    @SessionStoreIO func read() throws -> [SessionSummary] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        do {
            return try AtomicFileWriter.makeDecoder().decode([SessionSummary].self, from: data)
        } catch {
            throw SessionIndexStoreError.invalidIndex
        }
    }

    @SessionStoreIO private func write(_ summaries: [SessionSummary]) throws {
        try AtomicFileWriter.encode(summaries, to: fileURL)
    }

    private static func sorted(_ summaries: [SessionSummary]) -> [SessionSummary] {
        summaries.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

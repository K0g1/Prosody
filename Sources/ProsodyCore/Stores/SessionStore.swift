import Foundation

public enum SessionStoreError: Error, Equatable, Sendable {
    case sessionNotFound
    case invalidManifest
    case invalidTranscript
}

/// Resolves retained audio using file metadata only. Callers that work outside
/// the app container must hold their security-scoped folder access while this
/// runs; decoding is left to the playback layer.
public enum SessionAssetResolver {
    public static let audioFileExtensions: Set<String> = [
        "m4a", "caf", "wav", "mp3", "aiff", "aif", "flac", "mp4"
    ]

    public static func audioURLs(in sessionDirectory: URL) -> [URL] {
        let fileManager = FileManager.default
        let audioDirectory = sessionDirectory.appendingPathComponent("audio", isDirectory: true)
        for source in AudioSource.allCases {
            let sourceDirectory = audioDirectory.appendingPathComponent(source.rawValue, isDirectory: true)
            guard let urls = try? fileManager.contentsOfDirectory(
                at: sourceDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            let chunks = urls.filter(isPlayableFile).sorted { $0.path < $1.path }
            if !chunks.isEmpty { return chunks }
        }

        return [sessionDirectory.appendingPathComponent("system.caf"),
                sessionDirectory.appendingPathComponent("microphone.caf")]
            .filter(isPlayableFile)
    }

    public static func allAudioTracks(in sessionDirectory: URL) -> [AudioSource: [URL]] {
        var tracks: [AudioSource: [URL]] = [:]
        let audioDirectory = sessionDirectory.appendingPathComponent("audio", isDirectory: true)
        for source in AudioSource.allCases {
            let directory = audioDirectory.appendingPathComponent(source.rawValue, isDirectory: true)
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            let chunks = urls.filter(isPlayableFile).sorted { $0.path < $1.path }
            let legacy = sessionDirectory.appendingPathComponent(source.rawValue + ".caf")
            if !chunks.isEmpty { tracks[source] = chunks }
            else if isPlayableFile(legacy) { tracks[source] = [legacy] }
        }
        return tracks
    }

    public static func hasRetainedAudio(in sessionDirectory: URL) -> Bool {
        let fileManager = FileManager.default
        let audioDirectory = sessionDirectory.appendingPathComponent("audio", isDirectory: true)
        for source in AudioSource.allCases {
            let sourceDirectory = audioDirectory.appendingPathComponent(source.rawValue, isDirectory: true)
            guard let urls = try? fileManager.contentsOfDirectory(
                at: sourceDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            if urls.contains(where: isPlayableFile) { return true }
        }
        return [sessionDirectory.appendingPathComponent("system.caf"),
                sessionDirectory.appendingPathComponent("microphone.caf")]
            .contains(where: isPlayableFile)
    }

    private static func isPlayableFile(_ url: URL) -> Bool {
        guard audioFileExtensions.contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              (values.fileSize ?? 0) > 0
        else { return false }
        return true
    }
}

/// Durable final-session store. Each artifact is replaced atomically and the
/// index is updated only after the transcript and manifest are on disk.
public actor SessionStore {
    public let rootURL: URL

    private let indexStore: SessionIndexStore

    public init(rootURL: URL) {
        self.rootURL = rootURL
        self.indexStore = SessionIndexStore(rootURL: rootURL)
    }

    @discardableResult
    public func save(_ document: SessionDocument) async throws -> URL {
        try await saveToDisk(document)
    }

    @SessionStoreIO private func saveToDisk(_ document: SessionDocument) throws -> URL {
        let directory = sessionDirectoryURL(for: document.session.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let transcriptMarkdown = (document.session.labels == nil ? document.transcriptMarkdown : nil)
            ?? MarkdownRenderer.render(
                document.transcript,
                title: document.session.title,
                date: document.session.createdAt,
                duration: document.session.duration,
                labels: document.session.labels ?? []
            )

        // Persist the source-of-truth transcript before its human-readable
        // render and write the manifest last as the commit marker.
        try AtomicFileWriter.encode(document.transcript, to: directory.appendingPathComponent("transcript.json"))
        try AtomicFileWriter.write(Data(transcriptMarkdown.utf8), to: directory.appendingPathComponent(RecordingNaming.safeTranscriptFileName(document.session.transcriptFileName)))
        if let notesMarkdown = document.notesMarkdown {
            try AtomicFileWriter.write(Data(notesMarkdown.utf8), to: directory.appendingPathComponent("notes.md"))
        } else {
            let notesURL = directory.appendingPathComponent("notes.md")
            if FileManager.default.fileExists(atPath: notesURL.path) {
                try FileManager.default.removeItem(at: notesURL)
            }
        }
        var savedSession = document.session
        savedSession.outputFolderPath = directory.path
        let manifest = SessionManifest(session: savedSession)
        try AtomicFileWriter.encode(manifest, to: directory.appendingPathComponent("session.json"))
        let summary = makeSummary(manifest: manifest, directory: directory)
        try updateIndex(summary)
        return directory
    }

    @discardableResult
    public func save(
        session: RecordingSession,
        transcript: Transcript,
        transcriptMarkdown: String? = nil,
        notesMarkdown: String? = nil
    ) async throws -> URL {
        try await save(SessionDocument(
            session: session,
            transcript: transcript,
            transcriptMarkdown: transcriptMarkdown,
            notesMarkdown: notesMarkdown
        ))
    }

    public func load(id: UUID) async throws -> SessionDocument {
        try await loadFromDisk(id: id)
    }

    @SessionStoreIO private func loadFromDisk(id: UUID) throws -> SessionDocument {
        let directory = sessionDirectoryURL(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw SessionStoreError.sessionNotFound
        }
        let manifest: SessionManifest
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("session.json"))
            manifest = try AtomicFileWriter.makeDecoder().decode(
                SessionManifest.self,
                from: data
            )
        } catch {
            throw SessionStoreError.invalidManifest
        }

        let transcript: Transcript
        do {
            transcript = try AtomicFileWriter.makeDecoder().decode(
                Transcript.self,
                from: Data(contentsOf: directory.appendingPathComponent("transcript.json"))
            )
        } catch {
            throw SessionStoreError.invalidTranscript
        }

        let transcriptMarkdown = try? String(
            contentsOf: directory.appendingPathComponent(RecordingNaming.safeTranscriptFileName(manifest.transcriptFileName)),
            encoding: .utf8
        )
        let notesMarkdown = try? String(
            contentsOf: directory.appendingPathComponent("notes.md"),
            encoding: .utf8
        )
        var session = manifest.recordingSession
        session.sourceKind = resolvedSourceKind(for: manifest, directory: directory)
        return SessionDocument(
            session: session,
            transcript: transcript,
            transcriptMarkdown: transcriptMarkdown,
            notesMarkdown: notesMarkdown
        )
    }

    public func list() async throws -> [SessionSummary] {
        try await listFromDisk()
    }

    @SessionStoreIO private func listFromDisk() throws -> [SessionSummary] {
        guard FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(AppConstants.sessionIndexFileName).path) else {
            return try rebuildIndex()
        }
        do {
            let indexed = try indexStore.read()
            var metadata: [UUID: SessionSummary] = [:]
            for summary in indexed where summary.sourceKind == nil || summary.hasRetainedAudio == nil {
                let directory = sessionDirectoryURL(for: summary.id)
                if let resolved = try? readSummary(directory: directory) {
                    metadata[summary.id] = resolved
                }
            }
            let summaries = metadata.isEmpty
                ? indexed
                : try indexStore.backfillMetadataOnDisk(metadata)
            return summaries.map { summary in
                var summary = summary
                summary.folderPath = sessionDirectoryURL(for: summary.id).path
                return summary
            }
        }
        catch SessionIndexStoreError.invalidIndex { return try rebuildIndex() }
    }

    /// Re-reads the small manifest and retained-audio presence after an archive
    /// move or import copy, then updates only that session's index entry.
    public func refreshSummary(id: UUID) async throws -> SessionSummary? {
        try await refreshSummaryOnDisk(id: id)
    }

    @SessionStoreIO private func refreshSummaryOnDisk(id: UUID) throws -> SessionSummary? {
        let directory = sessionDirectoryURL(for: id)
        guard let summary = try readSummary(directory: directory) else { return nil }
        try updateIndex(summary)
        return summary
    }

    @SessionStoreIO private func updateIndex(_ summary: SessionSummary) throws {
        do { try indexStore.upsertOnDisk(summary) }
        catch SessionIndexStoreError.invalidIndex { _ = try rebuildIndex() }
    }

    @SessionStoreIO private func rebuildIndex() throws -> [SessionSummary] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let summaries = directories.compactMap { directory -> SessionSummary? in
            guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
            return try? readSummary(directory: directory)
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        try indexStore.replaceOnDisk(with: summaries)
        return summaries
    }

    public func folderURL(for id: UUID) -> URL {
        sessionDirectoryURL(for: id)
    }

    public func delete(id: UUID) async throws {
        try await deleteFromDisk(id: id)
    }

    @SessionStoreIO private func deleteFromDisk(id: UUID) throws {
        let directory = sessionDirectoryURL(for: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        do { try indexStore.removeFromDisk(id: id) }
        catch SessionIndexStoreError.invalidIndex { _ = try rebuildIndex() }
    }

    @SessionStoreIO private func readSummary(directory: URL) throws -> SessionSummary? {
        let manifestURL = directory.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        let manifest = try AtomicFileWriter.makeDecoder().decode(
            SessionManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        return makeSummary(manifest: manifest, directory: directory)
    }

    @SessionStoreIO private func makeSummary(manifest: SessionManifest, directory: URL) -> SessionSummary {
        let id = UUID(uuidString: directory.lastPathComponent) ?? manifest.id
        return SessionSummary(
            id: id,
            title: manifest.title,
            createdAt: manifest.createdAt,
            duration: manifest.duration,
            folderPath: directory.path,
            labels: manifest.labels,
            sourceKind: resolvedSourceKind(for: manifest, directory: directory),
            hasRetainedAudio: SessionAssetResolver.hasRetainedAudio(in: directory)
        )
    }

    @SessionStoreIO private func resolvedSourceKind(for manifest: SessionManifest, directory: URL) -> String {
        if let sourceKind = manifest.sourceKind, !sourceKind.isEmpty {
            return sourceKind
        }
        guard manifest.captureMode == .microphone,
              manifest.speakers.mode == .off,
              manifest.status == "completed",
              manifest.transcriptFileName == nil,
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes.md").path),
              Self.isLegacyDictationTitle(manifest.title, createdAt: manifest.createdAt)
        else { return SessionSummary.legacySourceKind }
        return "dictation"
    }

    private static func isLegacyDictationTitle(_ title: String, createdAt: Date) -> Bool {
        let prefix = "Dictation "
        guard title.hasPrefix(prefix) else { return false }
        let titleDate = String(title.dropFirst(prefix.count))
        // The historical title used Date.now before RecordingSession captured
        // createdAt. A crossing minute boundary can therefore put the title one
        // minute behind the manifest timestamp.
        return [createdAt, createdAt.addingTimeInterval(-60)].contains { date in
            date.formatted(date: .abbreviated, time: .shortened) == titleDate
        }
    }

    nonisolated private func sessionDirectoryURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }
}

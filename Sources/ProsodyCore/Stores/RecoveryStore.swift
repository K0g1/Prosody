import Foundation

public enum RecoveryState: String, Codable, Equatable, Sendable {
    case recording
    case paused
    case stopping
    case recoverable
    case completed
}

public struct RecoveryManifest: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public var session: RecordingSession
    public var state: RecoveryState
    public var updatedAt: Date
    public var duration: TimeInterval
    public var transcriptSegmentCount: Int

    public init(
        schemaVersion: Int = 1,
        session: RecordingSession,
        state: RecoveryState = .recording,
        updatedAt: Date = .now,
        duration: TimeInterval = 0,
        transcriptSegmentCount: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.id = session.id
        self.session = session
        self.state = state
        self.updatedAt = updatedAt
        self.duration = max(0, duration)
        self.transcriptSegmentCount = max(0, transcriptSegmentCount)
    }
}

public struct RecoveryDocument: Equatable, Sendable {
    public let manifest: RecoveryManifest
    public let transcript: Transcript
    public let ignoredTranscriptLineCount: Int

    public init(
        manifest: RecoveryManifest,
        transcript: Transcript,
        ignoredTranscriptLineCount: Int = 0
    ) {
        self.manifest = manifest
        self.transcript = transcript
        self.ignoredTranscriptLineCount = ignoredTranscriptLineCount
    }
}

public enum RecoveryStoreError: Error, Equatable, Sendable {
    case notFound
    case invalidManifest
}

/// Atomic manifests, synchronized append-only finalized segments, and one
/// replaceable provisional checkpoint per source. A torn JSONL tail is skipped.
public actor RecoveryStore {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public func begin(session: RecordingSession) throws -> RecoveryManifest {
        let manifest = RecoveryManifest(session: session)
        let directory = directoryURL(for: session.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AtomicFileWriter.encode(manifest, to: directory.appendingPathComponent(AppConstants.recoveryManifestFileName))
        try AtomicFileWriter.write(Data(), to: directory.appendingPathComponent(AppConstants.recoveryTranscriptFileName))
        return manifest
    }

    public func update(_ manifest: RecoveryManifest) throws {
        let directory = directoryURL(for: manifest.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AtomicFileWriter.encode(manifest, to: directory.appendingPathComponent(AppConstants.recoveryManifestFileName))
    }

    public func updateState(id: UUID, state: RecoveryState, duration: TimeInterval) throws {
        var manifest = try decodeManifest(at: directoryURL(for: id).appendingPathComponent(AppConstants.recoveryManifestFileName))
        guard manifest.state != .completed else { return }
        manifest.state = state
        manifest.duration = max(manifest.duration, duration)
        manifest.session.duration = manifest.duration
        manifest.updatedAt = .now
        try update(manifest)
    }

    public func checkpoint(segment: TranscriptSegment, to id: UUID) throws {
        let directory = directoryURL(for: id)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(AppConstants.recoveryManifestFileName).path) else {
            throw RecoveryStoreError.notFound
        }
        try AtomicFileWriter.encode(segment, to: directory.appendingPathComponent("tail-\(segment.source.rawValue).json"))
        try updateState(id: id, state: .recording, duration: segment.end)
    }

    public func append(segment: TranscriptSegment, to id: UUID) throws -> RecoveryManifest {
        let directory = directoryURL(for: id)
        let manifestURL = directory.appendingPathComponent(AppConstants.recoveryManifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw RecoveryStoreError.notFound
        }

        var manifest = try decodeManifest(at: manifestURL)
        // JSONL records must stay on one physical line. The normal atomic
        // encoder is pretty-printed for human-readable manifests, so use a
        // compact encoder for streaming recovery entries.
        let lineEncoder = JSONEncoder()
        lineEncoder.dateEncodingStrategy = .iso8601
        lineEncoder.outputFormatting = [.sortedKeys]
        var line = try lineEncoder.encode(segment)
        line.append(0x0A)
        let transcriptURL = directory.appendingPathComponent(AppConstants.recoveryTranscriptFileName)
        if !FileManager.default.fileExists(atPath: transcriptURL.path) {
            try AtomicFileWriter.write(Data(), to: transcriptURL)
        }
        let handle = try FileHandle(forWritingTo: transcriptURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
        manifest.transcriptSegmentCount += 1
        manifest.duration = max(manifest.duration, segment.end)
        manifest.session.duration = max(manifest.session.duration, segment.end)
        manifest.updatedAt = .now
        try AtomicFileWriter.encode(manifest, to: manifestURL)
        return manifest
    }

    public func load(id: UUID) throws -> RecoveryDocument {
        let directory = directoryURL(for: id)
        let manifestURL = directory.appendingPathComponent(AppConstants.recoveryManifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw RecoveryStoreError.notFound
        }

        let manifest = try decodeManifest(at: manifestURL)
        let transcriptURL = directory.appendingPathComponent(AppConstants.recoveryTranscriptFileName)
        let data = (try? Data(contentsOf: transcriptURL)) ?? Data()

        let decoder = AtomicFileWriter.makeDecoder()
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: { $0.isNewline })
        var segments: [TranscriptSegment] = []
        var ignoredLines = 0
        for line in lines {
            guard let segment = try? decoder.decode(TranscriptSegment.self, from: Data(line.utf8)) else {
                ignoredLines += 1
                continue
            }
            segments.append(segment)
        }
        let finalizedIDs = Set(segments.map(\.id))
        for source in AudioSource.allCases {
            let tailURL = directory.appendingPathComponent("tail-\(source.rawValue).json")
            if let data = try? Data(contentsOf: tailURL),
               var tail = try? decoder.decode(TranscriptSegment.self, from: data),
               !finalizedIDs.contains(tail.id) {
                tail.isFinal = true
                segments.append(tail)
            }
        }
        segments.sort { $0.start < $1.start }
        return RecoveryDocument(
            manifest: manifest,
            transcript: Transcript(segments: segments),
            ignoredTranscriptLineCount: ignoredLines
        )
    }

    public func list() throws -> [RecoveryManifest] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let manifestURL = url.appendingPathComponent(AppConstants.recoveryManifestFileName)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
            return try? decodeManifest(at: manifestURL)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func recoverableSessions() throws -> [RecoveryManifest] {
        try list().filter { $0.state != .completed }
    }

    public func markCompleted(id: UUID) throws {
        let document = try load(id: id)
        var manifest = document.manifest
        guard manifest.state != .completed else { return }
        manifest.state = .completed
        manifest.updatedAt = .now
        try update(manifest)
    }

    public func directoryURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func remove(id: UUID) throws {
        let directory = directoryURL(for: id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func decodeManifest(at url: URL) throws -> RecoveryManifest {
        do {
            return try AtomicFileWriter.makeDecoder().decode(RecoveryManifest.self, from: Data(contentsOf: url))
        } catch {
            throw RecoveryStoreError.invalidManifest
        }
    }
}

#if canImport(XCTest)
import Foundation
import XCTest
@testable import ProsodyCore

final class RecoveryArchiveTests: XCTestCase {
    func testEmptyRecoveryAudioPreservesExistingRetainedAudio() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveryAudio = root.appendingPathComponent("Recovery/audio", isDirectory: true)
        let finalSession = root.appendingPathComponent("Final", isDirectory: true)
        let finalAudio = finalSession.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(
            at: recoveryAudio.appendingPathComponent("system", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write(Data("retained".utf8), to: finalAudio.appendingPathComponent("system/000001.m4a"))

        let recoveryFiles = try AudioArchiveMerger.recoveryAudioFiles(in: recoveryAudio)
        XCTAssertTrue(recoveryFiles.isEmpty)
        _ = try AudioArchiveMerger.merge(recoveryFiles, from: recoveryAudio, into: finalAudio)

        XCTAssertEqual(
            try Data(contentsOf: finalAudio.appendingPathComponent("system/000001.m4a")),
            Data("retained".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryAudio.path))
    }

    func testMergeAddsMissingChunksAndIgnoresEmptyFiles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveryAudio = root.appendingPathComponent("Recovery/audio", isDirectory: true)
        let finalAudio = root.appendingPathComponent("Final/audio", isDirectory: true)
        let finalChunk = finalAudio.appendingPathComponent("system/000001.m4a")
        try write(Data("same".utf8), to: finalChunk)
        try write(Data("same".utf8), to: recoveryAudio.appendingPathComponent("system/000001.m4a"))
        try write(Data("new".utf8), to: recoveryAudio.appendingPathComponent("system/000002.m4a"))
        try write(Data(), to: recoveryAudio.appendingPathComponent("system/000003.m4a"))
        try write(Data("not audio".utf8), to: recoveryAudio.appendingPathComponent("system/000004.txt"))

        let recoveryFiles = try AudioArchiveMerger.recoveryAudioFiles(in: recoveryAudio)
        XCTAssertEqual(recoveryFiles.map(\.lastPathComponent), ["000001.m4a", "000002.m4a"])
        let moved = try AudioArchiveMerger.merge(recoveryFiles, from: recoveryAudio, into: finalAudio)

        XCTAssertEqual(moved.map(\.lastPathComponent), ["000002.m4a"])
        XCTAssertEqual(try Data(contentsOf: finalChunk), Data("same".utf8))
        XCTAssertEqual(
            try Data(contentsOf: finalAudio.appendingPathComponent("system/000002.m4a")),
            Data("new".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalAudio.appendingPathComponent("system/000003.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalAudio.appendingPathComponent("system/000004.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryAudio.appendingPathComponent("system/000001.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryAudio.appendingPathComponent("system/000003.m4a").path))
    }

    func testConflictingChunkKeepsBothFinalAndRecoveryFiles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveryAudio = root.appendingPathComponent("Recovery/audio", isDirectory: true)
        let finalAudio = root.appendingPathComponent("Final/audio", isDirectory: true)
        let finalChunk = finalAudio.appendingPathComponent("system/000001.m4a")
        let recoveryChunk = recoveryAudio.appendingPathComponent("system/000001.m4a")
        try write(Data("final".utf8), to: finalChunk)
        try write(Data("other".utf8), to: recoveryChunk)

        let recoveryFiles = try AudioArchiveMerger.recoveryAudioFiles(in: recoveryAudio)
        XCTAssertThrowsError(try AudioArchiveMerger.merge(recoveryFiles, from: recoveryAudio, into: finalAudio)) { error in
            guard let mergerError = error as? AudioArchiveMergerError,
                  case .conflictingArtifact = mergerError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: finalChunk), Data("final".utf8))
        XCTAssertEqual(try Data(contentsOf: recoveryChunk), Data("other".utf8))
    }

    func testRecoveryAudioScopeIncludesOnlyLegacyCAFAndKnownSourceDirectories() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveryAudio = root.appendingPathComponent("Recovery/audio", isDirectory: true)
        let finalSession = root.appendingPathComponent("Final", isDirectory: true)
        let finalAudio = finalSession.appendingPathComponent("audio", isDirectory: true)
        try write(Data("legacy".utf8), to: recoveryAudio.appendingPathComponent("system.caf"))
        try write(Data("system".utf8), to: recoveryAudio.appendingPathComponent("system/000001.m4a"))
        try write(Data("microphone".utf8), to: recoveryAudio.appendingPathComponent("microphone/000001.m4a"))
        try write(Data("ignored".utf8), to: recoveryAudio.appendingPathComponent("root.m4a"))
        try write(Data("ignored".utf8), to: recoveryAudio.appendingPathComponent("unknown/000001.m4a"))

        let recoveryFiles = try AudioArchiveMerger.recoveryAudioFiles(in: recoveryAudio)
        let relativePaths = Set(recoveryFiles.map {
            let parent = $0.deletingLastPathComponent().lastPathComponent
            return parent == "audio" ? $0.lastPathComponent : "\(parent)/\($0.lastPathComponent)"
        })
        XCTAssertEqual(relativePaths, Set(["system.caf", "system/000001.m4a", "microphone/000001.m4a"]))
        _ = try AudioArchiveMerger.merge(recoveryFiles, from: recoveryAudio, into: finalAudio)

        XCTAssertTrue(FileManager.default.fileExists(atPath: finalSession.appendingPathComponent("system.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalAudio.appendingPathComponent("system/000001.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalAudio.appendingPathComponent("microphone/000001.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalAudio.appendingPathComponent("root.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalAudio.appendingPathComponent("unknown/000001.m4a").path))
    }

    @MainActor
    func testFailedDictationArchiveSurvivesReopenAndTemporaryCleanup() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = AudioArchiveWriter(directoryURL: root.appendingPathComponent("Temporary/audio"))
        let recoveryRoot = root.appendingPathComponent("Support/Recovery")
        let recovery = RecoveryStore(rootURL: recoveryRoot)
        var session = makeSession(id: UUID(), keepAudio: false)
        session.sourceKind = "dictation"
        session.liveTranscriptionEnabled = false
        session.duration = 0.5

        let emptyAdopted = try await recovery.adoptFailedDictation(session, archive: archive)
        XCTAssertFalse(emptyAdopted)
        for (index, rate) in [16_000.0, 48_000.0].enumerated() {
            try await archive.append(CapturedAudioPacket(
                source: .microphone,
                presentationTime: Double(index) / 4,
                sampleRate: rate,
                samples: Array(repeating: 0.1, count: Int(rate / 4))
            ))
        }
        let chunks = try await archive.finish()
        XCTAssertEqual(chunks.count, 2)
        let recordedBytes = try chunks.map { try Data(contentsOf: $0) }
        let adopted = try await recovery.adoptFailedDictation(session, archive: archive)
        XCTAssertTrue(adopted)
        try await archive.discard()

        let reopened = RecoveryStore(rootURL: recoveryRoot)
        let recoverable = try await reopened.recoverableSessions()
        XCTAssertEqual(recoverable.map(\.id), [session.id])
        let recovered = try await reopened.load(id: session.id)
        XCTAssertEqual(recovered.manifest.state, .recoverable)
        XCTAssertEqual(recovered.manifest.session.sourceKind, "dictation")
        XCTAssertFalse(recovered.manifest.session.keepAudio)
        XCTAssertEqual(recovered.manifest.duration, 0.5)
        let directory = await reopened.directoryURL(for: session.id)
        let audio = try AudioArchiveMerger.recoveryAudioFiles(in: directory.appendingPathComponent("audio"))
        XCTAssertEqual(try audio.map { try Data(contentsOf: $0) }, recordedBytes)
    }

    @MainActor
    func testNoSpeechCompletionStillMarksRecoveryCompleted() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Prosody-Recovery-Completion-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ProsodyPreferences(defaults: defaults)
        preferences.outputFolderPath = root.appendingPathComponent("Sessions").path
        preferences.generateNotesAutomatically = false
        preferences.notifyWhenFinished = false
        let model = AppModel(
            preferences: preferences,
            demoMode: false,
            supportRootURL: root.appendingPathComponent("Support"),
            registerHotkey: false,
            loadStoredState: false
        )
        let session = makeSession(id: UUID(), keepAudio: false)
        let recovery = RecoveryStore(rootURL: root.appendingPathComponent("Support/Recovery"))
        _ = try await recovery.begin(session: session)
        model.activeRecoveryID = session.id

        await model.complete(
            result: RecordingResult(session: session, transcript: Transcript()),
            fallbackSession: session
        )

        let recovered = try await recovery.load(id: session.id)
        XCTAssertEqual(recovered.manifest.state, .completed)
        XCTAssertNil(model.activeRecoveryID)
        XCTAssertEqual(model.recordingState, .completed(session.id))
    }

    @MainActor
    func testRecoverWithoutAudioKeepsExistingFinalTranscript() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Prosody-Recovery-Existing-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ProsodyPreferences(defaults: defaults)
        preferences.outputFolderPath = root.appendingPathComponent("Sessions").path
        preferences.generateNotesAutomatically = false
        preferences.notifyWhenFinished = false
        preferences.wordReplacements = [WordReplacement(original: "durable", replacement: "changed")]
        let model = AppModel(
            preferences: preferences,
            demoMode: false,
            supportRootURL: root.appendingPathComponent("Support"),
            registerHotkey: false,
            loadStoredState: false
        )
        var session = makeSession(id: UUID(), keepAudio: true)
        session.status = "completed"
        let durable = Transcript(segments: [
            TranscriptSegment(source: .system, start: 0, end: 1, text: "durable transcript", isFinal: true)
        ])
        let sessions = SessionStore(rootURL: root.appendingPathComponent("Sessions"))
        _ = try await sessions.save(
            session: session,
            transcript: durable,
            notesMarkdown: "# Existing notes"
        )
        let recovery = RecoveryStore(rootURL: root.appendingPathComponent("Support/Recovery"))
        let manifest = try await recovery.begin(session: session)
        let recoveryDirectory = await recovery.directoryURL(for: session.id)
        try FileManager.default.createDirectory(
            at: recoveryDirectory.appendingPathComponent("audio/system", isDirectory: true),
            withIntermediateDirectories: true
        )

        model.recover(manifest)
        await model.transitionTask?.value

        let final = try await sessions.load(id: session.id)
        XCTAssertEqual(final.transcript.visibleSegments.map(\.text), ["durable transcript"])
        XCTAssertEqual(final.notesMarkdown, "# Existing notes")
        XCTAssertTrue(model.selectedSessionHasNotes)
        let recovered = try await recovery.load(id: session.id)
        XCTAssertEqual(recovered.manifest.state, .completed)
    }

    func testMarkCompletedIsIdempotent() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = RecoveryStore(rootURL: root)
        let session = makeSession(id: UUID(), keepAudio: false)
        _ = try await recovery.begin(session: session)

        try await recovery.markCompleted(id: session.id)
        let firstDocument = try await recovery.load(id: session.id)
        let first = firstDocument.manifest.updatedAt
        try await recovery.markCompleted(id: session.id)
        let secondDocument = try await recovery.load(id: session.id)
        let second = secondDocument.manifest.updatedAt

        XCTAssertEqual(first, second)
        XCTAssertEqual(secondDocument.manifest.state, .completed)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Prosody-Recovery-Tests-\(UUID())")
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func makeSession(id: UUID, keepAudio: Bool) -> RecordingSession {
        var session = RecordingSession(
            id: id,
            title: "Recovery fixture",
            duration: 1,
            captureMode: .microphone,
            sttEngineID: .parakeet,
            sttModelID: "parakeet-unified",
            speakerMode: .off,
            notesProviderID: "template-local",
            notesModelID: "fixture",
            noteTemplateID: .summary,
            keepAudio: keepAudio,
            status: "recording"
        )
        session.liveTranscriptionEnabled = false
        session.sourceKind = "recording"
        return session
    }
}
#endif

import Foundation
import XCTest
@testable import ProsodyCore

final class TranscriptLibraryTests: XCTestCase {
    func testLegacyIndexBackfillsKindAndAudioWithoutReadingTranscript() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let session = makeSession(
            title: generatedDictationTitle(for: createdAt),
            createdAt: createdAt,
            sourceKind: nil
        )
        let store = SessionStore(rootURL: root)
        let folder = try await store.save(session: session, transcript: Transcript())
        try FileManager.default.removeItem(at: folder.appendingPathComponent("transcript.json"))
        let manifestURL = folder.appendingPathComponent("session.json")
        let originalManifest = try Data(contentsOf: manifestURL)

        let legacyIndex = SessionSummary(
            id: session.id,
            title: session.title,
            createdAt: createdAt,
            duration: session.duration,
            folderPath: folder.path
        )
        try AtomicFileWriter.encode([legacyIndex], to: root.appendingPathComponent(AppConstants.sessionIndexFileName))
        let audioFolder = folder.appendingPathComponent("audio/system", isDirectory: true)
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        try Data([0x01, 0x02, 0x03]).write(to: audioFolder.appendingPathComponent("000001.m4a"))

        let summaries = try await store.list()
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(try Data(contentsOf: manifestURL), originalManifest)
        XCTAssertEqual(summary.sourceKind, "dictation")
        XCTAssertEqual(summary.hasRetainedAudio, true)
        XCTAssertTrue(TranscriptLibraryQuery.apply(to: summaries, search: "", labelID: nil, sort: .newest).isEmpty)
        XCTAssertEqual(
            TranscriptLibraryQuery.apply(
                to: summaries,
                search: "",
                labelID: nil,
                sort: .newest,
                includeDictation: true
            ).map(\.id),
            [session.id]
        )
    }

    func testLegacyDictationSignatureIsNarrowAndExplicitKindsWin() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let exactTitle = generatedDictationTitle(for: createdAt)
        let rolloverTitle = generatedDictationTitle(for: createdAt.addingTimeInterval(-60))
        let exact = makeSession(title: exactTitle, createdAt: createdAt, sourceKind: nil)
        let rollover = makeSession(title: rolloverTitle, createdAt: createdAt, sourceKind: nil)
        let custom = makeSession(title: "Dictation Meeting", createdAt: createdAt, sourceKind: nil)
        let explicitRecording = makeSession(title: exactTitle, createdAt: createdAt, sourceKind: "recording")
        let explicitFile = makeSession(title: exactTitle, createdAt: createdAt, sourceKind: "file")
        let customFilename = makeSession(
            title: exactTitle,
            createdAt: createdAt,
            sourceKind: nil,
            transcriptFileName: "custom.md"
        )
        let withNotes = makeSession(title: exactTitle, createdAt: createdAt, sourceKind: nil)

        let store = SessionStore(rootURL: root)
        for session in [exact, rollover, custom, explicitRecording, explicitFile, customFilename, withNotes] {
            _ = try await store.save(session: session, transcript: Transcript())
        }
        let notesFolder = await store.folderURL(for: withNotes.id)
        try Data("notes".utf8).write(to: notesFolder.appendingPathComponent("notes.md"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(AppConstants.sessionIndexFileName))

        let summaries = try await store.list()
        let kinds = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.sourceKind) })
        XCTAssertEqual(kinds[exact.id] ?? nil, "dictation")
        XCTAssertEqual(kinds[rollover.id] ?? nil, "dictation")
        XCTAssertEqual(kinds[custom.id] ?? nil, SessionSummary.legacySourceKind)
        XCTAssertEqual(kinds[explicitRecording.id] ?? nil, "recording")
        XCTAssertEqual(kinds[explicitFile.id] ?? nil, "file")
        XCTAssertEqual(kinds[customFilename.id] ?? nil, SessionSummary.legacySourceKind)
        XCTAssertEqual(kinds[withNotes.id] ?? nil, SessionSummary.legacySourceKind)

        let visibleIDs = Set(TranscriptLibraryQuery.apply(to: summaries, search: "", labelID: nil, sort: .newest).map(\.id))
        XCTAssertFalse(visibleIDs.contains(exact.id))
        XCTAssertFalse(visibleIDs.contains(rollover.id))
        XCTAssertTrue(visibleIDs.contains(custom.id))
        XCTAssertTrue(visibleIDs.contains(explicitRecording.id))
        XCTAssertTrue(visibleIDs.contains(explicitFile.id))
        XCTAssertTrue(visibleIDs.contains(customFilename.id))
        XCTAssertTrue(visibleIDs.contains(withNotes.id))

        let customFolder = await store.folderURL(for: custom.id)
        try FileManager.default.removeItem(at: customFolder.appendingPathComponent("session.json"))
        let cached = try await store.list()
        XCTAssertEqual(
            cached.first(where: { $0.id == custom.id })?.sourceKind,
            SessionSummary.legacySourceKind
        )
    }

    func testIndexMutationsAcrossInstancesPreserveUnrelatedWrites() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent(AppConstants.sessionIndexFileName)
        let legacyID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = SessionSummary(id: legacyID, title: "Legacy", createdAt: date, duration: 1)
        try AtomicFileWriter.encode([legacy], to: fileURL)

        let backfillStore = SessionIndexStore(fileURL: fileURL)
        let upsertStore = SessionIndexStore(fileURL: fileURL)
        let update = SessionSummary(
            id: legacyID,
            title: "Legacy",
            createdAt: date,
            duration: 1,
            sourceKind: SessionSummary.legacySourceKind,
            hasRetainedAudio: false
        )
        let inserted = SessionSummary(
            id: newID,
            title: "New",
            createdAt: date.addingTimeInterval(1),
            duration: 2,
            sourceKind: "recording",
            hasRetainedAudio: true
        )
        async let backfilled = backfillStore.backfillMetadata([legacyID: update])
        async let upserted: Void = upsertStore.upsert(inserted)
        _ = try await backfilled
        try await upserted

        let loaded = try await backfillStore.load()
        XCTAssertEqual(Set(loaded.map(\.id)), Set([legacyID, newID]))
        XCTAssertEqual(loaded.first(where: { $0.id == legacyID })?.sourceKind, SessionSummary.legacySourceKind)
        XCTAssertEqual(loaded.first(where: { $0.id == legacyID })?.hasRetainedAudio, false)
    }

    func testRetainedAudioReflectsFilesAfterArchivalPaths() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession(
            title: "Recording",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceKind: "recording",
            keepAudio: true
        )
        let store = SessionStore(rootURL: root)
        let folder = try await store.save(session: session, transcript: Transcript())
        var refreshed = try await store.refreshSummary(id: session.id)
        var summary = try XCTUnwrap(refreshed)
        XCTAssertEqual(summary.hasRetainedAudio, false)

        let systemFolder = folder.appendingPathComponent("audio/system", isDirectory: true)
        try FileManager.default.createDirectory(at: systemFolder, withIntermediateDirectories: true)
        try Data([0x01]).write(to: systemFolder.appendingPathComponent("000001.m4a"))
        refreshed = try await store.refreshSummary(id: session.id)
        summary = try XCTUnwrap(refreshed)
        XCTAssertEqual(summary.hasRetainedAudio, true)

        try FileManager.default.removeItem(at: folder.appendingPathComponent("audio"))
        try Data([0x02]).write(to: folder.appendingPathComponent("microphone.caf"))
        refreshed = try await store.refreshSummary(id: session.id)
        summary = try XCTUnwrap(refreshed)
        XCTAssertEqual(summary.hasRetainedAudio, true)

        try FileManager.default.removeItem(at: folder.appendingPathComponent("microphone.caf"))
        let emptyFolder = folder.appendingPathComponent("audio/microphone", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        try Data().write(to: emptyFolder.appendingPathComponent("000001.m4a"))
        refreshed = try await store.refreshSummary(id: session.id)
        summary = try XCTUnwrap(refreshed)
        XCTAssertEqual(summary.hasRetainedAudio, false)
    }

    func testQueryFiltersAudioAndUsesStableTieBreaks() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let dictation = SessionSummary(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            title: generatedDictationTitle(for: date),
            createdAt: date,
            duration: 10,
            sourceKind: "dictation",
            hasRetainedAudio: true
        )
        let retained = SessionSummary(
            id: firstID,
            title: "Same",
            createdAt: date,
            duration: 10,
            sourceKind: "recording",
            hasRetainedAudio: true
        )
        let withoutAudio = SessionSummary(
            id: secondID,
            title: "Same",
            createdAt: date,
            duration: 10,
            sourceKind: "file",
            hasRetainedAudio: false
        )
        let sessions = [withoutAudio, retained, dictation]

        XCTAssertEqual(
            TranscriptLibraryQuery.apply(to: sessions, search: "", labelID: nil, sort: .newest).map(\.id),
            [firstID, secondID]
        )
        XCTAssertEqual(
            TranscriptLibraryQuery.apply(
                to: sessions,
                search: "",
                labelID: nil,
                sort: .newest,
                includeDictation: true,
                audioFilter: .retained
            ).map(\.id),
            [firstID, dictation.id]
        )
        XCTAssertEqual(
            TranscriptLibraryQuery.apply(
                to: sessions,
                search: "",
                labelID: nil,
                sort: .newest,
                audioFilter: .notRetained
            ).map(\.id),
            [secondID]
        )
        XCTAssertEqual(
            TranscriptLibraryQuery.apply(to: sessions, search: "", labelID: nil, sort: .newest).map(\.id),
            TranscriptLibraryQuery.apply(to: sessions, search: "", labelID: nil, sort: .newest).map(\.id)
        )
    }

    func testManifestAndIndexDecodeOldJSONAndRoundTripSourceKind() async throws {
        let session = makeSession(
            title: "Explicit",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceKind: "dictation"
        )
        let manifest = SessionManifest(session: session)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.recordingSession.sourceKind, "dictation")

        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootURL: root)
        _ = try await store.save(session: session, transcript: Transcript())
        let loaded = try await store.load(id: session.id)
        XCTAssertEqual(loaded.session.sourceKind, "dictation")

        var manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: AtomicFileWriter.makeEncoder().encode(manifest)) as? [String: Any]
        )
        manifestObject.removeValue(forKey: "sourceKind")
        let legacyManifest = try AtomicFileWriter.makeDecoder().decode(
            SessionManifest.self,
            from: JSONSerialization.data(withJSONObject: manifestObject)
        )
        XCTAssertNil(legacyManifest.sourceKind)
        XCTAssertEqual(legacyManifest.schemaVersion, 1)

        let summary = SessionSummary(
            id: session.id,
            title: session.title,
            createdAt: session.createdAt,
            duration: session.duration
        )
        var indexObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: AtomicFileWriter.makeEncoder().encode([summary])) as? [[String: Any]]
        )
        indexObject[0].removeValue(forKey: "sourceKind")
        indexObject[0].removeValue(forKey: "hasRetainedAudio")
        let legacyIndex = try AtomicFileWriter.makeDecoder().decode(
            [SessionSummary].self,
            from: JSONSerialization.data(withJSONObject: indexObject)
        )
        XCTAssertNil(legacyIndex.first?.sourceKind)
        XCTAssertNil(legacyIndex.first?.hasRetainedAudio)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Prosody-Library-Tests-\(UUID())")
    }

    private func generatedDictationTitle(for date: Date) -> String {
        "Dictation \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func makeSession(
        title: String,
        createdAt: Date,
        sourceKind: String?,
        keepAudio: Bool = false,
        transcriptFileName: String? = nil
    ) -> RecordingSession {
        var session = RecordingSession(
            title: title,
            createdAt: createdAt,
            duration: 10,
            captureMode: .microphone,
            sttEngineID: .parakeet,
            sttModelID: "parakeet-unified",
            speakerMode: .off,
            notesProviderID: "template-local",
            notesModelID: "fixture",
            noteTemplateID: .summary,
            keepAudio: keepAudio,
            status: "completed",
            transcriptFileName: transcriptFileName
        )
        session.sourceKind = sourceKind
        return session
    }
}

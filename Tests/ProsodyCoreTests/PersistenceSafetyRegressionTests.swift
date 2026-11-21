#if canImport(Testing)
import Foundation
import Testing
@testable import ProsodyCore

@Suite("Persistence safety regressions")
struct PersistenceSafetyRegressionTests {
    @Test func journalRetainsUnicodeLineAndParagraphSeparators() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(rootURL: root)
        let session = makeSession()
        let segment = makeSegment("First\u{2028}second\u{2029}third", start: 0)
        _ = try await store.begin(session: session)
        _ = try await store.append(segment: segment, to: session.id)

        let journal = await journalURL(in: store, id: session.id)
        let bytes = try Data(contentsOf: journal)
        #expect(bytes.range(of: Data("\u{2028}".utf8)) != nil)
        #expect(bytes.range(of: Data("\u{2029}".utf8)) != nil)
        let recovered = try await store.load(id: session.id)
        #expect(recovered.transcript.segments == [segment])
        #expect(recovered.ignoredTranscriptLineCount == 0)
    }

    @Test func appendingAfterTornRecordRetainsBothValidRecords() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(rootURL: root)
        let session = makeSession()
        let first = makeSegment("Before the torn record", start: 0)
        let next = makeSegment("After reopening", start: 2)
        _ = try await store.begin(session: session)
        _ = try await store.append(segment: first, to: session.id)
        let journal = await journalURL(in: store, id: session.id)
        let file = try FileHandle(forWritingTo: journal)
        try file.seekToEnd()
        try file.write(contentsOf: Data(#"{"text":"unfinished"#.utf8))
        try file.close()

        let reopened = RecoveryStore(rootURL: root)
        _ = try await reopened.append(segment: next, to: session.id)
        let recovered = try await reopened.load(id: session.id)
        #expect(recovered.transcript.segments == [first, next])
        #expect(recovered.ignoredTranscriptLineCount == 1)
    }

    @Test func appendingPreservesACompleteRecordMissingItsTrailingLF() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(rootURL: root)
        let session = makeSession()
        let first = makeSegment("Complete record", start: 0)
        let next = makeSegment("Additional record", start: 2)
        _ = try await store.begin(session: session)
        _ = try await store.append(segment: first, to: session.id)
        let journal = await journalURL(in: store, id: session.id)
        let file = try FileHandle(forWritingTo: journal)
        let length = try file.seekToEnd()
        try file.truncate(atOffset: length - 1)
        try file.close()

        _ = try await store.append(segment: next, to: session.id)
        let recovered = try await store.load(id: session.id)
        #expect(recovered.transcript.segments == [first, next])
        #expect(recovered.ignoredTranscriptLineCount == 0)
    }

    @Test(arguments: [RecoveryState.paused, .stopping])
    func lateCheckpointPreservesManifestState(_ state: RecoveryState) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(rootURL: root)
        let session = makeSession()
        let segment = makeSegment("A delayed checkpoint", start: 2)
        _ = try await store.begin(session: session)
        try await store.updateState(id: session.id, state: state, duration: 2)
        try await store.checkpoint(segment: segment, to: session.id)

        let recovered = try await store.load(id: session.id)
        #expect(recovered.manifest.state == state)
        #expect(recovered.manifest.duration == segment.end)
        #expect(recovered.manifest.session.duration == segment.end)
        #expect(recovered.transcript.segments == [segment])
    }

    @Test func concurrentAtomicWritersPublishOneCompletePrivateFile() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("manifest.json")
        let candidates = (0..<24).map { Data(repeating: UInt8($0), count: 16_384) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for candidate in candidates {
                group.addTask { try AtomicFileWriter.write(candidate, to: destination) }
            }
            try await group.waitForAll()
        }
        let published = try Data(contentsOf: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect(candidates.contains(published))
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["manifest.json"])
    }

    @Test func atomicWriteReplacesADanglingLinkWithoutCreatingItsTarget() throws {
        let root = temporaryRoot()
        let manager = FileManager.default
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("manifest.json")
        let target = root.appendingPathComponent("missing.json")
        try manager.createSymbolicLink(at: destination, withDestinationURL: target)

        let contents = Data("actual data".utf8)
        try AtomicFileWriter.write(contents, to: destination)
        #expect(try Data(contentsOf: destination) == contents)
        #expect(try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(!manager.fileExists(atPath: target.path))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Prosody-Persistence-Test-\(UUID())")
    }

    private func journalURL(in store: RecoveryStore, id: UUID) async -> URL {
        await store.directoryURL(for: id).appendingPathComponent(AppConstants.recoveryTranscriptFileName)
    }

    private func makeSession() -> RecordingSession {
        RecordingSession(
            title: "Recovery fixture",
            captureMode: .microphone,
            sttEngineID: .parakeet,
            sttModelID: "parakeet-unified",
            speakerMode: .off,
            notesProviderID: "template-local",
            notesModelID: "fixture",
            noteTemplateID: .summary,
            keepAudio: true
        )
    }

    private func makeSegment(_ text: String, start: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(source: .microphone, start: start, end: start + 1, text: text, isFinal: true)
    }
}
#endif

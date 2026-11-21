#if canImport(XCTest)
import Foundation
import XCTest
@testable import ProsodyCore

final class AuditWorkflowTests: XCTestCase {
    @MainActor
    func testQuitDuringPreparationFinishesAndSavesRecording() async throws {
        try await withModel { model, root in
            model.preferences.liveTranscription = false
            model.preferences.generateNotesAutomatically = true
            model.startRecording()
            XCTAssertTrue(model.recordingState.isBusy)
            XCTAssertTrue(model.needsTimeToTerminate)

            await model.prepareForTermination()

            guard case .completed(let id) = model.recordingState else {
                return XCTFail("Quit returned without completing the recording.")
            }
            let saved = try await SessionStore(rootURL: root.appendingPathComponent("Sessions")).load(id: id)
            XCTAssertFalse(saved.transcript.visibleSegments.isEmpty)
            XCTAssertEqual(saved.session.status, "completed")
            XCTAssertNil(saved.notesMarkdown, "Quit should save the recording without starting automatic notes.")
            XCTAssertFalse(model.needsTimeToTerminate)
            XCTAssertFalse(model.canToggleRecording)
        }
    }

    @MainActor
    func testRecoveryAndRetryRespectInFlightOperations() async throws {
        try await withModel { model, _ in
            let manifest = RecoveryManifest(session: model.makeLibrarySession(title: "Recovery fixture", kind: "recording"))
            model.isImportingAudio = true
            model.recover(manifest)
            model.discardRecovery(manifest)
            XCTAssertNil(model.transitionTask)
            XCTAssertEqual(model.recordingState, .idle)
            model.isImportingAudio = false

            model.isTransitioning = true
            model.recover(manifest)
            XCTAssertNil(model.transitionTask)
            model.isTransitioning = false

            model.startRecording()
            let startingState = model.recordingState
            model.retryLastFailure()
            XCTAssertEqual(model.recordingState, startingState)
            await model.prepareForTermination()
        }
    }

    @MainActor
    func testSpeakerUndoWhileSaveIsPendingPersistsLatestEdit() async throws {
        try await withModel { model, root in
            var session = model.makeLibrarySession(title: "Speaker fixture", kind: "recording")
            session.status = "completed"
            let original = Transcript(segments: [
                TranscriptSegment(source: .microphone, start: 0, end: 1,
                                  text: "Hello", isFinal: true, speakerName: "Speaker 1")
            ])
            let store = SessionStore(rootURL: root.appendingPathComponent("Sessions"))
            session.outputFolderPath = try await store.save(session: session, transcript: original, notesMarkdown: "Existing notes").path
            model.activeSession = session
            model.selectedSessionID = session.id
            model.transcript = original
            model.transcriptUndoManager.groupsByEvent = false
            model.transcriptUndoManager.beginUndoGrouping()
            model.renameSpeaker(from: "Speaker 1", to: "Speaker 2")
            model.transcriptUndoManager.endUndoGrouping()
            XCTAssertTrue(model.isTransitioning)
            model.transcriptUndoManager.undo()

            await model.prepareForTermination()

            let saved = try await store.load(id: session.id)
            XCTAssertEqual(saved.transcript, original)
            XCTAssertEqual(saved.notesMarkdown, "Existing notes")
        }
    }

    func testDeleteRebuildsInvalidIndexFromRemainingSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Prosody-Index-Audit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootURL: root)
        let removed = makeSession(title: "Remove")
        let remaining = makeSession(title: "Keep")
        _ = try await store.save(session: removed, transcript: Transcript())
        _ = try await store.save(session: remaining, transcript: Transcript())
        try Data("Invalid index".utf8).write(to: root.appendingPathComponent(AppConstants.sessionIndexFileName))

        try await store.delete(id: removed.id)

        let listed = try await store.list()
        XCTAssertEqual(listed.map(\.id), [remaining.id])
    }

    func testConcurrentSaveAndDeleteKeepIndexConsistentAcrossStores() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Prosody-Index-Audit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = SessionStore(rootURL: root)
        let second = SessionStore(rootURL: root)
        let session = makeSession(title: "Concurrent fixture")

        async let saved = first.save(session: session, transcript: Transcript())
        async let deleted: Void = second.delete(id: session.id)
        let directory = try await saved
        try await deleted

        let listed = try await first.list()
        XCTAssertEqual(listed.contains { $0.id == session.id }, FileManager.default.fileExists(atPath: directory.path))
    }

    private func makeSession(title: String) -> RecordingSession {
        RecordingSession(title: title, captureMode: .microphone, sttEngineID: .parakeet,
                         sttModelID: SpeechModel.unified.rawValue, speakerMode: .off,
                         notesProviderID: "template-local", notesModelID: "", noteTemplateID: .transcriptOnly, keepAudio: false)
    }

    @MainActor
    private func withModel(_ check: (AppModel, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Prosody-Workflow-Audit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Prosody-Workflow-Audit-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ProsodyPreferences(defaults: defaults)
        preferences.outputFolderPath = root.appendingPathComponent("Sessions").path
        preferences.notifyWhenFinished = false
        preferences.generateNotesAutomatically = false
        preferences.speakerMode = .off
        let model = AppModel(preferences: preferences, demoMode: true, supportRootURL: root.appendingPathComponent("Support"),
                             registerHotkey: false, loadStoredState: false)
        try await check(model, root)
    }
}
#endif

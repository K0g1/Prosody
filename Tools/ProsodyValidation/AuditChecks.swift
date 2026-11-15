import ProsodyCore
import Foundation

extension ProsodyValidation {
    static func checkAuditRegressions() async throws {
        try checkStreamingTurns()
        try await checkContinuousResampling()
        try await checkRecoveryCheckpoints()
        try await checkIndexRepair()
        try await checkRecordingIsolation()
        try await checkProviderTransport()
        print("Audit regressions: PASS (streaming turns, resampling, recovery, index repair, lifecycle isolation)")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AuditFailure(message: message) }
    }

    private static func checkStreamingTurns() throws {
        var spacing = StreamingTranscriptAssembler(source: .system)
        _ = spacing.append(token: " These", start: 0, end: 0.1)
        _ = spacing.append(token: "▁", start: 0.1, end: 0.1)
        _ = spacing.append(token: "vectors", start: 0.2, end: 0.4)
        try require(spacing.provisional?.text == "These vectors", "A standalone word boundary disappeared between decoder batches")
        var assembler = StreamingTranscriptAssembler(source: .system)
        _ = assembler.append(token: " Neural", start: 1, end: 1.1)
        let id = assembler.provisional?.id
        _ = assembler.append(token: " net", start: 1.2, end: 1.3)
        _ = assembler.append(token: "works.", start: 1.3, end: 1.5)
        try require(assembler.provisional?.text == "Neural networks.", "Subwords split across decoder batches")
        let complete = assembler.append(token: " Next", start: 1.7, end: 1.9)
        try require(complete.count == 1 && complete[0].id == id, "Finalization must preserve provisional identity")
        try require(complete[0].words.count == 2 && complete[0].end == 1.5, "Word timing was not preserved")
        try require(assembler.provisional?.text == "Next", "A new sentence must start a fresh tail")
        for index in 0..<2_000 {
            _ = assembler.append(token: " word", start: 2 + Double(index) * 0.2, end: 2.1 + Double(index) * 0.2)
        }
        assembler.flush()
        try require(assembler.finalized.flatMap(\.words).count == 2_003, "Long streams lost words")
        try require(assembler.finalized.allSatisfy { $0.words.count <= 40 }, "Long streams must produce bounded turns")
        try require(ProsodyFormatters.duration(.nan) == "00:00" && ProsodyFormatters.timestamp(.infinity) == "00:00", "Invalid duration crashes formatting")
    }

    private static func checkContinuousResampling() async throws {
        for sampleRate in [48_000.0, 44_100.0] {
            let converter = StreamingAudioResampler()
            let count = Int(sampleRate / 100)
            var total = 0
            for packet in 0..<200 {
                let samples = (0..<count).map { Float(sin(Double(packet * count + $0) * 2 * .pi * 440 / sampleRate) * 0.2) }
                let output = try await converter.resample(samples, from: sampleRate)
                try require(output.allSatisfy(\.isFinite), "Resampling produced invalid PCM")
                total += output.count
            }
            try require(abs(total - 32_000) <= 1, "Streaming resampling drifts at \(sampleRate): \(total) frames")
        }
        do {
            _ = try await StreamingAudioResampler().resample([.nan], from: 48_000)
            throw AuditFailure(message: "Invalid PCM was accepted")
        } catch AudioSampleConverterError.invalidSamples { }
    }

    private static func makeSession() -> RecordingSession {
        RecordingSession(title: "Audit fixture", captureMode: .system, sttEngineID: .parakeet,
                         sttModelID: "parakeet-unified", speakerMode: .basic, notesProviderID: "template-local",
                         notesModelID: "offline", noteTemplateID: .summary, keepAudio: false, status: "completed")
    }

    private static func checkRecoveryCheckpoints() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Prosody-Audit-Recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(rootURL: root)
        let session = makeSession()
        _ = try await store.begin(session: session)
        var segment = TranscriptSegment(source: .system, start: 0, end: 2, text: "Recover this tail", isFinal: false)
        try await store.checkpoint(segment: segment, to: session.id)
        let partial = try await store.load(id: session.id)
        try require(partial.transcript.segments.count == 1, "Crash recovery lost a provisional-only transcript")
        segment.isFinal = true
        segment.text += "."
        _ = try await store.append(segment: segment, to: session.id)
        let recovered = try await store.load(id: session.id)
        try require(recovered.transcript.segments == [segment], "Recovery duplicated a checkpoint after finalization")
        try await store.updateState(id: session.id, state: .paused, duration: 1)
        let paused = try await store.load(id: session.id)
        try require(paused.manifest.duration == 2 && paused.manifest.transcriptSegmentCount == 1, "State update overwrote journal metadata")
        let directory = await store.directoryURL(for: session.id)
        let handle = try FileHandle(forWritingTo: directory.appendingPathComponent(AppConstants.recoveryTranscriptFileName))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{torn-json".utf8))
        try handle.close()
        let torn = try await store.load(id: session.id)
        try require(torn.ignoredTranscriptLineCount == 1 && torn.transcript.segments.count == 1, "Torn recovery tail invalidated durable text")
        try await store.markCompleted(id: session.id)
        try await store.updateState(id: session.id, state: .recording, duration: 3)
        let completed = try await store.recoverableSessions()
        try require(completed.isEmpty, "Late state update resurrected a completed recording")
    }

    private static func checkIndexRepair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Prosody-Audit-Index-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(rootURL: root)
        let session = makeSession()
        _ = try await store.save(SessionDocument(session: session, transcript: Transcript()))
        try Data("broken".utf8).write(to: root.appendingPathComponent(AppConstants.sessionIndexFileName))
        let repaired = try await store.list()
        try require(repaired.map(\.id) == [session.id], "A corrupt index hid a durable session")
        try FileManager.default.removeItem(at: root.appendingPathComponent(AppConstants.sessionIndexFileName))
        let rebuilt = try await store.list()
        try require(rebuilt.map(\.id) == [session.id], "A missing index hid a durable session")
    }

    @MainActor
    private static func checkRecordingIsolation() async throws {
        let name = "ProsodyAudit-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let preferences = ProsodyPreferences(defaults: defaults)
        preferences.captureMode = .system
        preferences.outputFolderPath = root.appendingPathComponent("Sessions").path
        preferences.notifyWhenFinished = false
        let model = AppModel(preferences: preferences, demoMode: true, supportRootURL: root,
                             registerHotkey: false, loadStoredState: false)
        let previous = model.recentSessions[0]
        model.startRecording()
        let preparingID = model.activeSession?.id
        model.selectSession(previous)
        try require(model.activeSession?.id == preparingID, "Browsing replaced the preparing session")
        try await Task.sleep(for: .milliseconds(700))
        try require(model.recordingState == .recording, "Demo capture did not start")
        let activeID = model.activeSession?.id
        try require(model.selectedSessionID == activeID, "Recording and selected session IDs diverged")
        model.startRecording()
        try require(model.activeSession?.id == activeID && model.recordingState == .recording,
                    "A duplicate start replaced the active recording")
        model.selectSession(previous)
        model.regenerateNotes()
        try require(model.activeSession?.id == activeID && model.recordingState == .recording, "Browsing or note generation interrupted capture")
        model.pauseRecording()
        model.finishRecording()
        try require(model.isTransitioning && !model.canFinishRecording, "Finish raced with pause")
        try await Task.sleep(for: .milliseconds(100))
        try require(model.recordingState == .paused, "Pause did not complete")
        model.startRecording()
        try require(model.activeSession?.id == activeID && model.recordingState == .paused,
                    "A duplicate start replaced the paused recording")
        model.resumeRecording()
        model.resumeRecording()
        try await Task.sleep(for: .milliseconds(400))
        try require(model.recordingState == .recording, "Resume did not complete")
        model.finishRecording()
        for _ in 0..<100 where model.recordingState.isBusy {
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(model.recordingState == .completed(activeID!), "Finish did not commit the captured session")
        try require(!model.transcript.segments.isEmpty, "Finishing lost the recorded transcript")
        let first = model.transcript.segments[0]
        model.renameSpeakers([first.visibleSpeakerName: "Lecturer"])
        for _ in 0..<100 where model.isTransitioning { try await Task.sleep(for: .milliseconds(10)) }
        let saved = try await SessionStore(rootURL: root.appendingPathComponent("Sessions")).load(id: activeID!)
        try require(saved.transcript.segments.first?.speakerName == "Lecturer", "Speaker rename was not durable")
        try require(saved.notesMarkdown != nil, "Speaker rename deleted notes")
        let player = SessionAudioPlayer(duration: 100)
        player.toggle()
        try require(!player.isPlaying && !player.hasAudio, "Playback pretended to play missing audio")
    }
}

private struct AuditFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

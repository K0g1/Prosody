#if canImport(XCTest)
import Foundation
import XCTest
@testable import ProsodyCore

final class CoreServicesTests: XCTestCase {
    @MainActor
    func testBeta2PreferencesAndLabelsRemainCompatible() throws {
        let suite = "Prosody-Beta2-Compatibility-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let oldValues: [String: Any] = [
            "preferences.dictationShortcut": "Right Option",
            "preferences.dictationActivation": "Press to start / stop",
            "preferences.dictationOverlayAppearance": "Minimal",
            "preferences.dictationInsertion": "Keyboard typing",
            "preferences.copyDictationToClipboard": true,
            "preferences.smartDictationCapitalization": false,
            "preferences.theme": "glass",
            "preferences.captureMode": "system",
            "preferences.sttModel": "parakeet-unified",
            "preferences.speakerMode": "full",
            "preferences.notesProvider": "openai",
            "preferences.notesModel": "legacy-model",
            "preferences.outputFolder": "/tmp/Prosody legacy output",
            "preferences.liveTranscription": false,
            "preferences.keepAudio": true,
            "preferences.globalShortcut": "⌃⌥R",
            "preferences.localOnly": false,
            "preferences.notifyWhenFinished": false,
            "preferences.checkForUpdates": false
        ]
        for (key, value) in oldValues { defaults.set(value, forKey: key) }

        let labelID = UUID()
        let oldLabels: [[String: Any]] = [[
            "id": labelID.uuidString,
            "name": "Course",
            "colorHex": "#336699",
            "outputFolderPath": "/tmp/Prosody legacy label",
            "namingPattern": "{date} - {title}",
            "dateFormat": "yyyy-MM-dd"
        ]]
        defaults.set(try JSONSerialization.data(withJSONObject: oldLabels), forKey: "preferences.recordingLabels")

        let restored = ProsodyPreferences(defaults: defaults)
        XCTAssertEqual(restored.dictationShortcut, .rightOption)
        XCTAssertEqual(restored.dictationActivation, .toggle)
        XCTAssertEqual(restored.dictationOverlayAppearance, .minimal)
        XCTAssertEqual(restored.dictationInsertionMethod, .typing)
        XCTAssertTrue(restored.copyDictationToClipboard)
        XCTAssertFalse(restored.smartDictationCapitalization)
        XCTAssertEqual(restored.theme, .glass)
        XCTAssertEqual(restored.captureMode, .system)
        XCTAssertEqual(restored.sttModelID, SpeechModel.unified.rawValue)
        XCTAssertEqual(restored.speakerMode, .full)
        XCTAssertEqual(restored.notesProviderID, "openai")
        XCTAssertEqual(restored.notesModelID, "legacy-model")
        XCTAssertEqual(restored.outputFolderPath, "/tmp/Prosody legacy output")
        XCTAssertFalse(restored.liveTranscription)
        XCTAssertTrue(restored.keepAudio)
        XCTAssertEqual(restored.globalShortcut, "⌃⌥R")
        XCTAssertFalse(restored.localOnlyMode)
        XCTAssertFalse(restored.notifyWhenFinished)
        XCTAssertFalse(restored.checkForUpdates)
        XCTAssertEqual(restored.recordingLabels.first?.id, labelID)
        XCTAssertNil(restored.recordingLabels.first?.transcriptCopy)

        // New preferences must use safe defaults without discarding Beta 2 values.
        XCTAssertFalse(restored.omitFillerWords)
        XCTAssertFalse(restored.cliEnabled)
        XCTAssertTrue(restored.transcriptExport.title)
        XCTAssertTrue(restored.transcriptCopyDestinations.isEmpty)
    }

    @MainActor
    func testExplicitPreferenceImportKeepsOlderDomainAndMissingCurrentValues() throws {
        let oldSuite = "Prosody-Previous-\(UUID())"
        let newSuite = "Prosody-Current-\(UUID())"
        let old = try XCTUnwrap(UserDefaults(suiteName: oldSuite))
        let current = try XCTUnwrap(UserDefaults(suiteName: newSuite))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).plist")
        defer {
            old.removePersistentDomain(forName: oldSuite)
            current.removePersistentDomain(forName: newSuite)
            try? FileManager.default.removeItem(at: url)
        }

        let label = RecordingLabel(name: "Legacy label")
        let archived: [String: Any] = [
            "preferences.theme": "amber-glass",
            "preferences.dictationShortcut": "Right Option",
            "preferences.outputFolder": "/tmp/Prosody-Legacy",
            "preferences.recordingLabels": try JSONEncoder().encode([label]),
            "preferences.recordingDestinations": try JSONEncoder().encode([
                RecordingDestination(path: "/tmp/Prosody-Previous-Label"),
                RecordingDestination(path: "/tmp/Prosody-Shared-Label")
            ]),
            "preferences.selectedRecordingLabels": [label.id.uuidString, UUID().uuidString],
            "preferences.transcriptExport": Data(#"{"timestamps":false}"#.utf8),
            "preferences.cliEnabled": true,
            "preferences.cliInstalledTarget": "/tmp/untrusted-link",
            "preferences.launchAtLogin": true,
            "preferences.sttModel": "unknown-model",
            TranscriptSegmentationConfiguration.maximumWordsDefaultsKey: 22,
            "SUFeedURL": "https://example.com/untrusted.xml"
        ]
        old.setPersistentDomain(archived, forName: oldSuite)
        let bytes = try PropertyListSerialization.data(fromPropertyList: archived, format: .binary, options: 0)
        try bytes.write(to: url)

        let preferences = ProsodyPreferences(defaults: current)
        XCTAssertEqual(preferences.theme, .graphite)
        XCTAssertEqual(preferences.dictationShortcut, .rightCommand)
        preferences.omitFillerWords = true
        preferences.outputFolderPath = "/tmp/Prosody-Current"
        preferences.outputFolderBookmarkData = Data([1, 2])
        preferences.recordingDestinations = [
            RecordingDestination(path: "/tmp/Prosody-New-Label"),
            RecordingDestination(path: "/tmp/Prosody-Shared-Label", bookmarkData: Data([3]))
        ]
        XCTAssertEqual(try preferences.importSettings(.file(url)), 8)
        XCTAssertEqual(preferences.theme, .amberGlass)
        XCTAssertEqual(preferences.dictationShortcut, .rightOption)
        XCTAssertEqual(preferences.recordingLabels, [label])
        XCTAssertEqual(preferences.selectedRecordingLabelIDs, [label.id])
        XCTAssertEqual(preferences.outputFolderPath, "/tmp/Prosody-Legacy")
        XCTAssertNil(preferences.outputFolderBookmarkData)
        XCTAssertEqual(preferences.recordingDestinations, [
            RecordingDestination(path: "/tmp/Prosody-New-Label"),
            RecordingDestination(path: "/tmp/Prosody-Shared-Label", bookmarkData: Data([3])),
            RecordingDestination(path: "/tmp/Prosody-Previous-Label"),
            RecordingDestination(path: "/tmp/Prosody-Current", bookmarkData: Data([1, 2]))
        ])
        XCTAssertEqual(preferences.transcriptSegmentationConfiguration.maximumWordsPerSegment, 22)
        XCTAssertEqual(preferences.transcriptSegmentationConfiguration.pauseThreshold, 1.5)
        XCTAssertFalse(preferences.transcriptExport.timestamps)
        XCTAssertTrue(preferences.transcriptExport.title)
        XCTAssertTrue(preferences.omitFillerWords)
        XCTAssertFalse(preferences.cliEnabled)
        XCTAssertNil(preferences.cliInstalledTarget)
        XCTAssertFalse(preferences.launchAtLogin)
        XCTAssertNil(current.object(forKey: "SUFeedURL"))
        XCTAssertEqual(preferences.sttModelID, SpeechModel.unified.rawValue)

        old.set("graphite", forKey: "preferences.theme")
        XCTAssertEqual(ProsodyPreferences(defaults: current).theme, .amberGlass)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertThrowsError(try preferences.importSettings(.init(title: "Invalid", values: [
            "preferences.theme": "future-theme",
            "preferences.recordingLabels": Data("invalid".utf8)
        ])))
        XCTAssertEqual(preferences.recordingLabels, [label])
    }

    @MainActor
    func testSandboxPreferenceImportFindsPreviousDefaultOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Clippy")
        let settings = root.appendingPathComponent("Library/Preferences")
        for directory in [folder, settings] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let url = settings.appendingPathComponent("\(AppConstants.bundleIdentifier).plist")
        let bytes = try PropertyListSerialization.data(
            fromPropertyList: ["preferences.outputFolder": "~/Clippy", "preferences.theme": "glass"],
            format: .xml, options: 0
        )
        try bytes.write(to: url)
        let archive = try PreferenceArchive.sandboxInstallation(in: root)
        XCTAssertEqual(archive.values["preferences.outputFolder"] as? String, folder.path)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    @MainActor
    func testMainScreenAndTranscriptPreferencesSurviveRelaunch() {
        let suite = "Prosody-Settings-Tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ProsodyPreferences(defaults: defaults)
        XCTAssertEqual(preferences.transcriptSegmentationConfiguration, .init())
        XCTAssertTrue(MainScreenSection.allCases.allSatisfy(preferences.showsOnMainScreen))
        preferences.transcriptSegmentationConfiguration = .init(maximumWordsPerSegment: 65, pauseThreshold: 2.75)
        preferences.setMainScreenSection(.source, visible: false)
        let restored = ProsodyPreferences(defaults: defaults)
        XCTAssertEqual(restored.transcriptSegmentationConfiguration, preferences.transcriptSegmentationConfiguration)
        XCTAssertFalse(restored.showsOnMainScreen(.source))
        XCTAssertTrue(restored.showsOnMainScreen(.branding))
        XCTAssertEqual(restored.captureMode, preferences.captureMode)
        restored.setMainScreenSection(.source, visible: true)
        XCTAssertTrue(ProsodyPreferences(defaults: defaults).showsOnMainScreen(.source))
    }

    func testMeterRespondsToQuietSpeechWithoutAnimatingSilence() {
        XCTAssertEqual(AudioMeterCalculator.displayAmplitude(rms: 0), 0)
        XCTAssertEqual(AudioMeterCalculator.displayAmplitude(rms: .nan), 0)
        XCTAssertGreaterThan(AudioMeterCalculator.displayAmplitude(rms: 0.03), 0.55)
        XCTAssertLessThan(AudioMeterCalculator.displayAmplitude(rms: 0.03), AudioMeterCalculator.displayAmplitude(rms: 0.1))
        XCTAssertEqual(AudioMeterCalculator.displayAmplitude(rms: 5), 1)
    }

    func testSessionClockKeepsTimelineContinuousAcrossPause() throws {
        var clock = SessionClock()
        try clock.start(firstPTS: 100)
        XCTAssertEqual(try clock.pause(atPTS: 110), 10, accuracy: 0.0001)
        try clock.resume(firstPTS: 500)
        XCTAssertEqual(clock.time(forPTS: 503), 13, accuracy: 0.0001)
        XCTAssertEqual(try clock.stop(atPTS: 504), 14, accuracy: 0.0001)
        XCTAssertEqual(clock.epochs.count, 2)
    }

    func testProvisionalTranscriptRevisionReplacesPreviousTail() {
        var accumulator = TranscriptAccumulator(speakerMode: .off)
        let first = makeSegment(id: UUID(), source: .system, start: 0, end: 1, text: "this is a")
        let revision = makeSegment(id: UUID(), source: .system, start: 0, end: 2, text: "this is a test")

        _ = accumulator.ingest(segment: first, isFinal: false)
        let snapshot = accumulator.ingest(segment: revision, isFinal: false)

        XCTAssertEqual(snapshot.segments.count, 1)
        XCTAssertEqual(snapshot.segments[0].text, "this is a test")
        XCTAssertFalse(snapshot.segments[0].isFinal)
    }

    func testTranscriptAccumulatorMergesSourcesByPresentationTime() {
        var accumulator = TranscriptAccumulator(speakerMode: .off)
        let values: [(AudioSource, Double)] = [(.system, 0), (.microphone, 2), (.system, 4), (.microphone, 6), (.system, 8)]
        for (source, start) in values {
            _ = accumulator.ingest(segment: makeSegment(source: source, start: start, end: start + 1, text: "\(Int(start))"), isFinal: true)
        }
        XCTAssertEqual(accumulator.segments.map { Int($0.start) }, [0, 2, 4, 6, 8])
    }

    func testRawTextSeparatesTranscriptBlocksWithBlankLine() {
        let transcript = Transcript(segments: [
            makeSegment(source: .system, start: 0, end: 1, text: " First   block. "),
            makeSegment(source: .system, start: 2, end: 3, text: "Second\nblock.")
        ])
        XCTAssertEqual(transcript.rawText, "First block.\n\nSecond block.")
    }

    func testStreamingAssemblerUsesCustomMaximumWords() {
        var assembler = StreamingTranscriptAssembler(
            source: .system,
            configuration: .init(maximumWordsPerSegment: 10, pauseThreshold: 5)
        )
        for index in 0..<10 {
            XCTAssertTrue(assembler.append(token: " word\(index)", start: Double(index), end: Double(index) + 0.1).isEmpty)
        }
        let completed = assembler.append(token: " next", start: 10, end: 10.1)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].words.count, 10)
        XCTAssertEqual(assembler.provisional?.text, "next")
    }

    func testStreamingAssemblerUsesCustomPauseThreshold() {
        var assembler = StreamingTranscriptAssembler(
            source: .system,
            configuration: .init(maximumWordsPerSegment: 100, pauseThreshold: 2.5)
        )
        _ = assembler.append(token: " first", start: 0, end: 0.2)
        XCTAssertTrue(assembler.append(token: " second", start: 2.4, end: 2.6).isEmpty)
        let completed = assembler.append(token: " third", start: 5.2, end: 5.4)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].text, "first second")
        XCTAssertEqual(assembler.provisional?.text, "third")
    }

    func testEchoDedupMarksOnlyOverlappingMicrophoneCopy() {
        let system = makeSegment(source: .system, start: 10, end: 13, text: "Let's move the deadline to Friday.")
        let micCopy = makeSegment(source: .microphone, start: 10.1, end: 12.9, text: "lets move the deadline to friday")
        let different = makeSegment(source: .microphone, start: 10, end: 13, text: "I will send the draft tomorrow")
        let result = EchoDeduplication().markDuplicates(in: [system, micCopy, different])

        XCTAssertTrue(result[1].isEchoDuplicate)
        XCTAssertFalse(result[2].isEchoDuplicate)
        XCTAssertFalse(result[0].isEchoDuplicate)
    }

    func testSpeakerAlignmentSplitsWordsAtSpeakerBoundary() {
        let words = [
            TranscriptWord(text: "we", start: 0, end: 1),
            TranscriptWord(text: "can", start: 1, end: 2),
            TranscriptWord(text: "start", start: 2, end: 3)
        ]
        let intervals = [
            SpeakerInterval(speakerID: "speaker-1", start: 0, end: 1.9),
            SpeakerInterval(speakerID: "speaker-2", start: 1.9, end: 4)
        ]
        let result = SpeakerAlignment().align(words: words, speakers: intervals)

        XCTAssertEqual(result.map(\.speakerID), ["speaker-1", "speaker-2"])
        XCTAssertEqual(result.map(\.text), ["we can", "start"])
    }

    func testChunkerPreservesAllSegmentsAndOrdering() {
        let segments = (0..<5).map { index in
            makeSegment(source: .system, start: Double(index * 4), end: Double(index * 4 + 1), text: "segment \(index)")
        }
        let chunker = TranscriptChunking(options: TranscriptChunkingOptions(
            targetDuration: 5,
            maximumDuration: 7,
            maximumCharacters: 1_000,
            silenceGap: 0
        ))
        let chunks = chunker.chunks(for: segments)

        XCTAssertEqual(chunks.flatMap(\.segments).map(\.id), segments.map(\.id))
        XCTAssertEqual(chunks.map(\.id), Array(0..<chunks.count))
        XCTAssertGreaterThan(chunks.count, 1)
    }

    func testMarkdownRendererUsesSafeFrontMatterAndOmitsEchoByDefault() {
        let transcript = Transcript(segments: [
            makeSegment(source: .system, start: 12, end: 18, text: "Hello *world*"),
            makeSegment(source: .microphone, start: 18, end: 20, text: "echo", echo: true)
        ])
        let markdown = MarkdownRenderer.render(
            transcript: transcript,
            title: "Lecture \"1\"",
            date: Date(timeIntervalSince1970: 0),
            duration: 20
        )

        XCTAssertTrue(markdown.contains("title: \"Lecture \\\"1\\\"\""))
        XCTAssertTrue(markdown.contains("**[00:12] Others:** Hello \\*world\\*"))
        XCTAssertFalse(markdown.contains("echo"))
    }

    func testSafeURLValidationAllowsLoopbackHTTPOnly() throws {
        XCTAssertTrue(SafeURLValidator.isAllowed(URL(string: "http://127.0.0.1:1234/v1")!))
        XCTAssertTrue(SafeURLValidator.isAllowed(URL(string: "http://[::1]:1234")!))
        XCTAssertFalse(SafeURLValidator.isAllowed(URL(string: "http://example.com")!))
        XCTAssertTrue(SafeURLValidator.isAllowed(URL(string: "https://example.com")!))
        XCTAssertFalse(SafeURLValidator.isAllowed(URL(string: "https://example.com")!, policy: SafeURLPolicy(localOnly: true)))
        XCTAssertThrowsError(try SafeURLValidator.validate(URL(string: "https://user:password@example.com")!))
    }

    func testSessionAndRecoveryStoresPersistAtomically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProsodyCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession()
        let transcript = Transcript(segments: [makeSegment(source: .system, start: 0, end: 2, text: "saved")])

        let store = SessionStore(rootURL: root.appendingPathComponent("Sessions"))
        let folder = try await store.save(session: session, transcript: transcript)
        let loaded = try await store.load(id: session.id)
        let expectedFolder = await store.folderURL(for: session.id)
        XCTAssertEqual(folder, expectedFolder)
        XCTAssertEqual(loaded.transcript, transcript)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.json").path))

        let recovery = RecoveryStore(rootURL: root.appendingPathComponent("Recovery"))
        _ = try await recovery.begin(session: session)
        _ = try await recovery.append(segment: transcript.segments[0], to: session.id)
        let recovered = try await recovery.load(id: session.id)
        XCTAssertEqual(recovered.transcript.segments, transcript.segments)
        XCTAssertEqual(recovered.manifest.transcriptSegmentCount, 1)
    }

    func testMockPipelineExercisesClockAndTranscriptWithoutCapturePermissions() async throws {
        let pipeline = MockRecordingPipeline(configuration: MockRecordingPipelineConfiguration(captureMode: .system))
        _ = try await pipeline.start(firstPTS: 10)
        let frame = try await pipeline.submit(audio: MockAudioInput(source: .system, presentationTime: 11, samples: [0, 0.25, 0]))
        XCTAssertEqual(frame.startTime, 1, accuracy: 0.0001)
        _ = try await pipeline.submit(segment: makeSegment(source: .system, start: 1, end: 2, text: "hello"), isFinal: true)
        let result = try await pipeline.finish(atPTS: 14)

        XCTAssertEqual(result.session.duration, 4, accuracy: 0.0001)
        XCTAssertEqual(result.transcript.segments.count, 1)
        let finalState = await pipeline.recordingState()
        XCTAssertEqual(finalState, .completed(result.session.id))
    }

    private func makeSession() -> RecordingSession {
        RecordingSession(
            title: "Test Session",
            captureMode: .both,
            sttEngineID: .parakeet,
            sttModelID: "parakeet-unified",
            speakerMode: .basic,
            notesProviderID: "local-openai-compatible",
            notesModelID: "test",
            noteTemplateID: .lectureNotes,
            keepAudio: false,
            status: "completed"
        )
    }

    private func makeSegment(
        id: UUID = UUID(),
        source: AudioSource,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        echo: Bool = false
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            source: source,
            start: start,
            end: end,
            text: text,
            isFinal: false,
            isEchoDuplicate: echo
        )
    }
}
#endif

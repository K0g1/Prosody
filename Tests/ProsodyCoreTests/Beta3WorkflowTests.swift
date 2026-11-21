#if canImport(Testing)
@preconcurrency import AVFoundation
import AppKit
import Foundation
import ProsodyIPC
import Testing
@testable import ProsodyCore

@Suite("Beta 3 workflows")
struct Beta3WorkflowTests {
    @Test(arguments: [
        ("UMMMM, uhhh, mmm, erm… let's go.", "Let's go."),
        ("Uhm, uh, a new idea.", "A new idea."),
        ("A— let's go.", "Let's go."),
        ("A letter from plan A, with a stamp.", "A letter from plan A, with a stamp."),
        ("The team, um, agreed. Uh, then we left.", "The team agreed. Then we left."),
        ("I think ( hmm ) we can go.", "I think we can go."),
        ("“Um, let's try it.”", "“Let's try it.”"),
        ("Um, iPhone works.", "iPhone works."),
        ("Uh, 10 entries were saved.", "10 entries were saved."),
        ("Ummm…", ""),
        ("Momentum and humming. Uh-huh. mm-hmm. 25 mm?", "Momentum and humming. Uh-huh. mm-hmm. 25 mm?"),
        ("Visit um.example and email user@example.com.", "Visit um.example and email user@example.com."),
        ("Um, él habla. Erm, ça marche.", "Él habla. Ça marche.")
    ])
    func filtersEnglishHesitation(input: String, expected: String) {
        #expect(FillerWordFilter.clean(input) == expected)
    }

    @Test func filterKeepsWordTimingsAndCapitalizesAcrossBlocks() throws {
        let filler = TranscriptSegment(source: .microphone, start: 0, end: 0.8, text: "Uhh…", isFinal: true)
        let a = TranscriptWord(text: "a", start: 1, end: 1.1)
        let book = TranscriptWord(text: "book", start: 1.2, end: 1.35)
        let trailing = TranscriptWord(text: "um", start: 1.4, end: 1.7)
        let words = TranscriptSegment(source: .microphone, start: 1, end: 1.7, text: "a book um",
                                      words: [a, book, trailing], isFinal: true)
        let result = FillerWordFilter().apply(to: Transcript(segments: [filler, words]))
        #expect(result.segments.count == 1)
        let segment = try #require(result.segments.first)
        #expect(segment.text == "A book")
        #expect(segment.words.map(\.text) == ["A", "book"])
        #expect(segment.words.map(\.id) == [a.id, book.id])
        #expect(segment.end == book.end)
    }

    @Test func packagedModelManifestsHaveExpectedComponents() throws {
        for model in [SpeechModel.tdtV3, .fluidSpeechPro] {
            let manifest = try #require(SpeechModelPackage.package(for: model))
            #expect(manifest.revision.count == 40)
            #expect(manifest.files.contains { $0.path == "Encoder.mlmodelc/weights/weight.bin" && $0.sha256?.count == 64 })
            #expect(manifest.files.contains { $0.path.hasSuffix("_vocab.json") })
        }
    }

    /// Opt-in release QA with a generated audio file and an isolated cache.
    @Test @MainActor func packagedCLIAndFailedBatchInput() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let cache = environment["PROSODY_QA_CACHE"],
              let file = environment["PROSODY_QA_AUDIO"],
              let cli = environment["PROSODY_QA_CLI"] else { return }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Prosody-QA-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "com.openai.clippy.qa.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ProsodyPreferences(defaults: defaults)
        preferences.outputFolderPath = root.path
        preferences.sttModelID = SpeechModel.fluidSpeechPro.rawValue
        preferences.cliEnabled = true
        preferences.generateNotesAutomatically = false
        preferences.notifyWhenFinished = false
        let model = AppModel(preferences: preferences, demoMode: true,
            supportRootURL: URL(fileURLWithPath: cache).deletingLastPathComponent(), registerHotkey: false, loadStoredState: false)
        try model.cliService.start(model: model)
        defer { model.cliService.stop() }

        let replacement = try await Self.invokeCLI(cli, ["replacements", "set", "meeting notes", "meeting minutes"])
        #expect(replacement.status == 0)
        #expect(preferences.wordReplacements.first?.replacement == "meeting minutes")
        let listed = try await Self.invokeCLI(cli, ["replacements", "--json", "list"])
        try #require(listed.status == 0, Comment(rawValue: listed.output))
        let listResponse = try JSONDecoder().decode(CLIResponse.self, from: Data(listed.output.utf8))
        #expect(listResponse.items.contains { $0.input == "meeting notes" && $0.text == "meeting minutes" })

        let literal = try await Self.invokeCLI(cli, ["replacements", "set", "--json", "", "--json"])
        try #require(literal.status == 0, Comment(rawValue: literal.output))
        _ = try JSONDecoder().decode(CLIResponse.self, from: Data(literal.output.utf8))
        #expect(preferences.wordReplacements.contains { $0.original == "--json" && $0.replacement.isEmpty })

        let result = try await Self.invokeCLI(cli, ["transcribe", "--output-dir", root.path, "--include", "audio-name", file])
        try #require(result.status == 0, Comment(rawValue: result.output))
        let outputURL = URL(fileURLWithPath: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        let markdown = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(markdown.contains("Source audio:"))
        #expect(markdown.contains("meeting minutes"))

        let invalid = root.appendingPathComponent("invalid.aiff")
        try Data("Invalid audio".utf8).write(to: invalid)
        model.transcribeFiles([URL(fileURLWithPath: file), invalid], options: .init())
        await model.waitForRecordingTransition()
        #expect(model.canBrowseSessions)
        #expect(model.userFacingError != nil)
        #expect(model.lastNotice == "Saved 1 of 2 transcripts.")

        model.cliService.stop()
        let disconnected = try await Self.invokeCLI(cli, ["status"])
        #expect(disconnected.status == 1)
    }

    private static func invokeCLI(_ path: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        try await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
        }.value
    }

    @Test func exportMetadataAndCollisionHandling() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var session = RecordingSession(title: "Weekly sync", captureMode: .microphone, sttEngineID: .parakeet,
            sttModelID: "parakeet-v3", speakerMode: .basic, notesProviderID: "template-local", notesModelID: "",
            noteTemplateID: .summary, keepAudio: false)
        session.originalAudioFileName = "standup.m4a"
        let segment = TranscriptSegment(source: .microphone, start: 0, end: 1, text: "Hello *world*", isFinal: true,
                                        speakerName: "Engineer")
        let document = SessionDocument(session: session, transcript: Transcript(segments: [segment]))
        var options = TranscriptExportOptions()
        options.originalAudioFileName = true
        options.timestamps = false
        options.speakerNames = false
        let markdown = TranscriptExportFormatter.render(document, options: options)
        #expect(markdown.contains("standup.m4a"))
        #expect(!markdown.contains("Engineer"))
        #expect(TranscriptExportFormatter.render(document, format: .rawText) == "Hello *world*")
        #expect(TranscriptExportFormatter.render(document, format: .textOnlyMarkdown) == #"Hello \*world\*"#)
        let first = try TranscriptExporter.writeCopy(markdown, fileName: "Transcript.md", in: root)
        let second = try TranscriptExporter.writeCopy("second", fileName: "Transcript.md", in: root)
        #expect(first.lastPathComponent == "Transcript.md")
        #expect(second.lastPathComponent == "Transcript (2).md")
        #expect(try String(contentsOf: first, encoding: .utf8) == markdown)
    }

    @Test func followLooksAheadOnlyDuringPlayback() {
        let segments = [
            TranscriptSegment(source: .system, start: 0, end: 3, text: "First", isFinal: true),
            TranscriptSegment(source: .system, start: 3, end: 6, text: "Second", isFinal: true)
        ]
        let timeline = TranscriptTimeline(segments: segments)
        #expect(timeline.row(at: TranscriptFollowPolicy.rowTime(2.85, playing: true, scrubbing: false))?.text == "Second")
        #expect(timeline.row(at: TranscriptFollowPolicy.rowTime(2.85, playing: false, scrubbing: false))?.text == "First")
        #expect(timeline.row(at: TranscriptFollowPolicy.rowTime(2.85, playing: true, scrubbing: true))?.text == "First")
    }

    @Test @MainActor func visiblePlaybackRowMovesToCenter() async throws {
        let scroll = TranscriptTableScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        let table = TranscriptTableView(frame: NSRect(x: 0, y: 0, width: 520, height: 720))
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = false
        table.rowHeight = 60
        table.intercellSpacing = .zero
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("test"))
        column.width = 520
        column.minWidth = 0
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.documentView = table
        let coordinator = TranscriptNativeTableView.Coordinator(
            rename: { _, _ in }, seek: { _ in }, onUserInteraction: {}, isScrubbing: { false }
        )
        coordinator.install(scrollView: scroll, tableView: table)
        defer { coordinator.dismantle() }
        table.dataSource = coordinator
        table.delegate = coordinator

        let segments = (0..<12).map { index in
            TranscriptSegment(source: .system, start: Double(index), end: Double(index + 1),
                              text: "Passage \(index + 1)", isFinal: true)
        }
        let rows = TranscriptTimeline(segments: segments).rows
        let palette = ProsodyTheme.graphite.palette
        func follow(_ directive: TranscriptFollowDirective?) {
            coordinator.update(rows: rows, revision: 1, canSeekAudio: true,
                followedRowID: directive?.rowID, followDirective: directive, isScrubbing: { false },
                reduceMotion: false, palette: palette, rename: { _, _ in }, seek: { _ in }, onUserInteraction: {})
        }

        follow(nil)
        scroll.layoutSubtreeIfNeeded()
        let visible = table.visibleRect
        let index = try #require(rows.indices.last { index in
            let rowCenter = table.rect(ofRow: index).midY
            return rowCenter > visible.midY + 8 && rowCenter < visible.maxY - 8
        })
        let initial = scroll.contentView.bounds.minY
        follow(.init(rowID: rows[index].id, rowIndex: index, requestID: 1, shouldAnimate: true))
        let clock = ContinuousClock()
        // Other AppKit tests can occupy the main actor during a full suite run.
        let timeout = clock.now.advanced(by: .seconds(5))
        while abs(table.visibleRect.midY - table.rect(ofRow: index).midY) > 2 && clock.now < timeout {
            try await Task.sleep(for: .milliseconds(16))
        }
        #expect(scroll.contentView.bounds.minY > initial)
        #expect(abs(table.visibleRect.midY - table.rect(ofRow: index).midY) <= 2)
    }

    @Test func compressionKeepsBothTracksAndTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("audio/system", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let transcript = root.appendingPathComponent("transcript.md")
        try Data("Transcript".utf8).write(to: transcript)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let channel = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) { channel[frame] = Float(sin(Double(frame) * 0.04)) * 0.2 }
        for url in [source.appendingPathComponent("000001.caf"), root.appendingPathComponent("microphone.caf")] {
            let output = try AVAudioFile(forWriting: url, settings: format.settings)
            try output.write(from: buffer)
        }
        let before = RetainedAudioCompression.storedBytes(in: root)
        let savings = try RetainedAudioCompression.compress(in: root)
        #expect(savings > 0)
        #expect(RetainedAudioCompression.storedBytes(in: root) == before - savings)
        #expect(SessionAssetResolver.allAudioTracks(in: root).count == 2)
        #expect(try String(contentsOf: transcript, encoding: .utf8) == "Transcript")
    }
}
#endif

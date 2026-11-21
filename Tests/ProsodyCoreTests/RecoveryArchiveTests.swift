#if canImport(XCTest)
import AVFoundation
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
        let retained = try writeAudioChunk(to: finalChunk, amplitude: 0.1)
        try write(retained, to: recoveryAudio.appendingPathComponent("system/000001.m4a"))
        let added = try writeAudioChunk(to: recoveryAudio.appendingPathComponent("system/000002.m4a"), amplitude: 0.2)
        try write(Data(), to: recoveryAudio.appendingPathComponent("system/000003.m4a"))
        try write(Data("not audio".utf8), to: recoveryAudio.appendingPathComponent("system/000004.txt"))

        let recoveryFiles = try AudioArchiveMerger.recoveryAudioFiles(in: recoveryAudio)
        XCTAssertEqual(recoveryFiles.map(\.lastPathComponent), ["000001.m4a", "000002.m4a"])
        let moved = try AudioArchiveMerger.merge(recoveryFiles, from: recoveryAudio, into: finalAudio)

        XCTAssertEqual(moved.map(\.lastPathComponent), ["000002.m4a"])
        XCTAssertEqual(try Data(contentsOf: finalChunk), retained)
        XCTAssertEqual(
            try Data(contentsOf: finalAudio.appendingPathComponent("system/000002.m4a")),
            added
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
        let finalChunk = finalAudio.appendingPathComponent("system/000002.m4a")
        let recoveryChunk = recoveryAudio.appendingPathComponent("system/000002.m4a")
        let earlierChunk = recoveryAudio.appendingPathComponent("system/000001.m4a")
        let earlier = try writeAudioChunk(to: earlierChunk)
        let retained = try writeAudioChunk(to: finalChunk, amplitude: 0.1)
        let conflicting = try writeAudioChunk(to: recoveryChunk, amplitude: 0.2)

        let recoveryFiles = try AudioArchiveMerger.recoveryAudioFiles(in: recoveryAudio)
        XCTAssertThrowsError(try AudioArchiveMerger.merge(recoveryFiles, from: recoveryAudio, into: finalAudio)) { error in
            guard let mergerError = error as? AudioArchiveMergerError,
                  case .conflictingArtifact = mergerError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: finalChunk), retained)
        XCTAssertEqual(try Data(contentsOf: recoveryChunk), conflicting)
        XCTAssertEqual(try Data(contentsOf: earlierChunk), earlier)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalAudio.appendingPathComponent("system/000001.m4a").path))
    }

    func testRecoveryAudioScopeIncludesOnlyLegacyCAFAndKnownSourceDirectories() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveryAudio = root.appendingPathComponent("Recovery/audio", isDirectory: true)
        let finalSession = root.appendingPathComponent("Final", isDirectory: true)
        let finalAudio = finalSession.appendingPathComponent("audio", isDirectory: true)
        try writeAudioChunk(to: recoveryAudio.appendingPathComponent("system.caf"))
        try writeAudioChunk(to: recoveryAudio.appendingPathComponent("system/000001.m4a"))
        try writeAudioChunk(to: recoveryAudio.appendingPathComponent("microphone/000001.m4a"))
        try writeAudioChunk(to: recoveryAudio.appendingPathComponent("root.m4a"))
        try writeAudioChunk(to: recoveryAudio.appendingPathComponent("unknown/000001.m4a"))

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

    func testRecoverySkipsUnfinalizedM4ATailAndRetainsPlayablePrefix() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveryAudio = root.appendingPathComponent("Recovery/audio", isDirectory: true)
        let finalSession = root.appendingPathComponent("Final", isDirectory: true)
        let good = recoveryAudio.appendingPathComponent("system/000001.m4a")
        let tail = recoveryAudio.appendingPathComponent("system/000002.m4a")
        try writeAudioChunk(to: good)

        // Nonempty M4A with an mdat atom but no moov atom, as when a
        // process is killed before the encoder finalizes its current chunk.
        let unfinalized = Data([
            0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20,
            0, 0, 0, 0, 0x4D, 0x34, 0x41, 0x20,
            0, 0, 0, 12, 0x6D, 0x64, 0x61, 0x74, 1, 2, 3, 4
        ])
        try write(unfinalized, to: tail)
        let files = try AudioArchiveMerger.recoveryAudioFiles(in: recoveryAudio)
        XCTAssertEqual(files.map(\.lastPathComponent), ["000001.m4a"])
        let moved = try AudioArchiveMerger.merge([good, tail], from: recoveryAudio, into: finalSession.appendingPathComponent("audio"))
        XCTAssertEqual(moved.map(\.lastPathComponent), ["000001.m4a"])
        let playbackFiles = SessionAssetResolver.audioURLs(in: finalSession)
        XCTAssertEqual(
            playbackFiles.map { $0.resolvingSymlinksInPath() },
            moved.map { $0.resolvingSymlinksInPath() }
        )
        XCTAssertTrue(SessionAudioTimeline.hasContiguousNumberedChunks(playbackFiles))
        XCTAssertGreaterThan(try AVAudioFile(forReading: XCTUnwrap(playbackFiles.first)).length, 0)
        XCTAssertEqual(try Data(contentsOf: tail), unfinalized)
    }

    @MainActor
    func testArchiveWritesReadableAudioAtNativeAndFallbackSampleRates() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for bitRate in [96_000, 192_000] {
            for rate in [8_000.0, 16_000, 24_000, 44_100, 48_000, 88_200, 96_000] {
                let archive = AudioArchiveWriter(directoryURL: root.appendingPathComponent("\(bitRate)-\(rate)"), bitRate: bitRate)
                let count = Int(rate / 20)
                let phaseStep = 2 * Double.pi * 440 / rate
                for packet in 0..<6 {
                    let samples = (0..<count).map { frame -> Float in
                        let phase = Double(packet * count + frame) * phaseStep
                        return Float(sin(phase)) * 0.25
                    }
                    try await archive.append(CapturedAudioPacket(
                        source: .microphone, presentationTime: Double(packet) / 20, sampleRate: rate, samples: samples
                    ))
                }
                let urls = try await archive.finish()
                XCTAssertEqual(urls.count, 1)
                let file = try AVAudioFile(forReading: XCTUnwrap(urls.first))
                let expectedRate = min(rate, 48_000)
                XCTAssertEqual(file.fileFormat.sampleRate, expectedRate)
                XCTAssertEqual(Double(file.length) / expectedRate, 0.3, accuracy: 0.002, "Input rate \(rate), bitrate \(bitRate)")
                let decoded = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_024))
                try file.read(into: decoded)
                let channel = try XCTUnwrap(decoded.floatChannelData?[0])
                XCTAssertTrue(UnsafeBufferPointer(start: channel, count: Int(decoded.frameLength)).contains { abs($0) > 0.05 })
            }
        }
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
        try await checkRecoveryKeepsExistingFinalDocument(withResidualAudio: false)
    }

    @MainActor
    func testRecoverWithResidualAudioKeepsExistingFinalTranscriptAndNotes() async throws {
        try await checkRecoveryKeepsExistingFinalDocument(withResidualAudio: true)
    }

    @MainActor
    private func checkRecoveryKeepsExistingFinalDocument(withResidualAudio: Bool) async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Prosody-Recovery-Existing-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ProsodyPreferences(defaults: defaults)
        preferences.outputFolderPath = root.appendingPathComponent("Sessions").path
        preferences.generateNotesAutomatically = withResidualAudio
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
        let finalDirectory = try await sessions.save(
            session: session,
            transcript: durable,
            notesMarkdown: "# Existing notes"
        )
        let recovery = RecoveryStore(rootURL: root.appendingPathComponent("Support/Recovery"))
        let manifest = try await recovery.begin(session: session)
        let recoveryDirectory = await recovery.directoryURL(for: session.id)
        let originalChunk = finalDirectory.appendingPathComponent("audio/microphone/000001.m4a")
        let residualChunk = recoveryDirectory.appendingPathComponent("audio/microphone/000002.m4a")
        if withResidualAudio {
            try writeAudioChunk(to: originalChunk)
            try writeAudioChunk(to: residualChunk)
        }

        model.recover(manifest)
        await model.transitionTask?.value

        let final = try await sessions.load(id: session.id)
        XCTAssertEqual(final.transcript.visibleSegments.map(\.text), ["durable transcript"])
        XCTAssertEqual(final.notesMarkdown, "# Existing notes")
        XCTAssertTrue(model.selectedSessionHasNotes)
        XCTAssertEqual(model.recordingState, .completed(session.id))
        if withResidualAudio {
            XCTAssertEqual(SessionAssetResolver.audioURLs(in: finalDirectory).map(\.lastPathComponent),
                           ["000001.m4a", "000002.m4a"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: residualChunk.path))
        }
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

    @discardableResult
    private func writeAudioChunk(to url: URL, amplitude: Float = 0.25) throws -> Data {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let settings = url.pathExtension == "caf" ? format.settings : [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) {
            channel[frame] = amplitude * Float(sin(2 * .pi * 440 * Double(frame) / 48_000))
        }
        try file.write(from: buffer)
        file.close()
        return try Data(contentsOf: url)
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

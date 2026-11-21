#if canImport(XCTest)
@preconcurrency import AVFoundation
import FluidAudio
import XCTest
@testable import ProsodyCore

final class SpeechSpeakerRegressionTests: XCTestCase {
    func testParakeetKeepsOneActiveSessionPerSource() async throws {
        let engine = makeEngine()
        try await engine.prepare(model: SpeechModel.unified.descriptor) { _ in }
        let system = try await engine.makeSession(source: .system)
        _ = try await engine.makeSession(source: .microphone)
        do {
            _ = try await engine.makeSession(source: .system)
            XCTFail("An active source must keep its manager.")
        } catch let error as STTError {
            guard case .failed = error else { return XCTFail("Unexpected error: \(error)") }
        }

        await system.cancel()
        let replacement = try await engine.makeSession(source: .system)
        await engine.unload()
        do {
            try await replacement.append(samples: [0], startTime: 0)
            XCTFail("Unload must end its sessions before cleaning up their managers.")
        } catch let error as STTError {
            XCTAssertEqual(error, .sessionFinished)
        }
    }

    func testParakeetDiscardsSourceLoadInvalidatedByUnload() async throws {
        let loader = UnifiedLoadGate(blockingCall: 2)
        let engine = makeEngine(loader: { try await loader.load($0) })
        try await engine.prepare(model: SpeechModel.unified.descriptor) { _ in }
        _ = try await engine.makeSession(source: .system)
        let pending = Task { try await engine.makeSession(source: .microphone) }
        await loader.waitUntilBlocked()
        await engine.unload()
        try await engine.prepare(model: SpeechModel.unified.descriptor) { _ in }
        let replacement = try await engine.makeSession(source: .microphone)
        await loader.release()

        do {
            _ = try await pending.value
            XCTFail("A manager loaded by an old generation must not open a session.")
        } catch is CancellationError {}
        do {
            _ = try await engine.makeSession(source: .microphone)
            XCTFail("The old reservation must not release the replacement source.")
        } catch let error as STTError {
            guard case .failed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        await replacement.cancel()
        await engine.unload()
    }

    func testParakeetDiscardsPreparationInvalidatedByUnload() async throws {
        let loader = UnifiedLoadGate(blockingCall: 1)
        let engine = makeEngine(loader: { try await loader.load($0) })
        let pending = Task { try await engine.prepare(model: SpeechModel.unified.descriptor) { _ in } }
        await loader.waitUntilBlocked()
        await engine.unload()
        await loader.release()

        do {
            try await pending.value
            XCTFail("Unload must invalidate an in-flight prepare.")
        } catch is CancellationError {}
        do {
            _ = try await engine.makeSession(source: .system)
            XCTFail("Loading late must not restore the unloaded engine.")
        } catch let error as ParakeetEngineError {
            XCTAssertEqual(error, .modelNotPrepared)
        }
    }

    func testParakeetTimestampsPreserveSourceGapsWithoutStretchingTokens() throws {
        var timeline = ParakeetAudioTimeline()
        timeline.append(sampleCount: 16_000, startTime: 2)
        timeline.append(sampleCount: 16_000, startTime: 3.01)
        timeline.append(sampleCount: 16_000, startTime: 8)
        timeline.append(sampleCount: 16_000, startTime: 2) // Live dictation repeats its original start.

        let beforeGap = try XCTUnwrap(timeline.map(start: 1.96, end: 2.04))
        XCTAssertEqual(beforeGap.start, 3.96, accuracy: 1e-9)
        XCTAssertEqual(beforeGap.end, 4, accuracy: 1e-9)
        let afterGap = try XCTUnwrap(timeline.map(start: 2, end: 2.10))
        XCTAssertEqual(afterGap.start, 8, accuracy: 1e-9)
        XCTAssertEqual(afterGap.end, 8.10, accuracy: 1e-9)
        XCTAssertEqual(timeline.endTime, 10)
    }

    func testDiarizationDownmixesAndPreservesLengthAndCallerOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("z.caf")
        let second = directory.appendingPathComponent("a.caf")
        let firstFrames = 288_013
        let secondFrames = 44_103
        try writeAudio(to: first, rate: 48_000, frames: firstFrames, values: [0, 0.5])
        try writeAudio(to: second, rate: 44_100, frames: secondFrames, values: [-0.5])

        let prepared = try FluidAudioDiarizer.makeDiarizationInput(from: [first, second], in: directory)
        let file = try AVAudioFile(forReading: prepared)
        let firstEnd = Double(firstFrames) * 16_000 / 48_000
        let expected = (firstEnd + Double(secondFrames) * 16_000 / 44_100).rounded()
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.length, AVAudioFramePosition(expected))
        XCTAssertGreaterThan(try sample(from: file, at: 80_000), 0.2)
        XCTAssertLessThan(try sample(from: file, at: Int64(firstEnd) + 1_000), -0.4)
    }

    func testSpeakerAlignmentKeepsManualEdits() {
        let segment = TranscriptSegment(
            source: .system, start: 0, end: 4, text: "my name",
            words: [TranscriptWord(text: "my", start: 0, end: 1), TranscriptWord(text: "name", start: 2, end: 3)],
            isFinal: true, speakerID: "speaker-1", speakerName: "Sam", wasUserEdited: true
        )
        let intervals = [
            SpeakerInterval(speakerID: "speaker-2", start: 0, end: 2),
            SpeakerInterval(speakerID: "speaker-3", start: 2, end: 4)
        ]
        XCTAssertEqual(SpeakerAlignment().apply(to: [segment], intervals: intervals), [segment])
    }

    func testSpeakerAlignmentUsesMeanConfidenceAndFurthestWordEnd() throws {
        let words = [
            TranscriptWord(text: "one", start: 0, end: 1),
            TranscriptWord(text: "two", start: 2, end: 5),
            TranscriptWord(text: "three", start: 3, end: 4)
        ]
        let intervals = [
            SpeakerInterval(speakerID: "speaker", start: 0, end: 1, confidence: 0.3),
            SpeakerInterval(speakerID: "speaker", start: 2, end: 3, confidence: 0.6),
            SpeakerInterval(speakerID: "speaker", start: 3, end: 4, confidence: 0.9)
        ]
        let segment = try XCTUnwrap(SpeakerAlignment().align(words: words, speakers: intervals).first)
        XCTAssertEqual(segment.words.count, 3)
        XCTAssertEqual(try XCTUnwrap(segment.confidence), 0.6, accuracy: 1e-5)
        XCTAssertEqual(segment.end, 5)
    }

    func testAssemblerAndChunkerPreserveOverlappingWordAndSegmentEnds() throws {
        var assembler = StreamingTranscriptAssembler(source: .system)
        _ = assembler.append(token: " a", start: 0, end: 8)
        _ = assembler.append(token: " b", start: 1, end: 2)
        XCTAssertTrue(assembler.append(token: " c", start: 5, end: 6).isEmpty)
        XCTAssertEqual(assembler.flush()?.end, 8)

        let segments = [
            segment(start: 0, end: 10),
            segment(start: 1, end: 2),
            segment(start: 7, end: 8)
        ]
        let chunker = TranscriptChunking(options: .init(targetDuration: 1, maximumDuration: 12, silenceGap: 2))
        let chunks = chunker.chunks(for: segments)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.end, 10)
    }

    func testAccumulatorKeepsOnlyLatestTailAndDoesNotDemoteFinals() {
        let old = segment(start: 0, end: 1)
        let distant = segment(start: 5, end: 6)
        let next = segment(start: 6, end: 7)
        var accumulator = TranscriptAccumulator(speakerMode: .off)

        _ = accumulator.ingest(segment: old, isFinal: false)
        _ = accumulator.ingest(segment: distant, isFinal: false)
        XCTAssertEqual(accumulator.segments.map(\.id), [distant.id])

        _ = accumulator.ingest(segment: distant, isFinal: true)
        _ = accumulator.ingest(segment: next, isFinal: false)
        _ = accumulator.ingest(segment: distant, isFinal: true)
        _ = accumulator.ingest(segment: distant, isFinal: false)
        XCTAssertEqual(accumulator.segments.map(\.id), [distant.id, next.id])
        XCTAssertEqual(accumulator.segments.map(\.isFinal), [true, false])
    }

    private func makeEngine(
        loader: @escaping @Sendable (URL) async throws -> StreamingUnifiedAsrManager = { _ in StreamingUnifiedAsrManager() }
    ) -> ParakeetEngine {
        ParakeetEngine(installedModelURL: { _ in URL(fileURLWithPath: "/") }, loadUnifiedManager: loader)
    }

    private func segment(start: TimeInterval, end: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(source: .system, start: start, end: end, text: "text", isFinal: true)
    }

    private func writeAudio(to url: URL, rate: Double, frames: Int, values: [Float]) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(values.count)))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192))
        let channels = try XCTUnwrap(buffer.floatChannelData)
        var remaining = frames
        while remaining > 0 {
            let count = min(remaining, Int(buffer.frameCapacity))
            buffer.frameLength = AVAudioFrameCount(count)
            for (channel, value) in values.enumerated() {
                channels[channel].update(repeating: value, count: count)
            }
            try file.write(from: buffer)
            remaining -= count
        }
    }

    private func sample(from file: AVAudioFile, at frame: AVAudioFramePosition) throws -> Float {
        file.framePosition = frame
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1))
        try file.read(into: buffer)
        XCTAssertEqual(buffer.frameLength, 1)
        return try XCTUnwrap(buffer.floatChannelData)[0][0]
    }
}

private actor UnifiedLoadGate {
    let blockingCall: Int
    var calls = 0
    var blocked: CheckedContinuation<Void, Never>?
    var arrivals: [CheckedContinuation<Void, Never>] = []

    init(blockingCall: Int) { self.blockingCall = blockingCall }

    func load(_ url: URL) async throws -> StreamingUnifiedAsrManager {
        calls += 1
        if calls == blockingCall {
            await withCheckedContinuation {
                blocked = $0
                for arrival in arrivals { arrival.resume() }
                arrivals.removeAll()
            }
        }
        return StreamingUnifiedAsrManager()
    }

    func waitUntilBlocked() async {
        if blocked == nil { await withCheckedContinuation { arrivals.append($0) } }
    }

    func release() {
        blocked?.resume()
        blocked = nil
    }
}
#endif

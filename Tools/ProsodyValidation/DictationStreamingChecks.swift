@_spi(Validation) import ProsodyCore
import Foundation

extension ProsodyValidation {
    static func checkDictationStreaming() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Prosody-Dictation-Checks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = DictationStreamingFixture(root: root)
        try await fixture.checkThresholdAndSilence()
        try await fixture.checkMalformedPackets()
        try await fixture.checkBackpressure()
        try await fixture.checkCancellation()
        try await fixture.checkCacheAndRepeatedStarts()
        try await fixture.checkPCMAndWindows()
        print("Dictation streaming regressions: PASS (duration, silence, malformed packets, overflow, cancellation, cache, rate changes and final PCM)")
    }
}

private struct DictationStreamingFixture {
    let root: URL

    func checkThresholdAndSilence() async throws {
        let probe = DictationModelProbe()
        let recognizer = makeRecognizer(probe)
        let justUnder = try await run("tap", recognizer, [packet(3_999)])
        precondition(justUnder == nil)
        let silence = try await run("silence", recognizer, [packet(8_000, value: 0)])
        precondition(silence == nil)
        let initiallyCold = await probe.loads
        precondition(initiallyCold == 0, "A tap or silent hold loaded the model.")

        // 10 × 25 ms sums to 0.24999999999999997 with binary doubles.
        let exact = try await run("exact minimum", recognizer,
                                  Array(repeating: packet(400, value: 0.00001), count: 10))
        precondition(exact?.usedArchive == false && abs((exact?.audio.duration ?? 0) - 0.25) < 1e-9)

        let startsMuted = try await run("leading silence", recognizer,
                                        [packet(1_600, value: 0), packet(2_400)])
        precondition(startsMuted?.audio.transcript.segments.first?.start == 0.1)
        precondition(startsMuted?.audio.transcript.segments.last?.end == 0.25)
        let trace = await probe.lastTrace
        precondition(trace?.pcm.count == 2_400 + 1_280, "Leading silence or padding was miscounted.")

        let noSpeech = DictationAudioPipeline(archive: archive("no speech"), bufferCapacity: 8, recognize: { packets in
            for await _ in packets {}
            return nil
        }, replay: unexpectedReplay)
        try await noSpeech.append(packet(8_000))
        let result = try await noSpeech.finish()
        precondition(result == nil, "A healthy empty result was replayed.")
    }

    func checkMalformedPackets() async throws {
        let invalidPackets = [
            packet(64, rate: .nan), packet(64, rate: .infinity),
            packet(64, rate: .greatestFiniteMagnitude), packet(64, rate: 0),
            packet(0), packet(64, value: .nan), packet(64, value: .infinity),
            CapturedAudioPacket(source: .system, presentationTime: 0, sampleRate: 16_000, samples: [0.1]),
            CapturedAudioPacket(source: .microphone, presentationTime: .nan, sampleRate: 16_000, samples: [0.1])
        ]
        for (index, invalid) in invalidPackets.enumerated() {
            let writer = archive("malformed-\(index)")
            let pipeline = DictationAudioPipeline(archive: writer, bufferCapacity: 8, recognize: { packets in
                for await _ in packets { preconditionFailure("Invalid audio reached the recognition worker.") }
                return nil
            }, replay: unexpectedReplay)
            do {
                try await pipeline.append(invalid)
                preconditionFailure("Invalid packet was accepted.")
            } catch STTError.invalidAudio {}
            do {
                _ = try await pipeline.finish()
                preconditionFailure("A failed input was silently finalized.")
            } catch STTError.invalidAudio {}
            let files = try await writer.finish()
            precondition(files.isEmpty, "Invalid audio reached the archive.")
        }

        // A write failure after live recognition has been offered the audio
        // must also prevent a partial result.
        let blocked = root.appendingPathComponent("archive-is-a-file")
        try Data().write(to: blocked)
        let failed = DictationAudioPipeline(archive: AudioArchiveWriter(directoryURL: blocked.appendingPathComponent("audio")),
                                           bufferCapacity: 8, recognize: { packets in
            for await _ in packets {}
            return nil
        }, replay: unexpectedReplay)
        do {
            try await failed.append(packet(8_000))
            preconditionFailure("An archive write unexpectedly succeeded.")
        } catch is CocoaError {}
        do {
            _ = try await failed.finish()
            preconditionFailure("Dictation finalized after an archive write failure.")
        } catch is CocoaError {}
    }

    func checkBackpressure() async throws {
        for isSilent in [false, true] {
            let started = DictationTestSignal()
            let saturated = DictationAudioPipeline(archive: archive("overrun-\(isSilent)"),
                                                   bufferCapacity: 1, recognize: { _ in
                started.send()
                do { try await Task.sleep(for: .seconds(10)) }
                catch is CancellationError { return nil }
                preconditionFailure("Queue overflow did not cancel the worker.")
            }, replay: { urls in
                precondition(!isSilent, "Silent capture should never trigger replay.")
                precondition(urls.count == 2, "A rate switch lost an archive chunk.")
                return try await Self.replayArchive(urls)
            })
            try await started.wait()
            for rate in [16_000.0, 24_000] {
                for _ in 0..<4 {
                    try await saturated.append(packet(Int(rate / 10), rate: rate, value: isSilent ? 0 : 0.2))
                }
            }
            let result = try await saturated.finish()
            if isSilent {
                precondition(result == nil)
            } else {
                precondition(result?.usedArchive == true)
                precondition(abs((result?.audio.duration ?? 0) - 0.8) < 0.001, "Archive fallback lost packets.")
            }
        }
    }

    func checkCancellation() async throws {
        let liveFinishing = DictationTestSignal()
        let live = DictationAudioPipeline(archive: archive("cancel-live"), bufferCapacity: 8, recognize: { packets in
            for await _ in packets {}
            liveFinishing.send()
            try await Task.sleep(for: .seconds(10))
            preconditionFailure("Cancelled final inference kept running.")
        }, replay: unexpectedReplay)
        try await live.append(packet(8_000))
        let liveResult = Task { try await live.finish() }
        try await liveFinishing.wait()
        liveResult.cancel()
        try await expectCancelled { _ = try await liveResult.value }

        // Test both cancellation paths with replay already running and with
        // the replay worker throwing something other than CancellationError.
        for cancelCaller in [false, true] {
            let replayStarted = DictationTestSignal()
            let stopped = ReplayCancellationProbe()
            let pipeline = DictationAudioPipeline(archive: archive("cancel-replay-\(cancelCaller)"),
                                                  bufferCapacity: 8, recognize: { packets in
                for await _ in packets {}
                throw STTError.failed("Live recognition unavailable")
            }, replay: { urls in
                precondition(urls.count == 1)
                replayStarted.send()
                do { try await Task.sleep(for: .seconds(10)) }
                catch is CancellationError {
                    await stopped.markStopped()
                    throw STTError.failed("Replay worker interrupted")
                }
                preconditionFailure("Archive replay kept running after cancellation.")
            })
            try await pipeline.append(packet(8_000))
            let result = Task { try await pipeline.finish() }
            try await replayStarted.wait()
            if cancelCaller { result.cancel() }
            else {
                await pipeline.cancel()
                let replayDrained = await stopped.stopped
                precondition(replayDrained, "Cancel returned before replay stopped.")
            }
            try await expectCancelled { _ = try await result.value }
            let replayDrained = await stopped.stopped
            precondition(replayDrained)
        }
    }

    func checkCacheAndRepeatedStarts() async throws {
        let probe = DictationModelProbe()
        let recognizer = makeRecognizer(probe)
        _ = try await run("warm", recognizer, [packet(8_000)])
        _ = try await run("warm tap", recognizer, [packet(100)])

        let finishing = DictationTestSignal()
        await probe.blockNextFinish(finishing)
        let first = makePipeline("active", recognizer)
        try await first.append(packet(8_000))
        let result = Task { try await first.finish() }
        try await finishing.wait()
        await recognizer.releaseIfIdle() // In-flight state must survive this.

        let second = DictationAudioPipeline(archive: archive("overlapping"), recognizer: recognizer,
                                           configuration: .init(), replay: Self.replayArchive)
        try await second.append(packet(8_000))
        let fallback = try await second.finish()
        precondition(fallback?.usedArchive == true, "Two sessions accessed the same decoder.")

        await first.cancel()
        try await expectCancelled { _ = try await result.value }

        let config = TranscriptSegmentationConfiguration(maximumWordsPerSegment: 13, pauseThreshold: 2.5)
        let again = try await run("after cancel", recognizer, [packet(8_000)], configuration: config)
        precondition(again?.usedArchive == false)
        let warmCounts = await probe.counts
        let trace = await probe.lastTrace
        precondition(warmCounts == .init(loads: 1, starts: 3, resets: 3, cancels: 1))
        precondition(trace?.configuration == config && trace?.pcm.count == 8_000 + 1_280)

        await probe.failNextReset()
        let completed = try await run("reset failure", recognizer, [packet(8_000)])
        precondition(completed?.usedArchive == false, "Reset failure discarded a completed transcript.")
        _ = try await run("fresh after reset failure", recognizer, [packet(8_000)])
        let reloaded = await probe.loads
        precondition(reloaded == 2)
        await recognizer.releaseIfIdle()
        _ = try await run("fresh after manual release", recognizer, [packet(8_000)])
        let released = await probe.loads
        precondition(released == 3)

        let uncachedProbe = DictationModelProbe()
        let uncached = DictationRecognizer(idleRetention: .zero, loadModel: { await uncachedProbe.load() })
        _ = try await run("no retention 1", uncached, [packet(8_000)])
        _ = try await run("no retention 2", uncached, [packet(8_000)])
        let uncachedLoads = await uncachedProbe.loads
        precondition(uncachedLoads == 2)
    }

    func checkPCMAndWindows() async throws {
        let probe = DictationModelProbe()
        let recognizer = makeRecognizer(probe)
        // Exact pre-change converter input for a 900 ms 48 kHz hold. This
        // compares the model's PCM, including the final partial native batch.
        let short = (0..<18).map { index in
            CapturedAudioPacket(source: .microphone, presentationTime: Double(index) * 0.05, sampleRate: 48_000,
                                samples: (0..<2_400).map { Float(sin(Double(index * 2_400 + $0) * 0.063)) * 0.2 })
        }
        let reference = StreamingAudioResampler()
        var originalPCM: [Float] = []
        for range in [0..<5, 5..<9, 9..<13, 13..<17] {
            originalPCM += try await reference.resample(short[range].flatMap(\.samples), from: 48_000)
        }
        originalPCM += try await reference.resample(short[17].samples + Array(repeating: 0, count: 3_840), from: 48_000)
        _ = try await run("short 48 kHz", recognizer, short)
        let shortTrace = await probe.lastTrace
        precondition(shortTrace?.pcm.elementsEqual(originalPCM, by: { $0.bitPattern == $1.bitPattern }) == true,
                     "Final PCM changed for a fixed-rate 48 kHz hold.")
        precondition(originalPCM.count >= 14_400)

        // The different DC levels make a missing or padded tail visible
        // independently of the final transcript returned by the test model.
        let switched = [packet(15_360, rate: 48_000, value: 0.2), packet(2_560, value: 0.4),
                        packet(15_360, rate: 48_000, value: 0.6), packet(8_820, rate: 44_100, value: 0.8)]
        let result = try await run("rate changes", recognizer, switched)
        let trace = await probe.lastTrace
        precondition(abs((result?.audio.duration ?? 0) - 1) < 1e-9)
        guard let pcm = trace?.pcm, pcm.count >= 16_000 else { preconditionFailure("Rate change dropped audio.") }
        let boundaries: [(Int, Float)] = [(5_120, 0.2), (7_680, 0.4), (12_800, 0.6), (16_000, 0.8)]
        for (boundary, level) in boundaries {
            precondition(abs(pcm[boundary - 128] - level) < 0.04, "Audio just before a rate boundary was lost.")
        }

        for frames in [33_279, 33_280, 49_920] {
            _ = try await run("boundary-\(frames)", recognizer, [packet(frames)])
            let boundary = await probe.lastTrace
            let expectedLive = frames < 33_280 ? 0 : frames
            precondition(boundary?.liveFrames == expectedLive && boundary?.pcm.count == frames + 1_280)
            precondition(abs((boundary?.end ?? 0) - Double(frames) / 16_000) < 1e-9)
        }
    }

    private func makeRecognizer(_ probe: DictationModelProbe) -> DictationRecognizer {
        DictationRecognizer(idleRetention: .seconds(60), loadModel: { await probe.load() })
    }

    private func archive(_ name: String) -> AudioArchiveWriter {
        AudioArchiveWriter(directoryURL: root.appendingPathComponent(name))
    }

    private func makePipeline(_ name: String, _ recognizer: DictationRecognizer,
                              configuration: TranscriptSegmentationConfiguration = .init()) -> DictationAudioPipeline {
        DictationAudioPipeline(archive: archive(name), recognizer: recognizer, configuration: configuration, replay: unexpectedReplay)
    }

    private func run(_ name: String, _ recognizer: DictationRecognizer, _ packets: [CapturedAudioPacket],
                     configuration: TranscriptSegmentationConfiguration = .init()) async throws -> (audio: AudioFileTranscription, usedArchive: Bool)? {
        let pipeline = makePipeline(name, recognizer, configuration: configuration)
        for packet in packets { try await pipeline.append(packet) }
        return try await pipeline.finish()
    }

    private func packet(_ count: Int, rate: Double = 16_000, value: Float = 0.2) -> CapturedAudioPacket {
        CapturedAudioPacket(source: .microphone, presentationTime: 0, sampleRate: rate,
                            samples: Array(repeating: value, count: count))
    }

    private var unexpectedReplay: @Sendable ([URL]) async throws -> AudioFileTranscription {
        { _ in preconditionFailure("Unexpected archive replay.") }
    }

    private static func replayArchive(_ urls: [URL]) async throws -> AudioFileTranscription {
        try await AudioFileTranscriber(engine: MockSTTEngine()).transcribe(files: [.microphone: urls])
    }

    private func expectCancelled(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            preconditionFailure("A cancelled dictation produced a result.")
        } catch is CancellationError {}
    }
}

private struct DictationTestSignal: Sendable {
    private let pair = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))

    func send() {
        pair.continuation.yield(())
        pair.continuation.finish()
    }

    func wait() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in pair.stream { return } }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw STTError.failed("Timed out waiting for a dictation worker.")
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

private actor ReplayCancellationProbe {
    private(set) var stopped = false
    func markStopped() { stopped = true }
}

private actor DictationModelProbe: DictationRecognitionModel, DictationRecognitionSession {
    struct Counts: Equatable {
        var loads = 0
        var starts = 0
        var resets = 0
        var cancels = 0
    }

    struct Trace {
        let configuration: TranscriptSegmentationConfiguration
        let pcm: [Float]
        let liveFrames: Int
        let end: TimeInterval
    }

    private(set) var counts = Counts()
    var loads: Int { counts.loads }
    private(set) var lastTrace: Trace?
    private var configuration: TranscriptSegmentationConfiguration?
    private var pcm: [Float] = []
    private var failReset = false
    private var finishBlocked: DictationTestSignal?

    func load() -> any DictationRecognitionModel {
        counts.loads += 1
        configuration = nil
        pcm.removeAll()
        return self
    }

    func makeDictationSession(configuration: TranscriptSegmentationConfiguration) -> any DictationRecognitionSession {
        precondition(self.configuration == nil && pcm.isEmpty, "Warm decoder still contains audio or settings.")
        counts.starts += 1
        self.configuration = configuration
        return self
    }

    func append(samples: [Float], startTime: TimeInterval) { pcm += samples }

    func finishDictation(appending samples: [Float], startTime: TimeInterval, endTime: TimeInterval) async throws -> FinalTranscript {
        if let finishBlocked {
            self.finishBlocked = nil
            finishBlocked.send()
            try await Task.sleep(for: .seconds(10))
            preconditionFailure("The final decoder call was never cancelled.")
        }
        guard let configuration else { throw STTError.modelNotLoaded }
        lastTrace = Trace(configuration: configuration, pcm: pcm + samples, liveFrames: pcm.count, end: endTime)
        return FinalTranscript(segments: [.init(source: .microphone, start: startTime, end: endTime, text: "Last word.", isFinal: true)])
    }

    func cancel() { counts.cancels += 1 }
    func blockNextFinish(_ signal: DictationTestSignal) { finishBlocked = signal }
    func failNextReset() { failReset = true }

    func reset() throws {
        counts.resets += 1
        if failReset {
            failReset = false
            throw STTError.failed("Injected decoder reset failure")
        }
        pcm.removeAll()
        configuration = nil
    }
}

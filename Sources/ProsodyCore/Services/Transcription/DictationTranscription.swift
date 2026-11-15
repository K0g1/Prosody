import Foundation

/// Dictation has one microphone source and needs only the finalized transcript.
/// Capture can keep writing its fallback archive even while Core ML is loading.
@_spi(Validation)
public actor DictationAudioPipeline {
    public static let minimumDuration: TimeInterval = 0.25

    private let archive: AudioArchiveWriter
    private let replay: @Sendable ([URL]) async throws -> AudioFileTranscription
    private let input: AsyncStream<CapturedAudioPacket>.Continuation
    private let recognition: Task<AudioFileTranscription?, Error>
    private var archiveReplay: Task<AudioFileTranscription?, Error>?
    private var archiveWriteInFlight = false
    private var archiveWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var captureFailure: (any Error)?
    private var duration: TimeInterval = 0
    private var hasSignal = false
    private var liveInputLost = false
    private var ended = false
    private var cancelled = false

    public init(
        archive: AudioArchiveWriter,
        recognizer: DictationRecognizer,
        configuration: TranscriptSegmentationConfiguration,
        replay: (@Sendable ([URL]) async throws -> AudioFileTranscription)? = nil
    ) {
        self.init(archive: archive, bufferCapacity: 256, recognize: { packets in
            try await recognizer.transcribe(packets, configuration: configuration)
        }, replay: replay ?? { urls in
            try await AudioFileTranscriber(segmentationConfiguration: configuration).transcribe(files: [.microphone: urls])
        })
    }

    // Injection is used by the model-free validation harness to exercise
    // backpressure, cancellation, and archive replay deterministically.
    public init(
        archive: AudioArchiveWriter,
        bufferCapacity: Int,
        recognize: @escaping @Sendable (AsyncStream<CapturedAudioPacket>) async throws -> AudioFileTranscription?,
        replay: @escaping @Sendable ([URL]) async throws -> AudioFileTranscription
    ) {
        self.archive = archive
        self.replay = replay
        let (packets, input) = AsyncStream.makeStream(
            of: CapturedAudioPacket.self, bufferingPolicy: .bufferingOldest(max(1, bufferCapacity))
        )
        self.input = input
        recognition = Task(priority: .userInitiated) {
            defer { input.finish() }
            try Task.checkCancellation()
            return try await recognize(packets)
        }
    }

    deinit {
        recognition.cancel()
        input.finish()
        archiveReplay?.cancel()
    }

    /// Called by a single consumer in capture order.
    public func append(_ packet: CapturedAudioPacket) async throws {
        try Task.checkCancellation()
        guard !ended, !cancelled else { throw STTError.sessionFinished }
        if let captureFailure { throw captureFailure }
        guard !archiveWriteInFlight else {
            throw STTError.failed("Dictation packets must be submitted in capture order.")
        }
        do {
            // Validate before either consumer sees the packet. In particular,
            // an enormous finite rate would overflow the archive's frame limit.
            try Self.validate(packet)
            if !liveInputLost {
                switch input.yield(packet) {
                case .enqueued: break
                case .dropped, .terminated:
                    // Never paste a truncated transcript. Capture keeps writing
                    // the archive even when inference falls behind or fails.
                    liveInputLost = true
                    recognition.cancel()
                    input.finish()
                @unknown default:
                    liveInputLost = true
                    recognition.cancel()
                    input.finish()
                }
            }
            archiveWriteInFlight = true
            defer {
                archiveWriteInFlight = false
                let waiters = archiveWriteWaiters
                archiveWriteWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
            try await archive.append(packet)
        } catch {
            captureFailure = error
            recognition.cancel()
            input.finish()
            throw error
        }
        duration += Double(packet.samples.count) / packet.sampleRate
        if !hasSignal { hasSignal = packet.samples.contains { $0 != 0 } }
        try checkCancellation()
    }

    public func finish() async throws -> (audio: AudioFileTranscription, usedArchive: Bool)? {
        guard !ended, !cancelled else { throw STTError.sessionFinished }
        ended = true
        input.finish()
        let recognition = self.recognition
        let result: Result<AudioFileTranscription?, any Error>? = try await withTaskCancellationHandler {
            await waitForArchiveWrite()
            let hasSpeechCandidate = hasSignal && Self.reachesMinimum(duration)
            if !hasSpeechCandidate { recognition.cancel() }
            let result = await recognition.result
            try checkCancellation()
            if let captureFailure { throw captureFailure }
            return hasSpeechCandidate ? result : nil
        } onCancel: {
            recognition.cancel()
        }
        try checkCancellation()
        guard let result else { return nil }
        if !liveInputLost, case .success(let audio) = result { return audio.map { ($0, false) } }

        AppLogger.dictationLatency.info("Streaming unavailable; replaying full dictation archive (live input interrupted=\(self.liveInputLost, privacy: .public))")
        let replayJob = Task<AudioFileTranscription?, Error>(priority: .userInitiated) { [archive, replay] in
            try Task.checkCancellation()
            let urls = try await archive.finish()
            try Task.checkCancellation()
            guard !urls.isEmpty else { return nil }
            return try await replay(urls)
        }
        archiveReplay = replayJob
        defer { archiveReplay = nil }
        let replayResult = await withTaskCancellationHandler {
            await replayJob.result
        } onCancel: {
            replayJob.cancel()
        }
        try checkCancellation()
        return try replayResult.get().map { ($0, true) }
    }

    /// Stops both recognition paths and drains any current archive write before
    /// the controller discards the temporary audio.
    public func cancel() async {
        cancelled = true
        recognition.cancel()
        input.finish()
        let replayJob = archiveReplay
        replayJob?.cancel()
        _ = await recognition.result
        _ = await replayJob?.result
        await waitForArchiveWrite()
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func waitForArchiveWrite() async {
        if archiveWriteInFlight {
            await withCheckedContinuation { archiveWriteWaiters.append($0) }
        }
    }

    private static func validate(_ packet: CapturedAudioPacket) throws {
        guard packet.source == .microphone, packet.presentationTime.isFinite,
              (1_000...384_000).contains(packet.sampleRate),
              !packet.samples.isEmpty, packet.samples.count < Int(UInt32.max),
              packet.samples.allSatisfy(\.isFinite) else { throw STTError.invalidAudio }
    }

    static func reachesMinimum(_ duration: TimeInterval) -> Bool {
        // A mathematically exact threshold can be a few ULPs under 250 ms
        // when summed packet by packet. A nanosecond is below a PCM sample.
        duration >= minimumDuration - 1e-9
    }
}

@_spi(Validation)
public protocol DictationRecognitionSession: Sendable {
    func append(samples: [Float], startTime: TimeInterval) async throws
    func finishDictation(appending samples: [Float], startTime: TimeInterval, endTime: TimeInterval) async throws -> FinalTranscript
    func cancel() async
}

@_spi(Validation)
public protocol DictationRecognitionModel: Sendable {
    func makeDictationSession(configuration: TranscriptSegmentationConfiguration) async throws -> any DictationRecognitionSession
    func reset() async throws
}

/// Owns a single short-lived, local model cache for consecutive dictations.
/// Nothing loads at launch; the cache never runs inference between utterances.
@_spi(Validation)
public actor DictationRecognizer {
    private let idleRetention: Duration
    private let loadModel: @Sendable () async throws -> any DictationRecognitionModel
    private var model: (any DictationRecognitionModel)?
    private var eviction: Task<Void, Never>?
    private var recognizing = false
    private var modelInUse = false

    public init(idleRetention: Duration = .seconds(20)) {
        self.init(idleRetention: idleRetention, loadModel: { try await ParakeetDictationModel.loadInstalled() })
    }

    public init(
        idleRetention: Duration,
        loadModel: @escaping @Sendable () async throws -> any DictationRecognitionModel
    ) {
        self.idleRetention = idleRetention
        self.loadModel = loadModel
    }

    deinit { eviction?.cancel() }

    public func releaseIfIdle() {
        guard !modelInUse else { return }
        eviction?.cancel()
        eviction = nil
        model = nil
    }

    func transcribe(
        _ packets: AsyncStream<CapturedAudioPacket>,
        configuration: TranscriptSegmentationConfiguration
    ) async throws -> AudioFileTranscription? {
        try Task.checkCancellation()
        guard !recognizing else { throw STTError.failed("Dictation recognition is already running.") }
        recognizing = true
        defer {
            recognizing = false
            if modelInUse {
                modelInUse = false
                if model != nil { scheduleEviction() }
            }
        }

        var session: (any DictationRecognitionSession)?
        var rateRun: DictationSampleRateRun?
        var pending: [Float] = []
        var duration: TimeInterval = 0
        var audioOrigin: TimeInterval?
        let windows = ParakeetStreamingSession.dictationWindows
        var samplesUntilWindow = windows.first
        let audio: AudioFileTranscription
        do {
            for await packet in packets {
                try Task.checkCancellation()
                let packetStart = duration
                duration += Double(packet.samples.count) / packet.sampleRate
                if audioOrigin == nil {
                    // A muted digital input can otherwise yield a stray word.
                    // Skip exact zeros only; quiet speech is still recognized.
                    guard packet.samples.contains(where: { $0 != 0 }) else { continue }
                    audioOrigin = packetStart
                }
                if rateRun?.rate != packet.sampleRate {
                    if let previous = rateRun { pending += try await previous.flush() }
                    rateRun = DictationSampleRateRun(rate: packet.sampleRate)
                }
                rateRun?.append(packet.samples)
                // Avoid loading the model for accidental taps. Once a real
                // utterance starts, load it in parallel with ongoing capture.
                if session == nil, DictationAudioPipeline.reachesMinimum(duration) {
                    session = try await makeSession(configuration: configuration)
                }
                if session != nil, let converted = try await rateRun?.convertBatchIfReady() {
                    pending += converted
                }
                // Wait until a whole encoder window can advance. Smaller
                // packets would just copy samples into Core ML's buffer.
                if let session, pending.count >= samplesUntilWindow {
                    let surplus = (pending.count - samplesUntilWindow) % windows.stride
                    samplesUntilWindow = windows.stride - surplus
                    try await session.append(samples: pending, startTime: audioOrigin ?? 0)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            guard let session, let audioOrigin, let rateRun else { return nil }
            // Preserve the established final PCM for an unchanged input rate:
            // one frame of native silence to drain the converter and provide
            // context. This silence is never part of the saved audio.
            let finalContext = Double(windows.frame) / AudioSampleConverter.speechSampleRate
            pending += try await rateRun.flush(finalContext: finalContext)
            // Finish with the unprocessed tail and release the model's right
            // context, even when the key goes up mid-word or on a boundary.
            let final = try await session.finishDictation(appending: pending, startTime: audioOrigin, endTime: duration)
            try Task.checkCancellation()
            audio = AudioFileTranscription(transcript: Transcript(segments: final.segments), duration: duration)
        } catch {
            await session?.cancel()
            if modelInUse {
                if Task.isCancelled || error is CancellationError { await resetCachedModel() }
                else { model = nil }
            }
            throw error
        }
        await resetCachedModel()
        try Task.checkCancellation()
        return audio
    }

    private func makeSession(
        configuration: TranscriptSegmentationConfiguration
    ) async throws -> any DictationRecognitionSession {
        try Task.checkCancellation()
        modelInUse = true
        eviction?.cancel()
        eviction = nil
        if model == nil { model = try await loadModel() }
        try Task.checkCancellation()
        guard let model else { throw STTError.modelNotLoaded }
        return try await model.makeDictationSession(configuration: configuration)
    }

    private func resetCachedModel() async {
        // The worker has stopped using the session before the decoder is
        // reset. Keep weights only if all utterance state could be cleared.
        do { try await model?.reset() }
        catch { model = nil }
    }

    private func scheduleEviction() {
        guard idleRetention > .zero else { releaseIfIdle(); return }
        eviction = Task { [weak self, idleRetention] in
            do { try await Task.sleep(for: idleRetention) } catch { return }
            await self?.evictExpiredModel()
        }
    }

    private func evictExpiredModel() {
        guard !Task.isCancelled else { return }
        releaseIfIdle()
    }
}

/// Converter state belongs to one uninterrupted native sample-rate run.
/// Flushing before switching preserves the old rate's buffered real audio,
/// including switches through the 16 kHz pass-through path.
private struct DictationSampleRateRun {
    let rate: Double
    private let resampler = StreamingAudioResampler()
    private var batch: [Float] = []
    private var inputFrames = 0
    private var outputFrames = 0

    init(rate: Double) { self.rate = rate }

    mutating func append(_ samples: [Float]) {
        batch += samples
        inputFrames += samples.count
    }

    mutating func convertBatchIfReady() async throws -> [Float] {
        guard Double(batch.count) >= rate * 0.16 else { return [] }
        let result = try await resampler.resample(batch, from: rate)
        batch.removeAll(keepingCapacity: true)
        outputFrames += result.count
        return result
    }

    func flush(finalContext: TimeInterval = 0) async throws -> [Float] {
        if rate == AudioSampleConverter.speechSampleRate, finalContext == 0 { return batch }
        let expected = Int((Double(inputFrames) * AudioSampleConverter.speechSampleRate / rate).rounded())
        let remaining = max(0, expected - outputFrames)
        guard remaining > 0 || finalContext > 0 else { return [] }
        var input = batch
        // AVAudioConverter may defer a block of output across calls. Supply
        // enough context to drain it. At a rate change, discard all synthetic
        // output so the next rate starts at the correct sample.
        let padding = finalContext > 0 ? finalContext : 0.16
        input += repeatElement(Float.zero, count: Int((rate * padding).rounded()))
        var converted = try await resampler.resample(input, from: rate)
        if converted.count < remaining, finalContext > 0 {
            let tail = try await resampler.resample(
                Array(repeating: 0, count: Int((rate * 0.16).rounded())), from: rate)
            converted += tail.prefix(remaining - converted.count)
        }
        guard converted.count >= remaining else { throw STTError.invalidAudio }
        return finalContext > 0 ? converted : Array(converted.prefix(remaining))
    }
}

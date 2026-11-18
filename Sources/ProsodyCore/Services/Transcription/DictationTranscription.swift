import Foundation

/// Dictation has one microphone source and needs only the finalized transcript.
/// Capture can keep writing its fallback archive even while Core ML is loading.
@_spi(Validation)
public actor DictationAudioPipeline {
    public static let minimumDuration: TimeInterval = 0.25

    private let archive: AudioArchiveWriter
    private let replay: @Sendable ([URL]) async throws -> AudioFileTranscription
    private let finishScope: (@Sendable () async -> Void)?
    private let input: AsyncStream<CapturedAudioPacket>.Continuation
    private let recognition: Task<AudioFileTranscription?, Error>
    private var archiveReplay: Task<AudioFileTranscription?, Error>?
    private var archiveWriteInFlight = false
    private var archiveWriteWaiters: [CheckedContinuation<Void, Never>] = []
    private var captureFailure: (any Error)?
    private var duration: TimeInterval = 0
    private var archivedDuration: TimeInterval = 0
    private var hasSignal = false
    private var liveInputLost = false
    private var ended = false
    private var cancelled = false
    private var scopeFinished = false
    private var scopeFinishTask: Task<Void, Never>?

    public init(
        archive: AudioArchiveWriter,
        recognizer: DictationRecognizer,
        configuration: TranscriptSegmentationConfiguration,
        replay: (@Sendable ([URL]) async throws -> AudioFileTranscription)? = nil
    ) {
        let scope = UUID()
        self.init(archive: archive, bufferCapacity: 256, recognize: { packets in
            try await recognizer.transcribe(
                packets, configuration: configuration, scope: scope
            )
        }, replay: replay ?? { urls in
            try await recognizer.replayArchive(
                urls, configuration: configuration, scope: scope
            )
        }, finishScope: {
            await recognizer.finishScope(scope)
        })
    }

    // Injection is used by the model-free validation harness to exercise
    // backpressure, cancellation, and archive replay deterministically.
    public init(
        archive: AudioArchiveWriter,
        bufferCapacity: Int,
        recognize: @escaping @Sendable (AsyncStream<CapturedAudioPacket>) async throws -> AudioFileTranscription?,
        replay: @escaping @Sendable ([URL]) async throws -> AudioFileTranscription,
        finishScope: (@Sendable () async -> Void)? = nil
    ) {
        self.archive = archive
        self.replay = replay
        self.finishScope = finishScope
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
        input.finish()
        let recognition = self.recognition
        let replay = archiveReplay
        recognition.cancel()
        replay?.cancel()
        if !scopeFinished, let finishScope {
            Task {
                _ = await recognition.result
                _ = await replay?.result
                await finishScope()
            }
        }
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
            // Publish capture state before the archive actor suspends. finish()
            // can then decide whether a short/silent no-op needs cancellation
            // without waiting behind an in-flight AAC write.
            duration += Double(packet.samples.count) / packet.sampleRate
            if !hasSignal { hasSignal = packet.samples.contains { $0 != 0 } }
            archiveWriteInFlight = true
            defer {
                archiveWriteInFlight = false
                let waiters = archiveWriteWaiters
                archiveWriteWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
            try await archive.append(packet)
            archivedDuration += Double(packet.samples.count) / packet.sampleRate
        } catch {
            captureFailure = error
            recognition.cancel()
            input.finish()
            throw error
        }
        try checkCancellation()
    }

    public func finish() async throws -> (audio: AudioFileTranscription, usedArchive: Bool)? {
        guard !ended, !cancelled else { throw STTError.sessionFinished }
        ended = true
        do {
            let result = try await finishOnce()
            await finishScopeOnce()
            return result
        } catch {
            await finishScopeOnce()
            throw error
        }
    }

    private func finishOnce() async throws -> (audio: AudioFileTranscription, usedArchive: Bool)? {
        input.finish()
        let recognition = self.recognition
        let hasSpeechCandidate = hasSignal && Self.reachesMinimum(duration)
        // A short or silent capture has no reason to retain a model operation.
        // Cancel it before waiting for archive I/O so a no-op pipeline can
        // complete promptly even if a shared preparation is still running.
        if !hasSpeechCandidate { recognition.cancel() }
        let result: Result<AudioFileTranscription?, any Error>? = try await withTaskCancellationHandler {
            await waitForArchiveWrite()
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
        await finishScopeOnce()
    }

    /// Successful PCM duration written to the fallback archive. Call after the
    /// capture feed has drained when deciding whether recovery audio is useful.
    public func capturedDuration() -> TimeInterval {
        archivedDuration
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

    private func finishScopeOnce() async {
        if let scopeFinishTask {
            await scopeFinishTask.value
            return
        }
        guard !scopeFinished else { return }
        scopeFinished = true
        guard let finishScope else { return }
        let task = Task { await finishScope() }
        scopeFinishTask = task
        await task.value
        scopeFinishTask = nil
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
    func unload() async
}

extension DictationRecognitionModel {
    /// Existing test models only need reset. Native models override this to
    /// release their Core ML resources as well.
    public func unload() async { try? await reset() }
}

@_spi(Validation)
public enum DictationRecognitionPhase: Sendable, Equatable {
    case preparingModel
    case transcribing
}

/// Owns the shared local model for live dictation and archive replay. Loading
/// can start before capture; inference runs only for a dictation request.
@_spi(Validation)
public actor DictationRecognizer {
    /// Keep the prepared model across short work pauses.
    /// The resident weights are clean model mappings, spend no CPU idle, and
    /// are released before recording/import or after this bounded five-minute
    /// window.
    public static let defaultIdleRetention: Duration = .seconds(300)

    private let modelCache: DictationModelCache<any DictationRecognitionModel>
    private var recognizing = false
    private var scopeLoadFailures: [UUID: any Error] = [:]

    public init(idleRetention: Duration = defaultIdleRetention) {
        self.init(idleRetention: idleRetention, loadModel: { try await ParakeetDictationModel.loadInstalled() })
    }

    public init(
        idleRetention: Duration,
        loadModel: @escaping @Sendable () async throws -> any DictationRecognitionModel
    ) {
        modelCache = DictationModelCache(
            idleRetention: idleRetention,
            load: loadModel,
            unload: { model in await model.unload() }
        )
    }

    /// Starts the one local installed-model flight in the background. This
    /// entry point never waits for FluidAudio to finish loading weights.
    public func prepare() async {
        await modelCache.prewarm()
    }

    /// Observes whether the shared model preparation flight is active.
    func modelPreparationUpdates() async -> AsyncStream<Bool> {
        await modelCache.modelPreparationUpdates()
    }

    public func waitUntilPrepared() async throws {
        try await modelCache.waitUntilPrepared()
    }

    public func releaseIfIdle() async {
        await modelCache.releaseIfIdle()
    }

    public func finishScope(_ scope: UUID) async {
        scopeLoadFailures[scope] = nil
        await modelCache.endScope(scope)
    }

    @_spi(Validation)
    public func transcribe(
        _ packets: AsyncStream<CapturedAudioPacket>,
        configuration: TranscriptSegmentationConfiguration,
        scope: UUID? = nil,
        onPhase: @Sendable (DictationRecognitionPhase) -> Void = { _ in }
    ) async throws -> AudioFileTranscription? {
        try Task.checkCancellation()
        guard !recognizing else { throw STTError.failed("Dictation recognition is already running.") }
        recognizing = true
        defer { recognizing = false }
        if let scope {
            scopeLoadFailures[scope] = nil
        }

        var session: (any DictationRecognitionSession)?
        var lease: DictationModelLease<any DictationRecognitionModel>?
        var rateRun: DictationSampleRateRun?
        var pending: [Float] = []
        var duration: TimeInterval = 0
        var audioOrigin: TimeInterval?
        let windows = ParakeetStreamingSession.dictationWindows
        var samplesUntilWindow = windows.first
        var didAttemptModelPreparation = false
        var announcedTranscribing = false
        var scopeStarted = false
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
                    didAttemptModelPreparation = true
                    if let scope, !scopeStarted {
                        await modelCache.beginScope(scope)
                        scopeStarted = true
                    }
                    let preparedLease = try await acquireModel(onPhase: onPhase)
                    lease = preparedLease
                    session = try await makeSession(
                        configuration: configuration, lease: preparedLease
                    )
                }
                if session != nil, let converted = try await rateRun?.convertBatchIfReady() {
                    pending += converted
                }
                // Wait until a whole encoder window can advance. Smaller
                // packets would just copy samples into Core ML's buffer.
                if let session, pending.count >= samplesUntilWindow {
                    let surplus = (pending.count - samplesUntilWindow) % windows.stride
                    samplesUntilWindow = windows.stride - surplus
                    if !announcedTranscribing {
                        onPhase(.transcribing)
                        announcedTranscribing = true
                    }
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
            if !announcedTranscribing {
                onPhase(.transcribing)
                announcedTranscribing = true
            }
            let final = try await session.finishDictation(appending: pending, startTime: audioOrigin, endTime: duration)
            try Task.checkCancellation()
            audio = AudioFileTranscription(transcript: Transcript(segments: final.segments), duration: duration)
        } catch {
            let wasCancelled = Task.isCancelled || error is CancellationError
            await session?.cancel()
            if let lease {
                if await resetModel(lease) { await modelCache.endUse(lease.id) }
            } else if !wasCancelled, didAttemptModelPreparation, let scope {
                // A failed cold load must not be retried immediately by archive
                // fallback within the same pipeline scope. A later explicit
                // dictation gets a new scope and can start a fresh flight.
                scopeLoadFailures[scope] = error
            }
            throw error
        }
        if let lease { await finishModelUse(lease) }
        try Task.checkCancellation()
        return audio
    }

    @_spi(Validation)
    public func replayArchive(
        _ urls: [URL],
        configuration: TranscriptSegmentationConfiguration,
        scope: UUID? = nil,
        onPhase: @Sendable (DictationRecognitionPhase) -> Void = { _ in }
    ) async throws -> AudioFileTranscription {
        try Task.checkCancellation()
        guard !urls.isEmpty else { throw STTError.invalidAudio }
        guard !recognizing else { throw STTError.failed("Dictation recognition is already running.") }
        recognizing = true
        defer { recognizing = false }
        if let scope {
            await modelCache.beginScope(scope)
            if let failure = scopeLoadFailures[scope] { throw failure }
        }

        var session: (any DictationRecognitionSession)?
        var lease: DictationModelLease<any DictationRecognitionModel>?
        var announcedTranscribing = false
        do {
            let preparedLease = try await acquireModel(onPhase: onPhase)
            lease = preparedLease
            let preparedSession = try await makeSession(
                configuration: configuration, lease: preparedLease
            )
            session = preparedSession

            var reader = AudioFilePCMReader(urls: urls, source: .microphone)
            while let chunk = try await reader.next() {
                try Task.checkCancellation()
                if !chunk.samples.isEmpty {
                    if !announcedTranscribing {
                        onPhase(.transcribing)
                        announcedTranscribing = true
                    }
                    try await preparedSession.append(samples: chunk.samples, startTime: chunk.startTime)
                }
            }
            if !announcedTranscribing {
                onPhase(.transcribing)
                announcedTranscribing = true
            }
            let final = try await preparedSession.finishDictation(
                appending: [], startTime: 0, endTime: reader.duration
            )
            try Task.checkCancellation()
            let audio = AudioFileTranscription(
                transcript: Transcript(segments: final.segments),
                duration: reader.duration
            )
            if let lease { await finishModelUse(lease) }
            lease = nil
            return audio
        } catch {
            await session?.cancel()
            if let lease { await finishModelUse(lease) }
            throw error
        }
    }

    private func acquireModel(
        onPhase: @Sendable (DictationRecognitionPhase) -> Void
    ) async throws -> DictationModelLease<any DictationRecognitionModel> {
        try Task.checkCancellation()
        return try await modelCache.acquire {
            onPhase(.preparingModel)
        }
    }

    private func makeSession(
        configuration: TranscriptSegmentationConfiguration,
        lease: DictationModelLease<any DictationRecognitionModel>
    ) async throws -> any DictationRecognitionSession {
        try Task.checkCancellation()
        let session = try await lease.model.makeDictationSession(configuration: configuration)
        try Task.checkCancellation()
        return session
    }

    private func finishModelUse(
        _ lease: DictationModelLease<any DictationRecognitionModel>
    ) async {
        // The session has stopped processing before this actor reaches reset.
        // Keep the shared weights only when all utterance state was cleared.
        if await resetModel(lease) { await modelCache.endUse(lease.id) }
    }

    private func resetModel(
        _ lease: DictationModelLease<any DictationRecognitionModel>
    ) async -> Bool {
        do {
            try await lease.model.reset()
            return true
        } catch {
            await modelCache.invalidate(lease.id)
            return false
        }
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

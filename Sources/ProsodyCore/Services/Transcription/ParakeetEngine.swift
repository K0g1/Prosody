@preconcurrency import AVFoundation
import Foundation

import FluidAudio

public enum ParakeetEngineError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedModel(String)
    case modelNotPrepared
    case modelUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel(let id): return "Parakeet model \(id) is unsupported."
        case .modelNotPrepared: return "Parakeet is not prepared."
        case .modelUnavailable(let message): return message
        }
    }
}

/// FluidAudio is intentionally confined to this adapter. The rest of Prosody
/// only consumes STTEngine/STTSession and remains insulated from package API
/// changes.
public actor ParakeetEngine: STTEngine {
    public nonisolated let descriptor = STTEngineDescriptor(
        id: .parakeet,
        displayName: "Parakeet",
        detail: "On-device speech recognition"
    )

    private let segmentationConfiguration: TranscriptSegmentationConfiguration
    private let installedModelURL: @Sendable (SpeechModel) async throws -> URL
    private let loadUnifiedManager: @Sendable (URL) async throws -> StreamingUnifiedAsrManager
    private var generation: UInt64 = 0
    private var openingSources: Set<AudioSource> = []
    private var sessions: [AudioSource: any ParakeetEngineSession] = [:]
    private var modelDirectory: URL?
    private var managers: [AudioSource: StreamingUnifiedAsrManager] = [:]
    private var preparedManager: StreamingUnifiedAsrManager?
    private var batchModel: BatchParakeetModel?

    public init(
        segmentationConfiguration: TranscriptSegmentationConfiguration = .persisted(),
        inventory: STTModelManager = STTModelManager()
    ) {
        self.init(
            segmentationConfiguration: segmentationConfiguration,
            installedModelURL: { try await inventory.installedURL(for: $0) },
            loadUnifiedManager: ParakeetDictationModel.loadManager(from:)
        )
    }

    init(
        segmentationConfiguration: TranscriptSegmentationConfiguration = .init(),
        installedModelURL: @escaping @Sendable (SpeechModel) async throws -> URL,
        loadUnifiedManager: @escaping @Sendable (URL) async throws -> StreamingUnifiedAsrManager
    ) {
        self.segmentationConfiguration = segmentationConfiguration
        self.installedModelURL = installedModelURL
        self.loadUnifiedManager = loadUnifiedManager
    }

    public func prepare(
        model: STTModelDescriptor,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard let speechModel = SpeechModel(descriptor: model) else {
            throw ParakeetEngineError.unsupportedModel(model.id)
        }
        try Task.checkCancellation()
        let newGeneration = generation &+ 1
        await unload()
        try checkGeneration(newGeneration)
        let directory = try await installedModelURL(speechModel)
        try checkGeneration(newGeneration)
        if speechModel == .unified {
            let manager = try await loadUnifiedManager(directory)
            do {
                try checkGeneration(newGeneration)
            } catch {
                await manager.cleanup()
                throw error
            }
            preparedManager = manager
            modelDirectory = directory
        } else {
            let model = try await BatchParakeetModel.load(speechModel, from: directory)
            do {
                try checkGeneration(newGeneration)
            } catch {
                await model.unload()
                throw error
            }
            batchModel = model
        }
        progress(1)
    }

    public func makeSession(source: AudioSource) async throws -> any STTSession {
        try Task.checkCancellation()
        guard batchModel != nil || modelDirectory != nil else {
            throw ParakeetEngineError.modelNotPrepared
        }
        guard openingSources.insert(source).inserted else { throw Self.sourceInUse }
        let currentGeneration = generation
        defer {
            if generation == currentGeneration { openingSources.remove(source) }
        }

        if let session = sessions[source] {
            guard await session.hasEnded else { throw Self.sourceInUse }
            try checkGeneration(currentGeneration)
        }

        let session: any ParakeetEngineSession
        if let batchModel {
            session = batchModel.makeSession(source: source, configuration: segmentationConfiguration)
        } else if let modelDirectory {
            // Own the manager locally across loading/reset. Unload invalidates
            // this reservation, and this invocation cleans up any late result.
            let manager: StreamingUnifiedAsrManager
            if let cached = managers.removeValue(forKey: source) {
                manager = cached
                do {
                    try await manager.reset()
                } catch {
                    await manager.cleanup()
                    throw error
                }
            } else if let preparedManager {
                self.preparedManager = nil
                manager = preparedManager
            } else {
                manager = try await loadUnifiedManager(modelDirectory)
            }
            do {
                try checkGeneration(currentGeneration)
            } catch {
                await manager.cleanup()
                throw error
            }
            managers[source] = manager
            session = ParakeetStreamingSession(
                source: source, manager: manager, segmentationConfiguration: segmentationConfiguration
            )
        } else {
            throw ParakeetEngineError.modelNotPrepared
        }
        sessions[source] = session
        return session
    }

    public func unload() async {
        // Detach the old generation before the first suspension.
        generation &+= 1
        let sessions = self.sessions
        let managers = self.managers
        let preparedManager = self.preparedManager
        let batchModel = self.batchModel
        self.sessions.removeAll()
        self.managers.removeAll()
        self.preparedManager = nil
        self.batchModel = nil
        modelDirectory = nil
        openingSources.removeAll()

        for session in sessions.values { await session.cancel() }
        for manager in managers.values { await manager.cleanup() }
        await preparedManager?.cleanup()
        await batchModel?.unload()
    }

    private static let sourceInUse = STTError.failed("Parakeet is already in use for this audio source.")

    private func checkGeneration(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
    }
}

protocol ParakeetEngineSession: STTSession {
    var hasEnded: Bool { get async }
}

/// The recognizer leases a local model across live input and archive replay.
struct ParakeetDictationModel: DictationRecognitionModel {
    private let manager: StreamingUnifiedAsrManager

    static let missingModelMessage = "Install Parakeet Unified in Settings → Models before using dictation."

    static func loadInstalled(
        _ model: SpeechModel = .unified, inventory: STTModelManager = STTModelManager()
    ) async throws -> any DictationRecognitionModel {
        let directory = try await inventory.installedURL(for: model)
        if model != .unified { return try await BatchParakeetModel.load(model, from: directory) }
        return try await Self(manager: loadManager(from: directory))
    }

    static func loadManager(from directory: URL) async throws -> StreamingUnifiedAsrManager {
        try Task.checkCancellation()
        let manager = StreamingUnifiedAsrManager()
        try await manager.loadModels(from: directory)
        return manager
    }

    func makeDictationSession(configuration: TranscriptSegmentationConfiguration) -> any DictationRecognitionSession {
        ParakeetStreamingSession(source: .microphone, manager: manager,
                                 segmentationConfiguration: configuration, publishesUpdates: false)
    }

    func reset() async throws { try await manager.reset() }
    func unload() async { await manager.cleanup() }
}

public actor ParakeetStreamingSession: STTSession, ParakeetEngineSession {
    public nonisolated let updates: AsyncStream<STTUpdate>

    static let dictationWindows: (first: Int, stride: Int, frame: Int) = {
        let config = UnifiedConfig()
        return (config.chunkSamples + config.rightSamples, config.chunkSamples, config.frameSamples)
    }()

    private let continuation: AsyncStream<STTUpdate>.Continuation
    private let source: AudioSource
    private let manager: StreamingUnifiedAsrManager
    private let publishesUpdates: Bool
    private var isFinished = false
    private var finishing = false
    private var processing = false
    private var processingWaiters: [CheckedContinuation<Void, Never>] = []
    private var assembler: StreamingTranscriptAssembler
    private var timeline = ParakeetAudioTimeline()

    var hasEnded: Bool { isFinished && !processing }

    public init(
        source: AudioSource,
        manager: StreamingUnifiedAsrManager,
        segmentationConfiguration: TranscriptSegmentationConfiguration = .init(),
        publishesUpdates: Bool = true
    ) {
        self.source = source
        self.manager = manager
        self.publishesUpdates = publishesUpdates
        self.assembler = StreamingTranscriptAssembler(
            source: source,
            configuration: segmentationConfiguration
        )
        var continuation: AsyncStream<STTUpdate>.Continuation!
        self.updates = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func append(samples: [Float], startTime: TimeInterval) async throws {
        try beginProcessing()
        defer { endProcessing() }
        try await bufferAudio(samples, startTime: startTime)
        try checkProcessing()
        try await manager.processBufferedAudio()
        try checkProcessing()
        try await assembleTokens()
    }

    @_spi(Validation)
    public func finishDictation(appending samples: [Float], startTime: TimeInterval, endTime: TimeInterval) async throws -> FinalTranscript {
        guard startTime.isFinite, startTime >= 0, endTime.isFinite, endTime >= startTime,
              endTime >= (timeline.startTime ?? startTime) else { throw STTError.invalidAudio }
        return try await finish(appending: samples, startTime: startTime, tokenEndLimit: endTime)
    }

    private func bufferAudio(_ samples: [Float], startTime: TimeInterval) async throws {
        guard !samples.isEmpty, samples.count < Int(UInt32.max), samples.allSatisfy(\Float.isFinite),
              startTime.isFinite, startTime >= 0 else {
            throw STTError.invalidAudio
        }
        let buffer = try makeBuffer(samples: samples)
        try await manager.appendAudio(buffer)
        timeline.append(sampleCount: samples.count, startTime: startTime)
    }

    public func finish() async throws -> FinalTranscript {
        try await finish(appending: [], startTime: 0, tokenEndLimit: .infinity)
    }

    private func finish(appending samples: [Float], startTime: TimeInterval, tokenEndLimit: TimeInterval) async throws -> FinalTranscript {
        try Task.checkCancellation()
        guard !isFinished, !finishing else { throw STTError.sessionFinished }
        finishing = true
        if processing { await waitForProcessing() }
        processing = true
        defer {
            isFinished = true
            continuation.finish()
            endProcessing()
        }
        try checkProcessing()
        // Hand the last audio to finish without processing it as a non-final
        // window first. This avoids re-encoding on an exact chunk boundary.
        if !samples.isEmpty { try await bufferAudio(samples, startTime: startTime) }
        try checkProcessing()
        _ = try await manager.finish()
        try checkProcessing()
        try await assembleTokens(endLimit: tokenEndLimit)
        if let segment = assembler.flush(), publishesUpdates {
            continuation.yield(.final(source: source, segment: segment))
        }
        if publishesUpdates { continuation.yield(.status(.finished)) }
        return FinalTranscript(segments: assembler.finalized)
    }

    public func cancel() async {
        isFinished = true
        continuation.finish()
        // Core ML may be between suspension points. Don't let a caller reset
        // or unload this manager until that in-flight operation has returned.
        if processing { await waitForProcessing() }
    }

    private func waitForProcessing() async {
        await withCheckedContinuation { processingWaiters.append($0) }
    }

    private func beginProcessing() throws {
        try Task.checkCancellation()
        guard !isFinished, !finishing else { throw STTError.sessionFinished }
        guard !processing else { throw STTError.failed("Parakeet is already processing audio for this session.") }
        processing = true
    }

    private func checkProcessing() throws {
        try Task.checkCancellation()
        if isFinished { throw CancellationError() }
    }

    private func endProcessing() {
        processing = false
        let waiters = processingWaiters
        processingWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func assembleTokens(endLimit: TimeInterval = .infinity) async throws {
        let tokens = await manager.consumeTokenTimings()
        try checkProcessing()
        guard !tokens.isEmpty else { return }
        let endLimit = min(endLimit, timeline.endTime ?? endLimit)
        for token in tokens {
            guard token.startTime.isFinite, token.endTime.isFinite,
                  token.startTime >= 0, token.endTime >= token.startTime,
                  let time = timeline.map(start: token.startTime, end: token.endTime) else { continue }
            // Keep a final subword that emitted on the added context frame,
            // without extending the transcript past actual microphone audio.
            let completed = assembler.append(token: token.token,
                start: min(time.start, endLimit),
                end: min(time.end, endLimit))
            if publishesUpdates {
                for segment in completed {
                    continuation.yield(.final(source: source, segment: segment))
                }
            }
        }
        if publishesUpdates, let tail = assembler.provisional {
            continuation.yield(.provisional(source: source, segment: tail))
        }
    }

    private func makeBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw STTError.invalidAudio
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            buffer.floatChannelData?[0].update(from: baseAddress, count: samples.count)
        }
        return buffer
    }
}

@_spi(Validation)
extension ParakeetStreamingSession: DictationRecognitionSession {}

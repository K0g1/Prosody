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
    private let inventory: STTModelManager
    private var modelDirectory: URL?
    private var managers: [AudioSource: StreamingUnifiedAsrManager] = [:]
    private var preparedManager: StreamingUnifiedAsrManager?
    private var batchModel: BatchParakeetModel?

    public init(
        segmentationConfiguration: TranscriptSegmentationConfiguration = .persisted(),
        inventory: STTModelManager = STTModelManager()
    ) {
        self.segmentationConfiguration = segmentationConfiguration
        self.inventory = inventory
    }

    public func prepare(
        model: STTModelDescriptor,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard let speechModel = SpeechModel(descriptor: model) else {
            throw ParakeetEngineError.unsupportedModel(model.id)
        }
        await unload()
        let directory = try await inventory.installedURL(for: speechModel)
        if speechModel == .unified {
            preparedManager = try await ParakeetDictationModel.loadManager(from: directory)
            modelDirectory = directory
        } else {
            batchModel = try await BatchParakeetModel.load(speechModel, from: directory)
        }
        progress(1)
    }

    public func makeSession(source: AudioSource) async throws -> any STTSession {
        if let batchModel {
            return batchModel.makeSession(source: source, configuration: segmentationConfiguration)
        }
        return ParakeetStreamingSession(source: source, manager: try await unifiedManager(for: source),
                                       segmentationConfiguration: segmentationConfiguration)
    }

    private func unifiedManager(for source: AudioSource) async throws -> StreamingUnifiedAsrManager {
        if let manager = managers[source] {
            try await manager.reset()
            return manager
        }
        guard let modelDirectory else { throw ParakeetEngineError.modelNotPrepared }
        let manager: StreamingUnifiedAsrManager
        if let preparedManager {
            self.preparedManager = nil
            manager = preparedManager
        } else {
            manager = try await ParakeetDictationModel.loadManager(from: modelDirectory)
        }
        managers[source] = manager
        return manager
    }

    public func unload() async {
        for manager in managers.values { await manager.cleanup() }
        managers.removeAll()
        await preparedManager?.cleanup()
        preparedManager = nil
        await batchModel?.unload()
        batchModel = nil
        modelDirectory = nil
    }
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

public actor ParakeetStreamingSession: STTSession {
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
    private var processing = false
    private var processingWaiters: [CheckedContinuation<Void, Never>] = []
    private var assembler: StreamingTranscriptAssembler
    private var audioOrigin: TimeInterval?

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
              endTime >= (audioOrigin ?? startTime) else { throw STTError.invalidAudio }
        return try await finish(appending: samples, startTime: startTime, tokenEndLimit: endTime)
    }

    private func bufferAudio(_ samples: [Float], startTime: TimeInterval) async throws {
        guard !samples.isEmpty, samples.count < Int(UInt32.max), samples.allSatisfy(\Float.isFinite),
              startTime.isFinite, startTime >= 0 else {
            throw STTError.invalidAudio
        }
        if audioOrigin == nil { audioOrigin = startTime }
        let buffer = try makeBuffer(samples: samples)
        try await manager.appendAudio(buffer)
    }

    public func finish() async throws -> FinalTranscript {
        try await finish(appending: [], startTime: 0, tokenEndLimit: .infinity)
    }

    private func finish(appending samples: [Float], startTime: TimeInterval, tokenEndLimit: TimeInterval) async throws -> FinalTranscript {
        try beginProcessing()
        defer {
            isFinished = true
            continuation.finish()
            endProcessing()
        }
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
        if processing {
            await withCheckedContinuation { processingWaiters.append($0) }
        }
    }

    private func beginProcessing() throws {
        try Task.checkCancellation()
        guard !isFinished else { throw STTError.sessionFinished }
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
        let origin = audioOrigin ?? 0
        for token in tokens {
            guard token.startTime.isFinite, token.endTime.isFinite,
                  token.startTime >= 0, token.endTime >= token.startTime else { continue }
            // Keep a final subword that emitted on the added context frame,
            // without extending the transcript past actual microphone audio.
            let completed = assembler.append(token: token.token,
                start: min(origin + token.startTime, endLimit),
                end: min(origin + token.endTime, endLimit))
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

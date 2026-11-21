@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Fluid Speech Pro shares v3's tensor shapes, vocabulary size and blank ID,
/// and ships a matching preprocessor and greedy joint. Load the files as a
/// unit, using the public offline model initializer.
struct BatchParakeetModel: DictationRecognitionModel {
    let manager: AsrManager

    static func load(_ model: SpeechModel, from directory: URL) async throws -> Self {
        let v3 = model == .tdtV3
        let names = ModelNames.ASR.self
        let vocabularyFile = v3 ? "parakeet_v3_vocab.json" : names.vocabularyFile
        let vocabularyData = try Data(contentsOf: directory.appendingPathComponent(vocabularyFile))
        let vocabulary = try JSONDecoder().decode([Int: String].self, from: vocabularyData)
        guard vocabulary.count >= 8192 else { throw STTError.failed("The model vocabulary is incomplete.") }

        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        let encoderConfig = MLModelConfiguration()
        encoderConfig.computeUnits = .cpuAndNeuralEngine
        let models = try await AsrModels(
            encoder: MLModel.load(contentsOf: directory.appendingPathComponent(names.encoderFile), configuration: encoderConfig),
            preprocessor: MLModel.load(contentsOf: directory.appendingPathComponent(names.preprocessorFile), configuration: cpu),
            decoder: MLModel.load(contentsOf: directory.appendingPathComponent(names.decoderFile), configuration: cpu),
            joint: MLModel.load(contentsOf: directory.appendingPathComponent(v3 ? names.jointV3File : names.jointFile), configuration: cpu),
            configuration: encoderConfig, vocabulary: vocabulary, version: .v3
        )
        let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1, melChunkContext: false))
        try await manager.loadModels(models)
        return Self(manager: manager)
    }

    func makeDictationSession(configuration: TranscriptSegmentationConfiguration) -> any DictationRecognitionSession {
        makeSession(source: .microphone, configuration: configuration)
    }

    func makeSession(source: AudioSource, configuration: TranscriptSegmentationConfiguration) -> BatchParakeetSession {
        BatchParakeetSession(source: source, manager: manager, configuration: configuration)
    }

    func reset() async throws {}
    func unload() async { await manager.cleanup() }
}

/// Keep short dictations in memory. Longer inputs spill to a private temporary
/// CAF and use FluidAudio's overlapping, disk-backed window processor.
actor BatchParakeetSession: ParakeetEngineSession, DictationRecognitionSession {
    nonisolated let updates: AsyncStream<STTUpdate>
    private let continuation: AsyncStream<STTUpdate>.Continuation
    private let source: AudioSource
    private let manager: AsrManager
    private let configuration: TranscriptSegmentationConfiguration
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("Prosody-\(UUID().uuidString).caf")
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var file: AVAudioFile?
    private var initialSamples: [Float] = []
    private var timeline = ParakeetAudioTimeline()
    private var sampleCount = 0
    private var sawSignal = false
    private var finished = false
    private var recognizing = false
    private var cancelled = false
    private var recognitionWaiters: [CheckedContinuation<Void, Never>] = []

    var hasEnded: Bool { finished && !recognizing }

    init(source: AudioSource, manager: AsrManager, configuration: TranscriptSegmentationConfiguration) {
        self.source = source
        self.manager = manager
        self.configuration = configuration
        (updates, continuation) = AsyncStream.makeStream()
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func append(samples: [Float], startTime: TimeInterval) throws {
        guard !finished else { throw STTError.sessionFinished }
        guard !samples.isEmpty else { return }
        try Task.checkCancellation()
        guard startTime.isFinite, startTime >= 0, samples.allSatisfy(\.isFinite) else {
            throw STTError.invalidAudio
        }
        if !sawSignal { sawSignal = samples.contains { $0 != 0 } }
        if sampleCount + samples.count <= ASRConstants.maxModelSamples {
            initialSamples.append(contentsOf: samples)
        } else {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: format.settings)
                if !initialSamples.isEmpty { try write(initialSamples) }
                initialSamples.removeAll(keepingCapacity: false)
            }
            try write(samples)
        }
        timeline.append(sampleCount: samples.count, startTime: startTime)
        sampleCount += samples.count
    }

    func finish() async throws -> FinalTranscript {
        try await recognize(endLimit: .infinity)
    }

    func finishDictation(appending samples: [Float], startTime: TimeInterval, endTime: TimeInterval) async throws -> FinalTranscript {
        try append(samples: samples, startTime: startTime)
        return try await recognize(endLimit: endTime)
    }

    func cancel() async {
        finished = true
        cancelled = true
        continuation.finish()
        if recognizing {
            await withCheckedContinuation { recognitionWaiters.append($0) }
        } else {
            discardAudio()
        }
    }

    private func discardAudio() {
        file = nil
        initialSamples.removeAll()
        try? FileManager.default.removeItem(at: url)
    }

    private func recognize(endLimit: TimeInterval) async throws -> FinalTranscript {
        guard !finished else { throw STTError.sessionFinished }
        finished = true
        recognizing = true
        defer {
            discardAudio()
            recognizing = false
            continuation.finish()
            let waiters = recognitionWaiters
            recognitionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        guard let origin = timeline.startTime, let actualEnd = timeline.endTime, sawSignal else {
            return FinalTranscript(segments: [])
        }
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: Int(format.sampleRate))
        var state = TdtDecoderState.make()
        let result: ASRResult
        if file != nil {
            file = nil
            result = try await manager.transcribeDiskBacked(url, decoderState: &state)
        } else {
            let padding = max(0, minimum - initialSamples.count)
            if padding > 0 { initialSamples.append(contentsOf: repeatElement(0, count: padding)) }
            result = try await manager.transcribe(initialSamples, decoderState: &state)
        }
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
        let end = min(endLimit, actualEnd)
        var assembler = StreamingTranscriptAssembler(source: source, configuration: configuration)
        for token in result.tokenTimings ?? [] {
            guard token.startTime.isFinite, token.endTime.isFinite,
                  token.startTime >= 0, token.endTime >= token.startTime,
                  let time = timeline.map(start: token.startTime, end: token.endTime),
                  time.start < end else { continue }
            _ = assembler.append(token: token.token, start: time.start, end: min(time.end, end))
        }
        assembler.flush()
        if assembler.finalized.isEmpty, !result.text.isEmpty {
            let segment = TranscriptSegment(source: source, start: origin, end: end, text: result.text, isFinal: true)
            return FinalTranscript(segments: [segment])
        }
        return FinalTranscript(segments: assembler.finalized)
    }

    private func write(_ samples: [Float]) throws {
        guard let count = AVAudioFrameCount(exactly: samples.count),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let channel = buffer.floatChannelData?[0], let file else { throw STTError.invalidAudio }
        buffer.frameLength = count
        samples.withUnsafeBufferPointer { input in
            if let base = input.baseAddress { channel.update(from: base, count: input.count) }
        }
        try file.write(from: buffer)
    }
}

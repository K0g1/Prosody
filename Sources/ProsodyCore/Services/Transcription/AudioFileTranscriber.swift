@preconcurrency import AVFoundation
import Foundation

public struct AudioFileTranscription: Sendable {
    public let transcript: Transcript
    public let duration: TimeInterval
}

struct AudioFilePCMChunk: Sendable {
    let samples: [Float]
    let startTime: TimeInterval
    let duration: TimeInterval
    let fileFraction: Double
    let finishedFiles: Int
}

/// Shared bounded reader for regular file transcription and dictation archive
/// replay. It reads at most one second of native PCM at a time, preserving the
/// existing AAC/CAF handling and source timeline across multi-part archives.
struct AudioFilePCMReader {
    private let urls: [URL]
    private let source: AudioSource
    private let resampler = StreamingAudioResampler()
    private var nextFileIndex = 0
    private var file: AVAudioFile?
    private var buffer: AVAudioPCMBuffer?
    private var format: AVAudioFormat?
    private var finishedFiles = 0
    private var sourceTime: TimeInterval = 0

    init(urls: [URL], source: AudioSource) {
        self.urls = urls
        self.source = source
    }

    var duration: TimeInterval { sourceTime }

    mutating func next() async throws -> AudioFilePCMChunk? {
        while true {
            if file == nil {
                guard nextFileIndex < urls.count else { return nil }
                let url = urls[nextFileIndex]
                nextFileIndex += 1
                let opened = try AVAudioFile(
                    forReading: url,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
                let processingFormat = opened.processingFormat
                guard processingFormat.sampleRate.isFinite,
                      processingFormat.sampleRate > 0,
                      processingFormat.sampleRate <= 384_000,
                      processingFormat.channelCount > 0,
                      processingFormat.channelCount <= 64,
                      let pcmBuffer = AVAudioPCMBuffer(
                        pcmFormat: processingFormat,
                        frameCapacity: AVAudioFrameCount(processingFormat.sampleRate)
                      ) else {
                    throw STTError.invalidAudio
                }
                file = opened
                format = processingFormat
                buffer = pcmBuffer
            }

            guard let file, let buffer, let format else { throw STTError.invalidAudio }
            try Task.checkCancellation()
            if file.framePosition >= file.length {
                self.file = nil
                self.buffer = nil
                self.format = nil
                finishedFiles += 1
                continue
            }
            try file.read(into: buffer)
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else {
                self.file = nil
                self.buffer = nil
                self.format = nil
                finishedFiles += 1
                continue
            }

            var mono = [Float](repeating: 0, count: count)
            let weight = 1 / Float(format.channelCount)
            for channel in 0..<Int(format.channelCount) {
                for index in 0..<count {
                    mono[index] += channels[channel][index] * weight
                }
            }
            let samples = try await resampler.resample(mono, from: format.sampleRate)
            let startTime = sourceTime
            sourceTime += Double(count) / format.sampleRate
            let fileFraction = Double(file.framePosition) / Double(max(file.length, 1))
            return AudioFilePCMChunk(
                samples: samples,
                startTime: startTime,
                duration: sourceTime,
                fileFraction: fileFraction,
                finishedFiles: finishedFiles
            )
        }
    }
}

/// A single post-recording pass shared by imports, deferred recording, and
/// dictation. Decode at most one second at a time; model memory and PCM memory
/// do not grow with recording length. No recognition runs until called.
public actor AudioFileTranscriber {
    private let engine: any STTEngine

    public init(engine: any STTEngine) { self.engine = engine }

    public init(segmentationConfiguration: TranscriptSegmentationConfiguration = .persisted()) {
        self.engine = ParakeetEngine(segmentationConfiguration: segmentationConfiguration)
    }

    public func transcribe(
        files: [AudioSource: [URL]],
        speakerMode: SpeakerMode = .off,
        progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> AudioFileTranscription {
        guard !files.values.flatMap({ $0 }).isEmpty else { throw STTError.invalidAudio }
        let registry = STTRegistry()
        guard let model = await registry.model(id: "parakeet-unified", for: .parakeet) else {
            throw STTError.unsupportedModel("parakeet-unified")
        }
        do {
            try Task.checkCancellation()
            try await engine.prepare(model: model) { progress($0 * 0.15) }
            let coordinator = TranscriptCoordinator(speakerMode: speakerMode)
            var duration: TimeInterval = 0
            let totalFiles = files.values.reduce(0) { $0 + $1.count }
            var finishedFiles = 0
            for source in AudioSource.allCases {
                guard let urls = files[source], !urls.isEmpty else { continue }
                try Task.checkCancellation()
                let session = try await engine.makeSession(source: source)
                // File consumers need only the final result. Drain live updates
                // so AsyncStream cannot retain every provisional revision.
                let drain = Task { for await _ in session.updates {} }
                do {
                    var reader = AudioFilePCMReader(urls: urls, source: source)
                    while let chunk = try await reader.next() {
                        try Task.checkCancellation()
                        if !chunk.samples.isEmpty {
                            try await session.append(samples: chunk.samples, startTime: chunk.startTime)
                        }
                        let fileIndex = finishedFiles + chunk.finishedFiles
                        progress(0.15 + 0.85 * (Double(fileIndex) + chunk.fileFraction) / Double(totalFiles))
                    }
                    finishedFiles += urls.count
                    let final = try await session.finish()
                    await drain.value
                    for segment in final.segments { _ = await coordinator.ingest(.final(source: source, segment: segment)) }
                    duration = max(duration, reader.duration)
                } catch {
                    await session.cancel()
                    drain.cancel()
                    throw error
                }
            }
            try Task.checkCancellation()
            let transcript = await coordinator.deduplicatedTranscript()
            await engine.unload()
            return AudioFileTranscription(transcript: transcript, duration: duration)
        } catch {
            await engine.unload()
            throw error
        }
    }
}

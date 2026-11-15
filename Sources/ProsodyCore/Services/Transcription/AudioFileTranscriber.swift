@preconcurrency import AVFoundation
import Foundation

public struct AudioFileTranscription: Sendable {
    public let transcript: Transcript
    public let duration: TimeInterval
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
                    var sourceTime: TimeInterval = 0
                    let resampler = StreamingAudioResampler()
                    for url in urls {
                        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                        let format = file.processingFormat
                        guard format.sampleRate.isFinite, format.sampleRate > 0, format.sampleRate <= 384_000,
                              format.channelCount > 0, format.channelCount <= 64,
                              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
                            throw STTError.invalidAudio
                        }
                        while file.framePosition < file.length {
                            try Task.checkCancellation()
                            try file.read(into: buffer)
                            let count = Int(buffer.frameLength)
                            guard count > 0, let channels = buffer.floatChannelData else { break }
                            var mono = [Float](repeating: 0, count: count)
                            let weight = 1 / Float(format.channelCount)
                            for channel in 0..<Int(format.channelCount) {
                                for index in 0..<count { mono[index] += channels[channel][index] * weight }
                            }
                            let samples = try await resampler.resample(mono, from: format.sampleRate)
                            if !samples.isEmpty { try await session.append(samples: samples, startTime: sourceTime) }
                            sourceTime += Double(count) / format.sampleRate
                            let fileFraction = Double(file.framePosition) / Double(max(file.length, 1))
                            progress(0.15 + 0.85 * (Double(finishedFiles) + fileFraction) / Double(totalFiles))
                        }
                        finishedFiles += 1
                    }
                    let final = try await session.finish()
                    await drain.value
                    for segment in final.segments { _ = await coordinator.ingest(.final(source: source, segment: segment)) }
                    duration = max(duration, sourceTime)
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

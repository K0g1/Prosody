#if canImport(FluidAudio)
import FluidAudio
#endif
@preconcurrency import AVFoundation
import Foundation

/// The app-facing result of the offline speaker pass. FluidAudio types stay
/// behind this adapter so the transcript and UI do not depend on its model
/// implementation.
public struct DiarizationIntervalResult: Sendable, Equatable {
    public let intervals: [SpeakerInterval]

    public init(intervals: [SpeakerInterval]) {
        self.intervals = intervals
    }
}

public enum FluidAudioDiarizerError: Error, LocalizedError, Equatable, Sendable {
    case unavailable
    case noAudio
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Offline speaker separation is unavailable on this Mac."
        case .noAudio:
            return "There is no retained audio to separate into speakers."
        case .failed(let message):
            return "Speaker separation failed: \(message)"
        }
    }
}

/// Loads FluidAudio's offline diarizer only for a Full-speaker recording and
/// releases the manager when the operation completes.
public actor FluidAudioDiarizer {
    private let modelDirectory: URL

    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    public func process(
        audioFileURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> DiarizationIntervalResult {
        try await process(audioFileURLs: [audioFileURL], progress: progress)
    }

    public func process(
        audioFileURLs: [URL],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> DiarizationIntervalResult {
        guard !audioFileURLs.isEmpty,
              audioFileURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw FluidAudioDiarizerError.noAudio
        }

#if canImport(FluidAudio)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Prosody-Diarization-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            let mergedURL = try makeDiarizationInput(
                from: audioFileURLs,
                in: temporaryURL
            )

            progress?(0.05)
            let manager = OfflineDiarizerManager(config: .default)
            try await manager.prepareModels(directory: modelDirectory)
            let result = try await manager.process(mergedURL) { completed, total in
                let fraction = Double(completed) / Double(max(1, total))
                progress?(0.05 + min(max(fraction, 0), 1) * 0.95)
            }

            let intervals = result.segments.compactMap { segment -> SpeakerInterval? in
                let start = TimeInterval(segment.startTimeSeconds)
                let end = TimeInterval(segment.endTimeSeconds)
                guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
                return SpeakerInterval(
                    speakerID: segment.speakerId,
                    start: start,
                    end: end,
                    confidence: segment.qualityScore.isFinite
                        ? min(max(segment.qualityScore, 0), 1)
                        : nil
                )
            }
            guard !intervals.isEmpty else {
                throw FluidAudioDiarizerError.noAudio
            }
            progress?(1)
            return DiarizationIntervalResult(intervals: intervals)
        } catch let error as FluidAudioDiarizerError {
            throw error
        } catch {
            throw FluidAudioDiarizerError.failed(error.localizedDescription)
        }
#else
        throw FluidAudioDiarizerError.unavailable
#endif
    }

#if canImport(FluidAudio)
    private func makeDiarizationInput(from urls: [URL], in directory: URL) throws -> URL {
        let outputURL = directory.appendingPathComponent("audio.caf")
        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: AudioSampleConverter.speechSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false
        ]

        var outputFile: AVAudioFile?
        defer { outputFile = nil }

        for url in urls.sorted(by: { $0.path < $1.path }) {
            let inputFile: AVAudioFile
            do {
                inputFile = try AVAudioFile(forReading: url)
            } catch {
                throw FluidAudioDiarizerError.failed(error.localizedDescription)
            }
            let frameCount = Int(inputFile.length)
            guard frameCount > 0,
                  let inputBuffer = AVAudioPCMBuffer(
                      pcmFormat: inputFile.processingFormat,
                      frameCapacity: AVAudioFrameCount(frameCount)
                  )
            else { continue }
            do {
                try inputFile.read(into: inputBuffer)
            } catch {
                throw FluidAudioDiarizerError.failed(error.localizedDescription)
            }
            guard let channel = inputBuffer.floatChannelData?[0] else {
                throw FluidAudioDiarizerError.failed("The archived audio is not readable PCM.")
            }

            let inputSamples = Array(
                UnsafeBufferPointer(start: channel, count: Int(inputBuffer.frameLength))
            )
            let samples: [Float]
            do {
                samples = try AudioSampleConverter.resample(
                    inputSamples,
                    from: inputFile.processingFormat.sampleRate,
                    to: AudioSampleConverter.speechSampleRate
                )
            } catch {
                throw FluidAudioDiarizerError.failed(error.localizedDescription)
            }
            guard !samples.isEmpty else { continue }

            if outputFile == nil {
                do {
                    outputFile = try AVAudioFile(
                        forWriting: outputURL,
                        settings: outputSettings,
                        commonFormat: .pcmFormatFloat32,
                        interleaved: false
                    )
                } catch {
                    throw FluidAudioDiarizerError.failed(error.localizedDescription)
                }
            }
            guard let outputFile,
                  let outputBuffer = AVAudioPCMBuffer(
                      pcmFormat: outputFile.processingFormat,
                      frameCapacity: AVAudioFrameCount(samples.count)
                  ),
                  let outputChannel = outputBuffer.floatChannelData?[0]
            else {
                throw FluidAudioDiarizerError.failed("The diarization audio buffer could not be created.")
            }
            outputBuffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                guard let baseAddress = source.baseAddress else { return }
                outputChannel.update(from: baseAddress, count: samples.count)
            }
            do {
                try outputFile.write(from: outputBuffer)
            } catch {
                throw FluidAudioDiarizerError.failed(error.localizedDescription)
            }
        }

        guard outputFile != nil else {
            throw FluidAudioDiarizerError.noAudio
        }
        return outputURL
    }
#endif
}

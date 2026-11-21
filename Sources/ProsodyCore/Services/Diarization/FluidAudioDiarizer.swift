#if canImport(FluidAudio)
import FluidAudio
#endif
@preconcurrency import AVFoundation
import Foundation
import os

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
            let mergedURL = try Self.makeDiarizationInput(
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
        } catch is CancellationError {
            throw CancellationError()
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
    /// Concatenate in the caller's timeline order. Keep a single converter
    /// for each input file so resampling phase survives buffer boundaries.
    static func makeDiarizationInput(from urls: [URL], in directory: URL) throws -> URL {
        let outputURL = directory.appendingPathComponent("audio.caf")
        let sampleRate = AudioSampleConverter.speechSampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384)
        else {
            throw FluidAudioDiarizerError.failed("The diarization audio buffer could not be created.")
        }
        let output = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        var expectedFrames = 0.0
        for url in urls {
            try Task.checkCancellation()
            let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard input.length > 0 else { continue }
            let inputFormat = input.processingFormat
            expectedFrames += Double(input.length) * sampleRate / inputFormat.sampleRate
            guard let endFrame = AVAudioFramePosition(exactly: expectedFrames.rounded()) else {
                throw FluidAudioDiarizerError.failed("The archived audio has an invalid duration.")
            }
            try convert(input, into: output, buffer: outputBuffer, through: endFrame)
        }
        guard output.framePosition > 0 else { throw FluidAudioDiarizerError.noAudio }
        return outputURL
    }

    private static func convert(
        _ input: AVAudioFile,
        into output: AVAudioFile,
        buffer: AVAudioPCMBuffer,
        through endFrame: AVAudioFramePosition
    ) throws {
        guard let converter = AVAudioConverter(from: input.processingFormat, to: buffer.format),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384)
        else {
            throw FluidAudioDiarizerError.failed("The archived audio format could not be converted.")
        }
        converter.downmix = true
        converter.primeMethod = .none
        let readError = OSAllocatedUnfairLock<Error?>(initialState: nil)
        // AVAudioConverter accesses this buffer only inside the synchronous callback.
        nonisolated(unsafe) let readBuffer = inputBuffer

        while output.framePosition < endFrame {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { requested, status in
                do {
                    let remaining = max(0, input.length - input.framePosition)
                    let count = min(AVAudioFramePosition(requested), AVAudioFramePosition(readBuffer.frameCapacity), remaining)
                    if count > 0 {
                        try input.read(into: readBuffer, frameCount: AVAudioFrameCount(count))
                        if readBuffer.frameLength > 0 {
                            status.pointee = .haveData
                            return readBuffer
                        }
                    }
                } catch {
                    readError.withLock { $0 = error }
                }
                status.pointee = .endOfStream
                return nil
            }
            if let error = readError.withLock({ $0 }) { throw error }
            if let conversionError { throw conversionError }
            if status == .error || status == .inputRanDry {
                throw FluidAudioDiarizerError.failed("The archived audio could not be converted.")
            }

            // Sample-rate conversion can emit a few extra frames at EOF.
            // Cap the output to the rounded source timeline across all files.
            buffer.frameLength = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameLength), endFrame - output.framePosition))
            if buffer.frameLength > 0 { try output.write(from: buffer) }
            if status == .endOfStream || buffer.frameLength == 0 { break }
        }
    }
#endif
}

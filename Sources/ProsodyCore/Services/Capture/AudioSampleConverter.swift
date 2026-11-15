@preconcurrency import AVFoundation
import Foundation
import os

public enum AudioSampleConverterError: Error, LocalizedError, Equatable, Sendable {
    case invalidFormat
    case invalidSamples
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Prosody could not create an audio conversion format."
        case .invalidSamples:
            return "Prosody received invalid audio samples."
        case .conversionFailed(let message):
            return "Audio conversion failed: " + message
        }
    }
}

/// Converts capture packets to the mono Float32/16 kHz representation used by
/// the speech model. ScreenCaptureKit commonly delivers 48 kHz audio, so the
/// conversion must happen before any STT session receives a packet.
public enum AudioSampleConverter {
    public static let speechSampleRate = 16_000.0

    public static func resample(
        _ samples: [Float],
        from inputSampleRate: Double,
        to outputSampleRate: Double = speechSampleRate
    ) throws -> [Float] {
        guard !samples.isEmpty,
              samples.allSatisfy(\Float.isFinite),
              inputSampleRate.isFinite,
              inputSampleRate > 0,
              outputSampleRate.isFinite,
              outputSampleRate > 0
        else { throw AudioSampleConverterError.invalidSamples }

        if abs(inputSampleRate - outputSampleRate) < 0.5 {
            return samples
        }

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputSampleRate,
            channels: 1,
            interleaved: false
        ), let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: false
        ), let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw AudioSampleConverterError.invalidFormat }

        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress,
                  let destination = inputBuffer.floatChannelData?[0]
            else { return }
            destination.update(from: baseAddress, count: samples.count)
        }

        let outputCapacity = AVAudioFrameCount(
            max(1, ceil(Double(samples.count) * outputSampleRate / inputSampleRate) + 32)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else { throw AudioSampleConverterError.invalidFormat }

        let providedInput = OSAllocatedUnfairLock(initialState: false)
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            let shouldProvide = providedInput.withLock { hasProvided in
                if hasProvided { return false }
                hasProvided = true
                return true
            }
            guard shouldProvide else {
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return inputBuffer
        }

        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer,
            error: &conversionError,
            withInputFrom: inputBlock
        )
        guard status != .error else {
            throw AudioSampleConverterError.conversionFailed(
                conversionError?.localizedDescription ?? "Unknown converter error"
            )
        }
        guard outputBuffer.frameLength > 0,
              let outputSamples = outputBuffer.floatChannelData?[0]
        else { throw AudioSampleConverterError.conversionFailed("The converter produced no samples.") }

        return Array(UnsafeBufferPointer(
            start: outputSamples,
            count: Int(outputBuffer.frameLength)
        ))
    }
}

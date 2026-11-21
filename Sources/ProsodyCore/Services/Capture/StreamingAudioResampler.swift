@preconcurrency import AVFoundation
import Foundation
import os

/// One converter per source preserves the sample-rate conversion phase across
/// packets. All conversion work and framework objects stay off the main actor.
public actor StreamingAudioResampler {
    private var resampler: MonoPCMResampler?

    public init() {}

    public func resample(_ samples: [Float], from rate: Double) throws -> [Float] {
        guard rate.isFinite, rate > 0, !samples.isEmpty,
              AVAudioFrameCount(exactly: samples.count) != nil, samples.allSatisfy(\.isFinite) else {
            throw AudioSampleConverterError.invalidSamples
        }
        if rate == AudioSampleConverter.speechSampleRate {
            resampler = nil
            return samples
        }
        if let resampler, resampler.inputRate == rate {
            return try resampler.resample(samples)
        }
        let next = try MonoPCMResampler(from: rate, to: AudioSampleConverter.speechSampleRate)
        resampler = next
        return try next.resample(samples)
    }
}

/// A streaming converter confined to its owner's actor. Retains fractional
/// conversion phase across packets of the same format.
struct MonoPCMResampler {
    private let converter: AVAudioConverter
    let inputRate: Double

    init(
        from inputRate: Double, to outputRate: Double, primeMethod: AVAudioConverterPrimeMethod = .none
    ) throws {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw AudioSampleConverterError.invalidFormat
        }
        converter.primeMethod = primeMethod
        self.converter = converter
        self.inputRate = inputRate
    }

    func resample(_ samples: [Float]) throws -> [Float] {
        let capacity = ceil(Double(samples.count) * converter.outputFormat.sampleRate / inputRate) + 32
        guard let inputFrames = AVAudioFrameCount(exactly: samples.count), inputFrames > 0,
              let outputFrames = AVAudioFrameCount(exactly: capacity),
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outputFrames),
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: inputFrames),
              let channel = input.floatChannelData?[0] else { throw AudioSampleConverterError.invalidFormat }
        input.frameLength = inputFrames
        samples.withUnsafeBufferPointer { source in
            if let address = source.baseAddress { channel.update(from: address, count: source.count) }
        }
        let supplied = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            let first = supplied.withLock { used in
                defer { used = true }
                return !used
            }
            inputStatus.pointee = first ? .haveData : .noDataNow
            return first ? input : nil
        }
        guard status != .error else {
            throw AudioSampleConverterError.conversionFailed(error?.localizedDescription ?? "Unknown conversion error")
        }
        guard let data = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }

    func finish() throws -> [Float] {
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: 4_096),
              let data = output.floatChannelData?[0]
        else { throw AudioSampleConverterError.invalidFormat }

        var tail: [Float] = []
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            tail.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
            if status == .endOfStream { return tail }
            guard status == .haveData, output.frameLength > 0 else {
                throw AudioSampleConverterError.conversionFailed(
                    error?.localizedDescription ?? "Could not drain the audio converter."
                )
            }
        }
    }
}

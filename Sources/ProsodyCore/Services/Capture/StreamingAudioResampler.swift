@preconcurrency import AVFoundation
import Foundation
import os

/// One converter per source preserves the sample-rate conversion phase across
/// packets. All conversion work and framework objects stay off the main actor.
public actor StreamingAudioResampler {
    private var converter: AVAudioConverter?
    private var inputRate: Double = 0

    public init() {}

    public func resample(_ samples: [Float], from rate: Double) throws -> [Float] {
        guard rate.isFinite, rate > 0, !samples.isEmpty,
              samples.count < Int(UInt32.max), samples.allSatisfy(\.isFinite) else {
            throw AudioSampleConverterError.invalidSamples
        }
        if rate == AudioSampleConverter.speechSampleRate { return samples }
        if converter == nil || inputRate != rate {
            guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
                  let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioSampleConverter.speechSampleRate, channels: 1, interleaved: false),
                  let created = AVAudioConverter(from: input, to: output) else {
                throw AudioSampleConverterError.invalidFormat
            }
            created.primeMethod = .none
            converter = created
            inputRate = rate
        }
        guard let converter,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0] else { throw AudioSampleConverterError.invalidFormat }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        let capacity = ceil(Double(samples.count) * AudioSampleConverter.speechSampleRate / rate) + 32
        guard capacity < Double(UInt32.max),
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(capacity)) else {
            throw AudioSampleConverterError.invalidFormat
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
}

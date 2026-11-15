import Foundation

/// The normalized audio value passed between capture and model services.
/// Samples are expected to be Float32, mono, and 16 kHz.
public struct AudioFrame: Codable, Equatable, Sendable {
    public let source: AudioSource
    public let epochID: UUID
    public let startTime: TimeInterval
    public let samples: [Float]
    public let sampleRate: Double

    public init(
        source: AudioSource,
        epochID: UUID,
        startTime: TimeInterval,
        samples: [Float],
        sampleRate: Double = 16_000
    ) {
        self.source = source
        self.epochID = epochID
        self.startTime = max(0, startTime)
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval {
        guard sampleRate > 0, sampleRate.isFinite else { return 0 }
        return Double(samples.count) / sampleRate
    }
}

public struct MockAudioInput: Equatable, Sendable {
    public let source: AudioSource
    public let presentationTime: TimeInterval
    public let samples: [Float]

    public init(source: AudioSource, presentationTime: TimeInterval, samples: [Float]) {
        self.source = source
        self.presentationTime = presentationTime
        self.samples = samples
    }
}

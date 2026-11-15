#if DEBUG
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Feeds a mono file into a fresh coordinator without starting hardware capture.
/// The caller owns stopping the capture stream after replay returns.
actor DictationAudioFixture {
    static func replay(_ url: URL, into capture: ScreenCaptureCoordinator) async throws {
        try await DictationAudioFixture().replayPackets(from: url, into: capture)
    }

    /// The opted-in microphone check uses one short, known audio clip. Route
    /// it to the built-in speakers without changing the system output device.
    @MainActor
    static func playThroughBuiltInSpeakers(_ url: URL) async throws {
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.duration > 0, player.duration <= 8, let device = builtInSpeakerUID() else {
            throw UserFacingError(title: "Invalid microphone fixture", message: "Use a short clip and a Mac with built-in speakers.")
        }
        player.currentDevice = device
        player.volume = 0.65
        player.prepareToPlay()
        try await Task.sleep(for: .milliseconds(350))
        guard player.play() else {
            throw UserFacingError(title: "Microphone fixture failed", message: "The test clip did not play.")
        }
        defer { player.stop() }
        try await Task.sleep(for: .seconds(player.duration) + .milliseconds(250))
    }

    private static func builtInSpeakerUID() -> String? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var list = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr, size > 0 else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard devices.withUnsafeMutableBytes({ AudioObjectGetPropertyData(system, &list, 0, nil, &size, $0.baseAddress!) }) == noErr else {
            return nil
        }
        for device in devices {
            var transport = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
            var kind: UInt32 = 0
            var kindSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &transport, 0, nil, &kindSize, &kind) == noErr,
                  kind == kAudioDeviceTransportTypeBuiltIn else { continue }
            var output = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                    mScope: kAudioDevicePropertyScopeOutput,
                                                    mElement: kAudioObjectPropertyElementMain)
            var outputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &output, 0, nil, &outputSize) == noErr,
                  outputSize > 0 else { continue }
            var identifier = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            var uid: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout.size(ofValue: uid))
            if AudioObjectGetPropertyData(device, &identifier, 0, nil, &uidSize, &uid) == noErr,
               let uid { return uid.takeRetainedValue() as String }
        }
        return nil
    }

    private func replayPackets(from url: URL, into capture: ScreenCaptureCoordinator) async throws {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let rate = format.sampleRate
        guard format.channelCount == 1, rate.isFinite, (1...384_000).contains(rate) else {
            throw UserFacingError(title: "Invalid dictation fixture", message: "Use a mono audio file with a supported sample rate.")
        }
        let framesPerPacket = AVAudioFrameCount(max(1, (rate * 0.05).rounded()))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerPacket) else {
            throw AudioSampleConverterError.invalidFormat
        }

        let length = file.length
        let clock = ContinuousClock()
        let start = clock.now
        var frame: AVAudioFramePosition = 0
        while frame < length {
            try Task.checkCancellation()
            let framesToRead = min(length - frame, AVAudioFramePosition(framesPerPacket))
            try file.read(into: buffer, frameCount: AVAudioFrameCount(framesToRead))
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData?[0] else {
                throw AudioSampleConverterError.invalidSamples
            }
            let packet = CapturedAudioPacket(
                source: .microphone,
                presentationTime: Double(frame) / rate,
                sampleRate: rate,
                samples: Array(UnsafeBufferPointer(start: data, count: count))
            )
            frame += AVAudioFramePosition(count)
            // A packet becomes available after its audio would have been captured.
            // Absolute deadlines avoid accumulating drift from reads and wakeups.
            try await clock.sleep(until: start.advanced(by: .seconds(Double(frame) / rate)), tolerance: .zero)
            try Task.checkCancellation()
            guard capture.enqueueValidationFixturePacket(packet) else { return }
        }
    }
}
#endif

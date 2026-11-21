@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import CoreGraphics
import Foundation

#if canImport(ScreenCaptureKit)
@preconcurrency import ScreenCaptureKit
#endif

public enum ScreenCaptureCoordinatorError: Error, LocalizedError, Equatable, Sendable {
    case unavailable
    case noDisplay
    case alreadyRunning
    case notRunning
    case screenPermissionDenied
    case startFailed(String)
    case sampleConversionFailed
    case bufferOverrun
    case pauseDrainTimedOut

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "ScreenCaptureKit is unavailable on this Mac."
        case .noDisplay: return "Prosody could not find a display to use for audio capture."
        case .alreadyRunning: return "Audio capture is already running."
        case .notRunning: return "Audio capture is not running."
        case .screenPermissionDenied:
            return "Screen Recording permission is required to capture system audio. Allow Prosody in System Settings, then try again."
        case .startFailed(let message): return message
        case .bufferOverrun: return "Transcription could not keep up with capture. The recording was stopped; recover the saved transcript in Prosody."
        case .sampleConversionFailed: return "Prosody could not read an audio sample from macOS."
        case .pauseDrainTimedOut:
            return "Audio processing stalled while pausing. Recover the saved part of the recording in Prosody."
        }
    }
}

public struct CapturedAudioPacket: Sendable, Equatable {
    public let source: AudioSource
    public let presentationTime: TimeInterval
    public let sampleRate: Double
    public let samples: [Float]

    public init(source: AudioSource, presentationTime: TimeInterval, sampleRate: Double, samples: [Float]) {
        self.source = source
        self.presentationTime = presentationTime
        self.sampleRate = sampleRate
        self.samples = samples
    }
}

/// Owns one native capture and emits copied, Sendable PCM packets. AVFoundation
/// handles microphone-only capture, and ScreenCaptureKit handles system audio.
public final class ScreenCaptureCoordinator: NSObject, SCStreamOutput, SCStreamDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public nonisolated let packets: AsyncThrowingStream<CapturedAudioPacket, Error>

    private let packetContinuation: AsyncThrowingStream<CapturedAudioPacket, Error>.Continuation
    private let systemOutputQueue: DispatchQueue
    private let microphoneOutputQueue: DispatchQueue
    private let lock = NSLock()
    private var currentMode: CaptureMode?
    private var pendingPackets = 0

#if canImport(ScreenCaptureKit)
    private enum Backend {
        case screen(SCStream)
        case microphone(MicrophoneCapture)

        var producerID: ObjectIdentifier {
            switch self {
            case .screen(let stream): ObjectIdentifier(stream)
            case .microphone(let mic): ObjectIdentifier(mic.output)
            }
        }
    }
    private var backend: Backend?
    private var starting = false
    private var startTask: Task<Void, Error>?
    private var stopTask: Task<Void, Never>?
    private var streamFailure: ScreenCaptureCoordinatorError?
#endif

    public override convenience init() {
        self.init(systemOutputQueue: DispatchQueue(label: "com.openai.clippy.capture.system", qos: .userInitiated),
                  microphoneOutputQueue: DispatchQueue(label: "com.openai.clippy.capture.microphone", qos: .userInitiated))
    }

    init(systemOutputQueue: DispatchQueue, microphoneOutputQueue: DispatchQueue) {
        self.systemOutputQueue = systemOutputQueue
        self.microphoneOutputQueue = microphoneOutputQueue
        var continuation: AsyncThrowingStream<CapturedAudioPacket, Error>.Continuation!
        self.packets = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation = $0 }
        self.packetContinuation = continuation
        super.init()
    }

    /// Ask macOS for the Screen Recording grant used by system-audio capture.
    /// This is exposed separately from `start` so first-run setup can request
    /// permissions before the user begins a recording.
    public static func requestSystemAudioPermission() -> Bool {
#if canImport(ScreenCaptureKit)
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
#else
        return false
#endif
    }

    public func start(mode: CaptureMode, microphoneDeviceID: String? = nil) async throws {
#if canImport(ScreenCaptureKit)
        try reserveStart()
        defer {
            lock.withLock {
                starting = false
                startTask = nil
            }
        }
        try Task.checkCancellation()
        guard !mode.sources.isEmpty else { throw ScreenCaptureCoordinatorError.unavailable }
        if mode.sources.contains(.system), !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess() else {
                throw ScreenCaptureCoordinatorError.screenPermissionDenied
            }
        }
        do {
            let backend: Backend
            if mode == .microphone {
                backend = .microphone(try MicrophoneCapture(
                    deviceID: microphoneDeviceID, delegate: self, sampleQueue: microphoneOutputQueue
                ) { [weak self] producer, failure in
                    self?.captureDidFail(producer: producer, failure: failure)
                })
            } else {
                backend = .screen(try await makeScreenStream(mode: mode, microphoneDeviceID: microphoneDeviceID))
            }
            try Task.checkCancellation()
            let startup = try install(backend: backend, mode: mode)
            do {
                try await startup.value
                try Task.checkCancellation()
                try lock.withLock {
                    if let streamFailure { throw streamFailure }
                    if stopTask != nil { throw CancellationError() }
                }
            } catch {
                await stop()
                throw error
            }
        } catch let error as ScreenCaptureCoordinatorError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScreenCaptureCoordinatorError.startFailed(error.localizedDescription)
        }
#else
        throw ScreenCaptureCoordinatorError.unavailable
#endif
    }

    public func pause() async throws {
#if canImport(ScreenCaptureKit)
        let (backend, mode) = try activeCapture()
        try await stopCapture(backend)
        // Drain framework callbacks and the consumer before closing the clock
        // epoch. Otherwise a pause discards the audio waiting behind inference.
        await drainOutputCallbacks(sources: mode.sources)
        try await waitForPendingPackets(until: ContinuousClock.now.advanced(by: .seconds(5)))
#else
        throw ScreenCaptureCoordinatorError.unavailable
#endif
    }

    public func resume() async throws {
#if canImport(ScreenCaptureKit)
        let (backend, _) = try activeCapture()
        try await startCapture(backend)
#else
        throw ScreenCaptureCoordinatorError.unavailable
#endif
    }

    /// Stop the producer, then let already queued callbacks yield their final
    /// packets before closing the stream. The caller owns waiting for the consumer.
    public func stop(drainOutputQueues: Bool = true) async {
#if canImport(ScreenCaptureKit)
        let stopping = lock.withLock {
            if let stopTask { return stopTask }
            // A second stop must join this task. Closing the packet stream on
            // that path would cut off the first stop's queued callbacks.
            let task = Task { await stopAndFinish(drainOutputQueues: drainOutputQueues) }
            stopTask = task
            return task
        }
        await stopping.value
#else
        packetContinuation.finish()
#endif
    }

    public func isRunning() -> Bool {
        currentModeSnapshot() != nil
    }

#if canImport(ScreenCaptureKit)
    private func makeScreenStream(mode: CaptureMode, microphoneDeviceID: String?) async throws -> SCStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first else { throw ScreenCaptureCoordinatorError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.queueDepth = 3
        configuration.capturesAudio = true
        configuration.captureMicrophone = mode.sources.contains(.microphone)
        configuration.microphoneCaptureDeviceID = microphoneDeviceID
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemOutputQueue)
        if configuration.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneOutputQueue)
        }
        return stream
    }

    private func stopAndFinish(drainOutputQueues: Bool) async {
        let (backend, mode, startup) = lock.withLock { (self.backend, currentMode, startTask) }
        // If startup has reached the framework, let its request complete before
        // stopping. Otherwise a late start could leave a closed stream capturing.
        _ = await startup?.result
        var stopFailure: ScreenCaptureCoordinatorError?
        if let backend {
            do {
                try await stopCapture(backend)
            } catch let error as SCStreamError where error.code == .attemptToStopStreamState {
                // A paused stream is already stopped.
            } catch {
                if drainOutputQueues { stopFailure = .startFailed(error.localizedDescription) }
            }
        }
        if drainOutputQueues {
            await drainOutputCallbacks(sources: mode?.sources ?? AudioSource.allCases)
        }
        let failure = lock.withLock {
            self.backend = nil
            currentMode = nil
            return streamFailure ?? stopFailure
        }
        packetContinuation.finish(throwing: failure)
    }

    private func drainOutputCallbacks(sources: [AudioSource]) async {
        for source in sources {
            let queue = source == .system ? systemOutputQueue : microphoneOutputQueue
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume() }
            }
        }
    }

    private func startCapture(_ backend: Backend) async throws {
        switch backend {
        case .screen(let stream): try await stream.startCapture()
        case .microphone(let microphone): try await microphone.start()
        }
    }

    private func stopCapture(_ backend: Backend) async throws {
        switch backend {
        case .screen(let stream): try await stream.stopCapture()
        case .microphone(let microphone): await microphone.stop()
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let source: AudioSource
        switch type {
        case .audio: source = .system
        case .microphone: source = .microphone
        default: return
        }
        receive(sampleBuffer, source: source, producer: ObjectIdentifier(stream))
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        receive(sampleBuffer, source: .microphone, producer: ObjectIdentifier(output))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        captureDidFail(producer: ObjectIdentifier(stream), failure: .startFailed(error.localizedDescription))
    }

    private func captureDidFail(producer: ObjectIdentifier, failure: ScreenCaptureCoordinatorError) {
        let shouldFinish = lock.withLock { () -> Bool? in
            guard backend?.producerID == producer, streamFailure == nil else { return nil }
            streamFailure = failure
            // During a normal stop the stop task owns stream termination,
            // including delivering this error after fencing the queues.
            guard stopTask == nil else { return false }
            currentMode = nil
            return true
        }
        guard let shouldFinish else { return }
        if shouldFinish { packetContinuation.finish(throwing: failure) }
        AppLogger.capture.error("Capture stopped: \(failure.localizedDescription, privacy: .private)")
    }

    private func receive(_ sampleBuffer: CMSampleBuffer, source: AudioSource, producer: ObjectIdentifier) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        guard let packet = Self.packet(from: sampleBuffer, source: source) else {
            captureDidFail(producer: producer, failure: .sampleConversionFailed)
            return
        }
        enqueue(packet, producer: producer)
    }

    static func packet(from sampleBuffer: CMSampleBuffer, source: AudioSource) -> CapturedAudioPacket? {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard timestamp.isFinite, timestamp >= 0, frameCount > 0,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              streamDescription.mSampleRate.isFinite, streamDescription.mSampleRate > 0,
              let format = CapturePCMFormat(streamDescription)
        else { return nil }

        var byteCount = 0
        let flags = UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment)
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &byteCount, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: flags, blockBufferOut: nil
        )
        guard sizeStatus == noErr, byteCount >= MemoryLayout<AudioBufferList>.size else { return nil }
        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        let bufferList = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: bufferList,
            bufferListSize: byteCount, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: flags, blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return nil }
        defer { withExtendedLifetime(retainedBlockBuffer) {} }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var channelCount = 0
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard buffer.mData != nil, channels > 0,
                  frameCount <= Int(buffer.mDataByteSize) / (channels * format.bytesPerChannel)
            else { return nil }
            channelCount += channels
        }
        guard channelCount == Int(streamDescription.mChannelsPerFrame), channelCount > 0 else { return nil }

        // Downmix directly into the packet. Keep the existing channel weights
        // so a change in the signal on one channel does not alter the gain.
        var mono = Array(repeating: Float.zero, count: frameCount)
        for buffer in buffers {
            guard let data = buffer.mData else { return nil }
            let channels = Int(buffer.mNumberChannels)
            let bytesPerFrame = channels * format.bytesPerChannel
            for frame in mono.indices {
                var sample = data.advanced(by: frame * bytesPerFrame)
                for _ in 0..<channels {
                    mono[frame] += format.readSample(at: sample)
                    sample += format.bytesPerChannel
                }
            }
        }
        let divisor = Float(channelCount)
        for frame in mono.indices {
            mono[frame] = max(-1, min(1, mono[frame] / divisor))
        }
        return CapturedAudioPacket(
            source: source,
            presentationTime: timestamp,
            sampleRate: streamDescription.mSampleRate,
            samples: mono
        )
    }
#endif

    @discardableResult
    private func enqueue(_ packet: CapturedAudioPacket, producer: ObjectIdentifier? = nil) -> Bool {
        let accepted = lock.withLock {
            if let producer, backend?.producerID != producer || streamFailure != nil { return false }
            pendingPackets += 1
            return true
        }
        guard accepted else { return false }
        switch packetContinuation.yield(packet) {
        case .dropped:
            acknowledgePacket()
            packetContinuation.finish(throwing: ScreenCaptureCoordinatorError.bufferOverrun)
        case .terminated:
            acknowledgePacket()
        case .enqueued:
            return true
        @unknown default:
            break
        }
        return false
    }

#if DEBUG
    func enqueueValidationFixturePacket(_ packet: CapturedAudioPacket) -> Bool {
        enqueue(packet)
    }

    func failValidationFixture(_ error: Error) {
        packetContinuation.finish(throwing: error)
    }
#endif

    private func currentModeSnapshot() -> CaptureMode? {
        lock.withLock {
            guard stopTask == nil, streamFailure == nil else { return nil }
            return currentMode
        }
    }

    public func acknowledgePacket() {
        lock.lock()
        pendingPackets = max(0, pendingPackets - 1)
        lock.unlock()
    }

#if canImport(ScreenCaptureKit)
    func waitForPendingPackets(until deadline: ContinuousClock.Instant) async throws {
        let clock = ContinuousClock()
        while true {
            try Task.checkCancellation()
            let remaining = try lock.withLock {
                if let streamFailure { throw streamFailure }
                guard stopTask == nil else { throw ScreenCaptureCoordinatorError.notRunning }
                return pendingPackets
            }
            guard remaining > 0 else { return }
            let now = clock.now
            guard now < deadline else { throw ScreenCaptureCoordinatorError.pauseDrainTimedOut }
            try await clock.sleep(until: min(deadline, now.advanced(by: .milliseconds(10))))
        }
    }

    private func activeCapture() throws -> (Backend, CaptureMode) {
        try lock.withLock {
            guard let backend, let currentMode, stopTask == nil, streamFailure == nil else {
                throw ScreenCaptureCoordinatorError.notRunning
            }
            return (backend, currentMode)
        }
    }

    private func reserveStart() throws {
        try lock.withLock {
            guard stopTask == nil, streamFailure == nil else { throw ScreenCaptureCoordinatorError.notRunning }
            guard !starting, backend == nil else { throw ScreenCaptureCoordinatorError.alreadyRunning }
            starting = true
        }
    }

    private func install(backend: Backend, mode: CaptureMode) throws -> Task<Void, Error> {
        try lock.withLock {
            guard stopTask == nil else { throw CancellationError() }
            self.backend = backend
            currentMode = mode
            let task = Task { try await startCapture(backend) }
            startTask = task
            return task
        }
    }
#endif
}

/// The ASBD specifies both the precision and the storage width. For example,
/// 24-bit input may use three packed bytes or a four-byte aligned container.
private struct CapturePCMFormat {
    let bytesPerChannel: Int
    private let bitsPerChannel: Int
    private let isFloat: Bool
    private let bigEndian: Bool
    private let alignedHigh: Bool

    init?(_ description: AudioStreamBasicDescription) {
        let flags = description.mFormatFlags
        let interleaved = flags & kAudioFormatFlagIsNonInterleaved == 0
        let channelsPerBuffer = interleaved ? Int(description.mChannelsPerFrame) : 1
        let bytesPerFrame = Int(description.mBytesPerFrame)
        guard description.mFormatID == kAudioFormatLinearPCM, channelsPerBuffer > 0,
              bytesPerFrame.isMultiple(of: channelsPerBuffer) else { return nil }
        bytesPerChannel = bytesPerFrame / channelsPerBuffer
        bitsPerChannel = Int(description.mBitsPerChannel)
        isFloat = flags & kAudioFormatFlagIsFloat != 0
        bigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        alignedHigh = flags & kAudioFormatFlagIsAlignedHigh != 0

        if isFloat {
            guard (bitsPerChannel, bytesPerChannel) == (32, 4) ||
                  (bitsPerChannel, bytesPerChannel) == (64, 8) else { return nil }
        } else {
            guard flags & kAudioFormatFlagIsSignedInteger != 0,
                  [16, 24, 32].contains(bitsPerChannel),
                  (bitsPerChannel / 8...4).contains(bytesPerChannel)
            else { return nil }
        }
    }

    func readSample(at data: UnsafeRawPointer) -> Float {
        if isFloat {
            let sample: Float
            if bitsPerChannel == 32 {
                let bits = data.loadUnaligned(as: UInt32.self)
                sample = Float(bitPattern: bigEndian ? UInt32(bigEndian: bits) : UInt32(littleEndian: bits))
            } else {
                let bits = data.loadUnaligned(as: UInt64.self)
                sample = Float(Double(bitPattern: bigEndian ? UInt64(bigEndian: bits) : UInt64(littleEndian: bits)))
            }
            return sample.isFinite ? sample : 0
        }

        let raw: UInt32
        switch bytesPerChannel {
        case 2:
            let bits = data.loadUnaligned(as: UInt16.self)
            raw = UInt32(bigEndian ? UInt16(bigEndian: bits) : UInt16(littleEndian: bits))
        case 3:
            let first = UInt32(data.load(as: UInt8.self))
            let second = UInt32(data.load(fromByteOffset: 1, as: UInt8.self))
            let third = UInt32(data.load(fromByteOffset: 2, as: UInt8.self))
            raw = bigEndian ? (first << 16) | (second << 8) | third : (third << 16) | (second << 8) | first
        default:
            let bits = data.loadUnaligned(as: UInt32.self)
            raw = bigEndian ? UInt32(bigEndian: bits) : UInt32(littleEndian: bits)
        }
        let shifted = raw << (32 - (alignedHigh ? bytesPerChannel * 8 : bitsPerChannel))
        return Float(Int32(bitPattern: shifted)) / 2_147_483_648
    }
}

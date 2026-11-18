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
        while pendingPacketCount() > 0, currentModeSnapshot() != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
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
        guard let packet = Self.packet(from: sampleBuffer, source: source) else { return }
        enqueue(packet, producer: ObjectIdentifier(stream))
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let packet = Self.packet(from: sampleBuffer, source: .microphone) else { return }
        enqueue(packet, producer: ObjectIdentifier(output))
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

    private static func packet(from sampleBuffer: CMSampleBuffer, source: AudioSource) -> CapturedAudioPacket? {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard timestamp.isFinite, timestamp >= 0,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { return nil }

        let bufferCount = max(1, Int(streamDescription.mChannelsPerFrame))
        let byteCount = MemoryLayout<AudioBufferList>.size + max(0, bufferCount - 1) * MemoryLayout<AudioBuffer>.stride
        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        let bufferList = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: byteCount,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return nil }
        // The list can point into the retained block rather than the original
        // sample. Keep the backing storage alive until all PCM has been copied.
        defer { withExtendedLifetime(retainedBlockBuffer) {} }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var channels: [[Float]] = []
        channels.reserveCapacity(buffers.count)
        let isFloat = (streamDescription.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (streamDescription.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let bitsPerChannel = Int(streamDescription.mBitsPerChannel)

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let channelCount = max(1, Int(buffer.mNumberChannels))
            let rawSamples: [Float]
            if isFloat && bitsPerChannel == 32 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                rawSamples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
            } else if isSignedInteger && bitsPerChannel == 16 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                rawSamples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: count).map {
                    Float($0) / Float(Int16.max)
                }
            } else {
                continue
            }

            if channelCount == 1 {
                channels.append(rawSamples)
            } else {
                for channel in 0..<channelCount {
                    channels.append(Array(stride(from: channel, to: rawSamples.count, by: channelCount).map { rawSamples[$0] }))
                }
            }
        }

        guard let frameCount = channels.map(\.count).min(), frameCount > 0 else { return nil }
        var mono = Array(repeating: Float.zero, count: frameCount)
        for channel in channels {
            for index in 0..<frameCount { mono[index] += channel[index] }
        }
        let divisor = Float(max(1, channels.count))
        mono = mono.map { max(-1, min(1, $0 / divisor)) }
        return CapturedAudioPacket(
            source: source,
            presentationTime: timestamp,
            sampleRate: Double(streamDescription.mSampleRate),
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

    private func pendingPacketCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingPackets
    }

#if canImport(ScreenCaptureKit)
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

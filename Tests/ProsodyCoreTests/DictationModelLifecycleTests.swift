#if canImport(XCTest)
@preconcurrency import AVFoundation
import Foundation
import XCTest
@_spi(Validation) @testable import ProsodyCore

final class DictationModelLifecycleTests: XCTestCase {
    private let configuration = TranscriptSegmentationConfiguration()

    func testPrepareStartsOneBackgroundFlightWithoutWaitingForLoad() async throws {
        let gate = LifecycleGate()
        let started = expectation(description: "load started")
        let counters = LifecycleCounters()
        let recognizer = DictationRecognizer(idleRetention: .seconds(30)) {
            await counters.incrementLoad()
            started.fulfill()
            await gate.wait()
            return LifecycleModel(counters: counters)
        }

        await recognizer.prepare()
        await fulfillment(of: [started], timeout: 2)
        let startedLoads = await counters.loadCount
        XCTAssertEqual(startedLoads, 1)

        await gate.release()
        try await recognizer.waitUntilPrepared()
        let completedLoads = await counters.loadCount
        XCTAssertEqual(completedLoads, 1)
    }

    func testPreparationUpdatesLateSubscriberSeesActiveFlight() async throws {
        let gate = LifecycleGate()
        let started = expectation(description: "load started")
        let counters = LifecycleCounters()
        let recognizer = DictationRecognizer(idleRetention: .seconds(30)) {
            await counters.incrementLoad()
            started.fulfill()
            await gate.wait()
            return LifecycleModel(counters: counters)
        }

        await recognizer.prepare()
        await fulfillment(of: [started], timeout: 2)

        let updates = await recognizer.modelPreparationUpdates()
        var iterator = updates.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, true)

        await gate.release()
        let finished = await iterator.next()
        XCTAssertEqual(finished, false)
        let loads = await counters.loadCount
        XCTAssertEqual(loads, 1)
    }

    func testPreparationUpdatesFinishWhenRecognizerIsReleased() async {
        let updates: AsyncStream<Bool>
        do {
            let recognizer = DictationRecognizer(idleRetention: .seconds(30)) {
                LifecycleModel(counters: LifecycleCounters())
            }
            updates = await recognizer.modelPreparationUpdates()
        }

        var iterator = updates.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, false)
        let finished = await iterator.next()
        XCTAssertNil(finished)
    }

    func testPreparationUpdatesReportsSuccessWithoutAnotherLoad() async throws {
        let gate = LifecycleGate()
        let started = expectation(description: "load started")
        let counters = LifecycleCounters()
        let recognizer = DictationRecognizer(idleRetention: .seconds(30)) {
            await counters.incrementLoad()
            started.fulfill()
            await gate.wait()
            return LifecycleModel(counters: counters)
        }

        let updates = await recognizer.modelPreparationUpdates()
        var iterator = updates.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, false)
        let initialLoads = await counters.loadCount
        XCTAssertEqual(initialLoads, 0)

        await recognizer.prepare()
        await fulfillment(of: [started], timeout: 2)
        let loading = await iterator.next()
        XCTAssertEqual(loading, true)

        await gate.release()
        let finished = await iterator.next()
        XCTAssertEqual(finished, false)
        try await recognizer.waitUntilPrepared()

        let loads = await counters.loadCount
        XCTAssertEqual(loads, 1)
        let lateUpdates = await recognizer.modelPreparationUpdates()
        var lateIterator = lateUpdates.makeAsyncIterator()
        let lateInitial = await lateIterator.next()
        XCTAssertEqual(lateInitial, false)
        let loadsAfterLateSubscription = await counters.loadCount
        XCTAssertEqual(loadsAfterLateSubscription, 1)
    }

    func testPreparationUpdatesReportsFailureWithoutAnotherLoad() async throws {
        let gate = LifecycleGate()
        let started = expectation(description: "load started")
        let counters = LifecycleCounters()
        let recognizer = DictationRecognizer(idleRetention: .seconds(30)) {
            await counters.incrementLoad()
            started.fulfill()
            await gate.wait()
            throw STTError.failed("load failed")
        }

        let updates = await recognizer.modelPreparationUpdates()
        var iterator = updates.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, false)

        await recognizer.prepare()
        await fulfillment(of: [started], timeout: 2)
        let loading = await iterator.next()
        XCTAssertEqual(loading, true)

        await gate.release()
        let finished = await iterator.next()
        XCTAssertEqual(finished, false)

        let loads = await counters.loadCount
        XCTAssertEqual(loads, 1)
        let lateUpdates = await recognizer.modelPreparationUpdates()
        var lateIterator = lateUpdates.makeAsyncIterator()
        let lateInitial = await lateIterator.next()
        XCTAssertEqual(lateInitial, false)
        let loadsAfterLateSubscription = await counters.loadCount
        XCTAssertEqual(loadsAfterLateSubscription, 1)
    }

    func testPreparationUpdatesReportsDiscardWithoutAnotherLoad() async throws {
        let gate = LifecycleGate()
        let started = expectation(description: "load started")
        let unloaded = expectation(description: "discarded model unloaded")
        let counters = LifecycleCounters()
        let recognizer = DictationRecognizer(idleRetention: .seconds(30)) {
            await counters.incrementLoad()
            started.fulfill()
            await gate.wait()
            return LifecycleModel(counters: counters, onUnload: { unloaded.fulfill() })
        }

        let updates = await recognizer.modelPreparationUpdates()
        var iterator = updates.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, false)

        await recognizer.prepare()
        await fulfillment(of: [started], timeout: 2)
        let loading = await iterator.next()
        XCTAssertEqual(loading, true)

        await recognizer.releaseIfIdle()
        await gate.release()
        let finished = await iterator.next()
        XCTAssertEqual(finished, false)
        await fulfillment(of: [unloaded], timeout: 2)

        let loads = await counters.loadCount
        XCTAssertEqual(loads, 1)
    }

    func testCancelledWaiterDoesNotCancelSharedLoadAndLateRequestRejoins() async throws {
        let gate = LifecycleGate()
        let started = expectation(description: "load started")
        let counters = LifecycleCounters()
        let recognizer = DictationRecognizer(idleRetention: .seconds(30)) {
            await counters.incrementLoad()
            started.fulfill()
            await gate.wait()
            return LifecycleModel(counters: counters)
        }

        let first = Task { try await recognizer.waitUntilPrepared() }
        await fulfillment(of: [started], timeout: 2)
        first.cancel()
        do {
            try await first.value
            XCTFail("The cancelled waiter should not return successfully.")
        } catch is CancellationError {
        }
        let loadsAfterCancellation = await counters.loadCount
        XCTAssertEqual(loadsAfterCancellation, 1)

        let second = Task { try await recognizer.waitUntilPrepared() }
        await Task.yield()
        await gate.release()
        try await second.value
        let loadsAfterRejoin = await counters.loadCount
        XCTAssertEqual(loadsAfterRejoin, 1)
    }

    func testReleaseDuringSuspendedLoadRevivesSameFlightForLateRequest() async throws {
        let gate = LifecycleGate()
        let started = expectation(description: "load started")
        let counters = LifecycleCounters()
        let recognizer = DictationRecognizer(idleRetention: .zero) {
            await counters.incrementLoad()
            started.fulfill()
            await gate.wait()
            return LifecycleModel(counters: counters)
        }

        await recognizer.prepare()
        await fulfillment(of: [started], timeout: 2)
        await recognizer.releaseIfIdle()

        let late = Task { try await recognizer.waitUntilPrepared() }
        await Task.yield()
        let loadsBeforeRelease = await counters.loadCount
        XCTAssertEqual(loadsBeforeRelease, 1)
        await gate.release()
        try await late.value
        let loadsAfterRelease = await counters.loadCount
        XCTAssertEqual(loadsAfterRelease, 1)
    }

    func testReleaseDiscardsSuspendedLoadResultWithoutStartingAnotherLoad() async throws {
        let gate = LifecycleGate()
        let started = expectation(description: "load started")
        let unloaded = expectation(description: "discarded model unloaded")
        let counters = LifecycleCounters()
        let recognizer = DictationRecognizer(idleRetention: .seconds(30)) {
            await counters.incrementLoad()
            started.fulfill()
            await gate.wait()
            return LifecycleModel(counters: counters, onUnload: { unloaded.fulfill() })
        }

        await recognizer.prepare()
        await fulfillment(of: [started], timeout: 2)
        await recognizer.releaseIfIdle()
        await gate.release()
        await fulfillment(of: [unloaded], timeout: 2)

        let loads = await counters.loadCount
        let unloads = await counters.unloadCount
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(unloads, 1)
    }

    func testCancelledRecognitionDoesNotReleaseSuspendedLoad() async throws {
        let gate = LifecycleGate()
        let started = expectation(description: "load started")
        let counters = LifecycleCounters()
        let recognizer = DictationRecognizer(idleRetention: .seconds(30)) {
            await counters.incrementLoad()
            started.fulfill()
            await gate.wait()
            return LifecycleModel(counters: counters)
        }

        let configuration = self.configuration
        let firstPackets = Self.stream([Self.packet()])
        let first = Task {
            try await recognizer.transcribe(
                firstPackets, configuration: configuration
            )
        }
        await fulfillment(of: [started], timeout: 2)
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("Cancelled recognition should throw.")
        } catch is CancellationError {
        }
        let loadsAfterCancellation = await counters.loadCount
        XCTAssertEqual(loadsAfterCancellation, 1)

        let secondPackets = Self.stream([Self.packet()])
        let second = Task {
            try await recognizer.transcribe(
                secondPackets, configuration: configuration
            )
        }
        await Task.yield()
        await gate.release()
        let result = try await second.value
        XCTAssertEqual(result?.transcript.rawText, "recognized")
        let loadsAfterRejoin = await counters.loadCount
        XCTAssertEqual(loadsAfterRejoin, 1)
    }

    func testPhasesAndCachedModelReuse() async throws {
        let counters = LifecycleCounters()
        let model = LifecycleModel(counters: counters)
        let recognizer = DictationRecognizer(idleRetention: .seconds(30)) {
            await counters.incrementLoad()
            return model
        }
        let phases = PhaseRecorder()

        let first = try await recognizer.transcribe(
            Self.stream([Self.packet()]), configuration: configuration,
            onPhase: { phases.append($0) }
        )
        XCTAssertEqual(first?.transcript.rawText, "recognized")
        XCTAssertEqual(phases.values, [.preparingModel, .transcribing])
        let firstLoads = await counters.loadCount
        let firstSessions = await counters.sessionCount
        let firstResets = await counters.resetCount
        XCTAssertEqual(firstLoads, 1)
        XCTAssertEqual(firstSessions, 1)
        XCTAssertEqual(firstResets, 1)

        phases.reset()
        let second = try await recognizer.transcribe(
            Self.stream([Self.packet()]), configuration: configuration,
            onPhase: { phases.append($0) }
        )
        XCTAssertEqual(second?.transcript.rawText, "recognized")
        XCTAssertEqual(phases.values, [.transcribing])
        let secondLoads = await counters.loadCount
        let secondSessions = await counters.sessionCount
        let secondResets = await counters.resetCount
        XCTAssertEqual(secondLoads, 1)
        XCTAssertEqual(secondSessions, 2)
        XCTAssertEqual(secondResets, 2)
    }

    func testShortAndSilentCaptureDoNotLoadWithoutExplicitPrewarm() async throws {
        let counters = LifecycleCounters()
        let model = LifecycleModel(counters: counters)
        let recognizer = DictationRecognizer(idleRetention: .seconds(30)) {
            await counters.incrementLoad()
            return model
        }

        let short = try await recognizer.transcribe(
            Self.stream([Self.packet(duration: 0.10)]), configuration: configuration
        )
        XCTAssertNil(short)
        let silent = try await recognizer.transcribe(
            Self.stream([Self.packet(duration: 0.50, amplitude: 0)]), configuration: configuration
        )
        XCTAssertNil(silent)
        let passiveLoads = await counters.loadCount
        XCTAssertEqual(passiveLoads, 0)

        await recognizer.prepare()
        try await recognizer.waitUntilPrepared()
        let prewarmedLoads = await counters.loadCount
        XCTAssertEqual(prewarmedLoads, 1)
    }

    func testShortPipelineCompletesWhilePrewarmLoadIsSuspended() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = LifecycleGate()
        let started = expectation(description: "load started")
        let counters = LifecycleCounters()
        let recognizer = DictationRecognizer(idleRetention: .seconds(30)) {
            await counters.incrementLoad()
            started.fulfill()
            await gate.wait()
            return LifecycleModel(counters: counters)
        }
        await recognizer.prepare()
        await fulfillment(of: [started], timeout: 2)

        let archive = AudioArchiveWriter(directoryURL: root)
        let pipeline = DictationAudioPipeline(
            archive: archive, recognizer: recognizer, configuration: configuration
        )
        try await pipeline.append(Self.packet(duration: 0.10))
        let result = try await pipeline.finish()
        XCTAssertNil(result)

        await gate.release()
        try await recognizer.waitUntilPrepared()
        await recognizer.releaseIfIdle()
    }

    func testReplayReadsMultipleAACPartsWithContinuousTimeline() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("000001.m4a")
        let secondURL = root.appendingPathComponent("000002.m4a")
        try writeAudio(to: firstURL, duration: 0.50)
        try writeAudio(to: secondURL, duration: 0.50)

        let counters = LifecycleCounters()
        let starts = StartTimeRecorder()
        let model = LifecycleModel(counters: counters, onAppend: { starts.append($0) })
        let recognizer = DictationRecognizer(idleRetention: .seconds(30)) {
            await counters.incrementLoad()
            return model
        }
        let phases = PhaseRecorder()

        let result = try await recognizer.replayArchive(
            [firstURL, secondURL], configuration: configuration,
            onPhase: { phases.append($0) }
        )
        XCTAssertEqual(result.transcript.rawText, "recognized")
        XCTAssertEqual(result.duration, 1.0, accuracy: 0.02)
        XCTAssertEqual(phases.values, [.preparingModel, .transcribing])
        let values = starts.values
        XCTAssertEqual(values.count, 2)
        if values.count == 2 {
            XCTAssertEqual(values[0], 0, accuracy: 0.001)
            XCTAssertEqual(values[1], 0.50, accuracy: 0.02)
        }
    }

    func testFallbackReplaysWithSameManagerAtZeroIdleTTL() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let counters = LifecycleCounters()
        let unloaded = expectation(description: "model unloaded")
        let model = LifecycleModel(
            counters: counters, failFinishSession: 1, onUnload: { unloaded.fulfill() }
        )
        let recognizer = DictationRecognizer(idleRetention: .zero) {
            await counters.incrementLoad()
            return model
        }
        let archive = AudioArchiveWriter(directoryURL: root)
        let pipeline = DictationAudioPipeline(
            archive: archive, recognizer: recognizer, configuration: configuration
        )
        let packet = Self.packet(duration: 0.30)

        try await pipeline.append(packet)
        let capturedDuration = await pipeline.capturedDuration()
        XCTAssertEqual(capturedDuration, 0.30, accuracy: 0.001)
        let result = try await pipeline.finish()

        XCTAssertEqual(result?.usedArchive, true)
        XCTAssertEqual(result?.audio.transcript.rawText, "recognized")
        let loads = await counters.loadCount
        let sessions = await counters.sessionCount
        let resets = await counters.resetCount
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(sessions, 2)
        XCTAssertEqual(resets, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("microphone/000001.m4a").path
        ))
        await fulfillment(of: [unloaded], timeout: 2)
    }

    func testScopedCancellationKeepsResetModelForReplayAtZeroTTL() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audioURL = root.appendingPathComponent("000001.m4a")
        try writeAudio(to: audioURL, duration: 0.50)

        let counters = LifecycleCounters()
        let sessionStarted = expectation(description: "live session started")
        let model = LifecycleModel(counters: counters, onSession: { count in
            if count == 1 { sessionStarted.fulfill() }
        })
        let recognizer = DictationRecognizer(idleRetention: .zero) {
            await counters.incrementLoad()
            return model
        }
        let scope = UUID()
        let livePhases = PhaseRecorder()
        let configuration = self.configuration
        let (packets, continuation) = AsyncStream.makeStream(of: CapturedAudioPacket.self)
        continuation.yield(Self.packet(duration: 0.30))

        let live = Task {
            try await recognizer.transcribe(
                packets, configuration: configuration, scope: scope,
                onPhase: { livePhases.append($0) }
            )
        }
        await fulfillment(of: [sessionStarted], timeout: 2)
        live.cancel()
        continuation.finish()
        do {
            _ = try await live.value
            XCTFail("Cancelled live recognition should throw.")
        } catch is CancellationError {
        }
        XCTAssertEqual(livePhases.values, [.preparingModel])

        let replayPhases = PhaseRecorder()
        let replay = try await recognizer.replayArchive(
            [audioURL], configuration: configuration, scope: scope,
            onPhase: { replayPhases.append($0) }
        )
        XCTAssertEqual(replay.transcript.rawText, "recognized")
        XCTAssertEqual(replayPhases.values, [.transcribing])
        let loads = await counters.loadCount
        let resets = await counters.resetCount
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(resets, 2)
        await recognizer.finishScope(scope)
    }

    func testResetFailureInvalidatesAndFallbackWaitsForOldManagerCleanup() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let counters = LifecycleCounters()
        let firstUnloaded = expectation(description: "first model unloaded")
        let first = LifecycleModel(
            counters: counters, failFinishSession: 1, resetFailures: 1,
            onUnload: { firstUnloaded.fulfill() }
        )
        let second = LifecycleModel(counters: counters)
        let recognizer = DictationRecognizer(idleRetention: .zero) {
            let count = await counters.incrementLoad()
            return count == 1 ? first : second
        }
        let archive = AudioArchiveWriter(directoryURL: root)
        let pipeline = DictationAudioPipeline(
            archive: archive, recognizer: recognizer, configuration: configuration
        )

        try await pipeline.append(Self.packet(duration: 0.30))
        let result = try await pipeline.finish()

        XCTAssertEqual(result?.usedArchive, true)
        let loads = await counters.loadCount
        let resets = await counters.resetCount
        let unloads = await counters.unloadCount
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(resets, 2)
        XCTAssertEqual(unloads, 2)
        await fulfillment(of: [firstUnloaded], timeout: 2)
    }

    func testFailedColdLoadIsNotRetriedByArchiveFallback() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let counters = LifecycleCounters()
        let recognizer = DictationRecognizer(idleRetention: .zero) {
            await counters.incrementLoad()
            throw ParakeetEngineError.modelUnavailable(
                ParakeetDictationModel.missingModelMessage
            )
        }
        let archive = AudioArchiveWriter(directoryURL: root)
        let pipeline = DictationAudioPipeline(
            archive: archive, recognizer: recognizer, configuration: configuration
        )

        try await pipeline.append(Self.packet(duration: 0.30))
        do {
            _ = try await pipeline.finish()
            XCTFail("A missing model should fail the pipeline.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Install Parakeet Unified"))
        }
        let loads = await counters.loadCount
        XCTAssertEqual(loads, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("microphone/000001.m4a").path
        ))
    }

    func testIdleEvictionUsesOneShotDeadline() async throws {
        let counters = LifecycleCounters()
        let unloaded = expectation(description: "model unloaded after idle")
        let model = LifecycleModel(counters: counters, onUnload: { unloaded.fulfill() })
        let recognizer = DictationRecognizer(idleRetention: .milliseconds(100)) {
            await counters.incrementLoad()
            return model
        }

        try await recognizer.waitUntilPrepared()
        await fulfillment(of: [unloaded], timeout: 2)
        let loads = await counters.loadCount
        let unloads = await counters.unloadCount
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(unloads, 1)

        try await Task.sleep(for: .milliseconds(150))
        let unloadsAfterDeadline = await counters.unloadCount
        XCTAssertEqual(unloadsAfterDeadline, 1)
    }

    private func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProsodyDictationLifecycle-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeAudio(to url: URL, duration: TimeInterval) throws {
        let rate = 16_000.0
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate * duration)
        ) else {
            throw STTError.invalidAudio
        }
        buffer.frameLength = AVAudioFrameCount(rate * duration)
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(buffer.frameLength) { channel[index] = 0.1 }
        }
        try file.write(from: buffer)
    }

    private static func packet(
        duration: TimeInterval = 0.30,
        amplitude: Float = 0.1
    ) -> CapturedAudioPacket {
        let rate = 16_000.0
        return CapturedAudioPacket(
            source: .microphone,
            presentationTime: 0,
            sampleRate: rate,
            samples: Array(repeating: amplitude, count: Int(rate * duration))
        )
    }

    private static func stream(_ packets: [CapturedAudioPacket]) -> AsyncStream<CapturedAudioPacket> {
        let (stream, continuation) = AsyncStream.makeStream(of: CapturedAudioPacket.self)
        for packet in packets { continuation.yield(packet) }
        continuation.finish()
        return stream
    }
}

private actor LifecycleCounters {
    private(set) var loadCount = 0
    private(set) var sessionCount = 0
    private(set) var resetCount = 0
    private(set) var unloadCount = 0

    @discardableResult
    func incrementLoad() -> Int {
        loadCount += 1
        return loadCount
    }

    @discardableResult
    func incrementSession() -> Int {
        sessionCount += 1
        return sessionCount
    }

    @discardableResult
    func incrementReset() -> Int {
        resetCount += 1
        return resetCount
    }

    func incrementUnload() {
        unloadCount += 1
    }
}

private actor LifecycleGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private actor LifecycleModel: DictationRecognitionModel {
    private let counters: LifecycleCounters
    private let failFinishSession: Int?
    private let resetFailures: Int
    private let onUnload: @Sendable () -> Void
    private let onAppend: @Sendable (TimeInterval) -> Void
    private let onSession: @Sendable (Int) -> Void
    private var resets = 0

    init(
        counters: LifecycleCounters,
        failFinishSession: Int? = nil,
        resetFailures: Int = 0,
        onUnload: @escaping @Sendable () -> Void = {},
        onAppend: @escaping @Sendable (TimeInterval) -> Void = { _ in },
        onSession: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.counters = counters
        self.failFinishSession = failFinishSession
        self.resetFailures = resetFailures
        self.onUnload = onUnload
        self.onAppend = onAppend
        self.onSession = onSession
    }

    func makeDictationSession(
        configuration: TranscriptSegmentationConfiguration
    ) async throws -> any DictationRecognitionSession {
        let session = await counters.incrementSession()
        onSession(session)
        return LifecycleSession(
            failFinish: failFinishSession == session,
            text: "recognized",
            onAppend: onAppend
        )
    }

    func reset() async throws {
        resets += 1
        await counters.incrementReset()
        if resets <= resetFailures { throw STTError.failed("reset failed") }
    }

    func unload() async {
        await counters.incrementUnload()
        onUnload()
    }
}

private actor LifecycleSession: DictationRecognitionSession {
    private let failFinish: Bool
    private let text: String
    private let onAppend: @Sendable (TimeInterval) -> Void

    init(
        failFinish: Bool,
        text: String,
        onAppend: @escaping @Sendable (TimeInterval) -> Void = { _ in }
    ) {
        self.failFinish = failFinish
        self.text = text
        self.onAppend = onAppend
    }

    func append(samples: [Float], startTime: TimeInterval) async throws {
        onAppend(startTime)
    }

    func finishDictation(
        appending samples: [Float],
        startTime: TimeInterval,
        endTime: TimeInterval
    ) async throws -> FinalTranscript {
        if failFinish { throw STTError.failed("live recognition failed") }
        return FinalTranscript(segments: [
            TranscriptSegment(
                source: .microphone,
                start: startTime,
                end: endTime,
                text: text,
                isFinal: true
            )
        ])
    }

    func cancel() async {}
}

private final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DictationRecognitionPhase] = []

    var values: [DictationRecognitionPhase] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ phase: DictationRecognitionPhase) {
        lock.lock()
        storage.append(phase)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}

private final class StartTimeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []

    var values: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: TimeInterval) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
#endif

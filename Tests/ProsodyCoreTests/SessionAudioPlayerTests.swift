#if canImport(XCTest)
import AppKit
import AVFoundation
import Combine
import Foundation
import XCTest
@testable import ProsodyCore

final class SessionAudioPlayerTests: XCTestCase {
    @MainActor
    func testPlayerMapsChunksPauseResumeAndSessionSwitches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProsodyPlaybackTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURLs = try makeWAVChunks(in: root.appendingPathComponent("first"), count: 3, duration: 0.2)
        let player = SessionAudioPlayer(duration: 0, audioURLs: firstURLs)

        XCTAssertTrue(player.hasAudio)
        XCTAssertEqual(player.audioTimeline.chunks.count, 3)
        XCTAssertEqual(player.duration, 0.6, accuracy: 0.03)

        player.seek(to: 0.35)
        XCTAssertEqual(player.currentTime, 0.35, accuracy: 0.001)
        XCTAssertEqual(player.activeChunkIndex, 1)
        let opensAfterSeek = player.chunkOpenCount
        player.seek(to: 0.38)
        XCTAssertEqual(player.chunkOpenCount, opensAfterSeek)
        player.seek(to: 0.65)
        XCTAssertEqual(player.activeChunkIndex, 2)
        XCTAssertEqual(player.chunkOpenCount, opensAfterSeek + 1)

        player.seek(to: 0.15)
        player.toggle()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThan(player.currentTime, 0.20)

        player.pause()
        let pausedTime = player.currentTime
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(player.currentTime, pausedTime, accuracy: 0.001)
        XCTAssertNotNil(player.decoderForTesting)
        XCTAssertNotNil(player.loadedChunkIndex)

        player.toggle()
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertGreaterThan(player.currentTime, pausedTime)

        let secondURLs = try makeWAVChunks(in: root.appendingPathComponent("second"), count: 2, duration: 0.2)
        player.load(audioURLs: secondURLs, sessionDuration: 99)
        XCTAssertTrue(player.hasAudio)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, 0.4, accuracy: 0.03)
        player.seek(to: 0.25)
        XCTAssertEqual(player.currentTime, 0.25, accuracy: 0.001)
        XCTAssertEqual(player.activeChunkIndex, 1)

        player.load(audioURLs: [], sessionDuration: 12)
        XCTAssertFalse(player.hasAudio)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, 12)
        XCTAssertTrue(player.didFinishLoading)
        XCTAssertEqual(player.requestedAudioCount, 0)
    }

    @MainActor
    func testScrubPreviewsWithoutOpeningOrSeekingUntilCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProsodyScrubTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let urls = try makeWAVChunks(in: root, count: 3, duration: 0.2)
        let player = SessionAudioPlayer(duration: 0, audioURLs: urls)
        player.seek(to: 0.05)
        let opensBeforeScrub = player.chunkOpenCount
        var committedTime: TimeInterval?
        let subscription = player.scrubCompletionPublisher.sink { completion in
            if case .committed(let time) = completion { committedTime = time }
        }
        defer { subscription.cancel() }

        player.beginScrubbing()
        player.previewSeek(to: 0.25)
        player.previewSeek(to: 0.45)

        XCTAssertEqual(player.currentTime, 0.45, accuracy: 0.001)
        XCTAssertEqual(player.chunkOpenCount, opensBeforeScrub)
        XCTAssertEqual(player.activeChunkIndex, 0)
        XCTAssertFalse(player.isPlaying)

        player.commitScrub(to: 0.45)
        XCTAssertEqual(player.currentTime, 0.45, accuracy: 0.001)
        XCTAssertEqual(player.activeChunkIndex, 2)
        XCTAssertEqual(player.chunkOpenCount, opensBeforeScrub + 1)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(try XCTUnwrap(committedTime), 0.45, accuracy: 0.001)
    }

    @MainActor
    func testCancellingScrubRestoresPositionAndPlayback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProsodyInterruptedScrubTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try makeWAVChunks(in: root, count: 2, duration: 2)
        let player = SessionAudioPlayer(audioURLs: urls)
        player.seek(to: 0.5)
        let openCount = player.chunkOpenCount

        player.beginScrubbing()
        player.previewSeek(to: 3)
        player.cancelScrub()
        XCTAssertFalse(player.isScrubbing)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0.5, accuracy: 0.001)
        XCTAssertEqual(player.chunkOpenCount, openCount)

        player.toggle()
        XCTAssertTrue(player.isPlaying)
        player.beginScrubbing()
        let origin = player.currentTime
        player.previewSeek(to: 3)
        player.cancelScrub()
        XCTAssertFalse(player.isScrubbing)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.currentTime, origin, accuracy: 0.001)
        XCTAssertEqual(player.chunkOpenCount, openCount)

        player.beginScrubbing()
        let timeBeforeStop = player.currentTime
        player.previewSeek(to: 3)
        player.stop()
        player.cancelScrub()
        XCTAssertFalse(player.isScrubbing)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, timeBeforeStop, accuracy: 0.001)
        XCTAssertNil(player.decoderForTesting)
    }

    @MainActor
    func testQueuedFinishFromReusedDecoderDoesNotSkipAfterSeek() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProsodyStaleFinishTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try makeWAVChunks(in: root, count: 2, duration: 2)
        let player = SessionAudioPlayer(audioURLs: urls)
        player.toggle()
        XCTAssertTrue(player.isPlaying)
        let decoder = try XCTUnwrap(player.decoderForTesting)
        // Queue completion on the controller, then restart that same decoder
        // before the main-actor callback can run.
        decoder.pause()
        player.audioPlayerDidFinishPlaying(decoder, successfully: true)
        player.seek(to: 1)
        XCTAssertTrue(player.decoderForTesting === decoder)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.activeChunkIndex, 0)
        XCTAssertEqual(player.chunkOpenCount, 1)
        XCTAssertEqual(player.currentTime, 1, accuracy: 0.15)
    }

    @MainActor
    func testCommitScrubAtEndStaysStoppedUntilExplicitPlay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProsodyEndScrubTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try makeWAVChunks(in: root, count: 2, duration: 2)
        let player = SessionAudioPlayer(audioURLs: urls)
        player.toggle()
        XCTAssertTrue(player.isPlaying)

        player.beginScrubbing()
        player.commitScrub(to: player.duration)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, player.duration, accuracy: 0.001)

        player.toggle()
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.activeChunkIndex, 0)
        XCTAssertEqual(player.currentTime, 0, accuracy: 0.001)
    }

    @MainActor
    func testAsyncMetadataLoadReplacesAStaleSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProsodyAsyncLoadTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURLs = try makeWAVChunks(in: root.appendingPathComponent("first"), count: 3, duration: 0.2)
        let secondURLs = try makeWAVChunks(in: root.appendingPathComponent("second"), count: 2, duration: 0.2)
        let player = SessionAudioPlayer()

        let staleLoad = Task {
            await player.loadAsync(audioURLs: firstURLs, sessionDuration: 0)
        }
        await Task.yield()
        await player.loadAsync(audioURLs: secondURLs, sessionDuration: 0)
        await staleLoad.value

        XCTAssertTrue(player.hasAudio)
        XCTAssertEqual(player.audioTimeline.chunks.count, 2)
        XCTAssertEqual(player.duration, 0.4, accuracy: 0.03)
        player.seek(to: 0.25)
        XCTAssertEqual(player.currentTime, 0.25, accuracy: 0.001)
        XCTAssertEqual(player.activeChunkIndex, 1)
    }

    @MainActor
    func testAudioAvailabilityPublisherIgnoresClockUpdates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProsodyAvailabilityPublisherTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let urls = try makeWAVChunks(in: root, count: 2, duration: 0.2)
        let player = SessionAudioPlayer(duration: 0, audioURLs: urls)
        var values: [Bool?] = []
        let cancellable = player.audioAvailabilityPublisher.sink { values.append($0) }

        player.previewSeek(to: 0.2)
        player.previewSeek(to: 0.3)

        XCTAssertEqual(values, [Optional(true)])
        XCTAssertEqual(player.currentTime, 0.3, accuracy: 0.001)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testCorruptTailOutsideNumberedArchiveMakesTheSourceUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProsodyCorruptChunkTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let urls = try makeWAVChunks(in: root, count: 3, duration: 0.2)
        try Data("not an audio header".utf8).write(to: urls[2])
        let player = SessionAudioPlayer(duration: 42, audioURLs: urls)

        XCTAssertFalse(player.hasAudio)
        XCTAssertTrue(player.didFinishLoading)
        XCTAssertEqual(player.duration, 42, accuracy: 0.001)
        XCTAssertTrue(player.audioTimeline.chunks.isEmpty)
        XCTAssertEqual(player.requestedAudioCount, 3)
    }

    @MainActor
    func testCorruptNumberedArchiveSuffixLeavesValidPrefixPlayable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProsodyCorruptArchiveTailTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try makeArchiveChunks(in: root, count: 4, corrupt: [3, 4])
        let retainedURLs = SessionAssetResolver.audioURLs(in: root)
        XCTAssertEqual(retainedURLs.map(\.lastPathComponent), urls.map(\.lastPathComponent))
        let player = SessionAudioPlayer()
        await player.loadAsync(audioURLs: retainedURLs, sessionDuration: 42)

        XCTAssertTrue(player.hasAudio)
        XCTAssertTrue(player.didFinishLoading)
        XCTAssertEqual(player.audioTimeline.chunks.map(\.url), Array(retainedURLs.prefix(2)))
        XCTAssertLessThan(player.duration, 42)
        XCTAssertEqual(player.requestedAudioCount, 4)
        let secondChunk = try XCTUnwrap(player.audioTimeline.chunks.dropFirst().first)
        player.seek(to: secondChunk.start + 0.05)
        XCTAssertEqual(player.activeChunkIndex, 1)
        player.toggle()
        XCTAssertTrue(player.isPlaying)
    }

    @MainActor
    func testNumberedArchiveRejectsCorruptOrMissingMiddleChunk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProsodyMiddleArchiveChunkTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try makeArchiveChunks(in: root, count: 3, corrupt: [2])
        let player = SessionAudioPlayer(duration: 42, audioURLs: urls)

        XCTAssertFalse(player.hasAudio)
        XCTAssertTrue(player.audioTimeline.chunks.isEmpty)

        try FileManager.default.removeItem(at: urls[1])
        player.load(audioURLs: urls, sessionDuration: 42)
        XCTAssertFalse(player.hasAudio)
        let retainedURLs = SessionAssetResolver.audioURLs(in: root)
        XCTAssertEqual(retainedURLs.map(\.lastPathComponent), [urls[0].lastPathComponent, urls[2].lastPathComponent])
        player.load(audioURLs: retainedURLs, sessionDuration: 42)
        XCTAssertFalse(player.hasAudio)
        XCTAssertTrue(player.audioTimeline.chunks.isEmpty)
    }

    @MainActor
    func testNumberedChunkGapMakesTheSelectedSourceUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProsodyChunkGapTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let urls = try makeWAVChunks(in: root, count: 3, duration: 0.2)
        let player = SessionAudioPlayer(duration: 42, audioURLs: [urls[0], urls[2]])

        XCTAssertFalse(player.hasAudio)
        XCTAssertTrue(player.didFinishLoading)
        XCTAssertEqual(player.duration, 42, accuracy: 0.001)
        XCTAssertTrue(player.audioTimeline.chunks.isEmpty)
        XCTAssertEqual(player.requestedAudioCount, 2)
    }

    @MainActor
    func testArbitrarySingleFileAndLegacyCAFPairRemainPlayable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProsodyLegacyAudioTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let arbitrary = try makeAudioFile(
            named: "recording.wav",
            in: root.appendingPathComponent("arbitrary"),
            duration: 0.2
        )
        let arbitraryPlayer = SessionAudioPlayer(duration: 0, audioURLs: [arbitrary])
        XCTAssertTrue(arbitraryPlayer.hasAudio)
        XCTAssertEqual(arbitraryPlayer.audioTimeline.chunks.count, 1)

        let legacyDirectory = root.appendingPathComponent("legacy")
        let system = try makeAudioFile(named: "system.caf", in: legacyDirectory, duration: 0.2)
        let microphone = try makeAudioFile(named: "microphone.caf", in: legacyDirectory, duration: 0.2)
        let legacyPlayer = SessionAudioPlayer(duration: 0, audioURLs: [system, microphone])
        XCTAssertTrue(legacyPlayer.hasAudio)
        XCTAssertEqual(legacyPlayer.audioTimeline.chunks.count, 2)
    }

    @MainActor
    func testCancelledAsyncLoadDoesNotReplaceReadySession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProsodyCancelledLoadTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let urls = try makeWAVChunks(in: root, count: 2, duration: 0.5)
        let player = SessionAudioPlayer(audioURLs: urls)
        let load = Task {
            await player.loadAsync(audioURLs: [], sessionDuration: 42)
        }
        load.cancel()
        await load.value

        XCTAssertTrue(player.hasAudio)
        XCTAssertTrue(player.didFinishLoading)
        XCTAssertEqual(player.duration, 1, accuracy: 0.001)
        XCTAssertEqual(player.requestedAudioCount, urls.count)
    }

    @MainActor
    func testCancellationAfterPreparationDoesNotPublishInspection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProsodyCancelledInspectionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try makeWAVChunks(in: root, count: 2, duration: 0.5)
        let player = SessionAudioPlayer()
        var load: Task<Void, Never>?
        let subscription = player.$requestedAudioCount.dropFirst().sink { _ in load?.cancel() }
        defer { subscription.cancel() }
        load = Task { await player.loadAsync(audioURLs: urls, sessionDuration: 42) }
        await load?.value

        XCTAssertFalse(player.hasAudio)
        XCTAssertFalse(player.didFinishLoading)
        XCTAssertEqual(player.requestedAudioCount, 2)
        XCTAssertEqual(player.duration, 42, accuracy: 0.001)
    }

    @MainActor
    func testRetainedWindowCloseStopsPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProsodyWindowCloseTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Keep this well inside the first chunk so the close assertion tests
        // lifecycle cleanup rather than a chunk-boundary timing race.
        let urls = try makeWAVChunks(in: root, count: 2, duration: 1.0)
        let player = SessionAudioPlayer(duration: 0, audioURLs: urls)
        player.toggle()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(player.isPlaying)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView = container
        let lifecycle = WindowPlaybackLifecycleView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        var stopCount = 0
        lifecycle.onWindowHidden = {
            player.stop()
            stopCount += 1
        }
        container.addSubview(lifecycle)

        let timeBeforeStop = player.currentTime
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(stopCount, 1)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.loadedChunkIndex)
        XCTAssertNil(player.activeChunkIndex)
        XCTAssertNil(player.decoderForTesting)
        XCTAssertTrue(player.hasAudio)
        XCTAssertEqual(player.audioTimeline.chunks.count, 2)
        let stoppedTime = player.currentTime
        XCTAssertGreaterThanOrEqual(stoppedTime, timeBeforeStop)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(player.currentTime, stoppedTime, accuracy: 0.001)

        let opensBeforeReplay = player.chunkOpenCount
        player.toggle()
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.chunkOpenCount, opensBeforeReplay + 1)
        XCTAssertNotNil(player.decoderForTesting)
        XCTAssertNotNil(player.loadedChunkIndex)
        XCTAssertNotNil(player.activeChunkIndex)

        player.stop()
        XCTAssertNil(player.decoderForTesting)
        XCTAssertNil(player.loadedChunkIndex)
        XCTAssertNil(player.activeChunkIndex)
        window.close()
    }

    private func makeWAVChunks(in directory: URL, count: Int, duration: TimeInterval) throws -> [URL] {
        try (0..<count).map { index in
            try makeAudioFile(
                named: String(format: "%06d.wav", index + 1),
                in: directory,
                duration: duration
            )
        }
    }

    private func makeArchiveChunks(in root: URL, count: Int, corrupt: Set<Int>) throws -> [URL] {
        let directory = root
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("system", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try (1...count).map { index in
            let name = String(format: "%06d.m4a", index)
            guard corrupt.contains(index) else {
                return try makeAudioFile(named: name, in: directory, duration: 1)
            }
            let url = directory.appendingPathComponent(name)
            try Data("not an audio header".utf8).write(to: url)
            return url
        }
    }

    private func makeAudioFile(
        named name: String,
        in directory: URL,
        duration: TimeInterval
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let isAAC = url.pathExtension == "m4a"
        let sampleRate = isAAC ? 16_000.0 : 8_000.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            throw PlaybackFixtureError.cannotCreateBuffer
        }
        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frameCount) {
                channel[frame] = Float(sin(Double(frame) * 0.02) * 0.1)
            }
        }

        let settings: [String: Any] = isAAC ? [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000
        ] : format.settings
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }
}

private enum PlaybackFixtureError: Error {
    case cannotCreateBuffer
}
#endif

@preconcurrency import AVFoundation
import Combine
import Foundation

private struct InspectedAudioChunk: Sendable {
    let url: URL
    let duration: TimeInterval
}

private enum AudioChunkInspection: Sendable {
    case ready([InspectedAudioChunk])
    case unavailable
    case cancelled
}

private final class PlaybackSecurityScope {
    private let url: URL

    init?(_ url: URL?) {
        guard let url, url.startAccessingSecurityScopedResource() else { return nil }
        self.url = url
    }

    deinit {
        url.stopAccessingSecurityScopedResource()
    }
}

/// Main-actor playback controller for the transcript window. Retained source
/// chunks are opened on demand, keeping decoder memory bounded by one chunk.
/// A corrupt suffix of a numbered archive can be dropped without shifting the
/// playable prefix against transcript timestamps. Reject gaps and interior
/// corruption. Source fallback belongs in the resolver.
@MainActor
public final class SessionAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum ScrubCompletion {
        case committed(TimeInterval)
        case cancelled
    }

    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval
    @Published public private(set) var isPlaying = false
    @Published public private(set) var hasAudio = false
    @Published public private(set) var didFinishLoading = false
    @Published public private(set) var requestedAudioCount = 0
    @Published public private(set) var isScrubbing = false
    private let playbackTicks = PassthroughSubject<TimeInterval, Never>()
    private let scrubCompletions = PassthroughSubject<ScrubCompletion, Never>()

    /// Row following uses the measured audio position at a finer cadence than
    /// the transport. Only a row transition invalidates the transcript view.
    var playbackTickPublisher: AnyPublisher<TimeInterval, Never> { playbackTicks.eraseToAnyPublisher() }
    var scrubCompletionPublisher: AnyPublisher<ScrubCompletion, Never> { scrubCompletions.eraseToAnyPublisher() }

    /// Emits only after inspection has settled for a nonempty request. The
    /// transcript root consumes this instead of observing every clock tick.
    var audioAvailabilityPublisher: AnyPublisher<Bool?, Never> {
        Publishers.CombineLatest3($didFinishLoading, $hasAudio, $requestedAudioCount)
            .map { state in
                guard state.0, state.2 > 0 else { return nil }
                return state.1
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    public private(set) var audioTimeline = SessionAudioTimeline.empty
    private(set) var activeChunkIndex: Int?
    private(set) var chunkOpenCount = 0

    private var player: AVAudioPlayer?
    private var securityScopedURL: URL?
    private var decoderSecurityScope: PlaybackSecurityScope?
    private(set) var loadedChunkIndex: Int?
    // Internal lifecycle probe: AVAudioPlayer owns the source file descriptor.
    var decoderForTesting: AVAudioPlayer? { player }
    private var tickTask: Task<Void, Never>?
    private var scrubOrigin: (time: TimeInterval, wasPlaying: Bool)?
    private var loadGeneration = 0
    private var inspectionTask: Task<AudioChunkInspection, Never>?

    public init(duration: TimeInterval = 0, audioURL: URL? = nil) {
        self.duration = max(0, duration)
        super.init()
        load(audioURLs: audioURL.map { [$0] } ?? [], sessionDuration: duration)
    }

    public init(duration: TimeInterval = 0, audioURLs: [URL]) {
        self.duration = max(0, duration)
        super.init()
        load(audioURLs: audioURLs, sessionDuration: duration)
    }

    deinit {
        tickTask?.cancel()
        inspectionTask?.cancel()
        player?.stop()
    }

    public func load(audioURL: URL?, sessionDuration: TimeInterval) {
        load(audioURLs: audioURL.map { [$0] } ?? [], sessionDuration: sessionDuration)
    }

    public func load(audioURLs: [URL], sessionDuration: TimeInterval, bookmarkData: Data? = nil) {
        let generation = prepareLoad(audioCount: audioURLs.count, sessionDuration: sessionDuration)
        let scopedURL = Self.resolveScope(for: audioURLs.first, bookmarkData: bookmarkData)
        let inspection = Self.inspectAudioChunksSynchronously(audioURLs, scopedURL: scopedURL)
        guard generation == loadGeneration else { return }
        applyInspection(inspection, scopedURL: scopedURL)
    }

    /// Header inspection can touch many files for hour-long sessions. Keep it
    /// off the main actor and discard stale results after a session switch.
    public func loadAsync(audioURLs: [URL], sessionDuration: TimeInterval, bookmarkData: Data? = nil) async {
        guard !Task.isCancelled else { return }
        let generation = prepareLoad(audioCount: audioURLs.count, sessionDuration: sessionDuration)
        let scopedURL = Self.resolveScope(for: audioURLs.first, bookmarkData: bookmarkData)
        let task = Task.detached(priority: .userInitiated) {
            Self.inspectAudioChunksSynchronously(audioURLs, scopedURL: scopedURL)
        }
        inspectionTask = task
        let inspection = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard generation == loadGeneration else { return }
        inspectionTask = nil
        guard !Task.isCancelled else { return }
        applyInspection(inspection, scopedURL: scopedURL)
    }

    public func cancelLoading() {
        invalidateInspection()
        didFinishLoading = false
    }

    private func invalidateInspection() {
        loadGeneration &+= 1
        inspectionTask?.cancel()
        inspectionTask = nil
    }

    private func prepareLoad(audioCount: Int, sessionDuration: TimeInterval) -> Int {
        invalidateInspection()
        stop()
        securityScopedURL = nil
        chunkOpenCount = 0
        audioTimeline = .empty
        currentTime = 0
        duration = max(0, sessionDuration)
        hasAudio = false
        didFinishLoading = false
        requestedAudioCount = audioCount
        return loadGeneration
    }

    private static func resolveScope(for firstURL: URL?, bookmarkData: Data?) -> URL? {
        guard let firstURL else { return nil }
        return try? SecurityScopedFolder.resolve(url: firstURL, bookmarkData: bookmarkData)
    }

    private func applyInspection(_ inspection: AudioChunkInspection, scopedURL: URL?) {
        switch inspection {
        case .ready(let inspected) where !inspected.isEmpty:
            securityScopedURL = scopedURL
            audioTimeline = SessionAudioTimeline(urls: inspected.map(\.url), durations: inspected.map(\.duration))
            duration = audioTimeline.duration
            hasAudio = true
            didFinishLoading = true
        case .ready, .unavailable:
            currentTime = 0
            didFinishLoading = true
        case .cancelled:
            break
        }
    }

    nonisolated private static func inspectAudioChunksSynchronously(
        _ urls: [URL],
        scopedURL: URL?
    ) -> AudioChunkInspection {
        guard !Task.isCancelled else { return .cancelled }
        guard SessionAudioTimeline.hasContiguousNumberedChunks(urls) else {
            return .unavailable
        }

        let access = PlaybackSecurityScope(scopedURL)
        defer { withExtendedLifetime(access) {} }
        var inspected: [InspectedAudioChunk] = []
        inspected.reserveCapacity(urls.count)
        var hasCorruptTail = false
        for url in urls {
            guard !Task.isCancelled else { return .cancelled }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return .unavailable }
            guard let duration = readableAudioDuration(at: url) else {
                guard hasCorruptTail || (!inspected.isEmpty && isCanonicalNumberedArchive(urls)) else {
                    return .unavailable
                }
                hasCorruptTail = true
                continue
            }
            guard !hasCorruptTail else { return .unavailable }
            inspected.append(InspectedAudioChunk(url: url, duration: duration))
        }
        return .ready(inspected)
    }

    nonisolated private static func readableAudioDuration(at url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else { return nil }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        return duration.isFinite && duration > 0 ? duration : nil
    }

    nonisolated private static func isCanonicalNumberedArchive(_ urls: [URL]) -> Bool {
        guard let directory = urls.first?.deletingLastPathComponent(),
              AudioSource(rawValue: directory.lastPathComponent) != nil,
              directory.deletingLastPathComponent().lastPathComponent == "audio" else { return false }
        return urls.enumerated().allSatisfy { index, url in
            url.deletingLastPathComponent() == directory
                && url.pathExtension.lowercased() == "m4a"
                && url.deletingPathExtension().lastPathComponent == String(format: "%06d", index + 1)
        }
    }

    public func toggle() {
        guard hasAudio, duration > 0 else { return }
        if isScrubbing {
            commitScrub(to: currentTime)
            if isPlaying { return }
        }
        if isPlaying {
            pause()
            return
        }

        if currentTime >= duration {
            currentTime = 0
        }
        applySeek(to: currentTime, resume: true)
    }

    public func pause() {
        refreshClockFromPlayer()
        player?.pause()
        isPlaying = false
        cancelTimer()
    }

    public func stop() {
        let abandonedScrub = scrubOrigin
        if isPlaying {
            refreshClockFromPlayer(minimumTime: currentTime)
        } else if let abandonedScrub {
            currentTime = abandonedScrub.time
        }
        closeDecoder()
        isPlaying = false
        resetScrub()
        cancelTimer()
        if abandonedScrub != nil { scrubCompletions.send(.cancelled) }
    }

    /// Updates only the displayed clock while a drag is in progress. The
    /// expensive source seek and chunk open happen once in `commitScrub`.
    public func beginScrubbing() {
        guard hasAudio, !isScrubbing else { return }
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        scrubOrigin = (currentTime, wasPlaying)
        isScrubbing = true
    }

    public func previewSeek(to value: TimeInterval) {
        guard value.isFinite else { return }
        currentTime = min(max(0, value), max(duration, 0))
    }

    public func commitScrub(to value: TimeInterval) {
        guard value.isFinite else { return }
        guard let origin = scrubOrigin else {
            seek(to: value)
            return
        }
        resetScrub()
        applySeek(to: value, resume: origin.wasPlaying)
        scrubCompletions.send(.committed(currentTime))
    }

    func cancelScrub() {
        guard let origin = scrubOrigin else { return }
        resetScrub()
        applySeek(to: origin.time, resume: origin.wasPlaying)
        scrubCompletions.send(.cancelled)
    }

    private func resetScrub() {
        scrubOrigin = nil
        isScrubbing = false
    }

    public func seek(to value: TimeInterval) {
        guard value.isFinite else { return }
        let interruptedScrub = isScrubbing
        resetScrub()
        applySeek(to: value, resume: isPlaying)
        if interruptedScrub { scrubCompletions.send(.cancelled) }
    }

    public func stepSeek(by delta: TimeInterval) {
        guard delta.isFinite else { return }
        seek(to: currentTime + delta)
    }

    private func applySeek(to value: TimeInterval, resume: Bool) {
        currentTime = min(max(0, value), max(duration, 0))
        guard hasAudio else {
            isPlaying = false
            cancelTimer()
            return
        }
        guard openChunkIfNeeded(containing: currentTime), let player else {
            isPlaying = false
            cancelTimer()
            return
        }

        player.currentTime = audioTimeline.localTime(
            for: currentTime,
            chunkIndex: activeChunkIndex ?? 0
        )
        if resume, currentTime < duration, player.play() {
            isPlaying = true
            startTimer()
        } else {
            if player.isPlaying { player.pause() }
            isPlaying = false
            cancelTimer()
        }
    }

    private func openChunkIfNeeded(containing time: TimeInterval) -> Bool {
        guard let index = audioTimeline.chunkIndex(containing: time) else { return false }
        if loadedChunkIndex == index, player != nil {
            activeChunkIndex = index
            return true
        }

        closeDecoder()
        let access = PlaybackSecurityScope(securityScopedURL)
        guard let nextPlayer = try? AVAudioPlayer(contentsOf: audioTimeline.chunks[index].url) else {
            return false
        }
        nextPlayer.delegate = self
        nextPlayer.prepareToPlay()
        player = nextPlayer
        decoderSecurityScope = access
        loadedChunkIndex = index
        activeChunkIndex = index
        chunkOpenCount += 1
        return true
    }

    private func closeDecoder() {
        player?.delegate = nil
        player?.stop()
        player = nil
        decoderSecurityScope = nil
        loadedChunkIndex = nil
        activeChunkIndex = nil
    }

    private func refreshClockFromPlayer(minimumTime: TimeInterval? = nil) {
        guard let measured = measuredPlaybackTime else { return }
        currentTime = max(minimumTime ?? measured, measured)
    }

    var measuredPlaybackTime: TimeInterval? {
        guard let player, let index = loadedChunkIndex else { return nil }
        return audioTimeline.globalTime(chunkIndex: index, localTime: player.currentTime)
    }

    private func startTimer() {
        cancelTimer()
        tickTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var nextTransportUpdate = clock.now.advanced(by: .milliseconds(200))
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled, self.isPlaying else { return }
                guard let measured = self.measuredPlaybackTime else { continue }
                self.playbackTicks.send(measured)
                let now = clock.now
                if now >= nextTransportUpdate {
                    self.currentTime = measured
                    nextTransportUpdate = now.advanced(by: .milliseconds(200))
                }
            }
        }
    }

    private func cancelTimer() {
        tickTask?.cancel()
        tickTask = nil
    }

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self, weak player] in
            // A queued completion can outlive a seek that reuses this decoder.
            guard let self, let player, self.player === player, self.isPlaying, !player.isPlaying,
                  let index = self.loadedChunkIndex else { return }
            guard flag else {
                self.stop()
                return
            }

            let nextStart = self.audioTimeline.chunks[index].end
            if index + 1 < self.audioTimeline.chunks.count {
                self.currentTime = nextStart
                if self.openChunkIfNeeded(containing: nextStart) {
                    self.player?.currentTime = 0
                    if self.player?.play() == true { return }
                }
            }

            self.currentTime = min(self.duration, nextStart)
            self.isPlaying = false
            self.cancelTimer()
        }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}

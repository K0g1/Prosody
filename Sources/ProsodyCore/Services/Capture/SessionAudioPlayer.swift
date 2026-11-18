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

/// Main-actor playback controller for the transcript window. Retained source
/// chunks are opened on demand, keeping decoder memory bounded by one chunk.
/// Sessions without retained audio never pretend to play. A numbered archive
/// is all-or-nothing: a failed header or sequence gap would shift every later
/// chunk against transcript timestamps. Source fallback belongs in the resolver
/// because this layer does not know source identity.
@MainActor
public final class SessionAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published public private(set) var currentTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval
    @Published public private(set) var isPlaying = false
    @Published public private(set) var hasAudio = false
    @Published public private(set) var didFinishLoading = false
    @Published public private(set) var requestedAudioCount = 0
    @Published public private(set) var isScrubbing = false
    @Published private(set) var scrubEndRequest = 0
    private let playbackTicks = PassthroughSubject<TimeInterval, Never>()

    /// Row following uses the measured audio position at a finer cadence than
    /// the transport. Only a row transition invalidates the transcript view.
    var playbackTickPublisher: AnyPublisher<TimeInterval, Never> { playbackTicks.eraseToAnyPublisher() }

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

    private var audioURLs: [URL] = []
    private var player: AVAudioPlayer?
    private var accessURL: URL?
    private(set) var loadedChunkIndex: Int?
    // Internal lifecycle probe: AVAudioPlayer owns the source file descriptor.
    var isDecoderLoadedForTesting: Bool { player != nil }
    private var tickTask: Task<Void, Never>?
    private var resumeAfterScrub = false
    private var loadGeneration = 0

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
        accessURL?.stopAccessingSecurityScopedResource()
    }

    public func load(audioURL: URL?, sessionDuration: TimeInterval) {
        load(audioURLs: audioURL.map { [$0] } ?? [], sessionDuration: sessionDuration)
    }

    public func load(audioURLs: [URL], sessionDuration: TimeInterval, bookmarkData: Data? = nil) {
        loadGeneration += 1
        let generation = loadGeneration
        prepareLoad(audioURLs: audioURLs, sessionDuration: sessionDuration, bookmarkData: bookmarkData)
        let inspection = Self.inspectAudioChunksSynchronously(audioURLs)
        guard generation == loadGeneration else { return }
        applyInspection(inspection, sessionDuration: sessionDuration)
    }

    /// Header inspection can touch many files for hour-long sessions. Keep it
    /// off the main actor and discard stale results after a session switch.
    public func loadAsync(audioURLs: [URL], sessionDuration: TimeInterval, bookmarkData: Data? = nil) async {
        loadGeneration += 1
        let generation = loadGeneration
        prepareLoad(audioURLs: audioURLs, sessionDuration: sessionDuration, bookmarkData: bookmarkData)
        let inspection = await Self.inspectAudioChunks(audioURLs)
        guard !Task.isCancelled, generation == loadGeneration else { return }
        applyInspection(inspection, sessionDuration: sessionDuration)
    }

    public func cancelLoading() {
        loadGeneration += 1
        didFinishLoading = false
    }

    private func prepareLoad(
        audioURLs: [URL],
        sessionDuration: TimeInterval,
        bookmarkData: Data?
    ) {
        stop()
        player = nil
        self.audioURLs.removeAll()
        accessURL?.stopAccessingSecurityScopedResource()
        accessURL = nil
        loadedChunkIndex = nil
        activeChunkIndex = nil
        chunkOpenCount = 0
        audioTimeline = .empty
        currentTime = 0
        duration = max(0, sessionDuration)
        hasAudio = false
        didFinishLoading = false
        requestedAudioCount = audioURLs.count
        isScrubbing = false
        resumeAfterScrub = false

        if let first = audioURLs.first,
           let resolved = try? SecurityScopedFolder.resolve(url: first, bookmarkData: bookmarkData),
           resolved.startAccessingSecurityScopedResource() {
            accessURL = resolved
        }
    }

    private func applyInspection(
        _ inspection: AudioChunkInspection,
        sessionDuration: TimeInterval
    ) {
        switch inspection {
        case .ready(let inspected):
            applyLoadedChunks(inspected, sessionDuration: sessionDuration)
        case .unavailable:
            markAudioUnavailable(sessionDuration: sessionDuration)
        case .cancelled:
            break
        }
    }

    private func applyLoadedChunks(
        _ inspected: [InspectedAudioChunk],
        sessionDuration: TimeInterval
    ) {
        guard !inspected.isEmpty else {
            markAudioUnavailable(sessionDuration: sessionDuration)
            return
        }

        let urls = inspected.map(\.url)
        let durations = inspected.map(\.duration)
        self.audioURLs = urls
        audioTimeline = SessionAudioTimeline(urls: urls, durations: durations)
        hasAudio = true
        didFinishLoading = true
        duration = audioTimeline.duration
    }

    private func markAudioUnavailable(sessionDuration: TimeInterval) {
        audioURLs.removeAll()
        audioTimeline = .empty
        currentTime = 0
        duration = max(0, sessionDuration)
        hasAudio = false
        didFinishLoading = true
        isPlaying = false
        isScrubbing = false
        resumeAfterScrub = false
        player?.stop()
        player = nil
        loadedChunkIndex = nil
        activeChunkIndex = nil
        cancelTimer()
    }

    nonisolated private static func inspectAudioChunksSynchronously(
        _ urls: [URL]
    ) -> AudioChunkInspection {
        guard !Task.isCancelled else { return .cancelled }
        guard SessionAudioTimeline.hasContiguousNumberedChunks(urls) else {
            return .unavailable
        }

        var inspected: [InspectedAudioChunk] = []
        inspected.reserveCapacity(urls.count)
        for url in urls {
            guard !Task.isCancelled else { return .cancelled }
            guard FileManager.default.fileExists(atPath: url.path),
                  let file = try? AVAudioFile(forReading: url),
                  file.processingFormat.sampleRate > 0
            else { return .unavailable }
            let duration = Double(file.length) / file.processingFormat.sampleRate
            guard duration.isFinite, duration > 0 else { return .unavailable }
            inspected.append(InspectedAudioChunk(url: url, duration: duration))
        }
        return .ready(inspected)
    }

    nonisolated private static func inspectAudioChunks(_ urls: [URL]) async -> AudioChunkInspection {
        let task = Task.detached(priority: .userInitiated) {
            Self.inspectAudioChunksSynchronously(urls)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
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
        if isPlaying {
            refreshClockFromPlayer(minimumTime: currentTime)
        }
        player?.stop()
        player = nil
        loadedChunkIndex = nil
        activeChunkIndex = nil
        isPlaying = false
        isScrubbing = false
        resumeAfterScrub = false
        cancelTimer()
    }

    /// Updates only the displayed clock while a drag is in progress. The
    /// expensive source seek and chunk open happen once in `commitScrub`.
    public func beginScrubbing() {
        guard hasAudio, !isScrubbing else { return }
        isScrubbing = true
        resumeAfterScrub = isPlaying
        if isPlaying {
            refreshClockFromPlayer()
            player?.pause()
            isPlaying = false
            cancelTimer()
        }
    }

    public func previewSeek(to value: TimeInterval) {
        guard value.isFinite else { return }
        currentTime = min(max(0, value), max(duration, 0))
    }

    public func commitScrub(to value: TimeInterval) {
        guard value.isFinite else { return }
        guard isScrubbing else {
            seek(to: value)
            return
        }
        let shouldResume = resumeAfterScrub
        isScrubbing = false
        resumeAfterScrub = false
        applySeek(to: value, resume: shouldResume)
        scrubEndRequest &+= 1
    }

    public func seek(to value: TimeInterval) {
        guard value.isFinite else { return }
        isScrubbing = false
        resumeAfterScrub = false
        applySeek(to: value, resume: isPlaying)
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
        if resume, player.play() {
            isPlaying = true
            startTimer()
        } else {
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

        player?.stop()
        player = nil
        loadedChunkIndex = nil
        activeChunkIndex = nil

        guard let nextPlayer = try? AVAudioPlayer(contentsOf: audioTimeline.chunks[index].url) else {
            return false
        }
        nextPlayer.delegate = self
        nextPlayer.prepareToPlay()
        player = nextPlayer
        loadedChunkIndex = index
        activeChunkIndex = index
        chunkOpenCount += 1
        return true
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
        Task { @MainActor [weak self] in
            guard let self, self.player === player, self.isPlaying else { return }
            guard let index = self.loadedChunkIndex else {
                self.isPlaying = false
                self.cancelTimer()
                return
            }

            let nextStart = self.audioTimeline.chunks[index].end
            if flag, index + 1 < self.audioTimeline.chunks.count {
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
}

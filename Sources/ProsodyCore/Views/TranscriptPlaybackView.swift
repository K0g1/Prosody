import AppKit
import SwiftUI

struct TranscriptFollowDirective: Equatable, Sendable {
    let rowID: UUID
    let rowIndex: Int
    let requestID: Int
    let shouldAnimate: Bool
}

/// Pure follow state. It emits at most one directive per row transition, even
/// when the source clock publishes many times inside the same row.
struct TranscriptFollowState: Equatable, Sendable {
    private(set) var lastRowID: UUID?
    private(set) var lastRowIndex: Int?
    private(set) var requestID = 0

    mutating func update(
        time: TimeInterval,
        timeline: TranscriptTimeline,
        allowsAnimation: Bool = true
    ) -> TranscriptFollowDirective? {
        guard let index = timeline.rowIndex(at: time) else {
            reset()
            return nil
        }
        let row = timeline.rows[index]
        guard row.id != lastRowID else { return nil }

        let previousIndex = lastRowIndex
        lastRowID = row.id
        lastRowIndex = index
        requestID += 1
        let distance = previousIndex.map { abs(index - $0) } ?? 0
        return TranscriptFollowDirective(
            rowID: row.id,
            rowIndex: index,
            requestID: requestID,
            shouldAnimate: allowsAnimation && distance > 0 && distance <= 6
        )
    }

    mutating func reset() {
        lastRowID = nil
        lastRowIndex = nil
    }
}

struct TranscriptFollowPolicy: Sendable {
    // Starts the centering motion just before the next spoken segment. The
    // displayed transport clock and explicit seeks stay at the actual time.
    static let playbackLead: TimeInterval = 0.18

    static func shouldFollow(
        autoFollow: Bool,
        isScrubbing: Bool,
        isSearchActive: Bool
    ) -> Bool {
        !isSearchActive && (autoFollow || isScrubbing)
    }

    static func rowTime(_ time: TimeInterval, playing: Bool, scrubbing: Bool) -> TimeInterval {
        playing && !scrubbing ? time + playbackLead : time
    }
}

@MainActor
final class TranscriptFollowController: ObservableObject {
    @Published private(set) var directive: TranscriptFollowDirective?

    private var state = TranscriptFollowState()
    private var coalescer: TranscriptFollowCoalescer
    private let clock = ContinuousClock()
    private var flushTask: Task<Void, Never>?

    init(minimumInterval: Duration = .milliseconds(40)) {
        coalescer = TranscriptFollowCoalescer(minimumInterval: minimumInterval)
    }

    func update(
        time: TimeInterval,
        timeline: TranscriptTimeline,
        allowsAnimation: Bool = true,
        minimumInterval: Duration = .milliseconds(40)
    ) {
        guard let next = state.update(
            time: time,
            timeline: timeline,
            allowsAnimation: allowsAnimation
        ) else { return }
        let now = clock.now
        coalescer.minimumInterval = minimumInterval
        if let emitted = coalescer.accept(next, at: now) {
            directive = emitted
            return
        }
        guard let delay = coalescer.delayUntilNextEmission(at: now) else { return }
        scheduleFlush(after: delay)
    }

    func suspend() {
        resetPendingUpdates()
        state.reset()
        if directive != nil { directive = nil }
    }

    func updateFromPlayback(
        time: TimeInterval,
        timeline: TranscriptTimeline,
        autoFollow: Bool,
        isPlaying: Bool,
        isScrubbing: Bool,
        isSearchActive: Bool
    ) {
        guard TranscriptFollowPolicy.shouldFollow(
            autoFollow: autoFollow,
            isScrubbing: isScrubbing,
            isSearchActive: isSearchActive
        ) else { return }
        update(
            time: TranscriptFollowPolicy.rowTime(time, playing: isPlaying, scrubbing: isScrubbing),
            timeline: timeline,
            allowsAnimation: isPlaying && !isScrubbing
        )
    }

    func finishScrub(at time: TimeInterval, timeline: TranscriptTimeline) {
        resetPendingUpdates()
        state.reset()
        directive = state.update(time: time, timeline: timeline, allowsAnimation: false)
    }

    private func resetPendingUpdates() {
        flushTask?.cancel()
        flushTask = nil
        coalescer.reset()
    }

    private func scheduleFlush(after delay: Duration) {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            let now = self.clock.now
            if self.coalescer.pending != nil, let delay = self.coalescer.delayUntilNextEmission(at: now) {
                self.scheduleFlush(after: delay)
                return
            }
            guard let pending = self.coalescer.takePending(at: now) else { return }
            self.directive = pending
        }
    }
}

/// A deterministic gate for rapid scrub samples. The latest directive wins
/// when the next emission window opens.
struct TranscriptFollowCoalescer: Sendable {
    var minimumInterval: Duration
    private(set) var lastEmission: ContinuousClock.Instant?
    private(set) var pending: TranscriptFollowDirective?

    init(minimumInterval: Duration) {
        self.minimumInterval = minimumInterval
    }

    mutating func accept(
        _ directive: TranscriptFollowDirective,
        at now: ContinuousClock.Instant
    ) -> TranscriptFollowDirective? {
        if let lastEmission,
           lastEmission.duration(to: now) < minimumInterval {
            pending = directive
            return nil
        }
        pending = nil
        lastEmission = now
        return directive
    }

    func delayUntilNextEmission(at now: ContinuousClock.Instant) -> Duration? {
        guard let lastEmission else { return nil }
        let elapsed = lastEmission.duration(to: now)
        guard elapsed < minimumInterval else { return nil }
        return minimumInterval - elapsed
    }

    mutating func takePending(at now: ContinuousClock.Instant) -> TranscriptFollowDirective? {
        guard let pending else { return nil }
        self.pending = nil
        lastEmission = now
        return pending
    }

    mutating func reset() {
        lastEmission = nil
        pending = nil
    }
}

/// This is the only transcript-side observer of the playback clock. It performs
/// a binary-search lookup and publishes only when the row changes.
struct TranscriptAudioClockObserver: View {
    @ObservedObject var player: SessionAudioPlayer
    let timeline: TranscriptTimeline
    let autoFollow: Bool
    let isSearchActive: Bool
    let controller: TranscriptFollowController

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { synchronize() }
            .onReceive(player.playbackTickPublisher) { time in synchronize(time) }
            .onChange(of: player.currentTime) { _, _ in
                if !player.isPlaying { synchronize() }
            }
            .onChange(of: player.isPlaying) { _, _ in synchronize() }
            .onReceive(player.scrubCompletionPublisher) { completion in
                switch completion {
                case .committed(let time):
                    if !isSearchActive { controller.finishScrub(at: time, timeline: timeline) }
                case .cancelled:
                    resetFollow()
                }
            }
            .onChange(of: timeline) { _, _ in resetFollow() }
            .onChange(of: autoFollow) { _, _ in resetFollow() }
            .onChange(of: isSearchActive) { _, _ in resetFollow() }
    }

    private func synchronize(_ measuredTime: TimeInterval? = nil) {
        let playing = player.isPlaying
        let time = measuredTime ?? (playing ? player.measuredPlaybackTime : nil) ?? player.currentTime
        controller.updateFromPlayback(
            time: time,
            timeline: timeline,
            autoFollow: autoFollow,
            isPlaying: playing,
            isScrubbing: player.isScrubbing,
            isSearchActive: isSearchActive
        )
    }

    private func resetFollow() {
        controller.suspend()
        synchronize()
    }
}

struct TranscriptPlaybackTransport: View {
    @Environment(\.prosodyPalette) private var palette
    @ObservedObject var player: SessionAudioPlayer
    let timeline: TranscriptTimeline
    @Binding var followsAudio: Bool
    let isSearchActive: Bool

    var body: some View {
        Group {
            if player.hasAudio {
                audioControls
            } else {
                unavailableState
            }
        }
        .onDisappear { player.stop() }
    }

    private var audioControls: some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .disabled(!player.hasAudio)
            .accessibilityLabel(player.isPlaying ? "Pause transcript audio" : "Play transcript audio")
            .accessibilityIdentifier("clippy.transcript.playback.toggle")

            Button { player.stepSeek(by: -5) } label: {
                Image(systemName: "gobackward.5")
            }
            .buttonStyle(.plain)
            .help("Back 5 seconds")
            .accessibilityLabel("Back 5 seconds")

            TranscriptTimelineBar(
                duration: player.duration,
                currentTime: player.currentTime,
                density: timeline.density,
                onScrubBegan: player.beginScrubbing,
                onScrubChanged: { if player.isScrubbing { player.previewSeek(to: $0) } },
                onScrubEnded: { if player.isScrubbing { player.commitScrub(to: $0) } },
                onScrubCancelled: player.cancelScrub,
                onStep: player.stepSeek
            )

            Button { player.stepSeek(by: 5) } label: {
                Image(systemName: "goforward.5")
            }
            .buttonStyle(.plain)
            .help("Forward 5 seconds")
            .accessibilityLabel("Forward 5 seconds")

            Text("\(ProsodyFormatters.timestamp(player.currentTime)) / \(ProsodyFormatters.duration(player.duration))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(palette.secondary)
                .frame(width: 116, alignment: .trailing)

            Button { followsAudio.toggle() } label: {
                Label(followsAudio ? "Following" : "Follow Audio", systemImage: followsAudio ? "location.fill" : "location")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(followsAudio ? palette.accent : palette.secondary)
            .opacity(isSearchActive ? 0.55 : 1)
            .disabled(isSearchActive)
            .help(isSearchActive
                ? "Clear transcript search to follow audio"
                : (followsAudio ? "Transcript follows playback" : "Resume following playback"))
            .accessibilityHint(isSearchActive ? "Clear transcript search to follow audio" : "")
            .accessibilityValue(followsAudio ? "On" : "Off")
            .accessibilityIdentifier("clippy.transcript.playback.follow")
        }
        .accessibilityIdentifier("clippy.transcript.playback")
    }

    private var unavailableState: some View {
        HStack(spacing: 10) {
            Image(systemName: player.didFinishLoading ? "speaker.slash" : "waveform")
                .foregroundStyle(palette.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(unavailableTitle)
                    .font(.system(size: 13, weight: .medium))
                Text("Reading, search, copy, notes, and export remain available.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(palette.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(palette.text.opacity(0.08), lineWidth: 1)
        }
        .accessibilityIdentifier("clippy.transcript.playback.unavailable")
    }

    private var unavailableTitle: String {
        if !player.didFinishLoading { return "Preparing audio…" }
        if player.requestedAudioCount > 0 { return "Audio could not be opened" }
        return "Audio was not retained for this session"
    }
}

struct TranscriptTimelineBar: View {
    @Environment(\.prosodyPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    let duration: TimeInterval
    let currentTime: TimeInterval
    let density: TranscriptTimelineDensity
    let onScrubBegan: () -> Void
    let onScrubChanged: (TimeInterval) -> Void
    let onScrubEnded: (TimeInterval) -> Void
    let onScrubCancelled: () -> Void
    let onStep: (TimeInterval) -> Void

    @GestureState private var isGestureActive = false
    @State private var dragID: UUID?

    var body: some View {
        GeometryReader { geometry in
            let fraction = duration > 0
                ? min(max(currentTime / duration, 0), 1)
                : 0
            let progressX = geometry.size.width * fraction
            ZStack(alignment: .leading) {
                TranscriptTimelineDensityView(density: density, duration: duration)
                    .equatable()
                    .allowsHitTesting(false)

                if progressX > 0 {
                    Rectangle()
                        .fill(palette.accent.opacity(0.24))
                        .frame(width: progressX, height: 4)
                        .allowsHitTesting(false)
                }
                Circle()
                    .fill(palette.accent)
                    .frame(width: 8, height: 8)
                    .offset(x: max(0, progressX - 4))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isGestureActive) { _, active, _ in active = true }
                    .onChanged { value in
                        guard isEnabled, duration > 0, geometry.size.width > 0 else { return }
                        if dragID == nil {
                            dragID = UUID()
                            onScrubBegan()
                        }
                        onScrubChanged(time(at: value.location.x, width: geometry.size.width))
                    }
                    .onEnded { value in
                        guard dragID != nil else { return }
                        guard isEnabled, duration > 0, geometry.size.width > 0 else {
                            cancelDrag()
                            return
                        }
                        dragID = nil
                        onScrubEnded(time(at: value.location.x, width: geometry.size.width))
                    }
            )
        }
        .frame(height: 30)
        .onChange(of: isGestureActive) { _, active in
            guard !active, let endingDrag = dragID else { return }
            // Give a successful gesture's onEnded callback the current turn.
            Task { @MainActor in
                if dragID == endingDrag { cancelDrag() }
            }
        }
        .onDisappear { cancelDrag() }
        .focusable()
        .onKeyPress(.leftArrow) {
            onStep(-5)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            onStep(5)
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel("Transcript audio timeline")
        .accessibilityValue("\(ProsodyFormatters.timestamp(currentTime)) of \(ProsodyFormatters.duration(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onStep(5)
            case .decrement: onStep(-5)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("clippy.transcript.playback.slider")
    }

    private func time(at x: CGFloat, width: CGFloat) -> TimeInterval {
        min(max(0, Double(x / width) * duration), duration)
    }

    private func cancelDrag() {
        guard dragID != nil else { return }
        dragID = nil
        onScrubCancelled()
    }
}

/// Static density is isolated behind `Equatable` so transport ticks update only
/// the lightweight progress rectangle and playhead above it.
private struct TranscriptTimelineDensityView: View, Equatable {
    @Environment(\.prosodyPalette) private var palette
    let density: TranscriptTimelineDensity
    let duration: TimeInterval

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.density == rhs.density && lhs.duration == rhs.duration
    }

    var body: some View {
        Canvas { context, size in
            let centerY = size.height / 2
            context.fill(
                Path(CGRect(x: 0, y: centerY - 1, width: size.width, height: 2)),
                with: .color(palette.text.opacity(0.10))
            )

            let bins = density.bins
            guard !bins.isEmpty else { return }
            let speechFraction = duration > 0
                ? min(max(density.speechEnd / duration, 0), 1)
                : 1
            let speechWidth = size.width * speechFraction
            let binWidth = speechWidth / CGFloat(bins.count)
            for (index, value) in bins.enumerated() where value > 0 {
                let height = CGFloat(3 + (value * 12))
                let rect = CGRect(
                    x: CGFloat(index) * binWidth,
                    y: centerY - height / 2,
                    width: max(1, binWidth * 0.72),
                    height: height
                )
                context.fill(Path(rect), with: .color(palette.text.opacity(0.12)))
            }
        }
    }
}

struct TranscriptPlaybackWindowLifecycle: NSViewRepresentable {
    let onWindowHidden: () -> Void

    func makeNSView(context: Context) -> WindowPlaybackLifecycleView {
        let view = WindowPlaybackLifecycleView()
        view.onWindowHidden = onWindowHidden
        return view
    }

    func updateNSView(_ nsView: WindowPlaybackLifecycleView, context: Context) {
        nsView.onWindowHidden = onWindowHidden
    }
}

/// Retained NSWindows keep their SwiftUI hosting hierarchy alive after close, so
/// `onDisappear` alone is not a reliable playback stop point.
final class WindowPlaybackLifecycleView: NSView {
    var onWindowHidden: (() -> Void)?

    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var hadWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else {
            if hadWindow {
                hadWindow = false
                onWindowHidden?()
            }
            return
        }

        hadWindow = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onWindowHidden?()
            }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}

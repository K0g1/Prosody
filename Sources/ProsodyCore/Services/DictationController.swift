@preconcurrency import AVFoundation
import AppKit
import ApplicationServices
import Combine

public enum DictationState: Equatable, Sendable {
    case idle, preparing, listening, transcribing, delivering, result
    public var isActive: Bool { self == .preparing || self == .listening || self == .transcribing || self == .delivering }
    // Delivery and cleanup still own the dictation resources, even after the HUD closes.
    var showsOverlay: Bool { self != .idle && self != .delivering }
}

protocol DictationCapture: AnyObject, Sendable {
    var packets: AsyncThrowingStream<CapturedAudioPacket, Error> { get }
    func start(mode: CaptureMode, microphoneDeviceID: String?) async throws
    func stop(drainOutputQueues: Bool) async
    func acknowledgePacket()
}

extension ScreenCaptureCoordinator: DictationCapture {}

@MainActor
protocol DictationTextDelivering {
    var identifier: String { get }
    func insert(_ text: String, keepOnClipboard: Bool, method: DictationInsertionMethod,
                onDispatched: () -> Void,
                waitForGestureRelease: () async -> Void,
                gestureIsHeld: () -> Bool,
                onReceipt: (DictationInsertionReceipt) -> Void) async -> Bool
}

extension DictationTextDestination: DictationTextDelivering {
    var identifier: String { application.bundleIdentifier ?? application.localizedName ?? "unknown" }
}

/// A FIFO gate with no polling. Cancellation removes a waiter and resumes it
/// with false; the holder releases the slot after its operation unwinds.
actor DictationGate {
    private var occupied = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    func acquire() async -> Bool {
        if !occupied {
            occupied = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        guard occupied else { return }
        guard !waiters.isEmpty else {
            occupied = false
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume(returning: true)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

struct DictationPreferencesSnapshot: Sendable {
    var segmentationConfiguration = TranscriptSegmentationConfiguration()
    var replacements = WordReplacementProcessor(rules: [])
    var copyToClipboard = false
    var insertionMethod: DictationInsertionMethod = .paste
}

/// One short dictation at a time. Capture and finalization are separate so a
/// new press can start recording while an earlier utterance is decoding or
/// pasting. Finalization remains serial and in release order.
@MainActor
public final class DictationController: ObservableObject {
    struct Dependencies {
        var canStart: @MainActor () -> Bool
        var preferences: @MainActor () -> DictationPreferencesSnapshot
        var frontmostApplication: @MainActor () -> NSRunningApplication?
        var makeCapture: @MainActor () -> any DictationCapture
        var resolveDestination: @MainActor (NSRunningApplication?) -> (any DictationTextDelivering)?
        var requireMicrophonePermission: @Sendable () async throws -> Void
        var saveDictation: @MainActor (Transcript, TimeInterval, AudioArchiveWriter) async throws -> Void
        var recognizer: DictationRecognizer
        var maximumSessions: Int
        var shortcut: @MainActor () -> DictationShortcut
        var activation: @MainActor () -> DictationActivation
        var accessibilityTrusted: @MainActor () -> Bool
        var requestAccessibilityPermission: @MainActor () -> Void
        var makeShortcutMonitor: @MainActor (DictationShortcut, DictationShortcutMonitorCallbacks) -> any DictationShortcutMonitoring
        var copyText: @MainActor (String) -> Void

        init(
            canStart: @escaping @MainActor () -> Bool = { true },
            preferences: @escaping @MainActor () -> DictationPreferencesSnapshot = { .init() },
            frontmostApplication: @escaping @MainActor () -> NSRunningApplication? = { nil },
            makeCapture: @escaping @MainActor () -> any DictationCapture = { ScreenCaptureCoordinator() },
            resolveDestination: @escaping @MainActor (NSRunningApplication?) -> (any DictationTextDelivering)? = {
                DictationTextDestination.capture(application: $0)
            },
            requireMicrophonePermission: @escaping @Sendable () async throws -> Void = {
                try await DictationController.requireMicrophonePermission()
            },
            saveDictation: @escaping @MainActor (Transcript, TimeInterval, AudioArchiveWriter) async throws -> Void = { _, _, _ in },
            recognizer: DictationRecognizer = DictationRecognizer(),
            maximumSessions: Int = 3,
            shortcut: @escaping @MainActor () -> DictationShortcut = { .rightCommand },
            activation: @escaping @MainActor () -> DictationActivation = { .hold },
            accessibilityTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
            requestAccessibilityPermission: @escaping @MainActor () -> Void = {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            },
            makeShortcutMonitor: @escaping @MainActor (DictationShortcut, DictationShortcutMonitorCallbacks) -> any DictationShortcutMonitoring = { shortcut, callbacks in
                DictationShortcutMonitor(
                    shortcut: shortcut,
                    changed: callbacks.changed,
                    cancel: callbacks.cancel,
                    resetGesture: callbacks.resetGesture
                )
            },
            copyText: @escaping @MainActor (String) -> Void = { DictationTextDestination.copy($0) }
        ) {
            self.canStart = canStart
            self.preferences = preferences
            self.frontmostApplication = frontmostApplication
            self.makeCapture = makeCapture
            self.resolveDestination = resolveDestination
            self.requireMicrophonePermission = requireMicrophonePermission
            self.saveDictation = saveDictation
            self.recognizer = recognizer
            self.maximumSessions = max(1, maximumSessions)
            self.shortcut = shortcut
            self.activation = activation
            self.accessibilityTrusted = accessibilityTrusted
            self.requestAccessibilityPermission = requestAccessibilityPermission
            self.makeShortcutMonitor = makeShortcutMonitor
            self.copyText = copyText
        }
    }

    private struct ShortcutConfiguration: Equatable {
        let shortcut: DictationShortcut
        let activation: DictationActivation
        let trusted: Bool
    }

    /// One in-memory failure remains copyable until dismiss/copy. A newer
    /// failure with text replaces it; a textless warning keeps the copyable
    /// text and uses a generic message so the two cannot be misattributed.
    private struct PendingFailure {
        var text: String
        var message: String
    }

    @Published public private(set) var state: DictationState = .idle {
        didSet {
            model?.objectWillChange.send()
            scheduleShortcutReconfigurationIfReady()
        }
    }
    @Published public private(set) var meter: MeterLevel = .zero
    @Published public private(set) var message = ""
    @Published public private(set) var resultText = ""
    @Published public private(set) var shortcutReady = false
    #if DEBUG
    @Published private(set) var validationReport = ""
    @Published var validationPreviewOnly = false
    #endif

    private weak var model: AppModel?
    private let dependencies: Dependencies
    private let recognizer: DictationRecognizer
    private let captureGate = DictationGate()
    private let recognitionGate = DictationGate()
    private var monitor: (any DictationShortcutMonitoring)?
    private var pendingShortcutConfiguration: ShortcutConfiguration?
    private var appliedShortcutConfiguration: ShortcutConfiguration?
    private var shortcutReconfigurationScheduled = false
    private var captureSession: DictationSession?
    private var releasedSessions: [DictationSession] = []
    private var finalizingSession: DictationSession?
    private var allSessions: [DictationSession] = []
    private var finalizationTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private var cancelling = false
    private var pendingFailure: PendingFailure?
    private var resultConfirmation: String?
    private var gestureHeld = false
    private var gestureWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []
    private var deliveryReceipts: [DictationInsertionReceipt] = []

    init(model: AppModel) {
        self.model = model
        let recognizer = DictationRecognizer()
        self.recognizer = recognizer
        dependencies = Dependencies(
            canStart: { [weak model] in
                guard let model else { return false }
                return !model.recordingState.isRecording && !model.recordingState.isBusy && !model.isTransitioning
            },
            preferences: { [weak model] in
                guard let model else { return .init() }
                return DictationPreferencesSnapshot(
                    segmentationConfiguration: model.preferences.transcriptSegmentationConfiguration,
                    replacements: WordReplacementProcessor(rules: model.preferences.wordReplacements),
                    copyToClipboard: model.preferences.copyDictationToClipboard,
                    insertionMethod: model.preferences.dictationInsertionMethod
                )
            },
            frontmostApplication: { NSWorkspace.shared.frontmostApplication },
            makeCapture: { ScreenCaptureCoordinator() },
            resolveDestination: { DictationTextDestination.capture(application: $0) },
            requireMicrophonePermission: { try await DictationController.requireMicrophonePermission() },
            saveDictation: { [weak model] transcript, duration, archive in
                guard let model else { return }
                try await model.saveDictation(transcript: transcript, duration: duration, archive: archive)
            },
            recognizer: recognizer,
            shortcut: { [weak model] in model?.preferences.dictationShortcut ?? .rightCommand },
            activation: { [weak model] in model?.preferences.dictationActivation ?? .hold }
        )
    }

    init(dependencies: Dependencies) {
        model = nil
        self.dependencies = dependencies
        recognizer = dependencies.recognizer
    }

    public var isActive: Bool { state.isActive }
    public var canFinish: Bool {
        guard let captureSession else { return false }
        return !captureSession.releaseRequested && !cancelling
    }

    public func configureShortcut(requestPermission: Bool = false) {
        if requestPermission { dependencies.requestAccessibilityPermission() }
        let desired = ShortcutConfiguration(
            shortcut: dependencies.shortcut(),
            activation: dependencies.activation(),
            trusted: dependencies.accessibilityTrusted()
        )
        if desired.trusted, monitor != nil, shortcutReady,
           appliedShortcutConfiguration == desired {
            pendingShortcutConfiguration = nil
            return
        }
        pendingShortcutConfiguration = desired
        scheduleShortcutReconfigurationIfReady()
    }

    private func scheduleShortcutReconfigurationIfReady() {
        guard pendingShortcutConfiguration != nil, !isActive, !gestureHeld,
              !shortcutReconfigurationScheduled else { return }
        shortcutReconfigurationScheduled = true
        // Never tear down the event tap from inside its own callback. The
        // deferred task also lets any in-flight state transition settle.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.shortcutReconfigurationScheduled = false
            self.applyPendingShortcutConfiguration()
        }
    }

    private func applyPendingShortcutConfiguration() {
        guard !isActive, !gestureHeld, let desired = pendingShortcutConfiguration else { return }
        if desired.trusted, monitor != nil, shortcutReady,
           appliedShortcutConfiguration == desired {
            pendingShortcutConfiguration = nil
            return
        }
        pendingShortcutConfiguration = nil
        monitor?.stop()
        monitor = nil
        shortcutReady = false
        appliedShortcutConfiguration = nil
        setGestureHeld(false)
        guard desired.trusted else { return }

        let callbacks = DictationShortcutMonitorCallbacks(
            changed: { [weak self] down in
                self?.handleShortcut(down: down, activation: desired.activation)
            },
            cancel: { [weak self] in
                guard let self, self.hasCancellableSession else { return false }
                self.cancel()
                return true
            },
            resetGesture: { [weak self] in
                self?.setGestureHeld(false)
            }
        )
        let newMonitor = dependencies.makeShortcutMonitor(desired.shortcut, callbacks)
        let started = newMonitor.start()
        shortcutReady = started
        if started {
            monitor = newMonitor
            appliedShortcutConfiguration = desired
        } else {
            newMonitor.stop()
        }
    }

    /// The event tap reports physical edges. The controller decides whether a
    /// press starts a new capture or releases the current one.
    func handleShortcut(down: Bool, activation: DictationActivation) {
        setGestureHeld(down)
        if activation == .hold {
            if down { start() } else { finish() }
        } else if down {
            if captureSession != nil { finish() } else { start() }
        }
    }

    public func start() {
        guard captureSession == nil, !cancelling, dependencies.canStart() else { return }
        guard allSessions.count < dependencies.maximumSessions else {
            message = "Dictation queue is full. Wait for earlier text to finish."
            if captureSession == nil { state = .preparing }
            return
        }
        let frontmost = dependencies.frontmostApplication()
        let session = DictationSession(frontmost: frontmost, preferences: dependencies.preferences())
        #if DEBUG
        session.isValidationPreview = usesValidationFixture && !hasValidationAudio
        if hasValidationAudio { validationReport = "Starting audio fixture…" }
        #endif
        allSessions.append(session)
        captureSession = session
        resultConfirmation = nil
        resultText = ""
        message = "Getting microphone ready…"
        state = .preparing
        session.startTask = Task { @MainActor [weak self, session] in
            guard let self else { return }
            await self.startCapture(session)
        }
    }

    public func finish() {
        guard canFinish else { return }
        finishCurrentSession()
    }

    private func finishCurrentSession() {
        guard let session = captureSession, !session.releaseRequested, !cancelling else { return }
        #if DEBUG
        if session.isValidationPreview, validationPreviewOnly {
            cancel()
            return
        }
        #endif
        session.releaseRequested = true
        session.releaseAt = .now
        captureSession = nil
        meter = .zero
        if session.isListening { enqueueReleased(session) }
        refreshState()
    }

    private func finish(_ session: DictationSession) {
        guard captureSession === session else { return }
        finishCurrentSession()
    }

    public func cancel() {
        guard isActive, !cancelling, hasCancellableSession else { return }
        setGestureHeld(false)
        cancelling = true
        message = "Cancelling…"
        if captureSession == nil, finalizingSession == nil { state = .preparing }
        let sessions = allSessions
        for session in sessions where !session.isCommitted {
            cancelSession(session)
        }
        let worker = finalizationTask
        cancellationTask = Task { @MainActor [weak self] in
            for session in sessions {
                await session.startTask?.value
                await session.stopTask?.value
            }
            await worker?.value
            guard let self else { return }
            for session in sessions where !session.isFinalized {
                await self.cleanUp(session)
                self.markFinalized(session)
            }
            self.cancelling = false
            self.clearReceiptsIfDrained()
            self.refreshState()
            self.cancellationTask = nil
        }
    }

    public func dismiss() {
        pendingFailure = nil
        resultConfirmation = nil
        resultText = ""
        message = ""
        if isActive { cancel() }
        else { state = .idle }
    }

    public func copyResult() {
        guard state == .result, !resultText.isEmpty else { return }
        dependencies.copyText(resultText)
        pendingFailure = nil
        resultConfirmation = "Copied to clipboard"
        message = resultConfirmation ?? "Copied to clipboard"
    }

    public func stopMonitoring() {
        pendingShortcutConfiguration = nil
        monitor?.stop()
        monitor = nil
        shortcutReady = false
        appliedShortcutConfiguration = nil
        setGestureHeld(false)
    }

    func releaseCachedModel() async { await recognizer.releaseIfIdle() }

    private var hasCancellableSession: Bool {
        allSessions.contains { !$0.isCommitted && !$0.isFinalized }
    }

    private func setGestureHeld(_ held: Bool) {
        gestureHeld = held
        guard !held else { return }
        let waiters = gestureWaiters
        gestureWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume() }
        scheduleShortcutReconfigurationIfReady()
    }

    func waitForGestureRelease() async {
        guard gestureHeld else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    gestureWaiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelGestureWaiter(id) }
        }
    }

    private func cancelGestureWaiter(_ id: UUID) {
        guard let index = gestureWaiters.firstIndex(where: { $0.id == id }) else { return }
        gestureWaiters.remove(at: index).continuation.resume()
    }

    private func recordDeliveryReceipt(_ receipt: DictationInsertionReceipt) {
        deliveryReceipts.append(receipt)
        if deliveryReceipts.count > dependencies.maximumSessions {
            deliveryReceipts.removeFirst(deliveryReceipts.count - dependencies.maximumSessions)
        }
    }

    private func rebaseDestination(_ session: DictationSession) {
        guard let destination = session.destination as? DictationTextDestination else { return }
        if let rebased = destination.rebased(after: deliveryReceipts) {
            session.destination = rebased
        } else if destination.hasMatchingReceipt(after: deliveryReceipts) {
            // A matching predecessor exists but the live field/caret could
            // not be verified. Keep the conservative fallback rather than
            // letting the ordinary unchanged-selection check race the paste.
            session.destination = nil
        }
    }

    private func startCapture(_ session: DictationSession) async {
        do {
            try Task.checkCancellation()
            guard !session.cancelRequested else { throw CancellationError() }
            session.destination = dependencies.resolveDestination(session.frontmost)
            #if DEBUG
            let fixture = validationAudioURL
            let microphoneFixture = validationMicrophoneURL
            let useMicrophone = fixture == nil
            if microphoneFixture != nil, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                throw UserFacingError(title: "Microphone fixture unavailable",
                                      message: "This test requires an existing microphone grant.")
            }
            if session.isValidationPreview {
                validationReport = "Captured: \(session.destination?.identifier ?? "none"); foreground: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")"
                session.isListening = true
                if captureSession === session {
                    state = .listening
                    message = "Listening · \(session.destination?.identifier ?? "No destination")"
                }
                session.previewTask = Task { @MainActor [weak self, session] in
                    var tick = 0.0
                    while !Task.isCancelled {
                        guard let self, self.captureSession === session,
                              !session.releaseRequested else { return }
                        self.meter = MeterLevel(rms: 0.003 + abs(sin(tick)) * 0.065, peak: 0.13)
                        tick += 0.6
                        if tick >= 30, self.validationPreviewOnly == false {
                            self.finish(session)
                            return
                        }
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    }
                }
                if session.releaseRequested, !session.cancelRequested { enqueueReleased(session) }
                return
            }
            #else
            let useMicrophone = true
            #endif

            guard await captureGate.acquire() else { throw CancellationError() }
            session.captureGateHeld = true
            do {
                if useMicrophone { try await dependencies.requireMicrophonePermission() }
                try Task.checkCancellation()
                guard !session.cancelRequested else { throw CancellationError() }

                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Prosody-Dictation-\(UUID().uuidString)", isDirectory: true)
                session.temporaryDirectory = directory
                let writer = AudioArchiveWriter(directoryURL: directory.appendingPathComponent("audio"))
                session.archive = writer
                let capture = dependencies.makeCapture()
                session.capture = capture
                if useMicrophone {
                    try await capture.start(mode: .microphone, microphoneDeviceID: model?.selectedMicrophoneDeviceID())
                }
                try Task.checkCancellation()
                guard !session.cancelRequested else { throw CancellationError() }

                let pipeline = makePipeline(archive: writer,
                                            configuration: session.preferences.segmentationConfiguration)
                session.pipeline = pipeline
                session.isListening = true
                if captureSession === session {
                    state = .listening
                    message = "Listening · Esc to cancel"
                }
                session.feed = makeFeed(session: session, capture: capture, pipeline: pipeline)

                #if DEBUG
                if let fixture = fixture ?? microphoneFixture {
                    session.playbackTask = Task { @MainActor [weak self, session, capture] in
                        do {
                            if microphoneFixture != nil {
                                try await DictationAudioFixture.playThroughBuiltInSpeakers(fixture)
                            } else if let capture = capture as? ScreenCaptureCoordinator {
                                try await DictationAudioFixture.replay(fixture, into: capture)
                            }
                        } catch is CancellationError {
                            return
                        } catch {
                            (capture as? ScreenCaptureCoordinator)?.failValidationFixture(error)
                        }
                        if !Task.isCancelled,
                           !ProcessInfo.processInfo.arguments.contains("--dictation-fixture-manual-stop") {
                            self?.finish(session)
                        }
                    }
                }
                #endif

                if session.releaseRequested, !session.cancelRequested { enqueueReleased(session) }
            }
        } catch {
            await handleFailure(error, session: session)
        }
    }

    private func makeFeed(session: DictationSession, capture: any DictationCapture,
                          pipeline: DictationAudioPipeline) -> Task<Void, Error> {
        Task { @MainActor [weak self, session, capture, pipeline] in
            do {
                for try await packet in capture.packets {
                    defer { capture.acknowledgePacket() }
                    try Task.checkCancellation()
                    try await pipeline.append(packet)
                    if let self, self.captureSession === session, !session.releaseRequested,
                       packet.presentationTime - session.lastMeterTime >= 0.1 {
                        session.lastMeterTime = packet.presentationTime
                        self.meter = AudioMeterCalculator.level(for: packet.samples)
                    }
                }
            } catch {
                // A stopped device must surface its error even in toggle mode,
                // where no key-up is expected.
                if !Task.isCancelled, !session.cancelRequested,
                   let self, self.captureSession === session {
                    self.finishCurrentSession()
                }
                throw error
            }
        }
    }

    private func makePipeline(archive: AudioArchiveWriter,
                              configuration: TranscriptSegmentationConfiguration) -> DictationAudioPipeline {
        let recognizer = self.recognizer
        let gate = self.recognitionGate
        return DictationAudioPipeline(
            archive: archive,
            bufferCapacity: 256,
            recognize: { packets in
                try await Self.withGate(gate) {
                    try await recognizer.transcribe(packets, configuration: configuration)
                }
            },
            replay: { urls in
                try await Self.withGate(gate) {
                    try await AudioFileTranscriber(segmentationConfiguration: configuration)
                        .transcribe(files: [.microphone: urls])
                }
            }
        )
    }

    private static func withGate<T: Sendable>(_ gate: DictationGate,
                                    operation: () async throws -> T) async throws -> T {
        guard await gate.acquire() else { throw CancellationError() }
        do {
            let value = try await operation()
            await gate.release()
            return value
        } catch {
            await gate.release()
            throw error
        }
    }

    private func enqueueReleased(_ session: DictationSession) {
        guard !session.isFinalized, !session.cancelRequested, !cancelling,
              session.stopTask == nil else { return }
        session.releaseAt = session.releaseAt ?? .now
        releasedSessions.append(session)
        session.stopTask = Task { @MainActor [weak self, session] in
            await session.capture?.stop(drainOutputQueues: true)
            session.captureStoppedAt = .now
            await self?.releaseCaptureGate(session)
            do { try await session.feed?.value }
            catch { session.feedError = error }
            session.feedDrainedAt = .now
        }
        startFinalizationWorker()
        refreshState()
    }

    private func releaseCaptureGate(_ session: DictationSession) async {
        guard session.captureGateHeld else { return }
        session.captureGateHeld = false
        await captureGate.release()
    }

    private func startFinalizationWorker() {
        guard finalizationTask == nil else { return }
        finalizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.releasedSessions.isEmpty {
                let session = self.releasedSessions.removeFirst()
                self.finalizingSession = session
                await session.stopTask?.value
                await self.finalize(session)
                self.finalizingSession = nil
                self.refreshState()
            }
            self.finalizationTask = nil
            self.refreshState()
        }
    }

    private func finalize(_ session: DictationSession) async {
        guard !session.isFinalized else { return }
        if session.cancelRequested || cancelling {
            await cleanUp(session)
            markFinalized(session)
            refreshState()
            return
        }
        if let feedError = session.feedError {
            await handleFailure(feedError, session: session)
            return
        }

        #if DEBUG
        if session.isValidationPreview {
            let text = DictationOutput.insertionText("Prosody insertion check. Café and 日本語.")
            session.resultText = text
            session.isCommitted = true
            if captureSession == nil { state = .delivering; message = "" }
            let inserted = await insert(text, into: session.destination,
                                        keepOnClipboard: session.preferences.copyToClipboard,
                                        method: session.preferences.insertionMethod)
            validationReport += "; delivery: \(inserted); foreground: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"); flags: \(CGEventSource.flagsState(.combinedSessionState).rawValue)"
            await cleanUp(session)
            finishDelivery(session, inserted: inserted)
            return
        }
        #endif

        guard let pipeline = session.pipeline, let archive = session.archive else {
            await finishQuietly(session)
            return
        }
        let release = session.releaseAt ?? .now
        do {
            try checkCancellation(session)
            guard let result = try await pipeline.finish() else {
                #if DEBUG
                if hasValidationAudio { validationReport = "Fixture finished without speech." }
                #endif
                await finishQuietly(session)
                return
            }
            try checkCancellation(session)
            let transcript = session.preferences.replacements.apply(to: result.audio.transcript)
            let text = transcript.visibleSegments.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                #if DEBUG
                if hasValidationAudio { validationReport = "Fixture finished without recognized text." }
                #endif
                await finishQuietly(session)
                return
            }
            // This is the commit boundary: Escape before this check never
            // inserts, copies, or saves an incomplete dictation.
            try checkCancellation(session)
            session.isCommitted = true
            let insertionText = DictationOutput.insertionText(text)
            session.resultText = insertionText
            if captureSession == nil {
                state = .delivering
                message = ""
            }
            rebaseDestination(session)
            let textReady = ContinuousClock.now
            let inserted = await insert(insertionText, into: session.destination,
                                        keepOnClipboard: session.preferences.copyToClipboard,
                                        method: session.preferences.insertionMethod,
                                        onDispatched: {
                                            let dispatched = ContinuousClock.now
                                            let captureStopped = session.captureStoppedAt ?? release
                                            let feedDrained = session.feedDrainedAt ?? captureStopped
                                            AppLogger.dictationLatency.info("""
                                                Dictation release to dispatch \(Self.milliseconds(release, dispatched), privacy: .public) ms; \
                                                capture stop \(Self.milliseconds(release, captureStopped), privacy: .public) ms; \
                                                packet drain \(Self.milliseconds(captureStopped, feedDrained), privacy: .public) ms; \
                                                text ready \(Self.milliseconds(release, textReady), privacy: .public) ms; \
                                                archive fallback \(result.usedArchive, privacy: .public)
                                                """)
                                        },
                                        waitForGestureRelease: { [weak self] in
                                            await self?.waitForGestureRelease()
                                        },
                                        gestureIsHeld: { [weak self] in self?.gestureHeld ?? false },
                                        onReceipt: { [weak self] receipt in
                                            self?.recordDeliveryReceipt(receipt)
                                        })
            if !inserted {
                AppLogger.dictationLatency.info("Dictation was ready after \(Self.milliseconds(release, textReady), privacy: .public) ms; insertion did not complete")
            }
            #if DEBUG
            if hasValidationAudio {
                validationReport = "Fixture text ready in \(Self.milliseconds(release, textReady)) ms; dispatched: \(inserted)"
            }
            #endif
            var saveWarning: String?
            do { try await dependencies.saveDictation(transcript, result.audio.duration, archive) }
            catch { saveWarning = "History could not be saved: \(error.localizedDescription)" }
            await cleanUp(session)
            finishDelivery(session, inserted: inserted, saveWarning: saveWarning)
        } catch {
            await handleFailure(error, session: session)
        }
    }

    private func checkCancellation(_ session: DictationSession) throws {
        try Task.checkCancellation()
        if session.cancelRequested || cancelling { throw CancellationError() }
    }

    private func cancelSession(_ session: DictationSession) {
        session.cancelRequested = true
        session.startTask?.cancel()
        session.feed?.cancel()
        session.playbackTask?.cancel()
        session.previewTask?.cancel()
        if captureSession === session { captureSession = nil }
        if let pipeline = session.pipeline {
            Task { await pipeline.cancel() }
        }
        if session.stopTask == nil, let capture = session.capture {
            session.stopTask = Task { @MainActor [weak self, session, capture] in
                await capture.stop(drainOutputQueues: true)
                session.captureStoppedAt = .now
                await self?.releaseCaptureGate(session)
            }
        }
    }

    private func finishDelivery(_ session: DictationSession, inserted: Bool, saveWarning: String? = nil) {
        markFinalized(session)
        guard !cancelling else { return }
        if !inserted || saveWarning != nil {
            let failure = saveWarning ?? "Couldn’t insert into the focused field. Copy the text below."
            recordFailure(failure, text: session.resultText)
        }
        refreshState()
    }

    /// An empty dictation releases capture and temporary audio without
    /// replacing an earlier failure that the user has not acknowledged.
    private func finishQuietly(_ session: DictationSession) async {
        await cleanUp(session)
        markFinalized(session)
        guard !cancelling else { return }
        refreshState()
    }

    private func handleFailure(_ error: Error, session: DictationSession) async {
        await cleanUp(session)
        markFinalized(session)
        guard !cancelling, !session.cancelRequested, !(error is CancellationError) else {
            refreshState()
            return
        }
        #if DEBUG
        if hasValidationAudio { validationReport = "Fixture stopped: \(error.localizedDescription)" }
        #endif
        recordFailure(error.localizedDescription, text: session.resultText)
        refreshState()
    }

    private func recordFailure(_ message: String, text: String) {
        resultConfirmation = nil
        if let existing = pendingFailure, text.isEmpty, !existing.text.isEmpty {
            pendingFailure = PendingFailure(
                text: existing.text,
                message: "A newer dictation failed. Copy the earlier text below."
            )
        } else {
            pendingFailure = PendingFailure(text: text, message: message)
        }
    }

    private func markFinalized(_ session: DictationSession) {
        session.isFinalized = true
        allSessions.removeAll { $0 === session }
        releasedSessions.removeAll { $0 === session }
        if captureSession === session { captureSession = nil }
        if finalizingSession === session { finalizingSession = nil }
    }

    private func refreshState() {
        clearReceiptsIfDrained()
        if cancelling {
            if state != .preparing { state = .preparing }
            return
        }
        if let captureSession {
            if captureSession.isListening {
                if state != .listening { state = .listening }
                if message.isEmpty { message = "Listening · Esc to cancel" }
            } else if state != .preparing {
                state = .preparing
                if message.isEmpty { message = "Getting microphone ready…" }
            }
            return
        }
        if let finalizingSession {
            if finalizingSession.isCommitted {
                if state != .delivering { state = .delivering; message = "" }
            } else if state != .transcribing {
                state = .transcribing
                message = "Transcribing… · Esc to cancel"
            }
            return
        }
        if !releasedSessions.isEmpty {
            if state != .transcribing { state = .transcribing; message = "Transcribing… · Esc to cancel" }
            return
        }
        if !allSessions.isEmpty {
            if state != .preparing { state = .preparing }
            return
        }
        if let pendingFailure {
            resultText = pendingFailure.text
            message = pendingFailure.message
            if state != .result { state = .result }
        } else if let resultConfirmation, !resultText.isEmpty {
            message = resultConfirmation
            if state != .result { state = .result }
        } else {
            resultConfirmation = nil
            if !resultText.isEmpty { resultText = "" }
            if !message.isEmpty { message = "" }
            if state != .idle { state = .idle }
        }
    }

    private func clearReceiptsIfDrained() {
        guard captureSession == nil, finalizingSession == nil,
              releasedSessions.isEmpty, allSessions.isEmpty else { return }
        deliveryReceipts.removeAll()
    }

    private func insert(_ text: String, into destination: (any DictationTextDelivering)?,
                        keepOnClipboard: Bool, method: DictationInsertionMethod,
                        onDispatched: () -> Void = {},
                        waitForGestureRelease: () async -> Void = {},
                        gestureIsHeld: () -> Bool = { false },
                        onReceipt: (DictationInsertionReceipt) -> Void = { _ in }) async -> Bool {
        let inserted = await destination?.insert(text, keepOnClipboard: keepOnClipboard, method: method,
                                                 onDispatched: onDispatched,
                                                 waitForGestureRelease: waitForGestureRelease,
                                                 gestureIsHeld: gestureIsHeld,
                                                 onReceipt: onReceipt) ?? false
        if !inserted, keepOnClipboard { DictationTextDestination.copy(text) }
        return inserted
    }

    private func cleanUp(_ session: DictationSession) async {
        guard !session.cleaned else { return }
        session.cleaned = true
        session.previewTask?.cancel()
        session.playbackTask?.cancel()
        session.startTask?.cancel()
        session.feed?.cancel()
        await session.capture?.stop(drainOutputQueues: true)
        await releaseCaptureGate(session)
        _ = try? await session.feed?.value
        await session.pipeline?.cancel()
        try? await session.archive?.discard()
        if let directory = session.temporaryDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        session.temporaryDirectory = nil
        session.capture = nil
        session.pipeline = nil
        session.archive = nil
        session.feed = nil
        session.destination = nil
        if captureSession == nil || captureSession === session { meter = .zero }
    }

    #if DEBUG
    /// Explicit opt-in UI fixtures are only available with isolated demo
    /// preferences and history. None of these paths compile in release builds.
    var usesValidationFixture: Bool {
        model?.demoMode == true && ProcessInfo.processInfo.arguments.contains("--dictation-fixture")
    }

    private var validationAudioURL: URL? {
        guard usesValidationFixture else { return nil }
        return Self.validationArgument("--dictation-audio-fixture").map { URL(fileURLWithPath: $0) }
    }

    private var validationMicrophoneURL: URL? {
        guard usesValidationFixture else { return nil }
        return Self.validationArgument("--dictation-microphone-fixture").map { URL(fileURLWithPath: $0) }
    }

    private var hasValidationAudio: Bool { validationAudioURL != nil || validationMicrophoneURL != nil }

    private static func validationArgument(_ flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let option = arguments.firstIndex(of: flag), arguments.indices.contains(option + 1) else { return nil }
        return arguments[option + 1]
    }

    func scheduleValidationDictation(applicationID: String) {
        guard usesValidationFixture else { return }
        let target = applicationID.isEmpty ? Self.validationArgument("--dictation-fixture-target") ?? "" : applicationID
        validationReport = "Starting fixture in 5 seconds…"
        Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if !target.isEmpty {
                guard let application = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == target }) else {
                    self?.validationReport = "Open the selected test application first."
                    return
                }
                NSApp.yieldActivation(to: application)
                if !application.activate(from: .current, options: []) {
                    application.activate()
                }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier,
                   !application.isTerminated, let url = application.bundleURL {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.addsToRecentItems = false
                    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
                    self?.validationReport = "Test cancelled: the selected app did not become active."
                    return
                }
            }
            self?.validationReport = ""
            self?.start()
        }
    }
    #endif

    private static func milliseconds(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Int {
        let (seconds, attoseconds) = from.duration(to: to).components
        return Int(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
    }

    private static func requireMicrophonePermission() async throws {
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
        default: granted = false
        }
        try Task.checkCancellation()
        guard granted else {
            throw UserFacingError(title: "Microphone required", message: "Allow Prosody in System Settings → Privacy & Security → Microphone.")
        }
    }
}

@MainActor
private final class DictationSession {
    let id = UUID()
    let frontmost: NSRunningApplication?
    let preferences: DictationPreferencesSnapshot
    var destination: (any DictationTextDelivering)?
    var capture: (any DictationCapture)?
    var archive: AudioArchiveWriter?
    var pipeline: DictationAudioPipeline?
    var feed: Task<Void, Error>?
    var startTask: Task<Void, Never>?
    var stopTask: Task<Void, Never>?
    var playbackTask: Task<Void, Never>?
    var previewTask: Task<Void, Never>?
    var temporaryDirectory: URL?
    var releaseAt: ContinuousClock.Instant?
    var captureStoppedAt: ContinuousClock.Instant?
    var feedDrainedAt: ContinuousClock.Instant?
    var lastMeterTime: TimeInterval = -.infinity
    var releaseRequested = false
    var isListening = false
    var isCommitted = false
    var isFinalized = false
    var cancelRequested = false
    var captureGateHeld = false
    var cleaned = false
    var feedError: Error?
    var resultText = ""
    #if DEBUG
    var isValidationPreview = false
    #endif

    init(frontmost: NSRunningApplication?, preferences: DictationPreferencesSnapshot) {
        self.frontmost = frontmost
        self.preferences = preferences
    }

    deinit {
        startTask?.cancel()
        feed?.cancel()
        playbackTask?.cancel()
        previewTask?.cancel()
    }
}

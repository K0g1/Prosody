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
                onReceipt: (DictationInsertionReceipt) -> Void,
                smartCapitalization: Bool) async -> Bool
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
        guard !Task.isCancelled else { return false }
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
    var omitFillerWords = false
    var replacements = WordReplacementProcessor(rules: [])
    var copyToClipboard = false
    var insertionMethod: DictationInsertionMethod = .paste
    var smartCapitalization = true
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
        var canPrewarmRecognition: @MainActor () -> Bool
        var preserveFailedDictation: @MainActor (TimeInterval, AudioArchiveWriter) async throws -> Bool

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
            copyText: @escaping @MainActor (String) -> Void = { DictationTextDestination.copy($0) },
            canPrewarmRecognition: @escaping @MainActor () -> Bool = {
                AXIsProcessTrusted() && MicrophonePermission.isGranted
            },
            preserveFailedDictation: @escaping @MainActor (TimeInterval, AudioArchiveWriter) async throws -> Bool = { _, _ in false }
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
            self.canPrewarmRecognition = canPrewarmRecognition
            self.preserveFailedDictation = preserveFailedDictation
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
    @Published private(set) var accessibilityGranted = false
    #if DEBUG
    @Published private(set) var validationReport = ""
    @Published var validationPreviewOnly = false
    #endif

    private weak var model: AppModel?
    private let dependencies: Dependencies
    private var recognizer: DictationRecognizer
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
    private var cleanupInFlight = 0
    private var pendingFailure: PendingFailure?
    private var resultConfirmation: String?
    private var gestureHeld = false
    private var gestureWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []
    private var deliveryReceipts: [DictationInsertionReceipt] = []

    init(model: AppModel) {
        self.model = model
        let recognizer = Self.makeRecognizer(for: model.selectedSpeechModel, inventory: model.modelManager)
        self.recognizer = recognizer
        dependencies = Dependencies(
            canStart: { [weak model] in
                guard let model else { return false }
                return !model.recordingState.isRecording && !model.recordingState.isBusy && !model.isTransitioning && !model.isImportingAudio
            },
            preferences: { [weak model] in
                guard let model else { return .init() }
                return DictationPreferencesSnapshot(
                    segmentationConfiguration: model.preferences.transcriptSegmentationConfiguration,
                    omitFillerWords: model.preferences.omitFillerWords,
                    replacements: WordReplacementProcessor(rules: model.preferences.wordReplacements),
                    copyToClipboard: model.preferences.copyDictationToClipboard,
                    insertionMethod: model.preferences.dictationInsertionMethod,
                    smartCapitalization: model.preferences.smartDictationCapitalization
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
            activation: { [weak model] in model?.preferences.dictationActivation ?? .hold },
            preserveFailedDictation: { [weak model] duration, archive in
                guard let model else { return false }
                return try await model.preserveFailedDictation(duration: duration, archive: archive)
            }
        )
    }

    init(dependencies: Dependencies) {
        model = nil
        self.dependencies = dependencies
        recognizer = dependencies.recognizer
    }

    private static func makeRecognizer(for model: SpeechModel, inventory: STTModelManager) -> DictationRecognizer {
        DictationRecognizer(idleRetention: DictationRecognizer.defaultIdleRetention) {
            try await ParakeetDictationModel.loadInstalled(model, inventory: inventory)
        }
    }

    var canChangeRecognitionModel: Bool { allSessions.isEmpty && !hasPendingCleanup }

    func selectRecognitionModel(_ model: SpeechModel, inventory: STTModelManager) async {
        let previous = recognizer
        recognizer = Self.makeRecognizer(for: model, inventory: inventory)
        await previous.releaseAndWaitIfIdle()
    }

    public var isActive: Bool { state.isActive }
    var hasPendingCleanup: Bool { cleanupInFlight > 0 }
    public var canFinish: Bool {
        guard let captureSession else { return false }
        return !captureSession.releaseRequested && !captureSession.cancelRequested
    }

    public func configureShortcut(requestPermission: Bool = false) {
        if requestPermission { dependencies.requestAccessibilityPermission() }
        let desired = ShortcutConfiguration(
            shortcut: dependencies.shortcut(),
            activation: dependencies.activation(),
            trusted: dependencies.accessibilityTrusted()
        )
        if accessibilityGranted != desired.trusted { accessibilityGranted = desired.trusted }
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
        guard captureSession == nil, dependencies.canStart() else { return }
        guard allSessions.count < dependencies.maximumSessions else {
            message = "Dictation queue is full. Wait for earlier text to finish."
            if captureSession == nil { state = .preparing }
            return
        }
        let prewarmScheduled = primeRecognitionForGesture()
        let frontmost = dependencies.frontmostApplication()
        let session = DictationSession(frontmost: frontmost, preferences: dependencies.preferences())
        session.prewarmScheduled = prewarmScheduled
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
        guard let session = captureSession, !session.releaseRequested else { return }
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
        guard isActive, hasCancellableSession else { return }
        setGestureHeld(false)
        let sessions = allSessions.filter { !$0.isCommitted && !$0.isFinalized }
        for session in sessions {
            cancelAndDetach(session)
        }
        // Escape must remove the attempt from the HUD, capacity, and queue
        // before any native stop or Core ML wait can finish.
        refreshState()
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

    /// Starts the installed-only model flight without waiting for weights. The
    /// app calls this after launch; a new gesture calls it again before the
    /// microphone starts when permission was not already granted.
    public func prewarmRecognition() {
        guard model?.canBrowseSessions != false, captureSession == nil, finalizationTask == nil, finalizingSession == nil,
              releasedSessions.isEmpty,
              !allSessions.contains(where: { $0.pipeline != nil || $0.isCommitted }) else { return }
        startPrewarmIfAuthorized()
    }

    func modelPreparationUpdates() async -> AsyncStream<Bool> {
        await recognizer.modelPreparationUpdates()
    }

    func transcribeFileWithCachedModel(_ url: URL, configuration: TranscriptSegmentationConfiguration,
                                       scope: UUID) async throws -> AudioFileTranscription {
        try await recognizer.replayArchive([url], configuration: configuration, scope: scope)
    }

    func finishExternalTranscription(_ scope: UUID) async {
        await recognizer.finishScope(scope)
    }

    func releaseCachedModel() async {
        await recognizer.releaseIfIdle()
        // A regular recording must not open the microphone while a cancelled
        // dictation is still stopping its native capture. The HUD already went
        // idle synchronously; only the hardware handoff waits here.
        guard await captureGate.acquire() else { return }
        await captureGate.release()
        if canChangeRecognitionModel { await recognizer.releaseAndWaitIfIdle() }
    }

    @discardableResult
    private func primeRecognitionForGesture() -> Bool {
        startPrewarmIfAuthorized()
    }

    @discardableResult
    private func startPrewarmIfAuthorized() -> Bool {
        guard dependencies.canPrewarmRecognition() else { return false }
        #if DEBUG
        // Demo and preview runs must not touch the installed model merely to
        // exercise UI behavior. A real audio fixture may still use the normal
        // installed-model path when both permissions already exist.
        if model?.demoMode == true, !(usesValidationFixture && hasValidationAudio) { return false }
        #endif
        let recognizer = self.recognizer
        Task { await recognizer.prepare() }
        return true
    }

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
            if session.destination == nil { AppLogger.dictationLatency.debug("No eligible destination at dictation start") }
            #if DEBUG
            let fixture = validationAudioURL
            let microphoneFixture = validationMicrophoneURL
            let useMicrophone = fixture == nil
            if microphoneFixture != nil, !MicrophonePermission.isGranted {
                throw UserFacingError(title: "Microphone fixture unavailable",
                                      message: "This test requires an existing microphone grant.")
            }
            if session.isValidationPreview {
                validationReport = "Captured: \(session.destination?.identifier ?? "none"); foreground: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")"
                session.isListening = true
                session.listeningMessage = "Listening · \(session.destination?.identifier ?? "No destination")"
                if captureSession === session {
                    refreshState()
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
            do {
                // Cancellation may have removed and cleaned this session while
                // it waited for the hardware gate. Check before claiming the
                // slot so a stale resume cannot leak it.
                try Task.checkCancellation()
                guard !session.cancelRequested, !session.cleaned,
                      !session.isFinalized else { throw CancellationError() }
            } catch {
                await captureGate.release()
                throw error
            }
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
                    // Permission is settled here, so this is the first point
                    // where a not-determined launch can safely prewarm.
                    if !session.prewarmScheduled {
                        session.prewarmScheduled = primeRecognitionForGesture()
                    }
                    try await capture.start(mode: .microphone, microphoneDeviceID: model?.selectedMicrophoneDeviceID())
                }
                try Task.checkCancellation()
                guard !session.cancelRequested else { throw CancellationError() }

                let pipeline = makePipeline(session: session,
                                            archive: writer,
                                            configuration: session.preferences.segmentationConfiguration)
                session.pipeline = pipeline
                session.isListening = true
                session.listeningMessage = "Listening · Esc to cancel"
                if captureSession === session {
                    refreshState()
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

    private func makePipeline(session: DictationSession,
                              archive: AudioArchiveWriter,
                              configuration: TranscriptSegmentationConfiguration) -> DictationAudioPipeline {
        let recognizer = self.recognizer
        let gate = self.recognitionGate
        let lease = PipelineRecognitionLease(gate: gate)
        session.recognitionLease = lease
        let scope = UUID()
        session.recognitionScope = scope
        let sessionID = session.id
        let phaseGeneration = session.phaseGeneration
        let liveGeneration = phaseGeneration.current()
        let livePhase: @Sendable (DictationRecognitionPhase) -> Void = { [weak self] phase in
            Task { @MainActor [weak self] in
                self?.applyRecognitionPhase(
                    phase,
                    sessionID: sessionID,
                    generation: liveGeneration
                )
            }
        }
        return DictationAudioPipeline(
            archive: archive,
            bufferCapacity: 256,
            recognize: { packets in
                try await lease.begin()
                return try await recognizer.transcribe(
                    packets,
                    configuration: configuration,
                    scope: scope,
                    onPhase: livePhase
                )
            },
            replay: { urls in
                let replayGeneration = phaseGeneration.next()
                let replayPhase: @Sendable (DictationRecognitionPhase) -> Void = { [weak self] phase in
                    Task { @MainActor [weak self] in
                        self?.applyRecognitionPhase(
                            phase,
                            sessionID: sessionID,
                            generation: replayGeneration
                        )
                    }
                }
                try await lease.begin()
                return try await recognizer.replayArchive(
                    urls,
                    configuration: configuration,
                    scope: scope,
                    onPhase: replayPhase
                )
            }
        )
    }

    private func applyRecognitionPhase(
        _ phase: DictationRecognitionPhase,
        sessionID: UUID,
        generation: Int
    ) {
        guard let session = allSessions.first(where: { $0.id == sessionID }),
              !session.isFinalized, !session.cancelRequested,
              session.phaseGeneration.current() == generation else { return }
        if session.recognitionPhaseGeneration != generation {
            session.recognitionPhaseGeneration = generation
            session.recognitionPhase = nil
        }
        if let current = session.recognitionPhase,
           current.progressOrder > phase.progressOrder { return }
        session.recognitionPhase = phase
        refreshState()
    }

    private func releaseRecognitionLease(_ session: DictationSession) async {
        if let scope = session.recognitionScope {
            session.recognitionScope = nil
            // The scope pins the shared model through live recognition and any
            // archive replay. Clear it before opening the controller gate so a
            // later pipeline cannot observe a released manager.
            await recognizer.finishScope(scope)
        }
        await session.recognitionLease?.finish()
        session.recognitionLease = nil
    }

    private func enqueueReleased(_ session: DictationSession) {
        guard !session.isFinalized, !session.cancelRequested else { return }
        session.releaseAt = session.releaseAt ?? .now
        if !releasedSessions.contains(where: { $0 === session }) {
            releasedSessions.append(session)
        }
        ensureStopTask(session)
        startFinalizationWorker()
        refreshState()
    }

    /// Capture stop is a one-shot operation. Release, cancellation, and cleanup
    /// all converge here so a device cannot be stopped twice or have its gate
    /// released by a second worker.
    private func ensureStopTask(_ session: DictationSession) {
        guard session.stopTask == nil, let capture = session.capture else { return }
        session.stopTask = Task { @MainActor [weak self, session, capture] in
            await capture.stop(drainOutputQueues: true)
            session.captureStoppedAt = .now
            await self?.releaseCaptureGate(session)
            do { try await session.feed?.value }
            catch { session.feedError = error }
            session.feedDrainedAt = .now
        }
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
                guard !session.cancelRequested, !session.isFinalized else { continue }
                self.finalizingSession = session
                await session.stopTask?.value
                await self.finalize(session)
                if self.finalizingSession === session {
                    self.finalizingSession = nil
                }
                self.refreshState()
            }
            self.finalizationTask = nil
            self.refreshState()
        }
    }

    private func finalize(_ session: DictationSession) async {
        guard !session.isFinalized else { return }
        if session.cancelRequested {
            await cleanUp(session)
            markFinalized(session)
            refreshState()
            return
        }
        if let feedError = session.feedError {
            await handleFailure(feedError, session: session, recoveryEligible: true)
            return
        }

        #if DEBUG
        if session.isValidationPreview {
            let text = DictationOutput.insertionText("Prosody insertion check. Café and 日本語.")
            session.resultText = text
            session.isCommitted = true
            refreshState()
            let inserted = await insert(text, into: session.destination,
                                        keepOnClipboard: session.preferences.copyToClipboard,
                                        method: session.preferences.insertionMethod,
                                        smartCapitalization: session.preferences.smartCapitalization)
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
            let finished: (audio: AudioFileTranscription, usedArchive: Bool)?
            do {
                finished = try await pipeline.finish()
            } catch {
                await releaseRecognitionLease(session)
                throw error
            }
            // The pipeline owns the gate through both live recognition and any
            // archive replay. Release it only after that complete path returns.
            await releaseRecognitionLease(session)
            guard let result = finished else {
                #if DEBUG
                if hasValidationAudio { validationReport = "Fixture finished without speech." }
                #endif
                await finishQuietly(session)
                return
            }
            try checkCancellation(session)
            let recognized = result.audio.transcript
            let cleaned = session.preferences.omitFillerWords ? FillerWordFilter().apply(to: recognized) : recognized
            let transcript = session.preferences.replacements.apply(to: cleaned)
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
            refreshState()
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
                                        },
                                        smartCapitalization: session.preferences.smartCapitalization)
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
            await handleFailure(error, session: session, recoveryEligible: true)
        }
    }

    private func checkCancellation(_ session: DictationSession) throws {
        try Task.checkCancellation()
        if session.cancelRequested { throw CancellationError() }
    }

    private func cancelAndDetach(_ session: DictationSession) {
        guard !session.isCommitted, !session.isFinalized else { return }
        session.cancelRequested = true
        session.startTask?.cancel()
        session.feed?.cancel()
        session.playbackTask?.cancel()
        session.previewTask?.cancel()
        if captureSession === session {
            captureSession = nil
            meter = .zero
        }
        releasedSessions.removeAll { $0 === session }
        allSessions.removeAll { $0 === session }
        if finalizingSession === session { finalizingSession = nil }
        if let pipeline = session.pipeline, session.pipelineCancelTask == nil {
            session.pipelineCancelTask = Task { await pipeline.cancel() }
        }
        ensureStopTask(session)
        guard session.cleanupTask == nil else { return }
        cleanupInFlight += 1
        session.cleanupTask = Task { @MainActor [weak self, session] in
            guard let self else { return }
            await self.cleanUp(session)
            self.markFinalized(session)
            self.refreshState()
            self.cleanupInFlight -= 1
        }
    }

    private func finishDelivery(_ session: DictationSession, inserted: Bool, saveWarning: String? = nil) {
        markFinalized(session)
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
        refreshState()
    }

    private func handleFailure(
        _ error: Error,
        session: DictationSession,
        recoveryEligible: Bool = false
    ) async {
        var recoveryNote: String?
        if recoveryEligible, !session.cancelRequested, !(error is CancellationError),
           let pipeline = session.pipeline, let archive = session.archive {
            let duration = await pipeline.capturedDuration()
            if duration >= DictationAudioPipeline.minimumDuration,
               !session.cancelRequested, !Task.isCancelled {
                // Recovery adoption moves the archive out of the temporary
                // directory. Commit that ownership before the await so Escape
                // cannot start a concurrent discard while files are moving.
                session.isCommitted = true
                refreshState()
                do {
                    if try await dependencies.preserveFailedDictation(duration, archive) {
                        recoveryNote = "Audio saved in Recovery."
                    }
                } catch {
                    // Recovery storage failed after capture succeeded. Keep the
                    // otherwise valid archive for manual recovery instead of
                    // letting the ordinary cleanup path discard it.
                    session.keepTemporaryAudio = true
                    let path = session.temporaryDirectory?.path
                        ?? archive.directoryURL.deletingLastPathComponent().path
                    recoveryNote = "Audio recovery failed: \(error.localizedDescription). Temporary audio remains at \(path)."
                }
            }
        }
        await cleanUp(session)
        markFinalized(session)
        guard !session.cancelRequested, !(error is CancellationError) else {
            refreshState()
            return
        }
        #if DEBUG
        if hasValidationAudio { validationReport = "Fixture stopped: \(error.localizedDescription)" }
        #endif
        let failure = [error.localizedDescription, recoveryNote]
            .compactMap { $0 }
            .joined(separator: " ")
        recordFailure(failure, text: session.resultText)
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
        if let captureSession, !captureSession.cancelRequested, !captureSession.isFinalized {
            if captureSession.isListening {
                present(.listening, message: captureSession.listeningMessage)
            } else {
                present(.preparing, message: "Getting microphone ready…")
            }
            return
        }
        if let finalizingSession, presentFinishingStatus(for: finalizingSession) { return }
        if let releasedHead = releasedSessions.first,
           presentFinishingStatus(for: releasedHead) { return }
        if !allSessions.isEmpty {
            present(.preparing, message: "Preparing dictation…")
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

    @discardableResult
    private func presentFinishingStatus(for session: DictationSession) -> Bool {
        guard allSessions.contains(where: { $0 === session }),
              !session.cancelRequested, !session.isFinalized else { return false }
        if session.isCommitted {
            present(.delivering, message: "")
            return true
        }
        let phase = session.recognitionPhaseGeneration == session.phaseGeneration.current()
            ? session.recognitionPhase : nil
        switch phase {
        case .preparingModel:
            present(.preparing, message: "Preparing speech model… · Esc to cancel")
        case .transcribing:
            present(.transcribing, message: "Transcribing… · Esc to cancel")
        case nil:
            present(.preparing, message: "Finishing audio… · Esc to cancel")
        }
        return true
    }

    private func present(_ newState: DictationState, message newMessage: String) {
        if state != newState { state = newState }
        if message != newMessage { message = newMessage }
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
                        onReceipt: (DictationInsertionReceipt) -> Void = { _ in },
                        smartCapitalization: Bool = true) async -> Bool {
        let inserted = await destination?.insert(text, keepOnClipboard: keepOnClipboard, method: method,
                                                 onDispatched: onDispatched,
                                                 waitForGestureRelease: waitForGestureRelease,
                                                 gestureIsHeld: gestureIsHeld,
                                                 onReceipt: onReceipt,
                                                 smartCapitalization: smartCapitalization) ?? false
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
        // The stop task is the single owner of device shutdown and gate
        // release. Awaiting it here also covers a start that was suspended in
        // capture.start when cancellation arrived.
        ensureStopTask(session)
        await session.stopTask?.value
        await releaseCaptureGate(session)
        _ = try? await session.feed?.value
        await session.pipelineCancelTask?.value
        await session.pipeline?.cancel()
        await releaseRecognitionLease(session)
        if !session.keepTemporaryAudio {
            try? await session.archive?.discard()
            if let directory = session.temporaryDirectory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        session.temporaryDirectory = nil
        session.capture = nil
        session.pipeline = nil
        session.archive = nil
        session.feed = nil
        session.destination = nil
        if captureSession == nil || captureSession === session { meter = .zero }
        session.cleanupTask = nil
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
        let granted = await MicrophonePermission.requestIfNeeded()
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
    var recognitionLease: PipelineRecognitionLease?
    var recognitionScope: UUID?
    var feed: Task<Void, Error>?
    var startTask: Task<Void, Never>?
    var stopTask: Task<Void, Never>?
    var cleanupTask: Task<Void, Never>?
    var pipelineCancelTask: Task<Void, Never>?
    var playbackTask: Task<Void, Never>?
    var previewTask: Task<Void, Never>?
    var temporaryDirectory: URL?
    var releaseAt: ContinuousClock.Instant?
    var captureStoppedAt: ContinuousClock.Instant?
    var feedDrainedAt: ContinuousClock.Instant?
    var lastMeterTime: TimeInterval = -.infinity
    var releaseRequested = false
    var isListening = false
    var listeningMessage = "Listening · Esc to cancel"
    var prewarmScheduled = false
    var isCommitted = false
    var isFinalized = false
    var cancelRequested = false
    var captureGateHeld = false
    var cleaned = false
    var keepTemporaryAudio = false
    var feedError: Error?
    var resultText = ""
    let phaseGeneration = RecognitionPhaseGeneration()
    var recognitionPhaseGeneration = -1
    var recognitionPhase: DictationRecognitionPhase?
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
        cleanupTask?.cancel()
        pipelineCancelTask?.cancel()
    }
}

/// Phase callbacks can outlive the recognition path that emitted them. A small
/// lock-backed generation token lets the live path and archive replay share a
/// session without allowing an old callback to overwrite the newer path.
private final class RecognitionPhaseGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Holds the controller-wide recognition gate for one capture pipeline. The
/// lease spans the live pass and any archive replay so a later utterance cannot
/// acquire between those two phases and reorder delivery.
private actor PipelineRecognitionLease {
    private let gate: DictationGate
    private var held = false
    private var finished = false

    init(gate: DictationGate) {
        self.gate = gate
    }

    func begin() async throws {
        try Task.checkCancellation()
        guard !finished else { throw CancellationError() }
        if held { return }
        guard await gate.acquire() else { throw CancellationError() }
        if finished {
            await gate.release()
            throw CancellationError()
        }
        if held {
            await gate.release()
            return
        }
        held = true
    }

    func finish() async {
        guard !finished else { return }
        finished = true
        guard held else { return }
        held = false
        await gate.release()
    }
}

private extension DictationRecognitionPhase {
    var progressOrder: Int {
        switch self {
        case .preparingModel: 0
        case .transcribing: 1
        }
    }
}

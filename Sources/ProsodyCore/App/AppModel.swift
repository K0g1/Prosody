@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation
import UserNotifications

/// The main-actor coordinator shared by the menu bar, settings, and
/// transcript windows. The UI owns no recording truth: capture, STT, and
/// transcript assembly live in their services, while this object publishes
/// snapshots and drives the user-visible state machine.
@MainActor
public final class AppModel: ObservableObject {
    /// The application has one source of truth shared by the menu bar,
    /// settings, transcript window, and the explicit UI-test host.
    public static let shared = AppModel()

    @Published public var recordingTitle = ""
    @Published public var recordingState: RecordingState = .idle
    @Published public var activeSession: RecordingSession?
    @Published public var recentSessions: [SessionSummary]
    @Published public var liveSegments: [TranscriptSegment] = []
    @Published public var transcript: Transcript
    @Published public var systemMeter: MeterLevel = .zero
    @Published public var microphoneMeter: MeterLevel = .zero
    @Published public var processingStatus: ProcessingStatus?
    @Published public var userFacingError: UserFacingError?
    @Published public var selectedSessionID: UUID?
    @Published var requestedSettingsSection: SettingsSection?
    @Published var librarySidebarVisible = true
    @Published var libraryShowDictationRequest = 0
    @Published var libraryFindRequest = 0
    @Published var librarySelection: [UUID] = []
    @Published var isImportingAudio = false
    @Published var isCompressingAudio = false
    @Published var audioAssetRevision = 0
    @Published public var lastNotice: String?
    @Published public private(set) var recordingCompletion: RecordingCompletion?
    private var completionDismissal: Task<Void, Never>?
    @Published public private(set) var recoverableSessions: [RecoveryManifest] = []
    @Published public internal(set) var installedModelIDs: Set<String> = []
    @Published var cachedModelIDs: Set<String> = []
    @Published public internal(set) var modelStorageUsedBytes: Int64 = 0
    @Published public internal(set) var modelDownloadingID: String?
    @Published public internal(set) var modelDownloadProgress: Double = 0

    public lazy var dictation = DictationController(model: self)
    lazy var softwareUpdates = SoftwareUpdates(model: self)

    public let preferences: ProsodyPreferences

    let demoMode: Bool
    let supportRootURL: URL
    private let recoveryStore: RecoveryStore
    private let keychainStore = KeychainStore()
    let transcriptUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 8
        return manager
    }()
    let cliService = CLIService()
    let modelManager: STTModelManager
    var modelDownloadTask: Task<Void, Never>?
    private let diarizer: FluidAudioDiarizer
    private var globalHotkeyManager: GlobalHotkeyManager?
    private var registeredGlobalShortcut: String?

    @Published public internal(set) var isTransitioning = false
    @Published public internal(set) var selectedSessionHasNotes = false
    var selectionTask: Task<Void, Never>?
    private var lastMeterPTS: [AudioSource: TimeInterval] = [:]
    private var recoveryCheckpointTimes: [AudioSource: TimeInterval] = [:]
    private var notesFallbackWarning: String?
    private var recordingWarning: String?
    private var audioArchiveWarning: String?

    var transitionTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var transcriptFeedTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var sttUpdateTasks: [AudioSource: Task<Void, Never>] = [:]

    private var demoPipeline: MockRecordingPipeline?
    private var productionCapture: ScreenCaptureCoordinator?
    private var handlingCaptureFailure = false
    private var productionEngine: (any STTEngine)?
    private var recordingSegmentationConfiguration = TranscriptSegmentationConfiguration()
    private var productionSTTSessions: [AudioSource: any STTSession] = [:]
    private var productionCoordinator: TranscriptCoordinator?
    var audioArchiveWriter: AudioArchiveWriter?
    private var productionClock = SessionClock()
    private var lastCapturePTS: TimeInterval?

    private var recordingStartedAt: Date?
    var accumulatedDuration: TimeInterval = 0
    var activeRecoveryID: UUID?
    private var recoverySegmentIDs: Set<UUID> = []

    public init(preferences: ProsodyPreferences? = nil, demoMode: Bool? = nil,
                supportRootURL: URL? = nil, registerHotkey: Bool = true, loadStoredState: Bool = true) {
        let runningInDemoMode = demoMode ?? AppConstants.isDemoModeRequested
        self.demoMode = runningInDemoMode
        if let preferences {
            self.preferences = preferences
        } else if runningInDemoMode {
            // Demo mode must never display or mutate the user's real labels,
            // destinations, or recording history. An ephemeral suite keeps
            // the built-in demo useful for screenshots and UI automation.
            let demoDefaults = UserDefaults(suiteName: "com.openai.clippy.demo.\(UUID().uuidString)")!
            self.preferences = ProsodyPreferences(defaults: demoDefaults)
            self.preferences.outputFolderPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("Prosody-Demo-\(UUID().uuidString)/Recordings").path
        } else {
            self.preferences = ProsodyPreferences()
        }

        let applicationSupport = supportRootURL ?? (runningInDemoMode
            ? FileManager.default.temporaryDirectory.appendingPathComponent("Prosody-Demo-Support-\(UUID().uuidString)")
            : ProsodyStorage.applicationSupportDirectory)
        self.supportRootURL = applicationSupport
        self.modelManager = STTModelManager(rootURL: applicationSupport.appendingPathComponent("Models", isDirectory: true))
        self.recoveryStore = RecoveryStore(
            rootURL: applicationSupport.appendingPathComponent(AppConstants.recoveryFolderName, isDirectory: true)
        )
        self.diarizer = FluidAudioDiarizer(
            modelDirectory: applicationSupport
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent("Diarization", isDirectory: true)
        )

        let samples = self.demoMode ? Self.sampleSessions() : []
        self.recentSessions = samples
        self.selectedSessionID = samples.first?.id
        self.transcript = Transcript(segments: self.demoMode ? Self.sampleSegments() : [])

        if registerHotkey { configureGlobalHotkey() }

        if loadStoredState && !self.demoMode { Task { @MainActor [weak self] in
            await self?.loadPersistedState()
            await self?.refreshModelInventory()
        } }
    }

    deinit {
        modelDownloadTask?.cancel()
        transitionTask?.cancel()
        meterTask?.cancel()
        eventTask?.cancel()
        transcriptFeedTask?.cancel()
        captureTask?.cancel()
        sttUpdateTasks.values.forEach { $0.cancel() }
    }

    public var canToggleRecording: Bool {
        guard !isTransitioning, !isImportingAudio, !dictation.isActive else { return false }
        switch recordingState {
        case .idle, .recording, .paused, .completed, .failed:
            return true
        case .preparing, .stopping, .finalizingTranscript, .diarizing, .generatingNotes:
            return false
        }
    }

    public var canFinishRecording: Bool {
        guard !isTransitioning, !isImportingAudio, !dictation.isActive else { return false }
        switch recordingState {
        case .recording, .paused: return true
        default: return false
        }
    }

    public var canBrowseSessions: Bool {
        !recordingState.isRecording && !recordingState.isBusy && !isTransitioning && !isImportingAudio && !dictation.isActive
    }

    public var selectedSessionTitle: String {
        if let activeSession, activeSession.id == selectedSessionID {
            return activeSession.title
        }
        return recentSessions.first(where: { $0.id == selectedSessionID })?.title
            ?? activeSession?.title
            ?? "New Recording"
    }

    @Published public internal(set) var selectedSessionAudioURLs: [URL] = []

    func refreshSelectedAudio() {
        guard let directory = selectedSessionDirectoryURL() else { selectedSessionAudioURLs = []; return }
        let urls = (try? SecurityScopedFolder.withSynchronousAccess(to: directory.deletingLastPathComponent(), bookmarkData: bookmark(for: directory.deletingLastPathComponent())) { _ in
            SessionAssetResolver.audioURLs(in: directory)
        }) ?? []
        selectedSessionAudioURLs = urls
        if let id = selectedSessionID,
           let index = recentSessions.firstIndex(where: { $0.id == id }) {
            recentSessions[index].hasRetainedAudio = !urls.isEmpty
        }
    }

    public var selectedSessionAudioURL: URL? {
        selectedSessionAudioURLs.first
    }

    public var currentDuration: TimeInterval {
        elapsedDuration(at: .now)
    }

    public func elapsedDuration(at date: Date) -> TimeInterval {
        guard let recordingStartedAt else { return max(0, accumulatedDuration) }
        return max(0, accumulatedDuration + date.timeIntervalSince(recordingStartedAt))
    }

    public func toggleRecording() {
        switch recordingState {
        case .idle, .completed, .failed:
            startRecording()
        case .recording:
            pauseRecording()
        case .paused:
            resumeRecording()
        default:
            break
        }
    }

    /// Re-register the system-wide recording shortcut after the user edits it.
    /// A failed replacement leaves the last valid registration active so a
    /// transiently incomplete text-field edit cannot strand the app.
    public func configureGlobalHotkey() {
        guard preferences.globalShortcut != registeredGlobalShortcut else { return }
        do {
            let replacement = try GlobalHotkeyManager(shortcut: preferences.globalShortcut) { @MainActor [weak self] in
                self?.toggleRecording()
            }
            globalHotkeyManager?.stop()
            globalHotkeyManager = replacement
            registeredGlobalShortcut = preferences.globalShortcut
        } catch {
            lastNotice = error.localizedDescription
        }
    }

    func announceSavedSession(_ sessionID: UUID, message: String) {
        completionDismissal?.cancel()
        let notice = RecordingCompletion(sessionID: sessionID, message: message)
        recordingCompletion = notice
        completionDismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard self?.recordingCompletion?.id == notice.id else { return }
            self?.recordingCompletion = nil
        }
    }

    /// Request the grants needed for the currently selected capture sources
    /// without starting a recording. This powers first-run setup and gives the
    /// user a deliberate way to approve permissions in advance.
    public func requestPermissionsForCurrentCaptureMode() async {
        guard !demoMode else {
            lastNotice = "Demo mode does not need audio permissions"
            return
        }

        AppLogger.permissions.info("Requesting permissions for capture mode \(self.preferences.captureMode.rawValue, privacy: .public)")
        var missing: [String] = []
        if preferences.captureMode.sources.contains(.microphone) {
            let granted = await MicrophonePermission.requestIfNeeded()
            AppLogger.permissions.info("Microphone permission result: \(granted, privacy: .public)")
            if !granted { missing.append("Microphone") }
        }

        if preferences.captureMode.sources.contains(.system),
           !ScreenCaptureCoordinator.requestSystemAudioPermission() {
            AppLogger.permissions.info("Screen Recording permission result: denied")
            missing.append("Screen Recording")
        } else if preferences.captureMode.sources.contains(.system) {
            AppLogger.permissions.info("Screen Recording permission result: granted")
        }

        if missing.isEmpty {
            lastNotice = "Permissions ready"
        } else {
            let names = missing.joined(separator: " and ")
            lastNotice = "Allow \(names) in System Settings, then try again."
        }
    }

    public func startRecording() {
        guard canToggleRecording, !recordingState.isRecording else { return }
        recordingSegmentationConfiguration = preferences.transcriptSegmentationConfiguration
        cancelRecordingTasks()
        transcriptUndoManager.removeAllActions()
        selectionTask?.cancel()
        selectedSessionHasNotes = false
        selectedSessionAudioURLs = []
        lastMeterPTS.removeAll()
        recoveryCheckpointTimes.removeAll()
        recordingWarning = nil
        audioArchiveWarning = nil

        userFacingError = nil
        lastNotice = nil
        processingStatus = nil
        recordingCompletion = nil
        completionDismissal?.cancel()
        recordingStartedAt = nil
        accumulatedDuration = 0
        lastCapturePTS = nil
        productionClock.reset()
        activeSession = nil
        selectedSessionID = nil
        liveSegments = []
        transcript = Transcript()
        systemMeter = .zero
        microphoneMeter = .zero

        var session = RecordingSession(
            title: recordingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Recording" : recordingTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            captureMode: preferences.captureMode,
            sttEngineID: preferences.sttEngineID,
            sttModelID: preferences.sttModelID,
            speakerMode: preferences.speakerMode,
            notesProviderID: preferences.notesProviderID,
            notesModelID: preferences.notesModelID,
            noteTemplateID: preferences.noteTemplateID,
            keepAudio: preferences.keepAudio,
            status: "preparing"
        )
        let labels = preferences.selectedRecordingLabels
        session.labels = labels.map(\.snapshot)
        session.labelTranscriptCopies = labels.compactMap(\.transcriptCopy)
        session.destinationRootPath = labels.first?.outputFolderPath ?? expandedOutputFolderURL().path
        if let primary = labels.first {
            session.title = RecordingNaming.title(pattern: primary.namingPattern, title: session.title,
                label: primary.name, date: session.createdAt, id: session.id, dateFormat: primary.dateFormat)
            session.transcriptFileName = RecordingNaming.transcriptFileName(for: session.title)
        }
        preferences.rememberDestination(path: session.destinationRootPath!, bookmarkData: bookmark(for: URL(fileURLWithPath: session.destinationRootPath!)))
        session.liveTranscriptionEnabled = preferences.liveTranscription && selectedSpeechModel.descriptor.supportsStreaming
        session.sourceKind = "recording"
        activeSession = session
        selectedSessionID = session.id
        recordingState = .preparing(.requestingPermissions)

        if demoMode && !usesHardwareRecordingFixture {
            startDemoRecording(session: session)
        } else {
            transitionTask = Task { @MainActor [weak self] in
                await self?.startProductionRecording(session: session)
            }
        }
    }

    public func pauseRecording() {
        guard recordingState == .recording, !isTransitioning else { return }
        isTransitioning = true
        let duration = elapsedDuration(at: .now)
        accumulatedDuration = duration
        recordingStartedAt = nil
        systemMeter = .zero
        microphoneMeter = .zero

        if demoMode, let pipeline = demoPipeline {
            transitionTask = Task { @MainActor [weak self, pipeline] in
                defer { self?.isTransitioning = false }
                do {
                    try await pipeline.pause(atPTS: max(0, duration))
                    guard let self else { return }
                    self.activeSession?.duration = duration
                    self.activeSession?.status = "paused"
                    self.recordingState = .paused
                    self.updateRecovery(state: .paused, duration: duration)
                } catch {
                    self?.fail(title: "Could not pause recording", error: error)
                }
            }
        } else if let capture = productionCapture {
            transitionTask = Task { @MainActor [weak self, capture] in
                defer { self?.isTransitioning = false }
                do {
                    try await capture.pause()
                    guard let self, self.recordingState == .recording else { return }
                    if let lastCapturePTS = self.lastCapturePTS, self.productionClock.isRunning {
                        _ = try? self.productionClock.pause(atPTS: lastCapturePTS)
                    }
                    self.activeSession?.duration = duration
                    self.activeSession?.status = "paused"
                    self.recordingState = .paused
                    self.updateRecovery(state: .paused, duration: duration)
                } catch {
                    await self?.failProductionCapture(capture, title: "Could not pause recording", error: error)
                }
            }
        } else {
            isTransitioning = false
            activeSession?.duration = duration
            activeSession?.status = "paused"
            recordingState = .paused
        }
    }

    public func resumeRecording() {
        guard recordingState == .paused, !isTransitioning else { return }
        isTransitioning = true

        if demoMode, let pipeline = demoPipeline {
            transitionTask = Task { @MainActor [weak self, pipeline] in
                defer { self?.isTransitioning = false }
                do {
                    try await pipeline.resume(firstPTS: max(0, (self?.lastCapturePTS ?? 0) + 0.01))
                    guard let self else { return }
                    self.recordingStartedAt = .now
                    self.activeSession?.status = "recording"
                    self.recordingState = .recording
                    self.startMeterTicker()
                    self.updateRecovery(state: .recording, duration: self.accumulatedDuration)
                } catch {
                    self?.fail(title: "Could not resume recording", error: error)
                }
            }
        } else if let capture = productionCapture {
            transitionTask = Task { @MainActor [weak self, capture] in
                defer { self?.isTransitioning = false }
                do {
                    try await capture.resume()
                    guard let self, self.recordingState == .paused else { return }
                    // Start the next clock epoch from the first packet after
                    // resume. ScreenCaptureKit may advance its PTS while the
                    // stream is paused, and using the old PTS would count that
                    // wall-clock gap as recording time.
                    self.recordingStartedAt = .now
                    self.activeSession?.status = "recording"
                    self.recordingState = .recording
                    self.startMeterTicker()
                    self.updateRecovery(state: .recording, duration: self.accumulatedDuration)
                } catch {
                    await self?.failProductionCapture(capture, title: "Could not resume recording", error: error)
                }
            }
        } else {
            isTransitioning = false
            recordingStartedAt = .now
            activeSession?.status = "recording"
            recordingState = .recording
            startMeterTicker()
        }
    }

    public func finishRecording() {
        guard canFinishRecording, let session = activeSession else { return }
        cancelTask(&transcriptFeedTask)
        cancelTask(&meterTask)

        let duration = elapsedDuration(at: .now)
        accumulatedDuration = duration
        recordingStartedAt = nil
        activeSession?.duration = duration
        activeSession?.status = "processing"
        systemMeter = .zero
        microphoneMeter = .zero
        recordingState = .stopping
        processingStatus = .saved
        updateRecovery(state: .stopping, duration: duration)

        if demoMode, let pipeline = demoPipeline {
            transitionTask = Task { @MainActor [weak self, pipeline, session] in
                do {
                    if session.liveTranscriptionEnabled == false {
                        // Demo mode follows the production contract too: no
                        // recognition work is simulated while the recorder is
                        // running when live preview is disabled. Feed the
                        // complete fixture only at Finish.
                        for segment in Self.demoRecordingSegments(for: session.captureMode) {
                            _ = try await pipeline.submit(segment: segment, isFinal: true)
                        }
                    }
                    let result = try await pipeline.finish(atPTS: max(10, duration))
                    await self?.complete(result: result, fallbackSession: session)
                } catch {
                    self?.fail(title: "Could not finish recording", error: error)
                }
            }
        } else {
            transitionTask = Task { @MainActor [weak self] in
                await self?.finishProductionRecording()
            }
        }
    }

    public func selectSession(_ session: SessionSummary) {
        guard canBrowseSessions else { return }
        selectionTask?.cancel()
        if selectedSessionID != session.id { transcriptUndoManager.removeAllActions() }
        selectedSessionID = session.id
        lastNotice = nil
        guard activeSession?.id != session.id else { return }
        activeSession = nil
        transcript = Transcript()
        liveSegments = []
        selectedSessionHasNotes = false
        selectedSessionAudioURLs = []
        if demoMode && session.folderPath == nil {
            transcript = Transcript(segments: Self.sampleSegments(for: session.title))
            liveSegments = transcript.visibleSegments
            return
        }

        selectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let document = await self.loadDocument(id: session.id), !Task.isCancelled,
                  self.canBrowseSessions, self.selectedSessionID == session.id else { return }
            self.selectedSessionHasNotes = document.notesMarkdown != nil
            self.activeSession = document.session
            self.transcript = document.transcript
            self.liveSegments = document.transcript.visibleSegments
            self.processingStatus = document.notesMarkdown == nil ? nil : .completed
            self.refreshSelectedAudio()
        }
    }

    public func renameSpeaker(from oldName: String, to newName: String) {
        renameSpeakers([oldName: newName])
    }

    public func renameSpeakers(_ names: [String: String]) {
        guard canBrowseSessions else { return }
        let replacements = names.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.value.isEmpty && $0.key != $0.value }
        guard !replacements.isEmpty else { return }
        func rename(_ segment: TranscriptSegment) -> TranscriptSegment {
            var edited = segment
            if let replacement = replacements[segment.visibleSpeakerName] {
                edited.speakerName = replacement
                edited.wasUserEdited = true
            }
            return edited
        }
        var edited = transcript
        edited.segments = edited.segments.map(rename)
        if edited != transcript { applySpeakerEdit(edited) }
    }

    private func applySpeakerEdit(_ edited: Transcript) {
        guard canBrowseSessions, let session = activeSession, session.status == "completed",
              selectedSessionID == session.id else {
            // The demo transcript has no saved session.
            if demoMode, !recordingState.isBusy {
                transcript = edited
                liveSegments = edited.visibleSegments
                lastNotice = "Speaker names updated"
            }
            return
        }
        let previous = transcript
        transcriptUndoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                guard model.selectedSessionID == session.id else { return }
                model.applySpeakerEdit(previous)
            }
        }
        transcriptUndoManager.setActionName("Rename Speakers")
        transcript = edited
        liveSegments = edited.visibleSegments
        lastNotice = "Speaker names updated"
        isTransitioning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.persistCurrentSession(session: session, editedTranscript: edited)
            self.isTransitioning = false
        }
    }

    public func regenerateNotes() {
        guard canBrowseSessions, let session = activeSession, session.status == "completed" else { return }
        let sourceTranscript = transcript
        transitionTask?.cancel()
        recordingState = .generatingNotes(progress: 0.1)
        processingStatus = .generatingNotes(0.1)
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let notes = try await self.generateNotes(for: session, transcript: sourceTranscript)
                self.recordingState = .generatingNotes(progress: 0.75)
                self.processingStatus = .generatingNotes(0.75)
                var updated = session
                updated.outputFolderPath = session.outputFolderPath
                _ = try await self.persist(document: SessionDocument(
                    session: updated,
                    transcript: sourceTranscript,
                    notesMarkdown: notes
                ))
                self.selectedSessionHasNotes = true
                self.processingStatus = self.notesFallbackWarning.map(ProcessingStatus.warning) ?? .completed
                self.recordingState = .completed(session.id)
                self.lastNotice = self.notesFallbackWarning ?? "Notes regenerated"
            } catch {
                self.recordingState = .completed(session.id)
                self.processingStatus = .warning(error.localizedDescription)
                self.lastNotice = "Notes could not be regenerated"
            }
        }
    }

    public func retryLastFailure() {
        cancelRecordingTasks()
        userFacingError = nil
        lastNotice = nil
        activeSession = nil
        selectedSessionID = recentSessions.first(where: { !$0.isDictation })?.id
            ?? recentSessions.first?.id
        recordingState = .idle
    }

    public func recover(_ manifest: RecoveryManifest) {
        guard !recordingState.isBusy, !recordingState.isRecording else { return }
        cancelRecordingTasks()
        userFacingError = nil
        lastNotice = nil
        recordingState = .finalizingTranscript
        processingStatus = .saved
        transitionTask = Task { @MainActor [weak self] in
            await self?.finishRecovery(manifest)
        }
    }

    public func discardRecovery(_ manifest: RecoveryManifest) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.recoveryStore.remove(id: manifest.id)
                await self.refreshRecoveryInventory()
                self.lastNotice = "Unfinished recording deleted"
            } catch {
                self.userFacingError = UserFacingError(
                    title: "Could not delete unfinished recording",
                    message: error.localizedDescription
                )
            }
        }
    }

    public var selectedSessionLabels: [RecordingLabelSnapshot] {
        guard activeSession?.id == selectedSessionID else { return [] }
        return activeSession?.labels ?? []
    }

    public var selectedSessionBookmarkData: Data? {
        selectedSessionDirectoryURL().flatMap { bookmark(for: $0.deletingLastPathComponent()) }
    }

    public var nextRecordingFolderPath: String {
        preferences.selectedRecordingLabels.first?.outputFolderPath ?? preferences.outputFolderPath
    }

    public func saveRecordingLabel(_ label: RecordingLabel, bookmarkData: Data? = nil, transcriptBookmarkData: Data? = nil) {
        var cleaned = label
        cleaned.name = String(label.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !cleaned.name.isEmpty else { return }
        if let path = label.outputFolderPath { preferences.rememberDestination(path: path, bookmarkData: bookmarkData) }
        if let path = cleaned.transcriptCopy?.folderPath, let transcriptBookmarkData {
            preferences.transcriptCopyDestinations.removeAll { $0.path == path }
            preferences.transcriptCopyDestinations.append(.init(path: path, bookmarkData: transcriptBookmarkData))
        }
        if let index = preferences.recordingLabels.firstIndex(where: { $0.id == label.id }) {
            preferences.recordingLabels[index] = cleaned
        } else { preferences.recordingLabels.append(cleaned) }
        reloadSessions()
    }

    public func removeRecordingLabel(id: UUID) {
        preferences.recordingLabels.removeAll { $0.id == id }
        preferences.selectedRecordingLabelIDs.removeAll { $0 == id }
        // Keep prior folder grants and session snapshots so history remains accessible.
    }

    public func setSessionLabels(_ labels: [RecordingLabelSnapshot]) {
        guard canBrowseSessions, var session = activeSession, session.id == selectedSessionID,
              session.status == "completed" else { return }
        session.labels = labels
        let editedTranscript = transcript
        isTransitioning = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isTransitioning = false }
            do {
                guard let existing = await self.loadDocument(id: session.id) else { throw SessionStoreError.sessionNotFound }
                _ = try await self.persist(document: SessionDocument(session: session, transcript: editedTranscript, notesMarkdown: existing.notesMarkdown))
                self.activeSession = session
                if let index = self.recentSessions.firstIndex(where: { $0.id == session.id }) { self.recentSessions[index].labels = labels }
                self.lastNotice = "Labels saved to recording and transcript Markdown"
            } catch {
                self.userFacingError = UserFacingError(title: "Could not save labels", message: error.localizedDescription)
                self.lastNotice = "Labels could not be saved: \(error.localizedDescription)"
            }
        }
    }

    private var libraryRoots: [URL] {
        var paths = [expandedOutputFolderURL().path] + preferences.recordingDestinations.map(\.path)
        paths += preferences.recordingLabels.compactMap(\.outputFolderPath)
        var seen = Set<String>()
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }.filter { seen.insert($0.path).inserted }
    }

    func bookmark(for root: URL) -> Data? {
        if root.standardizedFileURL == expandedOutputFolderURL().standardizedFileURL,
           let data = preferences.outputFolderBookmarkData {
            return data
        }
        return preferences.recordingDestinations.first {
            URL(fileURLWithPath: $0.path).standardizedFileURL == root.standardizedFileURL
                || (try? SecurityScopedFolder.resolve(url: URL(fileURLWithPath: $0.path), bookmarkData: $0.bookmarkData).standardizedFileURL) == root.standardizedFileURL
        }?.bookmarkData
    }

    public func chooseOutputFolder(for labelID: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where Prosody saves transcripts and notes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let data = try SecurityScopedFolder.bookmarkData(for: url)
            if let labelID, var label = preferences.recordingLabels.first(where: { $0.id == labelID }) {
                label.outputFolderPath = url.path
                saveRecordingLabel(label, bookmarkData: data)
                lastNotice = "Save folder updated for \(label.name)"
            } else {
                preferences.rememberDestination(path: expandedOutputFolderURL().path, bookmarkData: preferences.outputFolderBookmarkData)
                preferences.rememberDestination(path: url.path, bookmarkData: data)
                preferences.outputFolderPath = url.path
                preferences.outputFolderBookmarkData = data
                lastNotice = "Output folder updated"
            }
            reloadSessions()
        } catch {
            userFacingError = UserFacingError(title: "Could not use that folder", message: error.localizedDescription)
        }
    }

    public func revealOutputFolder() {
        let url = expandedOutputFolderURL()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            lastNotice = "Output folder will be created when a session is saved"
        }
    }

    public func revealCompletedSession() {
        guard let url = selectedSessionDirectoryURL() else {
            revealOutputFolder()
            return
        }
        NSWorkspace.shared.open(url)
    }

    public func openNotes() {
        guard let directory = selectedSessionDirectoryURL() else {
            revealOutputFolder()
            return
        }
        do {
            try SecurityScopedFolder.withSynchronousAccess(to: directory.deletingLastPathComponent(), bookmarkData: selectedSessionBookmarkData) { root in
                let resolvedDirectory = root.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
                let notesURL = resolvedDirectory.appendingPathComponent("notes.md")
                if FileManager.default.fileExists(atPath: notesURL.path) {
                    NSWorkspace.shared.open(notesURL)
                } else {
                    NSWorkspace.shared.open(resolvedDirectory)
                    lastNotice = "Notes are not available for this session"
                }
            }
        } catch {
            lastNotice = "Could not open notes: \(error.localizedDescription)"
        }
    }

    public func providerAPIKey(for providerID: String? = nil) -> String {
        (try? keychainStore.read(account: providerID ?? preferences.notesProviderID)) ?? ""
    }

    public func saveProviderAPIKey(_ value: String, for providerID: String? = nil) {
        let account = providerID ?? preferences.notesProviderID
        do {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try keychainStore.delete(account: account)
            } else {
                try keychainStore.save(value, account: account)
            }
            lastNotice = "API key stored in Keychain"
        } catch {
            userFacingError = UserFacingError(title: "Could not store API key", message: error.localizedDescription)
        }
    }

    public func testNotesConnection() async -> String {
        do {
            guard let baseURL = URL(string: preferences.notesBaseURL) else {
                return "Invalid base URL"
            }
            let provider = OpenAICompatibleProvider(
                id: preferences.notesProviderID,
                baseURL: baseURL,
                apiKey: providerAPIKey(),
                localOnly: preferences.localOnlyMode
            )
            return try await provider.testConnection()
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Production recording

    private var usesHardwareRecordingFixture: Bool {
        #if DEBUG
        demoMode && ProcessInfo.processInfo.arguments.contains("--hardware-recording-fixture")
        #else
        false
        #endif
    }

    private func startProductionRecording(session: RecordingSession) async {
        do {
            await dictation.releaseCachedModel()
            #if DEBUG
            if usesHardwareRecordingFixture {
                let microphoneReady = !session.captureMode.sources.contains(.microphone) || MicrophonePermission.isGranted
                let systemReady = !session.captureMode.sources.contains(.system) || CGPreflightScreenCaptureAccess()
                guard microphoneReady, systemReady else {
                    throw UserFacingError(title: "Capture fixture unavailable",
                                          message: "The hardware fixture requires existing capture permissions.")
                }
            }
            #endif
            if session.captureMode.sources.contains(.microphone) {
                let granted = await MicrophonePermission.requestIfNeeded()
                try Task.checkCancellation()
                guard granted else {
                    throw UserFacingError(
                        title: "Microphone permission required",
                        message: "Allow Prosody to use the microphone in System Settings, then try again.",
                        recoveryAction: "Open Microphone Settings",
                        recoveryURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                    )
                }
            }

            if session.captureMode.sources.contains(.system), !ScreenCaptureCoordinator.requestSystemAudioPermission() {
                throw ScreenCaptureCoordinatorError.screenPermissionDenied
            }
            var sttSessions: [AudioSource: any STTSession] = [:]
            guard session.sttEngineID == .parakeet, let speechModel = SpeechModel(rawValue: session.sttModelID) else {
                throw STTError.unsupportedModel(session.sttModelID)
            }
            // Validate before capture even when transcription is deferred.
            _ = try await modelManager.installedURL(for: speechModel)
            if session.liveTranscriptionEnabled != false {
                recordingState = .preparing(.loadingModel(progress: 0))
                let engine = ParakeetEngine(segmentationConfiguration: recordingSegmentationConfiguration, inventory: modelManager)
                productionEngine = engine
                try await engine.prepare(model: speechModel.descriptor) { _ in }
                try Task.checkCancellation()
                for source in session.captureMode.sources {
                    sttSessions[source] = try await engine.makeSession(source: source)
                }
            }
            try Task.checkCancellation()
            recordingState = .preparing(.startingCapture)
            let capture = ScreenCaptureCoordinator()
            productionCapture = capture
            productionSTTSessions = sttSessions
            try await capture.start(
                mode: session.captureMode,
                microphoneDeviceID: selectedMicrophoneDeviceID()
            )
            try Task.checkCancellation()
            do {
                _ = try await recoveryStore.begin(session: session)
            } catch {
                audioArchiveWarning = "Recovery setup failed: \(error.localizedDescription)"
                throw error
            }
            // Always archive while recording. If Keep Audio is off, the
            // temporary archive is deleted only after the final transcript is
            // safely committed, preserving crash recovery semantics.
            let recoveryDirectory = await recoveryStore.directoryURL(for: session.id)
            audioArchiveWriter = AudioArchiveWriter(
                directoryURL: recoveryDirectory.appendingPathComponent("audio", isDirectory: true),
                bitRate: preferences.recordingQuality == "high" ? 192_000 : 96_000
            )

            productionCapture = capture
            productionSTTSessions = sttSessions
            productionCoordinator = TranscriptCoordinator(speakerMode: session.speakerMode)
            productionClock.reset()
            activeRecoveryID = session.id
            recoverySegmentIDs.removeAll()
            recordingStartedAt = .now
            activeSession?.status = "recording"
            recordingState = .recording
            startMeterTicker()
            startProductionTasks(capture: capture, sessions: sttSessions)
        } catch let error as UserFacingError {
            await cleanupProduction()
            fail(error: error)
        } catch let error as ScreenCaptureCoordinatorError where error == .screenPermissionDenied {
            await cleanupProduction()
            fail(error: UserFacingError(
                title: "Screen Recording permission required",
                message: error.localizedDescription,
                recoveryAction: "Open Screen Recording Settings",
                recoveryURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            ))
        } catch {
            await cleanupProduction()
            fail(title: "Prosody could not start", error: error)
        }
    }

    private func startProductionTasks(capture: ScreenCaptureCoordinator, sessions: [AudioSource: any STTSession]) {
        let resamplers = Dictionary(uniqueKeysWithValues: sessions.keys.map { ($0, StreamingAudioResampler()) })
        captureTask = Task { @MainActor [weak self, capture] in
            do {
            for try await packet in capture.packets {
                defer { capture.acknowledgePacket() }
                guard let self, !Task.isCancelled else { return }
                // Finish changes the UI state to stopping before ScreenCaptureKit
                // drains its output queue. Keep accepting those queued packets
                // so the final transcript and archive do not lose the tail.
                guard self.recordingState == .recording || self.recordingState == .stopping
                        || (self.recordingState == .paused && self.isTransitioning) else {
                    continue
                }
                let startTime = self.sessionTime(for: packet.presentationTime)
                self.lastCapturePTS = max(self.lastCapturePTS ?? 0, packet.presentationTime + Double(packet.samples.count) / packet.sampleRate)
                if let archiveWriter = self.audioArchiveWriter {
                    do {
                        try await archiveWriter.append(packet)
                    } catch {
                        self.audioArchiveWarning = "Audio archive could not be written; it remains in Recovery."
                        throw error
                    }
                }
                if packet.presentationTime - self.lastMeterPTS[packet.source, default: 0] >= 0.1 {
                    self.lastMeterPTS[packet.source] = packet.presentationTime
                    let level = AudioMeterCalculator.level(for: packet.samples)
                    if packet.source == .system { self.systemMeter = level }
                    else { self.microphoneMeter = level }
                }
                guard let sttSession = sessions[packet.source] else { continue }
                guard let resampler = resamplers[packet.source] else { continue }
                let speechSamples = try await resampler.resample(
                    packet.samples,
                    from: packet.sampleRate
                )
                if !speechSamples.isEmpty {
                    try await sttSession.append(samples: speechSamples, startTime: startTime)
                }
            }
            } catch {
                guard let self, !Task.isCancelled else { return }
                await self.failProductionCapture(capture, title: "Recording interrupted", error: error, fromConsumer: true)
                return
            }
            if let self, !Task.isCancelled, self.recordingState == .recording {
                await self.failProductionCapture(
                    capture, title: "Audio capture stopped",
                    error: ScreenCaptureCoordinatorError.notRunning, fromConsumer: true
                )
            }
        }

        for (source, session) in sessions {
            sttUpdateTasks[source]?.cancel()
            sttUpdateTasks[source] = Task { @MainActor [weak self, session] in
                for await update in session.updates {
                    guard let self, !Task.isCancelled else { return }
                    guard let coordinator = self.productionCoordinator else { continue }
                    let snapshot = await coordinator.ingest(update)
                    self.transcript = Transcript(segments: snapshot.segments)
                    self.liveSegments = self.preferences.liveTranscription ? snapshot.visibleSegments : []
                    if case .final(_, let segment) = update {
                        await self.appendRecovery(segment)
                    } else if case .provisional(let source, let segment) = update,
                              segment.end - self.recoveryCheckpointTimes[source, default: -2] >= 2,
                              let id = self.activeRecoveryID {
                        self.recoveryCheckpointTimes[source] = segment.end
                        do { try await self.recoveryStore.checkpoint(segment: segment, to: id) }
                        catch { self.audioArchiveWarning = "Recovery checkpoint failed: \(error.localizedDescription)" }
                    }
                }
            }
        }
    }

    private func finishProductionRecording() async {
        isTransitioning = true
        defer { isTransitioning = false }
        let capture = productionCapture
        await capture?.stop()
        if let captureTask {
            await captureTask.value
        }
        captureTask = nil
        if case .failed = recordingState { return }

        recordingState = .finalizingTranscript
        let coordinator = productionCoordinator
        do {
            for (source, session) in productionSTTSessions {
                let final = try await session.finish()
                if let coordinator {
                    for segment in final.segments {
                        _ = await coordinator.ingest(.final(source: source, segment: segment))
                    }
                }
            }
            for task in sttUpdateTasks.values { await task.value }
            sttUpdateTasks.removeAll()
            let finalTranscript: Transcript
            if activeSession?.liveTranscriptionEnabled == false, let writer = audioArchiveWriter {
                let urls: [URL]
                do {
                    urls = try await writer.finish()
                } catch {
                    audioArchiveWarning = "Audio archive could not be finalized; it remains in Recovery."
                    throw error
                }
                let files = Dictionary(grouping: urls) { url in
                    AudioSource(rawValue: url.deletingLastPathComponent().lastPathComponent) ?? .microphone
                }
                guard let activeSession else { throw STTError.failed("The active recording is unavailable.") }
                finalTranscript = try await transcribeAudio(
                    files: files, session: activeSession, configuration: recordingSegmentationConfiguration
                ).transcript
            } else {
                if let coordinator {
                    finalTranscript = await coordinator.deduplicatedTranscript()
                } else {
                    finalTranscript = transcript
                }
            }
            let session = activeSession ?? RecordingSession(
                title: "New Recording",
                captureMode: preferences.captureMode,
                sttEngineID: preferences.sttEngineID,
                sttModelID: preferences.sttModelID,
                speakerMode: preferences.speakerMode,
                notesProviderID: preferences.notesProviderID,
                notesModelID: preferences.notesModelID,
                noteTemplateID: preferences.noteTemplateID,
                keepAudio: preferences.keepAudio
            )
            await complete(
                result: RecordingResult(session: session, transcript: finalTranscript),
                fallbackSession: session
            )
        } catch {
            let partial = Transcript(segments: transcript.segments)
            if let session = activeSession {
                _ = try? await persist(document: SessionDocument(session: session, transcript: partial))
            }
            await cleanupProduction()
            fail(title: "Could not finish transcription", error: error)
            return
        }
        await cleanupProduction()
    }

    private func sessionTime(for pts: TimeInterval) -> TimeInterval {
        guard pts.isFinite, pts >= 0 else { return currentDuration }
        lastCapturePTS = max(lastCapturePTS ?? pts, pts)
        if productionClock.epochs.isEmpty {
            try? productionClock.start(firstPTS: pts)
        } else if !productionClock.isRunning {
            try? productionClock.resume(firstPTS: pts)
        }
        guard let epochID = productionClock.currentEpochID else { return currentDuration }
        return productionClock.time(forPTS: pts, epochID: epochID)
    }

    func selectedMicrophoneDeviceID() -> String? {
        guard preferences.microphoneName != "System Default" else { return nil }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.first {
            $0.localizedName.caseInsensitiveCompare(preferences.microphoneName) == .orderedSame
        }?.uniqueID
    }

    // MARK: - Demo mode and processing

    private func startDemoRecording(session: RecordingSession) {
        let configuration = MockRecordingPipelineConfiguration(
            title: session.title,
            captureMode: session.captureMode,
            sttEngineID: session.sttEngineID,
            sttModelID: session.sttModelID,
            speakerMode: session.speakerMode,
            notesProviderID: session.notesProviderID,
            notesModelID: session.notesModelID,
            noteTemplateID: session.noteTemplateID,
            keepAudio: session.keepAudio
        )
        let pipeline = MockRecordingPipeline(configuration: configuration)
        demoPipeline = pipeline
        eventTask = Task { @MainActor [weak self, pipeline] in
            for await event in pipeline.events {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .transcript(let snapshot):
                    self.transcript = Transcript(segments: snapshot.segments)
                    self.liveSegments = self.preferences.liveTranscription ? snapshot.visibleSegments : []
                    for segment in snapshot.segments where segment.isFinal {
                        await self.appendRecovery(segment)
                    }
                case .audio(let frame):
                    let meter = AudioMeterCalculator.level(for: frame.samples)
                    if frame.source == .system { self.systemMeter = meter }
                    else { self.microphoneMeter = meter }
                case .state, .completed:
                    break
                }
            }
        }
        transitionTask = Task { @MainActor [weak self, pipeline] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                _ = try await pipeline.start(firstPTS: 0)
                // Keep the identity used by naming tokens and the preparation UI.
                let started = session
                self.activeSession = started
                self.selectedSessionID = started.id
                self.activeSession?.status = "recording"
                self.activeRecoveryID = started.id
                self.recoverySegmentIDs.removeAll()
                do {
                    _ = try await self.recoveryStore.begin(session: started)
                } catch {
                    self.activeRecoveryID = nil
                    self.audioArchiveWarning = "Recovery setup failed: \(error.localizedDescription)"
                }
                self.recordingStartedAt = .now
                self.recordingState = .recording
                self.startMeterTicker()
                if started.liveTranscriptionEnabled != false {
                    self.startDemoTranscriptFeed(pipeline: pipeline, session: started)
                }
            } catch {
                self?.fail(title: "Could not start demo recording", error: error)
            }
        }
    }

    private func startDemoTranscriptFeed(pipeline: MockRecordingPipeline, session: RecordingSession) {
        let segments = Self.demoRecordingSegments(for: session.captureMode)
        transcriptFeedTask = Task { @MainActor [weak self, pipeline] in
            for segment in segments {
                guard let self, !Task.isCancelled else { return }
                while self.recordingState == .paused {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                }
                guard self.recordingState == .recording else { return }
                var provisional = segment
                provisional.text = String(segment.text.prefix(max(1, segment.text.count / 2))) + "…"
                provisional.isFinal = false
                _ = try? await pipeline.submit(segment: provisional, isFinal: false)
                try? await Task.sleep(for: .milliseconds(260))
                guard self.recordingState == .recording else { return }
                _ = try? await pipeline.submit(segment: segment, isFinal: true)
                try? await Task.sleep(for: .milliseconds(420))
            }
        }
    }

    private func startMeterTicker() {
        cancelTask(&meterTask)
        guard demoMode else { return }
        meterTask = Task { @MainActor [weak self] in
            var phase = 0.0
            while !Task.isCancelled {
                guard let self else { return }
                guard self.recordingState == .recording else {
                    try? await Task.sleep(for: .milliseconds(120))
                    continue
                }
                phase += 0.45
                if self.preferences.captureMode.sources.contains(.system) {
                    self.systemMeter = MeterLevel(rms: 0.62 + sin(phase) * 0.12, peak: 0.78 + sin(phase * 0.7) * 0.08)
                }
                if self.preferences.captureMode.sources.contains(.microphone) {
                    self.microphoneMeter = MeterLevel(rms: 0.50 + sin(phase * 1.13) * 0.14, peak: 0.68 + sin(phase * 0.8) * 0.10)
                }
                try? await Task.sleep(for: .milliseconds(220))
            }
        }
    }

    func complete(result: RecordingResult, fallbackSession: RecordingSession, announceCompletion: Bool = true,
                  importedAudio: URL? = nil) async {
        recordingState = .finalizingTranscript

        if importedAudio != nil { recordingWarning = nil }
        var session = result.session
        if session.id != fallbackSession.id {
            session = fallbackSession
        }
        session.labels = fallbackSession.labels
        session.destinationRootPath = fallbackSession.destinationRootPath
        session.transcriptFileName = fallbackSession.transcriptFileName
        session.duration = max(elapsedDuration(at: .now), result.session.duration)
        let replacements = WordReplacementProcessor(rules: preferences.wordReplacements)
        let recognized = result.transcript
        let cleaned = preferences.omitFillerWords ? FillerWordFilter().apply(to: recognized) : recognized
        let initialTranscript = replacements.apply(to: cleaned)
        var finalTranscript = initialTranscript
        if recognized.visibleSegments.isEmpty {
            recordingWarning = "No speech was recognized. Check the audio source and try another recording."
        }

        // A final STT result can arrive just as the capture stream is
        // stopping. Flush every final segment before changing the recovery
        // state so a crash during the remainder of processing still leaves a
        // complete transcript to recover.
        for segment in recognized.segments {
            await appendRecovery(segment)
        }

        session.status = "completed"
        session.outputFolderPath = nil
        transcript = finalTranscript
        liveSegments = finalTranscript.visibleSegments

        do {
            // Commit the transcript before diarization, note generation, or
            // cleanup. This is the crash-safety boundary for a finished
            // recording.
            let directory = try await persist(document: SessionDocument(
                session: session,
                transcript: finalTranscript
            ))
            session.outputFolderPath = directory.path
            processingStatus = .saved

            let transcriptionWarning = recordingWarning
            var archiveWarning = importedAudio == nil ? audioArchiveWarning : nil
            var archivedAudioURLs: [URL] = []
            if let archiveWriter = audioArchiveWriter {
                do {
                    archivedAudioURLs = try await archiveWriter.finish()
                } catch {
                    archiveWarning = "Audio archive could not be finalized; it remains in Recovery."
                }
            }

            var processingWarning: String?
            if session.speakerMode == .full {
                recordingState = .diarizing(progress: 0.35)
                processingStatus = .diarizing(0.35)
                let source = importedAudio.map { (urls: [$0], source: AudioSource.microphone) }
                    ?? preferredDiarizationAudio(from: archivedAudioURLs)
                if let audio = source {
                    do {
                        let aligned = try await applyDiarization(to: cleaned, audioURLs: audio.urls, source: audio.source)
                        finalTranscript = replacements.apply(to: aligned)
                        recordingState = .diarizing(progress: 0.9)
                        processingStatus = .diarizing(0.9)
                    } catch {
                        finalTranscript = applySourceSpeakerFallback(to: finalTranscript)
                        processingWarning = "Speaker separation was unavailable; source labels were kept."
                    }
                } else {
                    finalTranscript = applySourceSpeakerFallback(to: finalTranscript)
                    processingWarning = "No audio archive was available for speaker separation."
                }
                transcript = finalTranscript
                liveSegments = finalTranscript.visibleSegments
            }

            // The transcript and (when requested) its audio are now durable.
            // Notes are deliberately generated after this point.
            var retainedURLs: [URL] = []
            if let archiveWriter = audioArchiveWriter {
                do {
                    if session.keepAudio {
                        _ = try await SecurityScopedFolder.withAccess(to: directory.deletingLastPathComponent(), bookmarkData: bookmark(for: directory.deletingLastPathComponent())) { _ in
                            try await archiveWriter.moveArtifacts(to: directory)
                        }
                    } else {
                        try await archiveWriter.discard()
                    }
                } catch {
                    archiveWarning = "Audio archive cleanup failed; it remains in Recovery."
                }
                audioArchiveWriter = nil
            }
            retainedURLs = await retainedAudioURLs(in: directory)
            if activeRecoveryID == session.id {
                if archiveWarning == nil {
                    do {
                        try await recoveryStore.markCompleted(id: session.id)
                        activeRecoveryID = nil
                    } catch {
                        archiveWarning = "Recovery could not be marked complete; it remains available in Recovery."
                        await refreshRecoveryInventory()
                    }
                } else {
                    await refreshRecoveryInventory()
                }
            }

            var notes: String?
            var notesWarning: String?
            if preferences.generateNotesAutomatically && session.sourceKind != "dictation" {
                recordingState = .generatingNotes(progress: 0.25)
                processingStatus = .generatingNotes(0.25)
                do {
                    notes = try await generateNotes(for: session, transcript: finalTranscript)
                    notesWarning = notesFallbackWarning
                } catch {
                    notesWarning = error.localizedDescription
                }
            }

            // Rewrite the durable source-of-truth JSON/Markdown after the
            // optional speaker pass and notes generation. If this rewrite
            // fails, the first transcript commit above is still valid.
            do {
                if notes != nil || finalTranscript != initialTranscript {
                    _ = try await persist(document: SessionDocument(
                        session: session,
                        transcript: finalTranscript,
                        notesMarkdown: notes
                    ))
                }
            } catch {
                notesWarning = notesWarning ?? error.localizedDescription
            }

            activeSession = session
            if let summary = await refreshLibrarySummary(id: session.id, folderPath: directory.path) {
                upsertRecentSummary(summary)
            } else {
                upsertRecentSummary(SessionSummary(
                    id: session.id,
                    title: session.title == "New Recording" ? "Untitled Recording" : session.title,
                    createdAt: session.createdAt,
                    duration: session.duration,
                    folderPath: directory.path,
                    labels: session.labels,
                    sourceKind: session.sourceKind,
                    hasRetainedAudio: !retainedURLs.isEmpty
                ))
            }
            selectedSessionID = session.id
            refreshSelectedAudio()
            let copyWarning = await writeLabelTranscriptCopies(SessionDocument(session: session, transcript: finalTranscript))
            let warning = [transcriptionWarning, archiveWarning, processingWarning, notesWarning, copyWarning]
                .compactMap { $0 }
                .first
            selectedSessionHasNotes = notes != nil
            processingStatus = warning.map(ProcessingStatus.warning) ?? .completed
            lastNotice = warning
            recordingState = .completed(session.id)
            if announceCompletion {
                announceSavedSession(session.id, message: notes == nil ? "Transcript saved" : "Transcript and notes saved")
                if session.sourceKind != "dictation" { sendFinishedNotification(title: session.title) }
                if preferences.automaticallyRevealNotes && notes != nil { openNotes() }
            }
        } catch {
            fail(title: "Could not save session", error: error)
        }
    }

    private func generateNotes(for session: RecordingSession, transcript: Transcript) async throws -> String {
        notesFallbackWarning = nil
        let request = NotesRequest(
            title: session.title == "New Recording" ? "Untitled Recording" : session.title,
            transcript: transcript,
            template: session.noteTemplateID,
            duration: session.duration
        )
        if demoMode || preferences.notesProviderID == "template-local" {
            return try await TemplateNotesProvider().generate(request: request, modelID: session.notesModelID).markdown
        }

        let key = try? keychainStore.read(account: preferences.notesProviderID)
        let provider = OpenAICompatibleProvider(
            id: preferences.notesProviderID,
            baseURL: URL(string: preferences.notesBaseURL) ?? URL(string: "http://127.0.0.1:1234/v1")!,
            apiKey: key,
            localOnly: preferences.localOnlyMode
        )
        do {
            return try await provider.generate(request: request, modelID: session.notesModelID).markdown
        } catch {
            notesFallbackWarning = "The notes provider was unavailable. Saved an offline outline; it is not an AI summary."
            return try await TemplateNotesProvider().generate(request: request, modelID: session.notesModelID).markdown
        }
    }

    private func applySourceSpeakerFallback(to transcript: Transcript) -> Transcript {
        var copy = transcript
        copy.segments = copy.segments.map { segment in
            var updated = segment
            if updated.source == .microphone {
                updated.speakerID = updated.speakerID ?? "you"
                updated.speakerName = updated.speakerName ?? "You"
            } else {
                updated.speakerID = updated.speakerID ?? "speaker-1"
                updated.speakerName = updated.speakerName ?? "Speaker 1"
            }
            return updated
        }
        return copy
    }

    private func preferredDiarizationAudio(from urls: [URL]) -> (urls: [URL], source: AudioSource)? {
        for source in [AudioSource.system, .microphone] {
            let matching = urls
                .filter { url in
                    let isChunk = url.deletingLastPathComponent().lastPathComponent == source.rawValue
                        && ["m4a", "caf"].contains(url.pathExtension.lowercased())
                    let isLegacy = url.lastPathComponent == "\(source.rawValue).caf"
                    return isChunk || isLegacy
                }
                .sorted { $0.path < $1.path }
            if !matching.isEmpty {
                return (matching, source)
            }
        }
        return nil
    }

    private func preferredRecoveryDiarizationAudio(for sessionID: UUID) async -> (urls: [URL], source: AudioSource)? {
        let directory = await recoveryStore.directoryURL(for: sessionID)
            .appendingPathComponent("audio", isDirectory: true)
        let urls = (try? AudioArchiveMerger.recoveryAudioFiles(in: directory)) ?? []
        return preferredDiarizationAudio(from: urls)
    }

    private func applyDiarization(
        to transcript: Transcript,
        audioURLs: [URL],
        source: AudioSource
    ) async throws -> Transcript {
        let progress: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, case .diarizing = self.recordingState else { return }
                let normalized = min(max(value, 0), 1)
                let displayProgress = 0.35 + normalized * 0.55
                self.recordingState = .diarizing(progress: displayProgress)
                self.processingStatus = .diarizing(displayProgress)
            }
        }
        let result = try await diarizer.process(
            audioFileURLs: audioURLs,
            progress: progress
        )
        let sourceSegments = transcript.segments.filter { $0.source == source }
        guard !sourceSegments.isEmpty else { return transcript }

        let aligner = SpeakerAlignment()
        let aligned = aligner.apply(to: sourceSegments, intervals: result.intervals).map { segment in
            var named = segment
            if let speakerID = segment.speakerID {
                named.speakerName = displayName(forDiarizedSpeakerID: speakerID)
            }
            return named
        }
        var merged = transcript.segments.filter { $0.source != source }
        merged.append(contentsOf: aligned)
        merged.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.id.uuidString < $1.id.uuidString
        }
        return Transcript(schemaVersion: transcript.schemaVersion, segments: merged)
    }

    private func displayName(forDiarizedSpeakerID id: String) -> String {
        let digits = id.drop { !$0.isNumber }
        if let number = Int(digits), number > 0 {
            return "Speaker \(number)"
        }
        return id.isEmpty ? "Speaker" : id
    }

    // MARK: - Persistence and recovery

    private func loadPersistedState() async {
        let persisted = await loadSummaries()
        guard canBrowseSessions else { return }
        if demoMode {
            let sampleIDs = Set(recentSessions.map(\.id))
            recentSessions = persisted.filter { !sampleIDs.contains($0.id) } + recentSessions
        } else {
            recentSessions = persisted
        }
        if selectedSessionID == nil {
            selectedSessionID = recentSessions.first(where: { !$0.isDictation })?.id
                ?? recentSessions.first?.id
        }

        if let selected = recentSessions.first(where: { $0.id == selectedSessionID }), !demoMode {
            selectSession(selected)
        }
        recoverableSessions = (try? await recoveryStore.recoverableSessions()) ?? []
        if !recoverableSessions.isEmpty {
            lastNotice = "A recoverable recording is available in Recovery."
        }
    }

    private func refreshRecoveryInventory() async {
        recoverableSessions = (try? await recoveryStore.recoverableSessions()) ?? []
    }

    func adoptDictationRecovery(_ session: RecordingSession, archive: AudioArchiveWriter) async throws -> Bool {
        let adopted = try await recoveryStore.adoptFailedDictation(session, archive: archive)
        if adopted { await refreshRecoveryInventory() }
        return adopted
    }

    private func finishRecovery(_ manifest: RecoveryManifest) async {
        let segmentationConfiguration = preferences.transcriptSegmentationConfiguration
        do {
            let recovered = try await recoveryStore.load(id: manifest.id)
            var session = recovered.manifest.session
            session.duration = max(recovered.manifest.duration, session.duration)
            session.status = "completed"
            session.outputFolderPath = nil

            var finalTranscript = recovered.transcript
            let recoveryAudioDirectory = await recoveryStore.directoryURL(for: manifest.id)
                .appendingPathComponent("audio", isDirectory: true)
            let hasRecoveryAudio = !(try AudioArchiveMerger.recoveryAudioFiles(in: recoveryAudioDirectory)).isEmpty
            if !hasRecoveryAudio,
               let existing = await loadDocument(id: manifest.id),
               existing.session.status == "completed" {
                try await recoveryStore.markCompleted(id: manifest.id)
                if activeRecoveryID == manifest.id { activeRecoveryID = nil }
                await refreshRecoveryInventory()
                activeSession = existing.session
                transcript = existing.transcript
                liveSegments = existing.transcript.visibleSegments
                selectedSessionID = existing.session.id
                selectedSessionHasNotes = existing.notesMarkdown != nil
                refreshSelectedAudio()
                processingStatus = .completed
                lastNotice = nil
                announceSavedSession(existing.session.id, message: "Recovered recording saved")
                recordingState = .completed(existing.session.id)
                return
            }
            if session.liveTranscriptionEnabled == false {
                await dictation.releaseCachedModel()
                var files: [AudioSource: [URL]] = [:]
                for source in session.captureMode.sources {
                    files[source] = try audioChunks(in: recoveryAudioDirectory, source: source)
                }
                if files.values.contains(where: { !$0.isEmpty }) {
                    if let original = SpeechModel(rawValue: session.sttModelID),
                       await modelManager.isInstalled(original.descriptor) {
                        session.sttModelID = original.rawValue
                    } else {
                        session.sttModelID = selectedSpeechModel.rawValue
                    }
                    session.sttEngineID = .parakeet
                    finalTranscript = try await transcribeAudio(
                        files: files, session: session, configuration: segmentationConfiguration
                    ).transcript
                }
            }
            let replacements = WordReplacementProcessor(rules: preferences.wordReplacements)
            let cleaned = preferences.omitFillerWords ? FillerWordFilter().apply(to: finalTranscript) : finalTranscript
            finalTranscript = replacements.apply(to: cleaned)
            let directory = try await persist(document: SessionDocument(
                session: session,
                transcript: finalTranscript
            ))
            session.outputFolderPath = directory.path
            processingStatus = .saved

            var processingWarning: String?
            if session.speakerMode == .full {
                recordingState = .diarizing(progress: 0.35)
                processingStatus = .diarizing(0.35)
                if let audio = await preferredRecoveryDiarizationAudio(for: manifest.id) {
                    do {
                        let aligned = try await applyDiarization(to: cleaned, audioURLs: audio.urls, source: audio.source)
                        finalTranscript = replacements.apply(to: aligned)
                        processingStatus = .diarizing(0.9)
                    } catch {
                        finalTranscript = applySourceSpeakerFallback(to: finalTranscript)
                        processingWarning = "Speaker separation was unavailable; source labels were kept."
                    }
                } else {
                    finalTranscript = applySourceSpeakerFallback(to: finalTranscript)
                    processingWarning = "No audio archive was available for speaker separation."
                }
                transcript = finalTranscript
                liveSegments = finalTranscript.visibleSegments
            }

            let copyWarning = await writeLabelTranscriptCopies(SessionDocument(session: session, transcript: finalTranscript))
            processingWarning = processingWarning ?? copyWarning
            var notes: String?
            if preferences.generateNotesAutomatically && session.sourceKind != "dictation" {
                recordingState = .generatingNotes(progress: 0.25)
                processingStatus = .generatingNotes(0.25)
                do {
                    notes = try await generateNotes(for: session, transcript: finalTranscript)
                    processingWarning = processingWarning ?? notesFallbackWarning
                } catch {
                    processingWarning = processingWarning ?? error.localizedDescription
                }
            }
            _ = try await persist(document: SessionDocument(
                session: session,
                transcript: finalTranscript,
                notesMarkdown: notes
            ))

            let retainedURLs = try await moveRecoveredAudio(
                sessionID: manifest.id,
                keepAudio: session.keepAudio,
                to: directory
            )
            try await recoveryStore.markCompleted(id: manifest.id)
            if activeRecoveryID == manifest.id { activeRecoveryID = nil }
            await refreshRecoveryInventory()

            activeSession = session
            transcript = finalTranscript
            liveSegments = finalTranscript.visibleSegments
            if let summary = await refreshLibrarySummary(id: session.id, folderPath: directory.path) {
                upsertRecentSummary(summary)
            } else {
                upsertRecentSummary(SessionSummary(
                    id: session.id,
                    title: session.title == "New Recording" ? "Untitled Recording" : session.title,
                    createdAt: session.createdAt,
                    duration: session.duration,
                    folderPath: directory.path,
                    labels: session.labels,
                    sourceKind: session.sourceKind,
                    hasRetainedAudio: !retainedURLs.isEmpty
                ))
            }
            selectedSessionID = session.id
            selectedSessionHasNotes = notes != nil
            refreshSelectedAudio()
            processingStatus = processingWarning == nil
                ? .completed
                : .warning(processingWarning!)
            lastNotice = processingWarning
            announceSavedSession(session.id, message: "Recovered recording saved")
            recordingState = .completed(session.id)
        } catch {
            fail(title: "Could not recover recording", error: error)
        }
    }

    func reloadSessions() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let summaries = await self.loadSummaries()
            if !self.demoMode { self.recentSessions = summaries }
        }
    }

    public func loadSummaries() async -> [SessionSummary] {
        var results: [UUID: SessionSummary] = [:]
        for preferred in libraryRoots {
            if let summaries = try? await SecurityScopedFolder.withAccess(to: preferred, bookmarkData: bookmark(for: preferred), operation: { resolved in
                try await SessionStore(rootURL: resolved).list()
            }) {
                for summary in summaries { results[summary.id] = summary }
            }
        }
        let fallback = SessionStore(rootURL: supportRootURL.appendingPathComponent("Sessions", isDirectory: true))
        if let summaries = try? await fallback.list() {
            for summary in summaries where results[summary.id] == nil { results[summary.id] = summary }
        }
        return results.values.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func loadDocument(id: UUID) async -> SessionDocument? {
        for preferred in libraryRoots {
            if let document = try? await SecurityScopedFolder.withAccess(to: preferred, bookmarkData: bookmark(for: preferred), operation: { resolved in
                let document = try await SessionStore(rootURL: resolved).load(id: id)
                var session = document.session
                session.outputFolderPath = resolved.appendingPathComponent(id.uuidString).path
                return SessionDocument(session: session, transcript: document.transcript, transcriptMarkdown: document.transcriptMarkdown, notesMarkdown: document.notesMarkdown)
            }) { return document }
        }
        let fallback = SessionStore(rootURL: supportRootURL.appendingPathComponent("Sessions", isDirectory: true))
        return try? await fallback.load(id: id)
    }

    private func persistCurrentSession(session: RecordingSession, editedTranscript: Transcript) async {
        // Keep existing notes when a speaker rename rewrites the transcript;
        // SessionStore treats a nil notes value as an intentional deletion.
        let existingNotes = await loadDocument(id: session.id)?.notesMarkdown
        do {
            _ = try await persist(document: SessionDocument(session: session, transcript: editedTranscript, notesMarkdown: existingNotes))
        } catch {
            userFacingError = UserFacingError(title: "Could not save speaker names", message: error.localizedDescription)
        }
    }

    func persist(document: SessionDocument) async throws -> URL {
        let preferred = document.session.outputFolderPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? document.session.destinationRootPath.map { URL(fileURLWithPath: $0) } ?? expandedOutputFolderURL()
        let fallback = supportRootURL.appendingPathComponent("Sessions", isDirectory: true)
        if preferred.standardizedFileURL == fallback.standardizedFileURL {
            return try await SessionStore(rootURL: preferred).save(document)
        }
        do {
            return try await SecurityScopedFolder.withAccess(
                to: preferred,
                bookmarkData: bookmark(for: preferred)
            ) { resolved in
                try await SessionStore(rootURL: resolved).save(document)
            }
        } catch {
            // The default output path can be unavailable in a sandbox before
            // the user grants a folder extension. Keep the session durable in
            // the app container rather than dropping the transcript.
            guard bookmark(for: preferred) == nil, preferred.standardizedFileURL == expandedOutputFolderURL().standardizedFileURL else { throw error }
            let fallback = supportRootURL.appendingPathComponent("Sessions", isDirectory: true)
            return try await SessionStore(rootURL: fallback).save(document)
        }
    }

    private func moveRecoveredAudio(sessionID: UUID, keepAudio: Bool, to directory: URL) async throws -> [URL] {
        let recoveryAudio = await recoveryStore.directoryURL(for: sessionID)
            .appendingPathComponent("audio", isDirectory: true)
        guard FileManager.default.fileExists(atPath: recoveryAudio.path) else {
            return await retainedAudioURLs(in: directory)
        }

        return try await SecurityScopedFolder.withAccess(
            to: directory.deletingLastPathComponent(),
            bookmarkData: bookmark(for: directory.deletingLastPathComponent())
        ) { _ in
            let finalAudio = directory.appendingPathComponent("audio", isDirectory: true)
            let recoveryFiles = try AudioArchiveMerger.recoveryAudioFiles(in: recoveryAudio)
            if keepAudio {
                if !recoveryFiles.isEmpty {
                    _ = try AudioArchiveMerger.merge(recoveryFiles, from: recoveryAudio, into: finalAudio)
                }
            } else if !recoveryFiles.isEmpty {
                try FileManager.default.removeItem(at: recoveryAudio)
            }
            return SessionAssetResolver.audioURLs(in: directory)
        }
    }

    private func appendRecovery(_ segment: TranscriptSegment) async {
        guard segment.isFinal, let activeRecoveryID, !recoverySegmentIDs.contains(segment.id) else { return }
        do {
            _ = try await recoveryStore.append(segment: segment, to: activeRecoveryID)
            recoverySegmentIDs.insert(segment.id)
        } catch {
            audioArchiveWarning = "Recovery journal failed: \(error.localizedDescription)"
        }
    }

    private func updateRecovery(state: RecoveryState, duration: TimeInterval) {
        guard let id = activeRecoveryID, activeSession != nil else { return }
        Task { @MainActor [weak self, recoveryStore] in
            do {
                try await recoveryStore.updateState(id: id, state: state, duration: duration)
            } catch {
                self?.audioArchiveWarning = "Recovery state could not be updated: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Helpers

    private func selectedSessionDirectoryURL() -> URL? {
        if let activeSession, activeSession.id == selectedSessionID, let path = activeSession.outputFolderPath {
            return URL(fileURLWithPath: path)
        }
        guard let summary = recentSessions.first(where: { $0.id == selectedSessionID }), let path = summary.folderPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func audioChunks(in audioDirectory: URL, source: AudioSource) throws -> [URL] {
        let sourceDirectory = audioDirectory.appendingPathComponent(source.rawValue, isDirectory: true)
        return try AudioArchiveMerger.supportedFiles(in: sourceDirectory)
    }

    private func expandedOutputFolderURL() -> URL {
        let path = preferences.outputFolderPath
        if path == "~" { return URL(fileURLWithPath: NSHomeDirectory()) }
        if path.hasPrefix("~/") {
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func renamed(_ segment: TranscriptSegment, from oldName: String, to newName: String) -> TranscriptSegment {
        var updated = segment
        if updated.visibleSpeakerName == oldName { updated.speakerName = newName }
        return updated
    }

    private func cleanupProduction() async {
        await productionCapture?.stop()
        productionCapture = nil
        for session in productionSTTSessions.values { await session.cancel() }
        productionSTTSessions.removeAll()
        sttUpdateTasks.values.forEach { $0.cancel() }
        sttUpdateTasks.removeAll()
        await productionEngine?.unload()
        productionEngine = nil
        productionCoordinator = nil
    }

    private func failProductionCapture(
        _ capture: ScreenCaptureCoordinator,
        title: String,
        error: Error,
        fromConsumer: Bool = false
    ) async {
        guard productionCapture === capture, !handlingCaptureFailure else { return }
        handlingCaptureFailure = true
        defer { handlingCaptureFailure = false }
        isTransitioning = true
        recordingState = .stopping
        if !fromConsumer {
            captureTask?.cancel()
            await captureTask?.value
        }
        captureTask = nil
        await cleanupProduction()
        _ = try? await audioArchiveWriter?.finish()
        audioArchiveWriter = nil
        await refreshRecoveryInventory()
        // A failed state allows another recording. Publish it only after
        // the old stream and its model are no longer in use.
        fail(title: title, error: error)
    }

    private func cancelRecordingTasks() {
        transitionTask?.cancel()
        transitionTask = nil
        cancelTask(&meterTask)
        cancelTask(&eventTask)
        cancelTask(&transcriptFeedTask)
        cancelTask(&captureTask)
        sttUpdateTasks.values.forEach { $0.cancel() }
        sttUpdateTasks.removeAll()
    }

    private func cancelTask(_ task: inout Task<Void, Never>?) {
        task?.cancel()
        task = nil
    }

    private func fail(title: String, error: Error) {
        fail(error: UserFacingError(title: title, message: error.localizedDescription))
    }

    private func fail(error: UserFacingError) {
        recordingState = .failed(error)
        userFacingError = error
        processingStatus = .warning(error.message)
        systemMeter = .zero
        microphoneMeter = .zero
        recordingStartedAt = nil
        isTransitioning = false
        cancelTask(&meterTask)
        cancelTask(&transcriptFeedTask)
    }

    private func sendFinishedNotification(title: String) {
        guard preferences.notifyWhenFinished else { return }
        Task {
            let authorized: Bool = await withCheckedContinuation { continuation in
                UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
                    continuation.resume(returning: settings.authorizationStatus == .authorized)
                }
            }
            guard authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "Prosody finished"
            content.body = "Transcript and notes for \(title) are ready."
            let request = UNNotificationRequest(
                identifier: "clippy.finished.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private static func sampleSessions() -> [SessionSummary] {
        [
            SessionSummary(id: UUID(), title: "Neural Networks Lecture", createdAt: .now.addingTimeInterval(-60 * 18), duration: 12 * 60 + 47),
            SessionSummary(id: UUID(), title: "Backpropagation Explained", createdAt: .now.addingTimeInterval(-60 * 72), duration: 18 * 60 + 23),
            SessionSummary(id: UUID(), title: "Study Group Discussion", createdAt: .now.addingTimeInterval(-60 * 60 * 24), duration: 42 * 60 + 11)
        ]
    }

    private static func sampleSegments(for title: String? = nil) -> [TranscriptSegment] {
        switch title {
        case "Backpropagation Explained":
            return [
                TranscriptSegment(source: .system, start: 0, end: 5, text: "First, compare the prediction with the target and calculate the loss.", isFinal: true, speakerName: "Instructor"),
                TranscriptSegment(source: .system, start: 6, end: 11, text: "Use the chain rule to trace how each layer contributed to that loss.", isFinal: true, speakerName: "Instructor"),
                TranscriptSegment(source: .system, start: 12, end: 17, text: "Update the parameters using the resulting gradients, then run a new pass.", isFinal: true, speakerName: "Instructor")
            ]
        case "Study Group Discussion":
            return [
                TranscriptSegment(source: .microphone, start: 0, end: 4, text: "Let's use the first practice problem to compare approaches.", isFinal: true, speakerName: "You"),
                TranscriptSegment(source: .system, start: 5, end: 10, text: "I drew the dependency graph first so I could follow the chain rule.", isFinal: true, speakerName: "Study partner"),
                TranscriptSegment(source: .microphone, start: 11, end: 16, text: "We'll each solve the next problem and compare our answers.", isFinal: true, speakerName: "You")
            ]
        default: break
        }
        return [
            TranscriptSegment(source: .system, start: 12, end: 18, text: "Today, we'll explore how neural networks are inspired by the structure of the human brain.", isFinal: true, speakerID: "speaker-1", speakerName: "Professor"),
            TranscriptSegment(source: .microphone, start: 19, end: 25, text: "Could you explain how backpropagation works?", isFinal: true, speakerID: "you", speakerName: "You"),
            TranscriptSegment(source: .system, start: 26, end: 34, text: "Of course. It's how the network learns by minimizing error through gradient descent.", isFinal: true, speakerID: "speaker-1", speakerName: "Professor"),
            TranscriptSegment(source: .system, start: 36, end: 42, text: "The key idea is to send the error backward through each layer.", isFinal: false, speakerID: "speaker-1", speakerName: "Professor")
        ]
    }

    private static func demoRecordingSegments(for mode: CaptureMode) -> [TranscriptSegment] {
        let all = [
            TranscriptSegment(source: .system, start: 0.6, end: 2.4, text: "Today we'll explore how neural networks learn from examples.", isFinal: true, speakerID: "speaker-1", speakerName: "Professor"),
            TranscriptSegment(source: .microphone, start: 2.8, end: 4.1, text: "Could you explain how backpropagation works?", isFinal: true, speakerID: "you", speakerName: "You"),
            TranscriptSegment(source: .system, start: 4.5, end: 6.5, text: "It minimizes error through gradient descent across the layers.", isFinal: true, speakerID: "speaker-1", speakerName: "Professor"),
            TranscriptSegment(source: .microphone, start: 7.0, end: 8.2, text: "That makes the update rule much clearer.", isFinal: true, speakerID: "you", speakerName: "You")
        ]
        return all.filter { mode.sources.contains($0.source) }
    }
}

import AppKit
import UniformTypeIdentifiers

extension AppModel {
    /// Tray history intentionally excludes dictation. The transcript library
    /// keeps the complete history and exposes dictation through an opt-in.
    public var recentRecordings: [SessionSummary] {
        recentSessions.filter { !$0.isDictation }
    }

    public func chooseTranscriptionFile() {
        guard canBrowseSessions else { return }
        let panel = NSOpenPanel()
        panel.title = "Transcribe Audio File"
        panel.prompt = "Transcribe"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in self?.transcribeFile(url) }
        }
    }

    public func transcribeFile(_ url: URL) {
        guard canBrowseSessions else { return }
        selectionTask?.cancel()
        userFacingError = nil
        lastNotice = "Transcribing \(url.lastPathComponent)…"
        recordingState = .finalizingTranscript
        processingStatus = nil
        transcript = Transcript()
        liveSegments = []
        selectedSessionAudioURLs = []
        selectedSessionHasNotes = false
        accumulatedDuration = 0
        var session = makeLibrarySession(title: url.deletingPathExtension().lastPathComponent, kind: "file")
        session.speakerMode = preferences.speakerMode
        session.liveTranscriptionEnabled = false
        activeSession = session
        selectedSessionID = session.id
        let capturedSession = session
        let segmentationConfiguration = preferences.transcriptSegmentationConfiguration
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                await self.dictation.releaseCachedModel()
                let result = try await AudioFileTranscriber(segmentationConfiguration: segmentationConfiguration).transcribe(files: [.microphone: [url]], speakerMode: capturedSession.speakerMode)
                try Task.checkCancellation()
                var finished = capturedSession
                finished.duration = result.duration
                self.accumulatedDuration = result.duration
                await self.complete(result: RecordingResult(session: finished, transcript: result.transcript), fallbackSession: finished)
                if case .completed = self.recordingState, finished.keepAudio,
                   let path = self.activeSession?.outputFolderPath {
                    let folder = URL(fileURLWithPath: path).appendingPathComponent("audio/microphone", isDirectory: true)
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent("000001").appendingPathExtension(url.pathExtension))
                        self.refreshSelectedAudio()
                        if let summary = await self.refreshLibrarySummary(id: finished.id, folderPath: path) {
                            self.upsertRecentSummary(summary)
                        }
                    } catch { self.lastNotice = "Transcript saved, but audio could not be copied: \(error.localizedDescription)" }
                }
            } catch {
                let failure = UserFacingError(title: "Could not transcribe file", message: error.localizedDescription)
                self.userFacingError = failure
                self.recordingState = .failed(failure)
            }
        }
    }

    func saveDictation(transcript: Transcript, duration: TimeInterval, archive: AudioArchiveWriter) async throws {
        var session = makeLibrarySession(title: "Dictation \(Date.now.formatted(date: .abbreviated, time: .shortened))", kind: "dictation")
        session.duration = duration
        session.status = "completed"
        let directory = try await persist(document: SessionDocument(session: session, transcript: transcript))
        session.outputFolderPath = directory.path
        if session.keepAudio {
            _ = try await SecurityScopedFolder.withAccess(
                to: directory.deletingLastPathComponent(),
                bookmarkData: bookmark(for: directory.deletingLastPathComponent())
            ) { _ in
                try await archive.moveArtifacts(to: directory)
            }
        }
        if let summary = await refreshLibrarySummary(id: session.id, folderPath: directory.path) {
            upsertRecentSummary(summary)
        } else {
            upsertRecentSummary(SessionSummary(
                id: session.id,
                title: session.title,
                createdAt: session.createdAt,
                duration: duration,
                folderPath: directory.path,
                labels: session.labels,
                sourceKind: session.sourceKind,
                hasRetainedAudio: false
            ))
        }
    }

    func preserveFailedDictation(duration: TimeInterval, archive: AudioArchiveWriter) async throws -> Bool {
        var session = makeLibrarySession(title: "Dictation \(Date.now.formatted(date: .abbreviated, time: .shortened))", kind: "dictation")
        session.duration = duration
        session.status = "recoverable"
        return try await adoptDictationRecovery(session, archive: archive)
    }

    private func makeLibrarySession(title: String, kind: String) -> RecordingSession {
        var session = RecordingSession(title: title, captureMode: .microphone,
            sttEngineID: preferences.sttEngineID, sttModelID: preferences.sttModelID, speakerMode: .off,
            notesProviderID: preferences.notesProviderID, notesModelID: preferences.notesModelID,
            noteTemplateID: preferences.noteTemplateID, keepAudio: preferences.keepAudio)
        session.sourceKind = kind
        session.liveTranscriptionEnabled = false
        session.labels = preferences.selectedRecordingLabels.map(\.snapshot)
        session.destinationRootPath = preferences.selectedRecordingLabels.first?.outputFolderPath
        return session
    }

    public func deleteSession(_ summary: SessionSummary) {
        guard canBrowseSessions else { return }
        isTransitioning = true
        selectionTask?.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isTransitioning = false }
            do {
                if let path = summary.folderPath {
                    let root = URL(fileURLWithPath: path).deletingLastPathComponent()
                    try await SecurityScopedFolder.withAccess(to: root, bookmarkData: self.bookmark(for: root)) { resolved in
                        try await SessionStore(rootURL: resolved).delete(id: summary.id)
                    }
                }
                self.recentSessions.removeAll { $0.id == summary.id }
                if self.selectedSessionID == summary.id {
                    self.selectedSessionID = nil
                    self.activeSession = nil
                    self.transcript = Transcript()
                    self.liveSegments = []
                    self.selectedSessionHasNotes = false
                    self.selectedSessionAudioURLs = []
                }
                if case .completed(let id) = self.recordingState, id == summary.id { self.recordingState = .idle }
                self.lastNotice = "Recording deleted"
            } catch { self.userFacingError = UserFacingError(title: "Could not delete recording", message: error.localizedDescription) }
        }
    }

    public func revealSession(_ summary: SessionSummary) {
        guard let path = summary.folderPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public func copySession(_ summary: SessionSummary) {
        Task { @MainActor [weak self] in
            guard let self, let document = await self.loadDocument(id: summary.id) else { return }
            DictationTextDestination.copy(document.transcript.rawText)
            self.lastNotice = "Transcript copied"
        }
    }

    func refreshLibrarySummary(id: UUID, folderPath: String) async -> SessionSummary? {
        let directory = URL(fileURLWithPath: folderPath, isDirectory: true)
        let root = directory.deletingLastPathComponent()
        let bookmarkData = bookmark(for: root)
        return try? await SecurityScopedFolder.withAccess(
            to: root,
            bookmarkData: bookmarkData
        ) { resolved in
            let store = SessionStore(rootURL: resolved)
            guard var summary = try await store.refreshSummary(id: id) else { return nil }
            summary.folderPath = resolved.appendingPathComponent(id.uuidString, isDirectory: true).path
            return summary
        }
    }

    func upsertRecentSummary(_ summary: SessionSummary) {
        if let index = recentSessions.firstIndex(where: { $0.id == summary.id }) {
            recentSessions[index] = summary
        } else {
            recentSessions.insert(summary, at: 0)
        }
    }

    func retainedAudioURLs(in directory: URL) async -> [URL] {
        let root = directory.deletingLastPathComponent()
        let bookmarkData = bookmark(for: root)
        return (try? await SecurityScopedFolder.withAccess(
            to: root,
            bookmarkData: bookmarkData
        ) { resolved in
            SessionAssetResolver.audioURLs(
                in: resolved.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
            )
        }) ?? []
    }
}

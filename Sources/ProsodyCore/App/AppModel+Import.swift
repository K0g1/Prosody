import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AudioImportOptions: Sendable {
    var label: RecordingLabel?
    var preserveFileName = true
}

@MainActor
private final class ImportOptionsDraft: ObservableObject {
    @Published var labelID: UUID?
    @Published var preserveFileName = true
}

private struct AudioImportAccessory: View {
    let labels: [RecordingLabel]
    @ObservedObject var draft: ImportOptionsDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Label", selection: $draft.labelID) {
                Text("None").tag(nil as UUID?)
                ForEach(labels) { Text($0.name).tag(Optional($0.id)) }
            }
            .help("Apply a label and its save location to every selected file")
            Toggle("Use audio filenames for Markdown exports", isOn: $draft.preserveFileName)
                .help("Use the original audio name as the Markdown filename. Turn off to use the label’s naming pattern or the default transcript filename.")
        }
        .padding(12)
        .frame(width: 390, alignment: .leading)
    }
}

extension AppModel {
    public func chooseTranscriptionFile() {
        guard canBrowseSessions else { return }
        let panel = NSOpenPanel()
        let draft = ImportOptionsDraft()
        let labels = preferences.recordingLabels
        panel.title = "Transcribe Audio Files"
        panel.prompt = "Transcribe"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.accessoryView = NSHostingView(rootView: AudioImportAccessory(labels: labels, draft: draft))
        panel.isAccessoryViewDisclosed = true
        let receive: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let urls = panel?.urls, let self else { return }
            let label = labels.first { $0.id == draft.labelID }
            self.transcribeFiles(urls, options: AudioImportOptions(label: label, preserveFileName: draft.preserveFileName))
        }
        if let window = NSApp.keyWindow, window.identifier?.rawValue == "clippy.library" {
            panel.beginSheetModal(for: window, completionHandler: receive)
        } else {
            panel.begin(completionHandler: receive)
        }
    }

    public func transcribeFile(_ url: URL) { transcribeFiles([url], options: .init()) }

    func transcribeFiles(_ urls: [URL], options: AudioImportOptions) {
        guard canBrowseSessions, dictation.canChangeRecognitionModel, !urls.isEmpty else { return }
        selectionTask?.cancel()
        transcriptUndoManager.removeAllActions()
        userFacingError = nil
        isImportingAudio = true
        recordingState = .finalizingTranscript

        let model = selectedSpeechModel
        let configuration = preferences.transcriptSegmentationConfiguration
        let template = makeLibrarySession(title: "", kind: "file")
        let speakerMode = preferences.speakerMode
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isImportingAudio = false }
            var saved = 0
            var lastSaved: UUID?
            var failures: [String] = []
            let scope = UUID()
            do {
                _ = try await modelManager.installedURL(for: model)
                for (index, url) in urls.enumerated() {
                    try Task.checkCancellation()
                    recordingState = .finalizingTranscript
                    processingStatus = nil
                    lastNotice = "Transcribing \(index + 1) of \(urls.count) · \(url.lastPathComponent)"
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let result = try await dictation.transcribeFileWithCachedModel(url, configuration: configuration, scope: scope)
                        let session = importSession(for: url, options: options, template: template, duration: result.duration,
                                                    speakerMode: speakerMode)
                        accumulatedDuration = result.duration
                        activeSession = session
                        selectedSessionID = session.id
                        selectedSessionAudioURLs = []
                        selectedSessionHasNotes = false
                        await complete(result: RecordingResult(session: session, transcript: result.transcript),
                                       fallbackSession: session, announceCompletion: urls.count == 1, importedAudio: url)
                        guard recordingState == .completed(session.id) else {
                            throw userFacingError ?? UserFacingError(title: "Could not save transcript", message: session.title)
                        }
                        saved += 1
                        lastSaved = session.id
                        if session.keepAudio, let path = activeSession?.outputFolderPath {
                            try await retainImportedAudio(url, in: path, sessionID: session.id)
                        }
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            } catch {
                failures.append(error.localizedDescription)
            }
            await dictation.finishExternalTranscription(scope)
            if let lastSaved {
                recordingState = .completed(lastSaved)
                if selectedSessionID != lastSaved, let document = await loadDocument(id: lastSaved) {
                    activeSession = document.session
                    selectedSessionID = lastSaved
                    transcript = document.transcript
                    liveSegments = document.transcript.visibleSegments
                    selectedSessionHasNotes = document.notesMarkdown != nil
                    refreshSelectedAudio()
                }
                if urls.count > 1 { lastNotice = "Saved \(saved) of \(urls.count) transcripts." }
            }
            if !failures.isEmpty {
                let title = lastSaved == nil ? "Could not transcribe audio files" : "Some import steps failed"
                let failure = UserFacingError(title: title, message: failures.prefix(3).joined(separator: "\n"))
                userFacingError = failure
                if lastSaved == nil { recordingState = .failed(failure) }
            } else {
                userFacingError = nil
            }
        }
    }

    private func importSession(for url: URL, options: AudioImportOptions, template: RecordingSession,
                               duration: TimeInterval, speakerMode: SpeakerMode) -> RecordingSession {
        let name = url.deletingPathExtension().lastPathComponent
        var session = RecordingSession(title: name, duration: duration, captureMode: .microphone,
            sttEngineID: template.sttEngineID, sttModelID: template.sttModelID, speakerMode: speakerMode,
            notesProviderID: template.notesProviderID, notesModelID: template.notesModelID,
            noteTemplateID: template.noteTemplateID, keepAudio: template.keepAudio)
        session.sourceKind = "file"
        session.originalAudioFileName = url.lastPathComponent
        session.liveTranscriptionEnabled = false
        if let label = options.label {
            session.labels = [label.snapshot]
            session.labelTranscriptCopies = label.transcriptCopy.map { [$0] }
            session.destinationRootPath = label.outputFolderPath
            if !options.preserveFileName {
                session.title = RecordingNaming.title(pattern: label.namingPattern, title: "", label: label.name,
                    date: session.createdAt, id: session.id, dateFormat: label.dateFormat)
                session.transcriptFileName = RecordingNaming.transcriptFileName(for: session.title)
            }
        }
        if options.preserveFileName {
            session.transcriptFileName = RecordingNaming.transcriptFileName(for: name)
        } else if options.label == nil {
            // Keep the source visible in the library while using a generated
            // filename for this transcript and later exports.
            session.transcriptFileName = "Transcript-\(session.id.uuidString.prefix(8)).md"
        }
        return session
    }

    private func retainImportedAudio(_ url: URL, in path: String, sessionID: UUID) async throws {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let root = directory.deletingLastPathComponent()
        try await SecurityScopedFolder.withAccess(to: root, bookmarkData: bookmark(for: root)) { resolved in
            let folder = resolved.appendingPathComponent(directory.lastPathComponent)
                .appendingPathComponent("audio/microphone", isDirectory: true)
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url,
                    to: folder.appendingPathComponent("000001").appendingPathExtension(url.pathExtension))
            }.value
        }
        refreshSelectedAudio()
        if let summary = await refreshLibrarySummary(id: sessionID, folderPath: path) { upsertRecentSummary(summary) }
    }
}

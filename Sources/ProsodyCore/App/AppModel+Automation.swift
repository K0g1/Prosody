import Foundation
import ProsodyIPC

extension AppModel {
    /// File automation uses the dictation recognizer's installed-model lease.
    /// The app holds exclusive access to that recognizer for the whole batch.
    public func transcribeForShortcut(url: URL, format: TranscriptCopyFormat) async throws -> String {
        var request = CLIRequest(command: .transcribe)
        request.files = [url.path]
        request.stdout = true
        request.format = format.rawValue
        let response = await runFileAutomation(request)
        guard let text = response.items.first?.text else {
            throw UserFacingError(title: "Transcription failed", message: response.error ?? response.items.first?.error ?? "No result was returned.")
        }
        return text
    }

    public func cleanText(_ text: String) -> String {
        FillerWordFilter.clean(text)
    }

    func runFileAutomation(_ request: CLIRequest) async -> CLIResponse {
        switch request.command {
        case .status:
            let model = selectedSpeechModel
            let installed = await modelManager.isInstalled(model.descriptor)
            let status = isImportingAudio ? "Transcribing audio files" : recordingState.statusTitle
            return CLIResponse(message: "Model: \(model.descriptor.displayName) (\(installed ? "installed" : "download required"))\nStatus: \(status)")
        case .labels:
            let labels = preferences.recordingLabels.map {
                CLIResponse.Item(input: $0.id.uuidString, output: $0.transcriptCopy?.folderPath ?? $0.outputFolderPath, text: $0.name)
            }
            return CLIResponse(items: labels)
        case .replacements:
            return editWordReplacements(request)
        case .transcribe:
            break
        }

        guard canBrowseSessions, dictation.canChangeRecognitionModel else {
            return CLIResponse(error: "Prosody is recording, dictating, or processing another job.")
        }
        guard !request.files.isEmpty, request.files.count <= 512,
              !request.stdout || request.files.count == 1,
              request.title == nil || request.files.count == 1 else {
            return CLIResponse(error: "Provide 1–512 files. A custom title or standard output requires one file.")
        }

        let label: RecordingLabel?
        if let labelKey = request.label {
            let labels = preferences.recordingLabels.filter {
                $0.id.uuidString.caseInsensitiveCompare(labelKey) == .orderedSame
                    || $0.name.caseInsensitiveCompare(labelKey) == .orderedSame
            }
            guard labels.count == 1 else { return CLIResponse(error: "Use the name or ID of one saved label. Run prosody labels.") }
            label = labels[0]
        } else {
            label = preferences.selectedRecordingLabels.first
        }
        let format: TranscriptCopyFormat
        if let raw = request.format {
            guard let selected = TranscriptCopyFormat(rawValue: raw) else { return CLIResponse(error: "Unsupported export format.") }
            format = selected
        } else {
            format = label?.transcriptCopy?.format ?? .markdown
        }
        let folderPath = request.outputDirectory ?? label?.transcriptCopy?.folderPath ?? label?.outputFolderPath ?? preferences.outputFolderPath
        let output = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
        let outputGrant = preferences.transcriptCopyDestinations.first { $0.path == folderPath }?.bookmarkData ?? bookmark(for: output)
        let options = automationMarkdownOptions(fields: request.markdownFields)
        let configuration = preferences.transcriptSegmentationConfiguration
        let replacements = WordReplacementProcessor(rules: preferences.wordReplacements)
        let omitFillers = request.omitFillers ?? preferences.omitFillerWords
        let scope = UUID()
        isImportingAudio = true
        defer {
            isImportingAudio = false
            if Task.isCancelled { lastNotice = "Transcription cancelled." }
        }
        var replies: [CLIResponse.Item] = []
        do {
            _ = try await modelManager.installedURL(for: selectedSpeechModel)
            for path in request.files {
                try Task.checkCancellation()
                let url = URL(fileURLWithPath: path)
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                    guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                    lastNotice = "Transcribing \(url.lastPathComponent)…"
                    let result = try await dictation.transcribeFileWithCachedModel(url, configuration: configuration, scope: scope)
                    var transcript = result.transcript
                    if omitFillers { transcript = FillerWordFilter().apply(to: transcript) }
                    transcript = replacements.apply(to: transcript)
                    let sourceName = url.deletingPathExtension().lastPathComponent
                    var session = makeLibrarySession(title: request.title ?? sourceName, kind: "file")
                    session.duration = result.duration
                    session.originalAudioFileName = url.lastPathComponent
                    session.labels = label.map { [$0.snapshot] }
                    if request.preserveFileName != false {
                        session.transcriptFileName = RecordingNaming.transcriptFileName(for: sourceName)
                    } else if let label {
                        session.transcriptFileName = RecordingNaming.transcriptFileName(for: RecordingNaming.title(
                            pattern: label.namingPattern, title: session.title, label: label.name, date: session.createdAt,
                            id: session.id, dateFormat: label.dateFormat
                        ))
                    } else {
                        session.transcriptFileName = RecordingNaming.transcriptFileName(for: request.title ?? "Transcript-\(session.id.uuidString.prefix(8))")
                    }
                    let document = SessionDocument(session: session, transcript: transcript)
                    let body = await Task.detached(priority: .userInitiated) {
                        TranscriptExportFormatter.render(document, format: format, options: options)
                    }.value
                    try Task.checkCancellation()
                    if request.stdout {
                        replies.append(.init(input: path, text: body))
                    } else {
                        let fileName = TranscriptExporter.fileName(for: session, format: format)
                        let destination = try await SecurityScopedFolder.withAccess(to: output, bookmarkData: outputGrant) { directory in
                            try await Task.detached(priority: .utility) {
                                try TranscriptExporter.writeCopy(body, fileName: fileName, in: directory)
                            }.value
                        }
                        replies.append(.init(input: path, output: destination.path))
                    }
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    replies.append(.init(input: path, error: error.localizedDescription))
                }
            }
        } catch {
            await dictation.finishExternalTranscription(scope)
            return CLIResponse(error: error.localizedDescription, items: replies)
        }
        await dictation.finishExternalTranscription(scope)
        let count = replies.filter { $0.error == nil }.count
        lastNotice = "Transcribed \(count) of \(request.files.count) files."
        return CLIResponse(items: replies)
    }

    private func editWordReplacements(_ request: CLIRequest) -> CLIResponse {
        let operation = request.replacementOperation ?? .list
        if operation == .list {
            return CLIResponse(items: preferences.wordReplacements.filter {
                !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.map { .init(input: $0.original, text: $0.replacement) })
        }
        guard canBrowseSessions else { return CLIResponse(error: "Wait for Prosody to finish its current job.") }
        guard let original = request.originalWord?.trimmingCharacters(in: .whitespacesAndNewlines), !original.isEmpty else {
            return CLIResponse(error: "Enter the word or phrase exactly as the model writes it.")
        }
        var rules = preferences.wordReplacements
        let matching = rules.indices.filter {
            rules[$0].original.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(original) == .orderedSame
        }
        switch operation {
        case .set:
            guard let replacement = request.replacementWord else { return CLIResponse(error: "Enter a replacement.") }
            if let index = matching.first {
                rules[index].replacement = replacement
                for duplicate in matching.dropFirst().reversed() { rules.remove(at: duplicate) }
            } else {
                rules.append(WordReplacement(original: original, replacement: replacement))
            }
        case .remove:
            guard !matching.isEmpty else { return CLIResponse(error: "No matching replacement.") }
            for index in matching.reversed() { rules.remove(at: index) }
        case .list: break
        }
        preferences.wordReplacements = rules
        return CLIResponse(message: operation == .set ? "Replacement saved." : "Replacement removed.")
    }

    private func automationMarkdownOptions(fields: [String: Bool]) -> TranscriptExportOptions {
        var options = preferences.transcriptExport
        options.title = fields["title"] ?? options.title
        options.date = fields["date"] ?? options.date
        options.time = fields["time"] ?? options.time
        options.duration = fields["duration"] ?? options.duration
        options.originalAudioFileName = fields["audio-name"] ?? options.originalAudioFileName
        options.timestamps = fields["timestamps"] ?? options.timestamps
        options.speakerNames = fields["speakers"] ?? options.speakerNames
        options.labels = fields["labels"] ?? options.labels
        return options
    }

    func setCLIEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try cliService.install(previousTarget: preferences.cliInstalledTarget)
                preferences.cliInstalledTarget = cliService.currentTarget
                preferences.cliEnabled = true
                try cliService.start(model: self)
            } else {
                cliService.stop()
                try cliService.uninstall(target: preferences.cliInstalledTarget)
                preferences.cliEnabled = false
                preferences.cliInstalledTarget = nil
            }
            userFacingError = nil
        } catch {
            cliService.stop()
            preferences.cliEnabled = false
            userFacingError = UserFacingError(title: "Could not configure the CLI", message: error.localizedDescription)
        }
    }

    func restoreCLI() {
        if preferences.cliEnabled { setCLIEnabled(true) }
    }

    public func retainedFilesForShortcut(id: UUID) async throws -> [URL] {
        guard let document = await loadDocument(id: id) else { throw SessionStoreError.sessionNotFound }
        return try await withSessionAudioAccess(document.session) { directory in
            let tracks = SessionAssetResolver.allAudioTracks(in: directory)
            return AudioSource.allCases.flatMap { tracks[$0] ?? [] }
        }
    }

    public func openTranscriptFromShortcut(_ summary: SessionSummary) {
        if summary.isDictation { libraryShowDictationRequest &+= 1 }
        librarySelection = [summary.id]
        selectSession(summary)
    }

    public func waitForRecordingTransition() async {
        await transitionTask?.value
    }
}

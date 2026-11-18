import AppKit
import UniformTypeIdentifiers

extension AppModel {
    var exportSelection: [UUID] { librarySelection.isEmpty ? selectedSessionID.map { [$0] } ?? [] : librarySelection }

    var selectionMayHaveAudio: Bool {
        let selected = Set(exportSelection)
        return recentSessions.contains { selected.contains($0.id) && $0.hasRetainedAudio != false }
    }

    public func copySelectedTranscripts(format: TranscriptCopyFormat) {
        let ids = exportSelection
        guard !ids.isEmpty, canBrowseSessions else { return }
        let options = preferences.transcriptExport
        Task {
            var sections: [String] = []
            for id in ids {
                if let document = await loadDocument(id: id) {
                    sections.append(TranscriptExportFormatter.render(document, format: format, options: options))
                }
            }
            guard !sections.isEmpty else { return }
            let separator = format == .rawText ? "\n\n" : "\n\n---\n\n"
            DictationTextDestination.copy(sections.joined(separator: separator))
            lastNotice = sections.count == 1 ? "Transcript copied." : "Copied \(sections.count) transcripts."
        }
    }

    func chooseExport(_ mode: LibraryExport) {
        let ids = exportSelection
        guard !ids.isEmpty, canBrowseSessions else { return }
        let panel: NSSavePanel
        switch mode {
        case .combinedMarkdown:
            let save = NSSavePanel()
            save.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            save.nameFieldStringValue = ids.count == 1 ? TranscriptExporter.fileStem(for: selectedSessionTitle) + ".md" : "Transcripts.md"
            save.title = "Export Combined Markdown"
            panel = save
        case .separateMarkdown, .audio:
            let folder = NSOpenPanel()
            folder.canChooseDirectories = true
            folder.canChooseFiles = false
            folder.canCreateDirectories = true
            folder.title = mode == .audio ? "Export Retained Audio" : "Export Separate Markdown Files"
            folder.prompt = "Export"
            panel = folder
        }
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let destination = panel?.url, let self, self.canBrowseSessions else { return }
            Task { await self.exportTranscripts(ids, to: destination, mode: mode) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else {
            panel.begin(completionHandler: complete)
        }
    }

    func exportTranscripts(_ ids: [UUID], to destination: URL, mode: LibraryExport) async {
        guard canBrowseSessions else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        let options = preferences.transcriptExport
        let accessing = destination.startAccessingSecurityScopedResource()
        defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
        var report = TranscriptExporter.Report()
        var combined: [String] = []
        for id in ids {
            guard let document = await loadDocument(id: id) else {
                report.failures.append("A selected transcript could not be opened.")
                continue
            }
            do {
                switch mode {
                case .combinedMarkdown:
                    combined.append(TranscriptExportFormatter.render(document, options: options))
                case .separateMarkdown:
                    let name = TranscriptExporter.fileName(for: document.session)
                    try await Task.detached(priority: .utility) {
                        let content = TranscriptExportFormatter.render(document, options: options)
                        try TranscriptExporter.writeCopy(content, fileName: name, in: destination)
                    }.value
                    report.exported += 1
                case .audio:
                    if try await exportAudio(document.session, to: destination) { report.exported += 1 }
                    else { report.skipped += 1 }
                }
            } catch {
                report.failures.append("\(document.session.title): \(error.localizedDescription)")
            }
        }
        if mode == .combinedMarkdown, !combined.isEmpty {
            do {
                try Data(combined.joined(separator: "\n\n---\n\n").utf8).write(to: destination, options: .atomic)
                report.exported = combined.count
            } catch { report.failures.append(error.localizedDescription) }
        }
        lastNotice = "Exported \(report.exported) of \(ids.count) transcripts."
        if report.skipped > 0 {
            lastNotice = "Exported audio for \(report.exported) transcripts. \(report.skipped) had no retained audio."
        }
        userFacingError = report.failures.first.map {
            UserFacingError(title: "Some items could not be exported", message: $0)
        }
    }

    private func exportAudio(_ session: RecordingSession, to destination: URL) async throws -> Bool {
        guard let path = session.outputFolderPath else { return false }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let root = directory.deletingLastPathComponent()
        return try await SecurityScopedFolder.withAccess(to: root, bookmarkData: bookmark(for: root)) { resolved in
            let source = resolved.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
            return try await Task.detached(priority: .utility) {
                try TranscriptExporter.copyAudio(from: source, title: session.title, into: destination)
            }.value
        }
    }

    func writeLabelTranscriptCopies(_ document: SessionDocument) async -> String? {
        guard let copies = document.session.labelTranscriptCopies, !copies.isEmpty else { return nil }
        let options = preferences.transcriptExport
        var seen: [LabelTranscriptCopy] = []
        var failure: String?
        for copy in copies where !seen.contains(copy) {
            seen.append(copy)
            let directory = URL(fileURLWithPath: copy.folderPath, isDirectory: true)
            let grant = preferences.transcriptCopyDestinations.first { $0.path == copy.folderPath }?.bookmarkData
            do {
                try await SecurityScopedFolder.withAccess(to: directory, bookmarkData: grant) { resolved in
                    try await Task.detached(priority: .utility) {
                        let content = TranscriptExportFormatter.render(document, format: copy.format, options: options)
                        let name = TranscriptExporter.fileName(for: document.session, format: copy.format)
                        try TranscriptExporter.writeCopy(content, fileName: name, in: resolved)
                    }.value
                }
            } catch {
                failure = "Transcript saved, but a label’s transcript copy could not be written: \(error.localizedDescription)"
            }
        }
        return failure
    }
}

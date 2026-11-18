import AppKit

extension AppModel {
    func retainedAudioBytes(for session: RecordingSession) async -> Int64 {
        (try? await withSessionAudioAccess(session) { directory in
            await Task.detached(priority: .utility) { RetainedAudioCompression.storedBytes(in: directory) }.value
        }) ?? 0
    }

    var canCompressSelectedAudio: Bool {
        canBrowseSessions && librarySelection.count <= 1 && activeSession?.id == selectedSessionID
            && activeSession?.outputFolderPath != nil && !selectedSessionAudioURLs.isEmpty
    }

    func confirmAudioCompression() {
        guard canCompressSelectedAudio, let session = activeSession else { return }
        let alert = NSAlert()
        alert.messageText = "Compress retained audio?"
        alert.informativeText = "Prosody will replace the original audio with a smaller AAC copy when possible. Compression is lossy and can’t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Compress Audio").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let compress: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.canCompressSelectedAudio,
                  self.activeSession?.id == session.id else { return }
            Task { await self.compressAudio(session) }
        }
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: compress) }
        else { compress(alert.runModal()) }
    }

    private func compressAudio(_ session: RecordingSession) async {
        guard canCompressSelectedAudio, session.id == selectedSessionID else { return }
        isTransitioning = true
        isCompressingAudio = true
        defer {
            isCompressingAudio = false
            isTransitioning = false
        }
        userFacingError = nil
        lastNotice = "Compressing retained audio…"
        do {
            let savings = try await withSessionAudioAccess(session) { directory in
                try await Task.detached(priority: .utility) { try RetainedAudioCompression.compress(in: directory) }.value
            }
            if savings > 0 {
                refreshSelectedAudio()
                audioAssetRevision &+= 1
                lastNotice = "Audio compressed. Saved \(ByteCountFormatter.string(fromByteCount: savings, countStyle: .file))."
            } else {
                lastNotice = "The original audio was already smaller than the compressed copy."
            }
        } catch {
            lastNotice = nil
            userFacingError = UserFacingError(title: "Could not compress audio", message: error.localizedDescription)
        }
    }

    func withSessionAudioAccess<T: Sendable>(
        _ session: RecordingSession, work: @escaping @Sendable (URL) async throws -> T
    ) async throws -> T {
        guard let path = session.outputFolderPath else { throw SessionStoreError.sessionNotFound }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let root = directory.deletingLastPathComponent()
        return try await SecurityScopedFolder.withAccess(to: root, bookmarkData: bookmark(for: root)) {
            try await work($0.appendingPathComponent(directory.lastPathComponent, isDirectory: true))
        }
    }
}

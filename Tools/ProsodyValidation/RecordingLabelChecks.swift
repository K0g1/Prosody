import ProsodyCore
import Foundation

extension ProsodyValidation {
    @MainActor
    static func checkRecordingLabels() async throws {
        let namespace = "ProsodyLabels-\(UUID())"
        let defaults = UserDefaults(suiteName: namespace)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(namespace)
        defer {
            defaults.removePersistentDomain(forName: namespace)
            try? FileManager.default.removeItem(at: root)
        }
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw LabelFailure(message: message) }
        }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID()
        let title = RecordingNaming.title(pattern: "{label} - {date} - {title} - {time}", title: "Vectors {date}", label: "Math",
                                          date: date, id: id, dateFormat: "dd-MM-yyyy", timeZone: TimeZone(secondsFromGMT: 0)!)
        try check(title == "Math - 14-11-2023 - Vectors {date} - 22-13-20", "Template dates or literal user tokens changed: \(title)")
        try check(RecordingNaming.unknownTokens(in: "{title} {typo}") == ["{typo}"], "Unknown tokens were not reported")
        for hostile in ["../../notes", "notes", "Notes.md", "a/b\\c:d", String(repeating: "🧮", count: 300), "\0\n", ".", ""] {
            let filename = RecordingNaming.transcriptFileName(for: hostile)
            try check(!filename.contains("/") && !filename.contains("\\") && filename.utf8.count < 255 && filename != "notes.md", "Unsafe filename: \(filename)")
            try check(RecordingNaming.safeTranscriptFileName(filename) == filename, "Filename sanitization is not idempotent")
        }
        let preferences = ProsodyPreferences(defaults: defaults)
        preferences.outputFolderPath = root.appendingPathComponent("Default").path
        preferences.captureMode = .system
        preferences.keepAudio = false
        preferences.notifyWhenFinished = false
        let customRoot = root.appendingPathComponent("Math")
        var label = RecordingLabel(name: "Math \"A\"", colorHex: "#CC4488", outputFolderPath: customRoot.path,
                                   namingPattern: "{date} - {title}", dateFormat: "yyyyMMdd")
        let other = RecordingLabel(name: "Exam prep")
        preferences.recordingLabels = [label, other]
        preferences.selectedRecordingLabelIDs = [label.id, other.id]
        preferences.rememberDestination(path: customRoot.path, bookmarkData: nil)
        let reopened = ProsodyPreferences(defaults: defaults)
        try check(reopened.recordingLabels == [label, other] && reopened.selectedRecordingLabels == [label, other], "Label preferences did not round-trip")
        let model = AppModel(preferences: preferences, demoMode: true, supportRootURL: root.appendingPathComponent("Support"), registerHotkey: false, loadStoredState: false)
        model.recordingTitle = "Vectors"
        model.startRecording()
        let preparingID = model.activeSession?.id
        try await Task.sleep(for: .milliseconds(750))
        try check(model.activeSession?.id == preparingID, "Recording start changed the identity used by naming tokens")
        try check(model.activeSession?.labels == [label.snapshot, other.snapshot], "Demo start lost label snapshots")
        // Editing the catalog during a run must not alter its recovery/final destination.
        label.name = "Changed"
        label.outputFolderPath = root.appendingPathComponent("Elsewhere").path
        model.saveRecordingLabel(label)
        try await Task.sleep(for: .milliseconds(1100))
        model.finishRecording()
        for _ in 0..<100 {
            if model.canBrowseSessions { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let session = model.activeSession, session.status == "completed", let filename = session.transcriptFileName else {
            throw LabelFailure(message: "Labeled recording did not finish: \(model.recordingState)")
        }
        try check(session.destinationRootPath == customRoot.path && session.labels?.first?.name == "Math \"A\"", "Catalog edit changed recording snapshot")
        try check(session.title.hasSuffix(" - Vectors") && filename == session.title + ".md", "Custom naming did not reach the recording or filename")
        let directory = customRoot.appendingPathComponent(session.id.uuidString)
        let markdownURL = directory.appendingPathComponent(filename)
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        try check(markdown.contains("labels:\n") && markdown.contains("color: \"#CC4488\"") && markdown.contains("Math \\\"A\\\""), "Markdown lost escaped label metadata")
        let store = SessionStore(rootURL: customRoot)
        let document = try await store.load(id: session.id)
        try check(document.session.labels == session.labels && document.transcriptMarkdown == markdown, "Manifest/custom Markdown failed to round-trip")
        try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.md").path), "A duplicate default Markdown was written")
        let originalDefault = preferences.outputFolderPath
        let grant = try SecurityScopedFolder.bookmarkData(for: customRoot)
        preferences.rememberDestination(path: customRoot.path, bookmarkData: grant)
        preferences.outputFolderPath = customRoot.path
        try check(model.selectedSessionBookmarkData == grant, "A missing default grant masked the label folder grant")
        preferences.outputFolderPath = originalDefault
        let originalNotes = document.notesMarkdown
        model.setSessionLabels([other.snapshot])
        for _ in 0..<100 {
            if model.canBrowseSessions { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let relabeled = try await store.load(id: session.id)
        try check(relabeled.session.labels == [other.snapshot] && relabeled.notesMarkdown == originalNotes, "Relabeling lost labels or notes")
        try check(relabeled.session.transcriptFileName == filename && FileManager.default.fileExists(atPath: markdownURL.path), "Relabeling moved files")
        model.setSessionLabels([])
        for _ in 0..<100 {
            if model.canBrowseSessions { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let cleared = try await store.load(id: session.id)
        try check(cleared.session.labels == [] && !(cleared.transcriptMarkdown ?? "").contains("labels:"), "Removing labels left stale Markdown metadata")
        // Missing index repair includes labels; old manifests and recovery JSON omit all new keys.
        try FileManager.default.removeItem(at: customRoot.appendingPathComponent(AppConstants.sessionIndexFileName))
        let summaries = try await store.list()
        try check(summaries.first?.labels == [], "Index repair omitted label metadata")
        var oldSession = try JSONSerialization.jsonObject(with: AtomicFileWriter.makeEncoder().encode(session)) as! [String: Any]
        for key in ["labels", "destinationRootPath", "transcriptFileName"] { oldSession.removeValue(forKey: key) }
        let legacy = try AtomicFileWriter.makeDecoder().decode(RecordingSession.self, from: JSONSerialization.data(withJSONObject: oldSession))
        try check(legacy.labels == nil && legacy.transcriptFileName == nil, "Legacy recovery session is not compatible")
        var oldManifest = try JSONSerialization.jsonObject(with: AtomicFileWriter.makeEncoder().encode(SessionManifest(session: session))) as! [String: Any]
        for key in ["labels", "destinationRootPath", "transcriptFileName"] { oldManifest.removeValue(forKey: key) }
        let legacyManifest = try AtomicFileWriter.makeDecoder().decode(SessionManifest.self, from: JSONSerialization.data(withJSONObject: oldManifest))
        try check(legacyManifest.recordingSession.labels == nil, "Legacy manifest is not compatible")
        let recovery = RecoveryStore(rootURL: root.appendingPathComponent("RecoveryCheck"))
        _ = try await recovery.begin(session: session)
        let recovered = try await recovery.load(id: session.id)
        try check(recovered.manifest.session.labels == session.labels && recovered.manifest.session.destinationRootPath == customRoot.path, "Recovery lost routing metadata")
        model.removeRecordingLabel(id: label.id)
        try check(preferences.recordingDestinations.contains { $0.path == customRoot.path }, "Deleting a catalog label discarded old folder access")
        let library = AppModel(preferences: ProsodyPreferences(defaults: defaults), demoMode: false, supportRootURL: root.appendingPathComponent("Support"), registerHotkey: false)
        for _ in 0..<100 {
            if library.recentSessions.contains(where: { $0.id == session.id }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(library.recentSessions.contains { $0.id == session.id }, "Restart lost sessions in an old label destination")
        print("Recording labels: PASS (naming, safe paths, preferences, recording, Markdown, relabeling, recovery, legacy decoding, destination history)")
    }
}

private struct LabelFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

import AppIntents
import Foundation
import ProsodyCore
import UniformTypeIdentifiers

enum ShortcutTranscriptFormat: String, AppEnum {
    case rawText, markdown, plainMarkdown

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Transcript Format"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .rawText: "Raw Text", .markdown: "Formatted Markdown", .plainMarkdown: "Text-only Markdown"
    ]

    var format: TranscriptCopyFormat {
        switch self {
        case .rawText: .rawText
        case .markdown: .markdown
        case .plainMarkdown: .textOnlyMarkdown
        }
    }
}

struct ShortcutTranscript: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Prosody Transcript"
    static let defaultQuery = ShortcutTranscriptQuery()

    let id: UUID
    let title: String
    let date: Date

    init(_ summary: SessionSummary) {
        id = summary.id
        title = summary.title
        date = summary.createdAt
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(date.formatted(date: .abbreviated, time: .shortened))")
    }
}

struct ShortcutTranscriptQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ShortcutTranscript] {
        let summaries = await AppModel.shared.loadSummaries()
        let byID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        return identifiers.compactMap { byID[$0].map(ShortcutTranscript.init) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ShortcutTranscript] {
        Array(await AppModel.shared.loadSummaries().prefix(20)).map(ShortcutTranscript.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ShortcutTranscript] {
        let sessions = await AppModel.shared.loadSummaries()
        return sessions.filter { summary in
            string.isEmpty || summary.title.localizedCaseInsensitiveContains(string)
                || summary.labels?.contains(where: { $0.name.localizedCaseInsensitiveContains(string) }) == true
        }.map(ShortcutTranscript.init)
    }
}

struct TranscribeAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Transcribe Audio File"
    static let description = IntentDescription("Transcribe an audio file on this Mac using Prosody’s selected speech model.")
    @Parameter(title: "Audio File", supportedContentTypes: [.audio]) var audio: IntentFile
    @Parameter(title: "Format", default: .rawText) var format: ShortcutTranscriptFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Transcribe \(\.$audio) as \(\.$format)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        if let url = audio.fileURL {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            return .result(value: try await AppModel.shared.transcribeForShortcut(url: url, format: format.format))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Prosody-Shortcut-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent((audio.filename as NSString).lastPathComponent)
        try audio.data.write(to: url)
        return .result(value: try await AppModel.shared.transcribeForShortcut(url: url, format: format.format))
    }
}

struct GetLatestTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Transcript"
    static let description = IntentDescription("Find the newest saved transcript. Include saved dictations if requested.")
    @Parameter(title: "Include Dictation", default: false) var includeDictation: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ShortcutTranscript> {
        let summaries = await AppModel.shared.loadSummaries()
        guard let latest = summaries.first(where: { includeDictation || !$0.isDictation }) else {
            throw UserFacingError(title: "No saved transcripts", message: "Record or import audio in Prosody first.")
        }
        return .result(value: ShortcutTranscript(latest))
    }
}

struct FindTranscriptsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Transcripts by Title or Label"
    @Parameter(title: "Search") var query: String

    static var parameterSummary: some ParameterSummary { Summary("Find transcripts matching \(\.$query)") }

    func perform() async throws -> some IntentResult & ReturnsValue<[ShortcutTranscript]> {
        .result(value: try await ShortcutTranscriptQuery().entities(matching: query))
    }
}

struct GetTranscriptTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Transcript Text"
    @Parameter(title: "Transcript") var transcript: ShortcutTranscript
    @Parameter(title: "Format", default: .rawText) var format: ShortcutTranscriptFormat

    static var parameterSummary: some ParameterSummary { Summary("Get \(\.$transcript) as \(\.$format)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = AppModel.shared
        guard let document = await model.loadDocument(id: transcript.id) else { throw SessionStoreError.sessionNotFound }
        return .result(value: TranscriptExportFormatter.render(document, format: format.format, options: model.preferences.transcriptExport))
    }
}

struct GetTranscriptAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Retained Audio"
    @Parameter(title: "Transcript") var transcript: ShortcutTranscript

    static var parameterSummary: some ParameterSummary { Summary("Get retained audio from \(\.$transcript)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let files = try await AppModel.shared.retainedFilesForShortcut(id: transcript.id)
        return .result(value: files.map { IntentFile(fileURL: $0, type: .audio) })
    }
}

struct CleanSpeechIntent: AppIntent {
    static let title: LocalizedStringResource = "Omit Filler Words"
    @Parameter(title: "Text") var text: String

    static var parameterSummary: some ParameterSummary { Summary("Omit filler words from \(\.$text)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: AppModel.shared.cleanText(text))
    }
}

struct SetFillerPreferenceIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Filler Word Preference"
    @Parameter(title: "Omit Filler Words", default: true) var enabled: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.preferences.omitFillerWords = enabled
        return .result()
    }
}

struct GetRecordingStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recording Status"

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: AppModel.shared.recordingState.statusTitle)
    }
}

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Start recording with the audio source and label selected in Prosody.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        guard model.canToggleRecording, !model.recordingState.isRecording else { throw RecordingIntentError.unavailable }
        model.startRecording()
        await model.waitForRecordingTransition()
        guard model.recordingState == .recording else { throw (model.userFacingError as (any Error)?) ?? RecordingIntentError.unavailable }
        return .result()
    }
}

struct PauseResumeRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or Resume Recording"
    @Parameter(title: "Resume", default: false) var resume: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        let source: RecordingState = resume ? .paused : .recording
        let destination: RecordingState = resume ? .recording : .paused
        guard model.canToggleRecording, model.recordingState == source else { throw RecordingIntentError.unavailable }
        model.toggleRecording()
        await model.waitForRecordingTransition()
        guard model.recordingState == destination else { throw (model.userFacingError as (any Error)?) ?? RecordingIntentError.unavailable }
        return .result()
    }
}

struct FinishRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Finish Recording"
    static let description = IntentDescription("Finish recording and return the saved transcript when it is ready.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ShortcutTranscript> {
        let model = AppModel.shared
        guard model.canFinishRecording else { throw RecordingIntentError.unavailable }
        model.finishRecording()
        await model.waitForRecordingTransition()
        guard case .completed(let id) = model.recordingState,
              let saved = model.recentSessions.first(where: { $0.id == id }) else {
            throw (model.userFacingError as (any Error)?) ?? RecordingIntentError.unavailable
        }
        return .result(value: ShortcutTranscript(saved))
    }
}

private enum RecordingIntentError: Error, LocalizedError {
    case unavailable
    var errorDescription: String? { "Prosody can’t perform this action in its current recording state." }
}

struct OpenRecorderIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Recorder"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppWindowController.shared.showRecordingControls()
        return .result()
    }
}

struct OpenTranscriptsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Transcripts"
    static let openAppWhenRun = true
    @Parameter(title: "Transcript") var transcript: ShortcutTranscript?

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        if let transcript {
            let summaries = await model.loadSummaries()
            guard model.canBrowseSessions, let selected = summaries.first(where: { $0.id == transcript.id }) else {
                throw SessionStoreError.sessionNotFound
            }
            model.openTranscriptFromShortcut(selected)
        }
        AppWindowController.shared.showLibrary()
        return .result()
    }
}

struct OpenSettingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Prosody Settings"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppWindowController.shared.showSettings()
        return .result()
    }
}

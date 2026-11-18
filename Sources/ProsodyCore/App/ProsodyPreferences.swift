import Combine
import Foundation

public enum DictationOverlayAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard = "Standard"
    case minimal = "Minimal"
    public var id: String { rawValue }
}

@MainActor
public final class ProsodyPreferences: ObservableObject {
    @Published public var transcriptSegmentationConfiguration: TranscriptSegmentationConfiguration { didSet { persist() } }
    @Published public var hiddenMainScreenSections: Set<MainScreenSection> { didSet { persist() } }

    public func showsOnMainScreen(_ section: MainScreenSection) -> Bool {
        !hiddenMainScreenSections.contains(section)
    }

    public func setMainScreenSection(_ section: MainScreenSection, visible: Bool) {
        if visible { hiddenMainScreenSections.remove(section) }
        else { hiddenMainScreenSections.insert(section) }
    }

    @Published public var theme: ProsodyTheme { didSet { persist() } }
    @Published public var dictationInsertionMethod: DictationInsertionMethod { didSet { persist() } }
    @Published public var dictationShortcut: DictationShortcut { didSet { persist() } }
    @Published public var dictationActivation: DictationActivation { didSet { persist() } }
    @Published public var dictationOverlayAppearance: DictationOverlayAppearance { didSet { persist() } }
    @Published public var copyDictationToClipboard: Bool { didSet { persist() } }
    @Published public var smartDictationCapitalization: Bool { didSet { persist() } }
    @Published public var wordReplacements: [WordReplacement] { didSet { persist() } }
    @Published public var captureMode: CaptureMode { didSet { persist() } }
    @Published public var sttEngineID: STTEngineID { didSet { persist() } }
    @Published public var sttModelID: String { didSet { persist() } }
    @Published public var speakerMode: SpeakerMode { didSet { persist() } }
    @Published public var notesProviderID: String { didSet { persist() } }
    @Published public var notesModelID: String { didSet { persist() } }
    @Published public var notesBaseURL: String { didSet { persist() } }
    @Published public var noteTemplateID: NoteTemplateID { didSet { persist() } }
    @Published public var outputFolderPath: String { didSet { persist() } }
    @Published public var outputFolderBookmarkData: Data? { didSet { persist() } }
    @Published public var outputFormat: String { didSet { persist() } }
    @Published public var microphoneName: String { didSet { persist() } }
    @Published public var recordingQuality: String { didSet { persist() } }
    @Published public var language: String { didSet { persist() } }
    @Published public var liveTranscription: Bool { didSet { persist() } }
    @Published public var keepAudio: Bool { didSet { persist() } }
    @Published public var generateNotesAutomatically: Bool { didSet { persist() } }
    /// Compatibility cache only. SMAppService status is authoritative; this is
    /// updated after a successful user-initiated Settings change. External
    /// changes and older Clippy builds can leave this value stale.
    @Published public var launchAtLogin: Bool { didSet { persist() } }
    @Published public var globalShortcut: String { didSet { persist() } }
    @Published public var localOnlyMode: Bool { didSet { persist() } }
    @Published public var notifyWhenFinished: Bool { didSet { persist() } }
    @Published public var automaticallyRevealNotes: Bool { didSet { persist() } }
    @Published public var checkForUpdates: Bool { didSet { persist() } }

    @Published public var recordingLabels: [RecordingLabel] { didSet { persist() } }
    @Published public var selectedRecordingLabelIDs: [UUID] { didSet { persist() } }
    @Published public var recordingDestinations: [RecordingDestination] { didSet { persist() } }

    public var selectedRecordingLabels: [RecordingLabel] {
        selectedRecordingLabelIDs.compactMap { id in recordingLabels.first { $0.id == id } }
    }

    public func rememberDestination(path: String, bookmarkData: Data?) {
        if let index = recordingDestinations.firstIndex(where: { $0.path == path }) {
            if let bookmarkData { recordingDestinations[index].bookmarkData = bookmarkData }
        } else {
            recordingDestinations.append(.init(path: path, bookmarkData: bookmarkData))
        }
    }

    private let defaults: UserDefaults

    private enum Key {
        static let hiddenMainScreenSections = "preferences.hiddenMainScreenSections"
        static let dictationOverlayAppearance = "preferences.dictationOverlayAppearance"
        static let smartDictationCapitalization = "preferences.smartDictationCapitalization"
        static let captureMode = "preferences.captureMode"
        static let sttEngine = "preferences.sttEngine"
        static let sttModel = "preferences.sttModel"
        static let speakerMode = "preferences.speakerMode"
        static let notesProvider = "preferences.notesProvider"
        static let notesModel = "preferences.notesModel"
        static let notesBaseURL = "preferences.notesBaseURL"
        static let template = "preferences.template"
        static let outputFolder = "preferences.outputFolder"
        static let outputBookmark = "preferences.outputBookmark"
        static let outputFormat = "preferences.outputFormat"
        static let microphone = "preferences.microphone"
        static let quality = "preferences.quality"
        static let language = "preferences.language"
        static let liveTranscription = "preferences.liveTranscription"
        static let keepAudio = "preferences.keepAudio"
        static let generateNotes = "preferences.generateNotes"
        static let launchAtLogin = "preferences.launchAtLogin"
        static let globalShortcut = "preferences.globalShortcut"
        static let localOnly = "preferences.localOnly"
        static let notifyWhenFinished = "preferences.notifyWhenFinished"
        static let automaticallyReveal = "preferences.automaticallyReveal"
        static let checkForUpdates = "preferences.checkForUpdates"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        transcriptSegmentationConfiguration = .persisted(in: defaults)
        hiddenMainScreenSections = Set((defaults.stringArray(forKey: Key.hiddenMainScreenSections) ?? [])
            .compactMap(MainScreenSection.init(rawValue:)))
        dictationInsertionMethod = DictationInsertionMethod(rawValue: defaults.string(forKey: "preferences.dictationInsertion") ?? "") ?? .paste
        theme = ProsodyTheme(rawValue: defaults.string(forKey: "preferences.theme") ?? "") ?? .graphite
        dictationShortcut = DictationShortcut(rawValue: defaults.string(forKey: "preferences.dictationShortcut") ?? "") ?? .rightCommand
        dictationActivation = DictationActivation(rawValue: defaults.string(forKey: "preferences.dictationActivation") ?? "") ?? .hold
        dictationOverlayAppearance = DictationOverlayAppearance(rawValue: defaults.string(forKey: Key.dictationOverlayAppearance) ?? "") ?? .standard
        copyDictationToClipboard = defaults.bool(forKey: "preferences.copyDictationToClipboard")
        smartDictationCapitalization = defaults.object(forKey: Key.smartDictationCapitalization) as? Bool ?? true
        wordReplacements = defaults.data(forKey: "preferences.wordReplacements").flatMap { try? JSONDecoder().decode([WordReplacement].self, from: $0) } ?? []
        recordingLabels = (defaults.data(forKey: "preferences.recordingLabels").flatMap { try? JSONDecoder().decode([RecordingLabel].self, from: $0) }) ?? []
        selectedRecordingLabelIDs = (defaults.stringArray(forKey: "preferences.selectedRecordingLabels") ?? []).compactMap(UUID.init(uuidString:))
        recordingDestinations = (defaults.data(forKey: "preferences.recordingDestinations").flatMap { try? JSONDecoder().decode([RecordingDestination].self, from: $0) }) ?? []
        captureMode = CaptureMode(rawValue: defaults.string(forKey: Key.captureMode) ?? "") ?? .both
        sttEngineID = .parakeet
        sttModelID = "parakeet-unified"
        speakerMode = SpeakerMode(rawValue: defaults.string(forKey: Key.speakerMode) ?? "") ?? .basic
        notesProviderID = defaults.string(forKey: Key.notesProvider) ?? "template-local"
        notesModelID = defaults.string(forKey: Key.notesModel) ?? "qwen3-4b"
        notesBaseURL = defaults.string(forKey: Key.notesBaseURL) ?? "http://127.0.0.1:1234/v1"
        noteTemplateID = NoteTemplateID(rawValue: defaults.string(forKey: Key.template) ?? "") ?? .lectureNotes
        outputFolderPath = defaults.string(forKey: Key.outputFolder) ?? ProsodyStorage.defaultOutputFolderPath()
        outputFolderBookmarkData = defaults.data(forKey: Key.outputBookmark)
        outputFormat = "markdown"
        microphoneName = defaults.string(forKey: Key.microphone) ?? "System Default"
        recordingQuality = defaults.string(forKey: Key.quality) ?? "efficient"
        language = "English"
        liveTranscription = defaults.object(forKey: Key.liveTranscription) as? Bool ?? true
        keepAudio = defaults.object(forKey: Key.keepAudio) as? Bool ?? false
        generateNotesAutomatically = defaults.object(forKey: Key.generateNotes) as? Bool ?? true
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
        globalShortcut = defaults.string(forKey: Key.globalShortcut) ?? "⌥⌘R"
        localOnlyMode = defaults.object(forKey: Key.localOnly) as? Bool ?? true
        notifyWhenFinished = defaults.object(forKey: Key.notifyWhenFinished) as? Bool ?? true
        automaticallyRevealNotes = defaults.object(forKey: Key.automaticallyReveal) as? Bool ?? false
        checkForUpdates = defaults.object(forKey: Key.checkForUpdates) as? Bool ?? true
    }

    private func persist() {
        defaults.set(transcriptSegmentationConfiguration.maximumWordsPerSegment, forKey: TranscriptSegmentationConfiguration.maximumWordsDefaultsKey)
        defaults.set(transcriptSegmentationConfiguration.pauseThreshold, forKey: TranscriptSegmentationConfiguration.pauseThresholdDefaultsKey)
        defaults.set(hiddenMainScreenSections.map(\.rawValue).sorted(), forKey: Key.hiddenMainScreenSections)
        defaults.set(dictationInsertionMethod.rawValue, forKey: "preferences.dictationInsertion")
        defaults.set(theme.rawValue, forKey: "preferences.theme")
        defaults.set(dictationShortcut.rawValue, forKey: "preferences.dictationShortcut")
        defaults.set(dictationActivation.rawValue, forKey: "preferences.dictationActivation")
        defaults.set(dictationOverlayAppearance.rawValue, forKey: Key.dictationOverlayAppearance)
        defaults.set(copyDictationToClipboard, forKey: "preferences.copyDictationToClipboard")
        defaults.set(smartDictationCapitalization, forKey: Key.smartDictationCapitalization)
        defaults.set(try? JSONEncoder().encode(wordReplacements), forKey: "preferences.wordReplacements")
        defaults.set(try? JSONEncoder().encode(recordingLabels), forKey: "preferences.recordingLabels")
        defaults.set(selectedRecordingLabelIDs.map(\.uuidString), forKey: "preferences.selectedRecordingLabels")
        defaults.set(try? JSONEncoder().encode(recordingDestinations), forKey: "preferences.recordingDestinations")
        defaults.set(captureMode.rawValue, forKey: Key.captureMode)
        defaults.set(sttEngineID.rawValue, forKey: Key.sttEngine)
        defaults.set(sttModelID, forKey: Key.sttModel)
        defaults.set(speakerMode.rawValue, forKey: Key.speakerMode)
        defaults.set(notesProviderID, forKey: Key.notesProvider)
        defaults.set(notesModelID, forKey: Key.notesModel)
        defaults.set(notesBaseURL, forKey: Key.notesBaseURL)
        defaults.set(noteTemplateID.rawValue, forKey: Key.template)
        defaults.set(outputFolderPath, forKey: Key.outputFolder)
        defaults.set(outputFolderBookmarkData, forKey: Key.outputBookmark)
        defaults.set(outputFormat, forKey: Key.outputFormat)
        defaults.set(microphoneName, forKey: Key.microphone)
        defaults.set(recordingQuality, forKey: Key.quality)
        defaults.set(language, forKey: Key.language)
        defaults.set(liveTranscription, forKey: Key.liveTranscription)
        defaults.set(keepAudio, forKey: Key.keepAudio)
        defaults.set(generateNotesAutomatically, forKey: Key.generateNotes)
        defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
        defaults.set(globalShortcut, forKey: Key.globalShortcut)
        defaults.set(localOnlyMode, forKey: Key.localOnly)
        defaults.set(notifyWhenFinished, forKey: Key.notifyWhenFinished)
        defaults.set(automaticallyRevealNotes, forKey: Key.automaticallyReveal)
        defaults.set(checkForUpdates, forKey: Key.checkForUpdates)
    }
}

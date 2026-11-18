import Combine
import Foundation

public enum DictationOverlayAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard = "Standard"
    case minimal = "Minimal"
    public var id: String { rawValue }
}

@MainActor
public final class ProsodyPreferences: ObservableObject {
    // Keep this suite stable across app updates. Pre-isolation builds use the
    // bundle's standard domain and are read only when the user requests it.
    static let suiteName = "\(Bundle.main.bundleIdentifier ?? AppConstants.bundleIdentifier).preferences.v1"

    @Published public var transcriptSegmentationConfiguration: TranscriptSegmentationConfiguration {
        didSet {
            defaults.set(transcriptSegmentationConfiguration.maximumWordsPerSegment,
                         forKey: TranscriptSegmentationConfiguration.maximumWordsDefaultsKey)
            defaults.set(transcriptSegmentationConfiguration.pauseThreshold,
                         forKey: TranscriptSegmentationConfiguration.pauseThresholdDefaultsKey)
        }
    }

@Published public var theme: ProsodyTheme {
        didSet { Key.theme.write(theme, to: defaults) }
    }
@Published public var dictationInsertionMethod: DictationInsertionMethod {
        didSet { Key.dictationInsertion.write(dictationInsertionMethod, to: defaults) }
    }
@Published public var dictationShortcut: DictationShortcut {
        didSet { Key.dictationShortcut.write(dictationShortcut, to: defaults) }
    }
@Published public var dictationActivation: DictationActivation {
        didSet { Key.dictationActivation.write(dictationActivation, to: defaults) }
    }
@Published public var dictationOverlayAppearance: DictationOverlayAppearance {
        didSet { Key.dictationOverlayAppearance.write(dictationOverlayAppearance, to: defaults) }
    }
@Published public var copyDictationToClipboard: Bool {
        didSet { Key.copyDictationToClipboard.write(copyDictationToClipboard, to: defaults) }
    }
@Published public var smartDictationCapitalization: Bool {
        didSet { Key.smartDictationCapitalization.write(smartDictationCapitalization, to: defaults) }
    }
@Published var cliEnabled: Bool {
        didSet { Key.cliEnabled.write(cliEnabled, to: defaults) }
    }
var cliInstalledTarget: String? {
        didSet { Key.cliInstalledTarget.write(cliInstalledTarget, to: defaults) }
    }
@Published public var transcriptExport: TranscriptExportOptions {
        didSet { Key.transcriptExport.write(transcriptExport, to: defaults) }
    }
@Published public var transcriptCopyDestinations: [RecordingDestination] {
        didSet { Key.transcriptCopyDestinations.write(transcriptCopyDestinations, to: defaults) }
    }
@Published public var omitFillerWords: Bool {
        didSet { Key.omitFillerWords.write(omitFillerWords, to: defaults) }
    }
@Published public var wordReplacements: [WordReplacement] {
        didSet { Key.wordReplacements.write(wordReplacements, to: defaults) }
    }
@Published public var captureMode: CaptureMode {
        didSet { Key.captureMode.write(captureMode, to: defaults) }
    }
@Published public var sttModelID: String {
        didSet { Key.sttModel.write(sttModelID, to: defaults) }
    }
@Published public var speakerMode: SpeakerMode {
        didSet { Key.speakerMode.write(speakerMode, to: defaults) }
    }
@Published public var notesProviderID: String {
        didSet { Key.notesProvider.write(notesProviderID, to: defaults) }
    }
@Published public var notesModelID: String {
        didSet { Key.notesModel.write(notesModelID, to: defaults) }
    }
@Published public var notesBaseURL: String {
        didSet { Key.notesBaseURL.write(notesBaseURL, to: defaults) }
    }
@Published public var noteTemplateID: NoteTemplateID {
        didSet { Key.template.write(noteTemplateID, to: defaults) }
    }
@Published public var outputFolderPath: String {
        didSet { Key.outputFolder.write(outputFolderPath, to: defaults) }
    }
@Published public var outputFolderBookmarkData: Data? {
        didSet { Key.outputBookmark.write(outputFolderBookmarkData, to: defaults) }
    }
@Published public var microphoneName: String {
        didSet { Key.microphone.write(microphoneName, to: defaults) }
    }
@Published public var recordingQuality: String {
        didSet { Key.quality.write(recordingQuality, to: defaults) }
    }
@Published public var liveTranscription: Bool {
        didSet { Key.liveTranscription.write(liveTranscription, to: defaults) }
    }
@Published public var keepAudio: Bool {
        didSet { Key.keepAudio.write(keepAudio, to: defaults) }
    }
@Published public var generateNotesAutomatically: Bool {
        didSet { Key.generateNotes.write(generateNotesAutomatically, to: defaults) }
    }
@Published public var launchAtLogin: Bool {
        didSet { Key.launchAtLogin.write(launchAtLogin, to: defaults) }
    }
@Published public var globalShortcut: String {
        didSet { Key.globalShortcut.write(globalShortcut, to: defaults) }
    }
@Published public var localOnlyMode: Bool {
        didSet { Key.localOnly.write(localOnlyMode, to: defaults) }
    }
@Published public var notifyWhenFinished: Bool {
        didSet { Key.notifyWhenFinished.write(notifyWhenFinished, to: defaults) }
    }
@Published public var automaticallyRevealNotes: Bool {
        didSet { Key.automaticallyReveal.write(automaticallyRevealNotes, to: defaults) }
    }
@Published public var checkForUpdates: Bool {
        didSet { Key.checkForUpdates.write(checkForUpdates, to: defaults) }
    }
@Published public var recordingLabels: [RecordingLabel] {
        didSet { Key.recordingLabels.write(recordingLabels, to: defaults) }
    }
@Published public var selectedRecordingLabelIDs: [UUID] {
        didSet { Key.selectedRecordingLabels.write(selectedRecordingLabelIDs, to: defaults) }
    }
@Published public var recordingDestinations: [RecordingDestination] {
        didSet { Key.recordingDestinations.write(recordingDestinations, to: defaults) }
    }
@Published public var hiddenMainScreenSections: Set<MainScreenSection> {
        didSet { Key.hiddenMainScreenSections.write(hiddenMainScreenSections, to: defaults) }
    }
    @Published public var sttEngineID = STTEngineID.parakeet
    @Published public var outputFormat = "markdown"
    @Published public var language = "English"

    private let defaults: UserDefaults

    public convenience init() {
        self.init(defaults: UserDefaults(suiteName: Self.suiteName)!)
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        transcriptSegmentationConfiguration = .persisted(in: defaults)
        theme = Key.theme.read(from: defaults)
        dictationInsertionMethod = Key.dictationInsertion.read(from: defaults)
        dictationShortcut = Key.dictationShortcut.read(from: defaults)
        dictationActivation = Key.dictationActivation.read(from: defaults)
        dictationOverlayAppearance = Key.dictationOverlayAppearance.read(from: defaults)
        copyDictationToClipboard = Key.copyDictationToClipboard.read(from: defaults)
        smartDictationCapitalization = Key.smartDictationCapitalization.read(from: defaults)
        cliEnabled = Key.cliEnabled.read(from: defaults)
        cliInstalledTarget = Key.cliInstalledTarget.read(from: defaults)
        transcriptExport = Key.transcriptExport.read(from: defaults)
        transcriptCopyDestinations = Key.transcriptCopyDestinations.read(from: defaults)
        omitFillerWords = Key.omitFillerWords.read(from: defaults)
        wordReplacements = Key.wordReplacements.read(from: defaults)
        captureMode = Key.captureMode.read(from: defaults)
        sttModelID = Key.sttModel.read(from: defaults)
        speakerMode = Key.speakerMode.read(from: defaults)
        notesProviderID = Key.notesProvider.read(from: defaults)
        notesModelID = Key.notesModel.read(from: defaults)
        notesBaseURL = Key.notesBaseURL.read(from: defaults)
        noteTemplateID = Key.template.read(from: defaults)
        outputFolderPath = Key.outputFolder.read(from: defaults)
        outputFolderBookmarkData = Key.outputBookmark.read(from: defaults)
        microphoneName = Key.microphone.read(from: defaults)
        recordingQuality = Key.quality.read(from: defaults)
        liveTranscription = Key.liveTranscription.read(from: defaults)
        keepAudio = Key.keepAudio.read(from: defaults)
        generateNotesAutomatically = Key.generateNotes.read(from: defaults)
        launchAtLogin = Key.launchAtLogin.read(from: defaults)
        globalShortcut = Key.globalShortcut.read(from: defaults)
        localOnlyMode = Key.localOnly.read(from: defaults)
        notifyWhenFinished = Key.notifyWhenFinished.read(from: defaults)
        automaticallyRevealNotes = Key.automaticallyReveal.read(from: defaults)
        checkForUpdates = Key.checkForUpdates.read(from: defaults)
        recordingLabels = Key.recordingLabels.read(from: defaults)
        selectedRecordingLabelIDs = Key.selectedRecordingLabels.read(from: defaults)
        recordingDestinations = Key.recordingDestinations.read(from: defaults)
        hiddenMainScreenSections = Key.hiddenMainScreenSections.read(from: defaults)
    }

    public func showsOnMainScreen(_ section: MainScreenSection) -> Bool {
        !hiddenMainScreenSections.contains(section)
    }

    public func setMainScreenSection(_ section: MainScreenSection, visible: Bool) {
        if visible { hiddenMainScreenSections.remove(section) }
        else { hiddenMainScreenSections.insert(section) }
    }

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

    /// Applies only recognized values from an explicitly selected archive.
    /// System-managed state such as a login item and CLI symlink is local.
    func importSettings(_ archive: PreferenceArchive) throws -> Int {
        let values = archive.values
        let rules = Self.importRules.filter { $0.accepts(values) }
        let segmentation = transcriptSegmentationConfiguration
        let maximum = values[TranscriptSegmentationConfiguration.maximumWordsDefaultsKey] as? Int
        let pause = values[TranscriptSegmentationConfiguration.pauseThresholdDefaultsKey] as? Double
        let archivedDestinations = Key.recordingDestinations.value(in: values)
        let archivedCopyDestinations = Key.transcriptCopyDestinations.value(in: values)
        let additionalValues = [maximum != nil, pause != nil, archivedDestinations != nil, archivedCopyDestinations != nil]
        let count = rules.count + additionalValues.filter { $0 }.count
        guard count > 0 else { throw PreferenceArchiveError.noSettings }

        let oldOutput = outputFolderPath
        let oldBookmark = outputFolderBookmarkData
        for rule in rules { rule.apply(self, values) }
        if let archivedDestinations {
            recordingDestinations = Self.mergingDestinations(recordingDestinations, with: archivedDestinations)
        }
        if let archivedCopyDestinations {
            transcriptCopyDestinations = Self.mergingDestinations(transcriptCopyDestinations, with: archivedCopyDestinations)
        }
        if let path = Key.outputFolder.value(in: values) {
            outputFolderBookmarkData = Key.outputBookmark.value(in: values) ?? (path == oldOutput ? oldBookmark : nil)
            if path != oldOutput {
                // Keep previously used folders browsable after importing a new default.
                rememberDestination(path: (oldOutput as NSString).expandingTildeInPath, bookmarkData: oldBookmark)
            }
        }
        if maximum != nil || pause != nil {
            transcriptSegmentationConfiguration = .init(
                maximumWordsPerSegment: maximum ?? segmentation.maximumWordsPerSegment,
                pauseThreshold: pause ?? segmentation.pauseThreshold
            )
        }
        let availableLabels = Set(recordingLabels.map(\.id))
        let selected = selectedRecordingLabelIDs.filter { availableLabels.contains($0) }
        if selected != selectedRecordingLabelIDs { selectedRecordingLabelIDs = selected }
        return count
    }

    func flushBeforeUpdate() {
        defaults.synchronize()
    }

    private static func mergingDestinations(_ current: [RecordingDestination],
                                            with archived: [RecordingDestination]) -> [RecordingDestination] {
        var result = current
        for destination in archived {
            if let index = result.firstIndex(where: { $0.path == destination.path }) {
                if let bookmark = destination.bookmarkData { result[index].bookmarkData = bookmark }
            } else {
                result.append(destination)
            }
        }
        return result
    }

    private static let importRules: [ImportRule] = [
        Key.theme.importRule(\.theme),
        Key.dictationInsertion.importRule(\.dictationInsertionMethod),
        Key.dictationShortcut.importRule(\.dictationShortcut),
        Key.dictationActivation.importRule(\.dictationActivation),
        Key.dictationOverlayAppearance.importRule(\.dictationOverlayAppearance),
        Key.copyDictationToClipboard.importRule(\.copyDictationToClipboard),
        Key.smartDictationCapitalization.importRule(\.smartDictationCapitalization),
        Key.transcriptExport.importRule(\.transcriptExport),
        Key.omitFillerWords.importRule(\.omitFillerWords),
        Key.wordReplacements.importRule(\.wordReplacements),
        Key.captureMode.importRule(\.captureMode),
        Key.sttModel.importRule(\.sttModelID),
        Key.speakerMode.importRule(\.speakerMode),
        Key.notesProvider.importRule(\.notesProviderID),
        Key.notesModel.importRule(\.notesModelID),
        Key.notesBaseURL.importRule(\.notesBaseURL),
        Key.template.importRule(\.noteTemplateID),
        Key.outputFolder.importRule(\.outputFolderPath),
        Key.microphone.importRule(\.microphoneName),
        Key.quality.importRule(\.recordingQuality),
        Key.liveTranscription.importRule(\.liveTranscription),
        Key.keepAudio.importRule(\.keepAudio),
        Key.generateNotes.importRule(\.generateNotesAutomatically),
        Key.globalShortcut.importRule(\.globalShortcut),
        Key.localOnly.importRule(\.localOnlyMode),
        Key.notifyWhenFinished.importRule(\.notifyWhenFinished),
        Key.automaticallyReveal.importRule(\.automaticallyRevealNotes),
        Key.checkForUpdates.importRule(\.checkForUpdates),
        Key.recordingLabels.importRule(\.recordingLabels),
        Key.selectedRecordingLabels.importRule(\.selectedRecordingLabelIDs),
        Key.hiddenMainScreenSections.importRule(\.hiddenMainScreenSections),
    ]

    @MainActor private enum Key {
        static let theme: Preference<ProsodyTheme> = .identified("theme", .graphite)
        static let dictationInsertion: Preference<DictationInsertionMethod> = .identified("dictationInsertion", .paste)
        static let dictationShortcut: Preference<DictationShortcut> = .identified("dictationShortcut", .rightCommand)
        static let dictationActivation: Preference<DictationActivation> = .identified("dictationActivation", .hold)
        static let dictationOverlayAppearance: Preference<DictationOverlayAppearance> = .identified("dictationOverlayAppearance", .standard)
        static let copyDictationToClipboard: Preference<Bool> = .value("copyDictationToClipboard", false)
        static let smartDictationCapitalization: Preference<Bool> = .value("smartDictationCapitalization", true)
        static let cliEnabled: Preference<Bool> = .value("cliEnabled", false)
        static let cliInstalledTarget: Preference<String?> = Preference.optional("cliInstalledTarget")
        static let transcriptExport: Preference<TranscriptExportOptions> = .json("transcriptExport", .init())
        static let transcriptCopyDestinations: Preference<[RecordingDestination]> = .json("transcriptCopyDestinations", [])
        static let omitFillerWords: Preference<Bool> = .value("omitFillerWords", false)
        static let wordReplacements: Preference<[WordReplacement]> = .json("wordReplacements", [])
        static let captureMode: Preference<CaptureMode> = .identified("captureMode", .both)
        static let sttModel: Preference<String> = .init("sttModel", fallback: SpeechModel.unified.rawValue, decode: { raw in
            (raw as? String).flatMap(SpeechModel.init(rawValue:))?.rawValue
        }, encode: { $0 })
        static let speakerMode: Preference<SpeakerMode> = .identified("speakerMode", .basic)
        static let notesProvider: Preference<String> = .value("notesProvider", "template-local")
        static let notesModel: Preference<String> = .value("notesModel", "qwen3-4b")
        static let notesBaseURL: Preference<String> = .value("notesBaseURL", "http://127.0.0.1:1234/v1")
        static let template: Preference<NoteTemplateID> = .identified("template", .lectureNotes)
        static let outputFolder: Preference<String> = .init("outputFolder", fallback: ProsodyStorage.defaultOutputFolderPath(), decode: { raw in
            guard let path = raw as? String, path.hasPrefix("/") || path.hasPrefix("~/") else { return nil }
            return path
        }, encode: { $0 })
        static let outputBookmark: Preference<Data?> = Preference.optional("outputBookmark")
        static let microphone: Preference<String> = .value("microphone", "System Default")
        static let quality: Preference<String> = .value("quality", "efficient")
        static let liveTranscription: Preference<Bool> = .value("liveTranscription", true)
        static let keepAudio: Preference<Bool> = .value("keepAudio", false)
        static let generateNotes: Preference<Bool> = .value("generateNotes", true)
        static let launchAtLogin: Preference<Bool> = .value("launchAtLogin", false)
        static let globalShortcut: Preference<String> = .init("globalShortcut", fallback: "⌥⌘R", decode: { raw in
            guard let value = raw as? String, GlobalHotkeyManager.supports(value) else { return nil }
            return value
        }, encode: { $0 })
        static let localOnly: Preference<Bool> = .value("localOnly", true)
        static let notifyWhenFinished: Preference<Bool> = .value("notifyWhenFinished", true)
        static let automaticallyReveal: Preference<Bool> = .value("automaticallyReveal", false)
        static let checkForUpdates: Preference<Bool> = .value("checkForUpdates", false)
        static let recordingLabels: Preference<[RecordingLabel]> = .json("recordingLabels", [])
        static let selectedRecordingLabels: Preference<[UUID]> = .init("selectedRecordingLabels", fallback: [], decode: { ($0 as? [String])?.compactMap(UUID.init(uuidString:)) }, encode: { $0.map(\.uuidString) })
        static let recordingDestinations: Preference<[RecordingDestination]> = .json("recordingDestinations", [])
        static let hiddenMainScreenSections: Preference<Set<MainScreenSection>> = .init("hiddenMainScreenSections", fallback: [], decode: {
            ($0 as? [String]).map { Set($0.compactMap(MainScreenSection.init(rawValue:))) }
        }, encode: { $0.map(\.rawValue).sorted() })
    }

    private struct ImportRule {
        let accepts: ([String: Any]) -> Bool
        let apply: (ProsodyPreferences, [String: Any]) -> Void
    }

    /// A single property codec for loading, saving and importing that setting.
    private struct Preference<Value> {
        let name: String
        let fallback: () -> Value
        let decode: (Any) -> Value?
        let encode: (Value) -> Any?

        init(_ key: String, fallback: @autoclosure @escaping () -> Value,
             decode: @escaping (Any) -> Value?, encode: @escaping (Value) -> Any?) {
            name = "preferences." + key
            self.fallback = fallback
            self.decode = decode
            self.encode = encode
        }

        static func value(_ key: String, _ fallback: Value) -> Self {
            .init(key, fallback: fallback, decode: { $0 as? Value }, encode: { $0 })
        }

        static func optional<Wrapped>(_ key: String) -> Self where Value == Wrapped? {
            .init(key, fallback: nil, decode: { ($0 as? Wrapped).map(Optional.some) }, encode: { $0.map { $0 as Any } })
        }

        static func identified(_ key: String, _ fallback: Value) -> Self where Value: RawRepresentable, Value.RawValue == String {
            .init(key, fallback: fallback, decode: { ($0 as? String).flatMap(Value.init(rawValue:)) }, encode: { $0.rawValue })
        }

        static func json(_ key: String, _ fallback: Value) -> Self where Value: Codable {
            .init(key, fallback: fallback,
                  decode: { raw in (raw as? Data).flatMap { try? JSONDecoder().decode(Value.self, from: $0) } },
                  encode: { try? JSONEncoder().encode($0) })
        }

        func value(in values: [String: Any]) -> Value? { values[name].flatMap(decode) }

        func read(from defaults: UserDefaults) -> Value {
            defaults.object(forKey: name).flatMap(decode) ?? fallback()
        }

        func write(_ value: Value, to defaults: UserDefaults) {
            defaults.set(encode(value), forKey: name)
        }

        func importRule(_ path: ReferenceWritableKeyPath<ProsodyPreferences, Value>) -> ImportRule {
            ImportRule(accepts: { value(in: $0) != nil }, apply: { preferences, values in
                if let value = value(in: values) { preferences[keyPath: path] = value }
            })
        }
    }
}

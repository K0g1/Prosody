@_spi(Validation) import ProsodyCore
import Foundation

extension ProsodyValidation {
    @MainActor
    static func checkSettingsPresentation() {
        let suite = "Prosody-Settings-Validation-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ProsodyPreferences(defaults: defaults)
        precondition(preferences.transcriptSegmentationConfiguration == .init())
        precondition(preferences.transcriptSegmentationConfiguration.maximumWordsPerSegment == 40)
        precondition(preferences.transcriptSegmentationConfiguration.pauseThreshold == 1.5)
        precondition(MainScreenSection.allCases.allSatisfy(preferences.showsOnMainScreen))

        preferences.captureMode = .system
        preferences.outputFolderPath = "/tmp/Prosody-unchanged-destination"
        preferences.noteTemplateID = .summary
        for section in MainScreenSection.allCases {
            preferences.setMainScreenSection(section, visible: false)
        }
        preferences.transcriptSegmentationConfiguration = .init(maximumWordsPerSegment: 10, pauseThreshold: 2.5)
        var activeAssembler = StreamingTranscriptAssembler(source: .microphone, configuration: preferences.transcriptSegmentationConfiguration)
        preferences.transcriptSegmentationConfiguration = .init(maximumWordsPerSegment: 100, pauseThreshold: 5)
        let restored = ProsodyPreferences(defaults: defaults)
        precondition(restored.hiddenMainScreenSections == Set(MainScreenSection.allCases))
        precondition(restored.captureMode == .system && restored.outputFolderPath == preferences.outputFolderPath)
        precondition(restored.noteTemplateID == .summary)
        precondition(restored.transcriptSegmentationConfiguration == preferences.transcriptSegmentationConfiguration)
        precondition(.persisted(in: defaults) == restored.transcriptSegmentationConfiguration)

        for index in 0..<10 {
            precondition(activeAssembler.append(token: " word", start: Double(index), end: Double(index) + 0.1).isEmpty)
        }
        precondition(activeAssembler.append(token: " next", start: 10, end: 10.1).first?.words.count == 10,
                     "Changing settings mutated an active assembler's configuration")
        var nextAssembler = StreamingTranscriptAssembler(source: .microphone, configuration: restored.transcriptSegmentationConfiguration)
        for index in 0..<100 {
            precondition(nextAssembler.append(token: " word", start: Double(index), end: Double(index) + 0.1).isEmpty,
                         "The next transcription ignored its word limit or split on elapsed time")
        }
        precondition(nextAssembler.append(token: " next", start: 100, end: 100.1).first?.words.count == 100)

        var pauseAssembler = StreamingTranscriptAssembler(source: .system, configuration: .init(maximumWordsPerSegment: 100, pauseThreshold: 2.5))
        _ = pauseAssembler.append(token: " first", start: 0, end: 1)
        precondition(pauseAssembler.append(token: " second", start: 3.49, end: 4).isEmpty)
        precondition(pauseAssembler.append(token: " third", start: 6.5, end: 7).first?.text == "first second")

        restored.hiddenMainScreenSections = []
        precondition(ProsodyPreferences(defaults: defaults).hiddenMainScreenSections.isEmpty)
        defaults.set(500, forKey: TranscriptSegmentationConfiguration.maximumWordsDefaultsKey)
        defaults.set(-1, forKey: TranscriptSegmentationConfiguration.pauseThresholdDefaultsKey)
        precondition(ProsodyPreferences(defaults: defaults).transcriptSegmentationConfiguration == .init(maximumWordsPerSegment: 100, pauseThreshold: 0.5))
        precondition(TranscriptSegmentationConfiguration(pauseThreshold: .nan).pauseThreshold == 1.5)
        precondition(TranscriptSegmentationConfiguration(pauseThreshold: .infinity).pauseThreshold == 1.5)

        let amplitudes = [0.0, 0.001, 0.003, 0.01, 0.03, 0.1, 1].map { AudioMeterCalculator.displayAmplitude(rms: $0) }
        precondition(amplitudes == amplitudes.sorted())
        precondition(amplitudes.allSatisfy { $0.isFinite && (0...1).contains($0) })
        precondition(AudioMeterCalculator.displayAmplitude(rms: 0.03) > 0.55)
        for invalid in [Double.nan, .infinity, -.infinity, -1, 0] {
            precondition(AudioMeterCalculator.displayAmplitude(rms: invalid) == 0)
        }
        precondition(AudioMeterCalculator.level(for: Array(repeating: 0.01, count: 256)).rms < 0.025,
                     "Visual sensitivity must not change measured audio")
        checkDefaultOutputFolder()
        print("Settings/presentation: PASS (editable preference persistence, default destination, layout visibility, session snapshots, segmentation bounds, perceptual meter)")
    }

    @MainActor
    private static func checkDefaultOutputFolder() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("Prosody-Migration-Validation-\(UUID())")
        defer { try? fileManager.removeItem(at: root) }

        let home = root.appendingPathComponent("home", isDirectory: true)
        let legacyOutput = home.appendingPathComponent(AppConstants.legacyDefaultOutputFolderName, isDirectory: true)
        try! fileManager.createDirectory(at: legacyOutput, withIntermediateDirectories: true)
        precondition(ProsodyStorage.defaultOutputFolderPath(homeDirectory: home) == "~/Clippy")
        try! fileManager.removeItem(at: legacyOutput)
        precondition(fileManager.createFile(atPath: legacyOutput.path, contents: Data()))
        precondition(ProsodyStorage.defaultOutputFolderPath(homeDirectory: home) == "~/Prosody")
        try! fileManager.removeItem(at: legacyOutput)
        precondition(ProsodyStorage.defaultOutputFolderPath(homeDirectory: home) == "~/Prosody")
    }
}

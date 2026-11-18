import SwiftUI

struct TranscriptionSettingsView: GroupedSettingsSearchPage {
    @Environment(\.prosodyPalette) private var palette
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: ProsodyPreferences

    private static let streaming = SettingsControlGroup<Self>(controls: [
        .init("clippy.settings.transcription.live", "Live transcription",
              help: "Turn off to transcribe after recording and reduce CPU/GPU use during capture. Applies to the next recording.",
              keywords: ["streaming", "real time", "CPU GPU"]) { pane, entry in
            Toggle(entry.title, isOn: Binding(
                get: { pane.model.selectedSpeechModel.descriptor.supportsStreaming && pane.preferences.liveTranscription },
                set: { pane.preferences.liveTranscription = $0 }
            ))
            .labelsHidden().toggleStyle(.prosodySwitch)
            .disabled(!pane.model.selectedSpeechModel.descriptor.supportsStreaming)
        },
        .init("clippy.settings.transcription.model", "Speech model",
              help: "Recordings, imports, and dictation share this local model.",
              keywords: ["Parakeet Unified", "English", "language", "engine", "streaming model"]) { pane, _ in
            let descriptor = pane.model.selectedSpeechModel.descriptor
            Text(descriptor.displayName).foregroundStyle(pane.palette.secondary)
        }
    ])

    private static let cleanup = SettingsControlGroup<Self>("Text cleanup", controls: [
        .init("clippy.settings.transcription.filler-words", "Omit filler words",
              help: "Remove written hesitations such as um, uh, and hmm from new transcripts and dictation.",
              keywords: ["hesitation", "remove ums", "clean speech", "dictation", "capitalization"]) { pane, entry in
            Toggle(entry.title, isOn: pane.$preferences.omitFillerWords)
                .labelsHidden().toggleStyle(.prosodySwitch)
        }
    ])

    private static let layout = SettingsControlGroup<Self>("Transcript layout", controls: [
        .init("clippy.settings.transcription.maximum-words", "Maximum words per block",
              help: "Sentence endings can start a block sooner.",
              keywords: ["segmentation", "paragraph", "block size", "split", "word limit"]) { pane, entry in
            let range = TranscriptSegmentationConfiguration.maximumWordsRange
            SettingsNumberControl(
                title: entry.title, value: pane.maximumWords, range: Double(range.lowerBound)...Double(range.upperBound),
                step: 5, fractionDigits: 0, unit: "words", accessibilityID: entry.id,
                help: entry.help
            )
        },
        .init("clippy.settings.transcription.pause-threshold", "Pause before new block",
              help: "Start a new block when a pause between words lasts this long.",
              keywords: ["segmentation", "silence", "pause threshold", "split"]) { pane, entry in
            SettingsNumberControl(
                title: entry.title, value: pane.pauseThreshold,
                range: TranscriptSegmentationConfiguration.pauseThresholdRange,
                step: 0.25, fractionDigits: 2, unit: "s", accessibilityID: entry.id,
                help: entry.help
            )
        }
    ])

    static let groups = [streaming, cleanup, layout]

    init(model: AppModel) {
        self.model = model
        self.preferences = model.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPageHeader(title: "Transcription")
            Self.streaming.render(in: self, context: model.selectedSpeechModel.descriptor.supportsStreaming ? nil : "The selected model transcribes recordings after you finish.")
                .disabled(!model.canBrowseSessions)
            Self.cleanup.render(in: self)
            Self.layout.render(in: self, context: "Layout changes apply to the next transcription.")
        }
    }

    private var maximumWords: Binding<Double> {
        Binding(get: { Double(preferences.transcriptSegmentationConfiguration.maximumWordsPerSegment) }, set: {
            preferences.transcriptSegmentationConfiguration = .init(
                maximumWordsPerSegment: Int($0), pauseThreshold: preferences.transcriptSegmentationConfiguration.pauseThreshold
            )
        })
    }

    private var pauseThreshold: Binding<Double> {
        Binding(get: { preferences.transcriptSegmentationConfiguration.pauseThreshold }, set: {
            preferences.transcriptSegmentationConfiguration = .init(
                maximumWordsPerSegment: preferences.transcriptSegmentationConfiguration.maximumWordsPerSegment, pauseThreshold: $0
            )
        })
    }
}

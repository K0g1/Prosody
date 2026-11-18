import SwiftUI

struct TranscriptExportSettingsView: GroupedSettingsSearchPage {
    @ObservedObject var preferences: ProsodyPreferences

    private static func flag(_ id: String, _ title: String, _ key: WritableKeyPath<TranscriptExportOptions, Bool>) -> SettingsControl<Self> {
        SettingsControl("clippy.settings.export.\(id)", title, keywords: ["Markdown", "include", "transcript export"]) { pane, entry in
            Toggle(entry.title, isOn: Binding(
                get: { pane.preferences.transcriptExport[keyPath: key] },
                set: { pane.preferences.transcriptExport[keyPath: key] = $0 }
            ))
            .labelsHidden().toggleStyle(.prosodySwitch)
        }
    }

    static let groups: [SettingsControlGroup<Self>] = [
        .init("Document", controls: [
            flag("title", "Title", \.title), flag("date", "Recording date", \.date), flag("time", "Recording time", \.time),
            flag("duration", "Duration", \.duration), flag("source-name", "Original audio filename", \.originalAudioFileName),
            flag("labels", "Labels", \.labels)
        ]),
        .init("Speech", controls: [
            flag("timestamps", "Timestamps", \.timestamps), flag("speakers", "Speaker names", \.speakerNames)
        ])
    ]

    init(model: AppModel) { preferences = model.preferences }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader(title: "Transcript Export")
            Text("Choose what to include when you export or copy formatted Markdown.")
                .font(.callout).foregroundStyle(.secondary)
            renderGroups()
        }
    }
}

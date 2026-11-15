import SwiftUI

/// The label editor is also used by the recorder. Index the real management
/// pane without indexing private user labels or opening the editor on search.
struct LabelsSettingsSearchPage: SettingsSearchPage {
    @ObservedObject var model: AppModel

    private static let management = SettingsControl<Self>.custom(
        "clippy.settings.labels.management", "Recording labels",
        keywords: ["new label", "create label", "edit", "delete", "naming pattern", "filename", "date format"]
    ) { pane, _ in
        RecordingLabelsSettingsView(model: pane.model)
    }

    static var controlsForSearch: [SettingsSearchEntry] {
        [management.entry] + RecordingLabelsStudioView.searchEntries
    }

    init(model: AppModel) { self.model = model }

    var body: some View {
        Self.management.render(in: self, scrollAnchor: .top)
    }
}

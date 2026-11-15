import SwiftUI

struct MainScreenSettingsView: SettingsSearchPage {
    @ObservedObject var preferences: ProsodyPreferences

    private static let visibility = SettingsControlGroup<Self>(controls: MainScreenSection.allCases.map { section in
        SettingsControl("clippy.settings.main-screen.\(section.id)", section.title, help: section.detail,
                        keywords: ["show hide \(section.title)", "menu bar", "popup"]) { pane, entry in
            Toggle(entry.title, isOn: Binding(
                get: { pane.preferences.showsOnMainScreen(section) },
                set: { pane.preferences.setMainScreenSection(section, visible: $0) }
            ))
            .labelsHidden().toggleStyle(.switch)
            .accessibilityIdentifier(entry.id)
        }
    })

    private static let reset = SettingsControl<Self>.custom(
        "clippy.settings.main-screen.reset", "Show All Controls", keywords: ["reset", "unhide"]
    ) { pane, entry in
        Button(entry.title) { pane.preferences.hiddenMainScreenSections = [] }
            .disabled(pane.preferences.hiddenMainScreenSections.isEmpty)
            .accessibilityIdentifier(entry.id)
    }

    static var controlsForSearch: [SettingsSearchEntry] {
        visibility.searchEntries + [reset.entry]
    }

    init(model: AppModel) { preferences = model.preferences }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPageHeader(title: SettingsSection.mainScreen.title)
                .settingsHelp("Hidden tray elements keep their saved choices. Recording actions, status, and recovery notices stay visible in the popup.")
            Self.visibility.render(in: self)
            Self.reset.render(in: self)
        }
    }
}

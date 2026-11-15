#if canImport(Testing)
import Testing
@testable import ProsodyCore

@Suite("Tray settings")
struct TraySettingsTests {
    @Test @MainActor
    func trayElementsKeepsStableIdentifiersAndSearchAliases() {
        #expect(SettingsSection.mainScreen.title == "Tray Elements")
        #expect(SettingsSection.mainScreen.rawValue == "mainScreen")
        #expect(MainScreenSection.allCases.map(\.rawValue) == [
            "branding", "recordingTitle", "labels", "source",
            "noteTemplate", "saveLocation", "recents"
        ])
        #expect(MainScreenSection.allCases.allSatisfy { $0.detail.contains("tray popup") })
        #expect(MainScreenSettingsView.controlsForSearch.allSatisfy {
            $0.id.hasPrefix("clippy.settings.main-screen.")
        })

        let index = SettingsSearchIndex(sections: SettingsSection.allCases.map { section in
            (section: section, entries: section.page.controlsForSearch)
        })
        let mainScreenResults = index.results(for: "main screen")
        #expect(!mainScreenResults.isEmpty)
        #expect(mainScreenResults.allSatisfy { $0.section == .mainScreen })
        #expect(index.results(for: "popup").contains { $0.section == .mainScreen })
        #expect(index.results(for: "tray elements").contains { $0.section == .mainScreen })
        #expect(index.results(for: "menu bar").contains { $0.section == .mainScreen })
    }
}
#endif

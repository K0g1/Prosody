#if canImport(Testing)
import Testing
@testable import ProsodyCore

@Suite("Recording label settings")
struct RecordingLabelSettingsTests {
    @Test @MainActor
    func exposesNameColorAndFolderSearchTargets() {
        let entries = LabelsSettingsSearchPage.controlsForSearch
        let ids = Set(entries.map(\.id))

        #expect(ids.isSuperset(of: [
            "clippy.settings.labels.name",
            "clippy.settings.labels.color",
            "clippy.settings.labels.folder"
        ]))

        let index = SettingsSearchIndex(sections: [(.labels, entries)])
        #expect(index.results(for: "label name").contains { $0.id.control == "clippy.settings.labels.name" })
        #expect(index.results(for: "label color").contains { $0.id.control == "clippy.settings.labels.color" })
        #expect(index.results(for: "save folder").contains { $0.id.control == "clippy.settings.labels.folder" })
    }
}
#endif

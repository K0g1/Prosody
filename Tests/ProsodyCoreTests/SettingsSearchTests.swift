#if canImport(Testing)
import Testing
@testable import ProsodyCore

@Suite("Settings search")
struct SettingsSearchTests {
    private static let sections: [(section: SettingsSection, entries: [SettingsSearchEntry])] = [
        (.general, [
            .init(id: "output-folder", title: "Output folder",
                  help: "Choose where recordings are saved.",
                  keywords: ["destination", "save location"]),
            .init(id: "save-api-key", title: "Save API Key",
                  keywords: ["credentials", "token"]),
            .init(id: "token-exact", title: "Token", keywords: ["credential"])
        ]),
        (.notes, [
            .init(id: "api-key", title: "API key",
                  help: "Stored in the macOS Keychain.",
                  keywords: ["credentials", "password", "token"]),
            .init(id: "offline-outline", title: "Offline Outline",
                  keywords: ["template", "local notes"]),
            .init(id: "cafe-api", title: "Café API", keywords: ["unicode"])
        ]),
        (.transcription, [
            .init(id: "maximum-words", title: "Maximum words per block",
                  keywords: ["segmentation", "word limit"])
        ]),
        (.dictation, [
            .init(id: "text-insertion", title: "Text insertion",
                  keywords: ["keyboard typing", "paste"])
        ]),
        (.appearance, [
            .init(id: "frosted-glass", title: "Frosted Glass",
                  keywords: ["adaptive system automatic", "theme"])
        ]),
        (.audio, [
            .init(id: "audio-section-match", title: "Volume", help: "speaker"),
            .init(id: "audio-help-match", title: "Other", help: "audio")
        ])
    ]

    private let index = SettingsSearchIndex(sections: Self.sections)

    @Test("empty and whitespace-only queries return no results")
    func emptyQueries() {
        #expect(index.results(for: "").isEmpty)
        #expect(index.results(for: " \n\t ").isEmpty)
    }

    @Test("punctuation, case, width, and diacritics fold consistently")
    func foldingAndTokenization() {
        #expect(firstID(for: "API") == id(.notes, "api-key"))
        #expect(firstID(for: "API-KEY") == id(.notes, "api-key"))
        #expect(firstID(for: "api key") == id(.notes, "api-key"))
        #expect(firstID(for: "ＡＰＩ") == id(.notes, "api-key"))
        #expect(firstID(for: "cafe api") == id(.notes, "cafe-api"))
        #expect(firstID(for: "café/api") == id(.notes, "cafe-api"))
    }

    @Test("all query terms must match")
    func allTermsMustMatch() {
        #expect(index.results(for: "api folder").isEmpty)
        #expect(firstID(for: "api key") == id(.notes, "api-key"))
    }

    @Test("title, alias, section, and help ranking is deterministic")
    func fieldRanking() {
        #expect(firstID(for: "token") == id(.general, "token-exact"))
        #expect(firstID(for: "max") == id(.transcription, "maximum-words"))
        #expect(firstID(for: "keyboard typing") == id(.dictation, "text-insertion"))
        #expect(firstID(for: "audio") == id(.audio, "audio-section-match"))
    }

    @Test("equal scores preserve declaration order")
    func declarationOrderTieBreak() {
        let results = index.results(for: "credentials")
        #expect(results.prefix(2).map(\.id) == [
            id(.general, "save-api-key"),
            id(.notes, "api-key")
        ])
    }

    @Test("result IDs retain their owning section and control")
    func stableResultIDs() throws {
        let result = try #require(index.results(for: "output folder").first)
        #expect(result.id.section == .general)
        #expect(result.id.control == "output-folder")
        #expect(result.title == "Output folder")
    }

    @Test @MainActor
    func realPagesExposeEveryControlWithoutDuplicateTargets() {
        let realSections = SettingsSection.allCases.map { section in
            (section: section, entries: section.page.controlsForSearch)
        }
        let entries = realSections.flatMap { item in
            item.entries.map { (section: item.section, entry: $0) }
        }
        let targets = entries.map {
            SettingsSearchResult.ID(section: $0.section, control: $0.entry.id)
        }

        #expect(!entries.isEmpty)
        #expect(Set(entries.map(\.entry.id)).count == entries.count)
        #expect(Set(targets).count == targets.count)

        let realIndex = SettingsSearchIndex(sections: realSections)
        for item in entries {
            let results = realIndex.results(for: item.entry.title)
            #expect(results.contains { $0.id.control == item.entry.id })
        }
    }

    @Test @MainActor
    func realPageProbesResolveToTheirActualControls() {
        let realIndex = SettingsSearchIndex(sections: SettingsSection.allCases.map { section in
            (section: section, entries: section.page.controlsForSearch)
        })

        #expect(realIndex.results(for: "API-KEY").first?.id == id(.notes, "clippy.settings.notes.api-key"))
        #expect(realIndex.results(for: "max words").first?.id == id(.transcription, "clippy.settings.transcription.maximum-words"))
        #expect(realIndex.results(for: "keyboard typing").first?.id == id(.dictation, "clippy.settings.dictation.insertion"))
        #expect(realIndex.results(for: "Frosted Glass").first?.id == id(.appearance, "clippy.theme.glass"))
        #expect(realIndex.results(for: "True Black OLED").first?.id == id(.appearance, "clippy.theme.oled-true-black"))
        #expect(realIndex.results(for: "Moss Agate").first?.id == id(.appearance, "clippy.theme.moss-agate"))
        #expect(realIndex.results(for: "output folder").first?.id == id(.output, "clippy.settings.output.folder"))
        #expect(realIndex.results(for: "Offline Outline").first?.id == id(.notes, "clippy.settings.notes.provider"))
    }

    private func firstID(for query: String) -> SettingsSearchResult.ID? {
        index.results(for: query).first?.id
    }

    private func id(_ section: SettingsSection, _ control: String) -> SettingsSearchResult.ID {
        .init(section: section, control: control)
    }
}
#endif

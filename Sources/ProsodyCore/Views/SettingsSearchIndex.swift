import Foundation

struct SettingsSearchEntry: Identifiable, Sendable {
    let id: String
    let title: String
    var help: String? = nil
    var keywords: [String] = []
}

struct SettingsSearchResult: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let section: SettingsSection
        let control: String
    }

    let id: ID
    let title: String

    var section: SettingsSection { id.section }
}

/// Only the query is tokenized when the user types. Document tokens are built
/// once from the same declarations that render the controls.
struct SettingsSearchIndex {
    private struct Document {
        let result: SettingsSearchResult
        let title: [String]
        let keywords: [String]
        let section: [String]
        let help: [String]

        func score(for query: [String]) -> Int? {
            let startsTitle = query.count <= title.count && zip(title, query).allSatisfy { $0.hasPrefix($1) }
            var score = title == query ? 100 : (startsTitle ? 3 : 0)
            for term in query {
                if title.contains(term) { score += 12 }
                else if title.contains(where: { $0.hasPrefix(term) }) { score += 10 }
                else if keywords.contains(term) { score += 8 }
                else if keywords.contains(where: { $0.hasPrefix(term) }) { score += 6 }
                else if section.contains(term) { score += 4 }
                else if section.contains(where: { $0.hasPrefix(term) }) { score += 3 }
                else if help.contains(term) { score += 2 }
                else if help.contains(where: { $0.hasPrefix(term) }) { score += 1 }
                else { return nil }
            }
            return score
        }
    }

    private let documents: [Document]

    init(sections: [(section: SettingsSection, entries: [SettingsSearchEntry])]) {
        documents = sections.flatMap { section, entries in
            let sectionTerms = Self.sectionTerms(for: section)
            return entries.map { entry in
                Document(
                    result: .init(id: .init(section: section, control: entry.id), title: entry.title),
                    title: Self.terms(in: entry.title),
                    keywords: Self.terms(in: entry.keywords.joined(separator: " ")),
                    section: sectionTerms,
                    help: Self.terms(in: entry.help ?? "")
                )
            }
        }
        assert(Set(documents.map(\.result.id)).count == documents.count, "Duplicate Settings search target")
    }

    func results(for text: String) -> [SettingsSearchResult] {
        let query = Self.terms(in: text)
        guard !query.isEmpty else { return [] }
        var matches: [(score: Int, order: Int, result: SettingsSearchResult)] = []
        for (order, document) in documents.enumerated() {
            if let score = document.score(for: query) {
                matches.append((score, order, document.result))
            }
        }
        matches.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.order < rhs.order : lhs.score > rhs.score
        }
        return matches.map(\.result)
    }

    private static func terms(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func sectionTerms(for section: SettingsSection) -> [String] {
        switch section {
        case .mainScreen:
            // Keep the pre-rename vocabulary discoverable from every tray entry.
            return terms(in: "Tray Elements main screen popup menu bar tray")
        default:
            return terms(in: section.title)
        }
    }
}

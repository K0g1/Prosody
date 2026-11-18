import Accessibility
import AppKit
import SwiftUI

struct SettingsSidebarView: View {
    @Environment(\.prosodyPalette) private var palette
    @Environment(\.usesWindowMaterial) private var usesWindowMaterial
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    let selection: SettingsSection
    let select: (SettingsSection) -> Void
    let open: (SettingsSearchResult) -> Void

    @State private var query = ""
    @State private var results: [SettingsSearchResult] = []
    @State private var selectedResult = 0

    private static let index = SettingsSearchIndex(sections: SettingsSection.allCases.map { ($0, $0.page.controlsForSearch) })


    private var searchText: Binding<String> {
        Binding(get: { query }, set: { updateSearch($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowChromeSidebarHeader {
                HStack(spacing: 5) {
                    ProsodyLogoView(size: 19, prominent: true)
                    Text(AppConstants.applicationName).font(.callout.weight(.semibold))
                }
            }

            SettingsSearchField(query: searchText, move: moveResult, open: openSelectedResult, cancel: cancelSearch)
                .frame(height: 24)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections
            } else {
                SettingsSearchResultsView(
                    results: results,
                    selected: results.indices.contains(selectedResult) ? results[selectedResult].id : nil,
                    open: openResult
                )
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }

            footer
        }
        .frame(maxHeight: .infinity)
        .background(palette.sidebar.opacity(usesWindowMaterial ? 0.24 : 0.9))
    }

    private var sections: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(SettingsSection.allCases) { section in
                    Button { select(section) } label: {
                        Label(section.title, systemImage: section.systemImage)
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .background(
                                selection == section ? palette.accent.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selection == section ? palette.accent : palette.text)
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                    .accessibilityIdentifier("clippy.settings.section.\(section.id)")
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(AppConstants.displayVersion)
                .font(.caption)
                .accessibilityLabel("Version \(AppConstants.displayVersion)")
            Spacer()
            Button {
                AppWindowController.showAboutPanel()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 16))
            }
            .buttonStyle(.borderless)
            .settingsHelp("About \(AppConstants.applicationName)")
            .accessibilityLabel("About \(AppConstants.applicationName)")
            .accessibilityIdentifier("clippy.settings.about")
        }
        .foregroundStyle(palette.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func updateSearch(_ newQuery: String) {
        guard newQuery != query else { return }
        query = newQuery
        results = newQuery.isEmpty ? [] : Self.index.results(for: newQuery)
        selectedResult = 0
    }

    private func moveResult(_ direction: Int) -> Bool {
        guard !results.isEmpty else { return false }
        let next = min(max(selectedResult + direction, 0), results.count - 1)
        if next != selectedResult {
            selectedResult = next
            if voiceOverEnabled {
                let result = results[next]
                AccessibilityNotification.Announcement("\(result.title), \(result.section.title)").post()
            }
        }
        return true
    }

    private func openSelectedResult() -> Bool {
        guard results.indices.contains(selectedResult) else { return false }
        openResult(results[selectedResult])
        return true
    }

    private func openResult(_ result: SettingsSearchResult) {
        updateSearch("")
        open(result)
    }

    private func cancelSearch() -> Bool {
        guard !query.isEmpty else { return false }
        updateSearch("")
        return true
    }
}

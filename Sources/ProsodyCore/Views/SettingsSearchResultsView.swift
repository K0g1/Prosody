import SwiftUI

struct SettingsSearchResultsView: View {
    @Environment(\.prosodyPalette) private var palette
    let results: [SettingsSearchResult]
    let selected: SettingsSearchResult.ID?
    let open: (SettingsSearchResult) -> Void

    var body: some View {
        if results.isEmpty {
            Text("No settings found")
                .font(.callout)
                .foregroundStyle(palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .accessibilityIdentifier("clippy.settings.search.empty")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { result in
                            resultButton(result).id(result.id)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .onChange(of: selected) { _, selection in
                    if let selection { proxy.scrollTo(selection) }
                }
            }
        }
    }

    private func resultButton(_ result: SettingsSearchResult) -> some View {
        Button {
            open(result)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.callout.weight(.medium))
                Text(result.section.title).font(.caption).foregroundStyle(palette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                selected == result.id ? palette.accent.opacity(0.15) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(result.title), \(result.section.title)")
        .accessibilityAddTraits(selected == result.id ? .isSelected : [])
        .accessibilityIdentifier("clippy.settings.search.result.\(result.id.control)")
    }
}

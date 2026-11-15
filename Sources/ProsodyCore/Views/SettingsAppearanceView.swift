import SwiftUI

struct AppearanceSettingsView: SettingsSearchPage {
    @Environment(\.prosodyPalette) private var palette
    @ObservedObject var preferences: ProsodyPreferences

    private struct PaletteOption: Identifiable {
        let theme: ProsodyTheme
        let control: SettingsControl<AppearanceSettingsView>
        var id: String { control.id }
    }

    private struct PaletteSection: Identifiable {
        let group: ThemeGroup
        let options: [PaletteOption]
        var id: ThemeGroup { group }
    }

    private static let options: [ProsodyTheme: PaletteOption] = Dictionary(uniqueKeysWithValues: ThemeCatalog.entries.map { entry in
        let theme = entry.theme
        let palette = entry.palette
        let kind = theme.isAdaptive ? "adaptive system automatic" : (palette.dark ? "dark" : "light")
        let control = SettingsControl<Self>.custom(
            "clippy.theme.\(theme.id)", palette.name, help: palette.detail,
            keywords: [kind, "theme", "color palette"]
        ) { pane, entry in
            Button {
                pane.preferences.theme = theme
            } label: {
                ThemePreviewCard(theme: theme, name: entry.title, selected: pane.preferences.theme == theme)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.title) theme")
            .accessibilityValue(pane.preferences.theme == theme ? "Selected" : "Not selected")
            .accessibilityAddTraits(pane.preferences.theme == theme ? .isSelected : [])
            .accessibilityIdentifier(entry.id)
        }
        return (theme, PaletteOption(theme: theme, control: control))
    })

    private static let sections: [PaletteSection] = ThemeCatalog.sections.map { section in
        PaletteSection(
            group: section.group,
            options: section.entries.compactMap { options[$0.theme] }
        )
    }
    private static let searchOptions = sections.flatMap(\.options)
    private static let paletteColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 10)
    ]

    private static let chooser = SettingsControl<Self>.custom(
        "clippy.settings.appearance.palette-chooser", "Color palette",
        help: "Themes apply to all Prosody windows. Reduce Transparency simplifies the backgrounds.",
        keywords: ["theme", "appearance", "palette chooser", "color scheme", "dark mode", "light mode"]
    ) { pane, entry in
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(entry.title).font(.headline)
                Spacer()
                Text("Current: \(pane.palette.name)")
                    .font(.callout)
                    .foregroundStyle(pane.palette.secondary)
            }
            HStack(spacing: 9) {
                ThemeColorSwatch(palette: pane.palette)
                    .frame(width: 120, height: 32)
                    .clipShape(.rect(cornerRadius: 7))
                    .accessibilityHidden(true)
                Text(pane.palette.detail)
                    .font(.caption)
                    .foregroundStyle(pane.palette.secondary)
                    .lineLimit(2)
            }
        }
    }

    static let controlsForSearch = [chooser.entry] + searchOptions.map(\.control.entry)

    init(model: AppModel) { preferences = model.preferences }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPageHeader(title: "Appearance")
            Self.chooser.render(in: self)
            ForEach(Self.sections) { section in
                paletteGroup(section)
            }
        }
        .accessibilityIdentifier("clippy.settings.appearance")
    }

    private func paletteGroup(_ section: PaletteSection) -> some View {
        let scrollID = "clippy.appearance.group.\(section.group.rawValue)"
        return VStack(alignment: .leading, spacing: 8) {
            SettingsGroupTitle(title: section.group.title)
                .modifier(SettingsSearchGroupTarget(
                    controlIDs: section.options.map(\.id),
                    scrollID: scrollID,
                    scrollAnchor: .top
                ))
            LazyVGrid(columns: Self.paletteColumns, spacing: 10) {
                ForEach(section.options) { option in
                    option.control.render(in: self)
                }
            }
        }
    }
}

private struct ThemePreviewCard: View {
    @Environment(\.prosodyPalette) private var current
    let theme: ProsodyTheme
    let name: String
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if theme.isAdaptive {
                HStack(spacing: 0) {
                    ThemeColorSwatch(palette: theme.palette(for: .light))
                    ThemeColorSwatch(palette: theme.palette(for: .dark))
                }
                .accessibilityHidden(true)
            } else {
                ThemeColorSwatch(palette: theme.palette).accessibilityHidden(true)
            }
            HStack(spacing: 5) {
                Text(name).font(.caption.weight(.semibold))
                if theme.isAdaptive {
                    Text("Adaptive").font(.caption2).foregroundStyle(current.secondary)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(current.accent)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 29)
            .padding(.horizontal, 7)
        }
        .foregroundStyle(current.text)
        .background(current.surface)
        .clipShape(.rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? current.accent : current.border, lineWidth: selected ? 2 : 1)
                .allowsHitTesting(false)
        }
        .contentShape(.rect(cornerRadius: 7))
    }
}

private struct ThemeColorSwatch: View {
    let palette: ThemePalette

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(palette.sidebar)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(palette.surface)
                Capsule().fill(palette.accentGradient).frame(width: 26, height: 5)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background {
            LinearGradient(
                colors: [palette.background, palette.backgroundEnd],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }
}

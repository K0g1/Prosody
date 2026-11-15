import SwiftUI

/// The view factory is used only when this pane renders. The index can read
/// its entry without creating a pane, reading preferences, or starting tasks.
@MainActor
struct SettingsControl<Pane>: Identifiable {
    nonisolated var id: String { entry.id }
    nonisolated let entry: SettingsSearchEntry
    private let makeView: @MainActor (Pane) -> AnyView

    init<Control: View>(
        _ id: String, _ title: String,
        help: String? = nil, keywords: [String] = [], context: String? = nil,
        @ViewBuilder control: @escaping @MainActor (Pane, SettingsSearchEntry) -> Control
    ) {
        let hint = [help, context].compactMap { $0 }.joined(separator: " ")
        let entry = SettingsSearchEntry(id: id, title: title, help: hint.isEmpty ? nil : hint, keywords: keywords)
        self.entry = entry
        makeView = { pane in
            AnyView(SettingsRow(title: entry.title, detail: context, accessibilityID: entry.id) {
                control(pane, entry).settingsHelp(entry.help)
            })
        }
    }

    private init(entry: SettingsSearchEntry, makeView: @escaping @MainActor (Pane) -> AnyView) {
        self.entry = entry
        self.makeView = makeView
    }

    static func custom<Content: View>(
        _ id: String, _ title: String,
        help: String? = nil, keywords: [String] = [],
        @ViewBuilder content: @escaping @MainActor (Pane, SettingsSearchEntry) -> Content
    ) -> Self {
        let entry = SettingsSearchEntry(id: id, title: title, help: help, keywords: keywords)
        return Self(entry: entry) { pane in
            AnyView(content(pane, entry).settingsHelp(entry.help))
        }
    }

    func render(in pane: Pane, scrollAnchor: UnitPoint = .center) -> some View {
        makeView(pane).modifier(SettingsSearchTarget(id: id, scrollAnchor: scrollAnchor))
    }
}

@MainActor
struct SettingsControlGroup<Pane> {
    let title: String?
    let controls: [SettingsControl<Pane>]

    init(_ title: String? = nil, controls: [SettingsControl<Pane>]) {
        self.title = title
        self.controls = controls
    }

    var searchEntries: [SettingsSearchEntry] {
        controls.map { control in
            var entry = control.entry
            if let title { entry.keywords.append(title) }
            return entry
        }
    }

    func render(in pane: Pane, context: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SettingsGroupTitle(title: title) }
            if let context {
                Text(context)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsCard {
                ForEach(controls) { control in
                    if control.id != controls.first?.id { SettingsDivider() }
                    control.render(in: pane)
                }
            }
        }
    }
}

@MainActor
protocol SettingsSearchPage: View {
    static var controlsForSearch: [SettingsSearchEntry] { get }
    init(model: AppModel)
}

@MainActor
protocol GroupedSettingsSearchPage: SettingsSearchPage {
    static var groups: [SettingsControlGroup<Self>] { get }
}

extension GroupedSettingsSearchPage {
    static var controlsForSearch: [SettingsSearchEntry] {
        groups.flatMap(\.searchEntries)
    }

    func renderGroups() -> some View {
        ForEach(Self.groups.indices, id: \.self) { index in
            Self.groups[index].render(in: self)
        }
    }
}

extension View {
    @ViewBuilder
    func settingsHelp(_ text: String?) -> some View {
        if let text {
            help(Text(text)).accessibilityHint(Text(text))
        } else {
            self
        }
    }
}

struct SettingsSearchRequest: Equatable {
    let id: SettingsSearchResult.ID
    // Reopening the same result should scroll again, even after manual scrolling.
    private let invocation = UUID()
}

private struct SettingsSearchRequestKey: EnvironmentKey {
    static let defaultValue: SettingsSearchRequest? = nil
}

extension EnvironmentValues {
    var settingsSearchRequest: SettingsSearchRequest? {
        get { self[SettingsSearchRequestKey.self] }
        set { self[SettingsSearchRequestKey.self] = newValue }
    }
}

struct SettingsSearchReady: Equatable {
    let request: SettingsSearchRequest
    let scrollID: String
    let anchor: UnitPoint

    init(request: SettingsSearchRequest, scrollID: String? = nil, anchor: UnitPoint) {
        self.request = request
        self.scrollID = scrollID ?? request.id.control
        self.anchor = anchor
    }
}

struct SettingsSearchReadyKey: PreferenceKey {
    static let defaultValue: SettingsSearchReady? = nil

    static func reduce(value: inout SettingsSearchReady?, nextValue: () -> SettingsSearchReady?) {
        if let next = nextValue() { value = next }
    }
}

private struct SettingsSearchTarget: ViewModifier {
    @Environment(\.settingsSearchRequest) private var request
    @Environment(\.prosodyPalette) private var palette
    let id: String
    let scrollAnchor: UnitPoint

    func body(content: Content) -> some View {
        let match = request.flatMap { $0.id.control == id ? $0 : nil }
        content
            .overlay {
                if match != nil {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(palette.accent, lineWidth: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .id(id)
            // The active row reports readiness after layout, including when it
            // lives in a newly selected pane or a revealed connection group.
            .anchorPreference(key: SettingsSearchReadyKey.self, value: .bounds) { _ in
                match.map { SettingsSearchReady(request: $0, scrollID: id, anchor: scrollAnchor) }
            }
    }
}

/// A lightweight anchor for a lazy container. It scrolls to the containing
/// section first; once the target child is realized, its own anchor takes over
/// and performs the precise scroll.
struct SettingsSearchGroupTarget: ViewModifier {
    @Environment(\.settingsSearchRequest) private var request
    let controlIDs: [String]
    let scrollID: String
    let scrollAnchor: UnitPoint

    func body(content: Content) -> some View {
        let match = request.flatMap { controlIDs.contains($0.id.control) ? $0 : nil }
        content
            .id(scrollID)
            .anchorPreference(key: SettingsSearchReadyKey.self, value: .bounds) { _ in
                match.map { SettingsSearchReady(request: $0, scrollID: scrollID, anchor: scrollAnchor) }
            }
    }
}

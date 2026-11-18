import AppKit
import SwiftUI

struct DictationSettingsView: GroupedSettingsSearchPage {
    @Environment(\.prosodyPalette) private var palette
    @ObservedObject var preferences: ProsodyPreferences
    @ObservedObject var controller: DictationController
    #if DEBUG
    @State private var validationApplication = "com.apple.TextEdit"
    #endif

    private static let shortcuts = SettingsControlGroup<Self>(controls: [
        .init("clippy.settings.dictation.shortcut", "Shortcut",
              help: "Right Command is the default. Recording shortcuts are separate.",
              keywords: ["hotkey", "keyboard shortcut", "right command", "push to talk"]) { pane, entry in
            Picker("Dictation \(entry.title.lowercased())", selection: pane.$preferences.dictationShortcut) {
                ForEach(DictationShortcut.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 210)
            .accessibilityIdentifier(entry.id)
        },
        .init("clippy.settings.dictation.activation", "Activation",
              help: "Hold to talk, or press once to start and again to finish.",
              keywords: ["hold to talk", "push to talk", "toggle"]) { pane, entry in
            Picker(entry.title, selection: pane.$preferences.dictationActivation) {
                ForEach(DictationActivation.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 210)
            .accessibilityIdentifier(entry.id)
        },
        .init("clippy.settings.dictation.appearance", "Pop-up appearance",
              help: "Minimal shows a smaller waveform and a brief status.",
              keywords: ["popup", "overlay", "HUD", "waveform"]) { pane, entry in
            Picker(entry.title, selection: pane.$preferences.dictationOverlayAppearance) {
                ForEach(DictationOverlayAppearance.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 170)
            .accessibilityIdentifier(entry.id)
        }
    ])

    private static let textOutput = SettingsControlGroup<Self>("Text output", controls: [
        .init("clippy.settings.dictation.insertion", "Text insertion",
              help: "Use Keyboard typing if the editor blocks paste. Prosody adds a trailing space.",
              keywords: ["paste", "type", "keyboard typing", "insert", "trailing space"]) { pane, entry in
            Picker(entry.title, selection: pane.$preferences.dictationInsertionMethod) {
                ForEach(DictationInsertionMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 170)
            .accessibilityIdentifier(entry.id)
        },
        .init("clippy.settings.dictation.smart-capitalization", "Smart sentence capitalization",
              keywords: ["capitalization", "sentence case", "caret context", "punctuation"],
              context: "Best effort in apps that expose caret context.") { pane, entry in
            Toggle(entry.title, isOn: pane.$preferences.smartDictationCapitalization)
                .labelsHidden().toggleStyle(.switch)
                .accessibilityIdentifier(entry.id)
        },
        .init("clippy.settings.dictation.clipboard", "Copy output to clipboard",
              keywords: ["copy dictation text"]) { pane, entry in
            Toggle(entry.title, isOn: pane.$preferences.copyDictationToClipboard)
                .labelsHidden().toggleStyle(.switch)
                .accessibilityIdentifier(entry.id)
        }
    ])

    private static let permissions = SettingsControlGroup<Self>("Permissions", controls: [
        .init("clippy.settings.dictation.permission", "Accessibility",
              keywords: ["enable permission", "microphone", "system settings"],
              context: "Required for the global shortcut and text insertion. Microphone access is requested on first use.") { pane, entry in
            HStack(spacing: 8) {
                if pane.controller.shortcutReady {
                    Text("Enabled").font(.caption).foregroundStyle(.secondary)
                }
                Button(pane.controller.shortcutReady ? "Check Again" : "Enable…") {
                    pane.enableAccessibility()
                }
                .accessibilityLabel(pane.controller.shortcutReady ? "Check Accessibility Again" : "Enable Accessibility")
                .accessibilityIdentifier(entry.id)
            }
        }
    ])

    static let groups = [shortcuts, textOutput, permissions]

    init(model: AppModel) {
        preferences = model.preferences
        controller = model.dictation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPageHeader(title: "Dictation")
                .settingsHelp("Dictation uses your selected microphone and Word Replacements. It doesn’t generate notes.")
            #if DEBUG
            if controller.usesValidationFixture { validationControls }
            #endif
            Self.shortcuts.render(in: self)
            Text("Completed dictations are saved in Transcripts. Press Escape before dictation finishes to discard it without pasting, copying, or saving.")
                .font(.callout).foregroundStyle(palette.secondary)
            Self.textOutput.render(in: self, context: "Keep the same text field selected until insertion finishes. If Prosody can’t insert safely, use Copy Text.")
            Self.permissions.render(in: self)
        }
        .onChange(of: preferences.dictationShortcut) { _, _ in controller.configureShortcut() }
        .onChange(of: preferences.dictationActivation) { _, _ in controller.configureShortcut() }
        .onAppear { controller.configureShortcut() }
    }

    #if DEBUG
    @ViewBuilder private var validationControls: some View {
        Picker("UI test destination", selection: $validationApplication) {
            Text("Current foreground app").tag("")
            Text("TextEdit").tag("com.apple.TextEdit")
            Text("Arc").tag("company.thebrowser.Browser")
            Text("Visual Studio Code").tag("com.microsoft.VSCode")
        }
        Toggle("Keep waveform preview open", isOn: $controller.validationPreviewOnly)
        Button("Start UI fixture in 5 seconds") { controller.scheduleValidationDictation(applicationID: validationApplication) }
            .accessibilityIdentifier("clippy.validation.dictation")
        Text(controller.validationReport).font(.caption).textSelection(.enabled)
    }
    #endif

    private func enableAccessibility() {
        controller.configureShortcut(requestPermission: true)
        if !controller.shortcutReady,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct WordReplacementsSettingsView: SettingsSearchPage {
    @Environment(\.prosodyPalette) private var palette
    @ObservedObject var preferences: ProsodyPreferences

    private static let addReplacement = SettingsControl<Self>.custom(
        "clippy.settings.replacements.add", "Add Replacement",
        help: "Matches use whole words or phrases and ignore case. The longest matching phrase wins; duplicates use the first rule.",
        keywords: ["word replacements", "correction", "dictionary", "vocabulary", "replace phrase"]
    ) { pane, entry in
        Button(entry.title, systemImage: "plus") { pane.preferences.wordReplacements.append(WordReplacement()) }
            .accessibilityIdentifier(entry.id)
    }

    static var controlsForSearch: [SettingsSearchEntry] { [addReplacement.entry] }

    init(model: AppModel) { preferences = model.preferences }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPageHeader(title: "Word Replacements")
            Text("Applies to new recordings, imports, and dictations. Saved transcripts stay unchanged. An empty replacement removes the matched word.")
                .font(.callout).foregroundStyle(palette.secondary)
            VStack(spacing: 10) {
                if preferences.wordReplacements.isEmpty {
                    Text("No replacements yet").foregroundStyle(palette.secondary).padding(.vertical, 14)
                } else {
                    HStack { Text("Recognized as"); Spacer(); Text("Replace with"); Spacer() }
                        .font(.caption).foregroundStyle(palette.secondary)
                    ForEach($preferences.wordReplacements) { $rule in
                        HStack(spacing: 10) {
                            TextField("e.g. clip pee", text: $rule.original)
                                .accessibilityLabel("Recognized word")
                            Image(systemName: "arrow.right").foregroundStyle(palette.secondary).accessibilityHidden(true)
                            TextField("e.g. Prosody", text: $rule.replacement)
                                .accessibilityLabel("Replacement word")
                            Button {
                                preferences.wordReplacements.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove replacement")
                            .settingsHelp("Remove this rule from future transcriptions.")
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .prosodyPanel()
            Self.addReplacement.render(in: self)
        }
    }
}

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettingsView: GroupedSettingsSearchPage {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: ProsodyPreferences
    @ObservedObject var updates: SoftwareUpdates
    @StateObject private var loginItems: LoginItemManager
    @State private var importSource: PreferenceArchive?
    @State private var presentingImport = false

    static let groups: [SettingsControlGroup<Self>] = [
        .init("Application", controls: [
            .custom("clippy.settings.launch-at-login", "Launch \(AppConstants.applicationName) at login",
                    keywords: ["startup", "start on sign in", "login items"]) { pane, entry in
                SettingsRow(title: entry.title, detail: pane.loginItems.visibleStatusDescription,
                            accessibilityID: entry.id) {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 8) {
                            if pane.loginItems.showsProgress {
                                ProgressView().controlSize(.small)
                            }
                            Toggle(entry.title, isOn: Binding(
                                get: { pane.loginItems.isOn },
                                set: { pane.loginItems.requestEnabled($0) }
                            ))
                            .labelsHidden().toggleStyle(.prosodySwitch)
                            .disabled(!pane.loginItems.canToggle)
                            .accessibilityIdentifier(entry.id)
                        }
                        if pane.loginItems.shouldOfferOpenLoginItems {
                            Button("Open Login Items…") {
                                Task { await pane.loginItems.openLoginItems() }
                            }
                            .buttonStyle(.link)
                            .disabled(pane.loginItems.isBusy)
                            .accessibilityIdentifier("clippy.settings.login-items.open")
                        }
                        if pane.loginItems.canRetry {
                            Button("Try Again") {
                                Task { await pane.loginItems.refresh() }
                            }
                            .buttonStyle(.link)
                            .accessibilityIdentifier("clippy.settings.login-items.retry")
                        }
                    }
                }
                .settingsHelp(pane.loginItems.hoverStatusDescription)
            },
            .init("clippy.settings.global-shortcut", "Global recording shortcut",
                  help: "Start or pause a recording from any app.",
                  keywords: ["hotkey", "keyboard shortcut"]) { pane, entry in
                Picker(entry.title, selection: pane.$preferences.globalShortcut) {
                    ForEach(RecordingShortcut.allCases) { shortcut in
                        Text(shortcut.title).tag(shortcut.rawValue)
                    }
                    if RecordingShortcut(rawValue: pane.preferences.globalShortcut) == nil {
                        Text("\(pane.preferences.globalShortcut) · Current shortcut").tag(pane.preferences.globalShortcut)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 235)
                .accessibilityIdentifier("clippy.settings.recording-shortcut")
            },
            .init("clippy.settings.local-only", "Local-only mode",
                  keywords: ["offline", "privacy", "remote notes provider"],
                  context: "Allows only local notes providers. Speech models can still be downloaded.") { pane, entry in
                Toggle(entry.title, isOn: pane.$preferences.localOnlyMode)
                    .labelsHidden().toggleStyle(.prosodySwitch)
            },
            .init("clippy.settings.check-for-updates", "Software update",
                  keywords: ["version", "check for updates", "install update"],
                  context: "Prosody \(AppConstants.displayVersion) (build \(AppConstants.buildNumber))") { pane, entry in
                Button("Check for Updates…") { pane.updates.check() }
                    .disabled(!pane.updates.canCheck || !pane.model.canRelaunchForUpdate)
                    .accessibilityIdentifier(entry.id)
            },
            .init("clippy.settings.automatic-update-checks", "Check for updates automatically",
                  help: "Check for new releases in the background and ask before installing.",
                  keywords: ["automatic updates", "new release"]) { pane, entry in
                Toggle(entry.title, isOn: pane.$preferences.checkForUpdates)
                    .labelsHidden().toggleStyle(.prosodySwitch)
            }
        ]),
        .init("Preferences", controls: [
            .init("clippy.settings.import-preferences", "Import preferences",
                  keywords: ["upgrade", "migrate", "backup", "Clippy", "older version", "plist"],
                  context: "Copy settings from an earlier installation or a preferences file.") { pane, _ in
                Menu("Import Preferences…") {
                    if !pane.model.demoMode {
                        Button("Previous Prosody on This Mac") { pane.prepareImport { try .previousInstallation() } }
                        Button("Older Sandboxed Clippy") { pane.prepareImport { try .sandboxInstallation() } }
                        Divider()
                    }
                    Button("Choose Preferences File…") { pane.choosePreferencesFile() }
                }
                .fixedSize()
                .accessibilityIdentifier("clippy.settings.import-preferences.button")
            }
        ]),
        .init("Automation", controls: [
            .init("clippy.settings.cli", "Enable command-line tool",
                  help: "Install ~/.local/bin/prosody. The tool uses the selected model while Prosody is running.",
                  keywords: ["CLI", "command line", "terminal", "automation", "agent"]) { pane, entry in
                Toggle(entry.title, isOn: Binding(
                    get: { pane.preferences.cliEnabled },
                    set: { pane.model.setCLIEnabled($0) }
                ))
                .labelsHidden().toggleStyle(.prosodySwitch)
            }
        ]),
        .init("Notifications", controls: [
            .init("clippy.settings.notify-finished", "Show notification when finished",
                  keywords: ["alert", "transcript ready"]) { pane, entry in
                Toggle(entry.title, isOn: pane.$preferences.notifyWhenFinished)
                    .labelsHidden().toggleStyle(.prosodySwitch)
            },
            .init("clippy.settings.reveal-notes", "Automatically reveal completed notes",
                  help: "Open the output folder when processing finishes.",
                  keywords: ["Finder", "open saved folder"]) { pane, entry in
                Toggle(entry.title, isOn: pane.$preferences.automaticallyRevealNotes)
                    .labelsHidden().toggleStyle(.prosodySwitch)
            }
        ])
    ]

    init(model: AppModel) {
        self.model = model
        self.preferences = model.preferences
        self.updates = model.softwareUpdates
        let loginItems = model.demoMode
            ? LoginItemManager(backend: FixtureLoginItemBackend())
            : LoginItemManager.live
        loginItems.onSuccessfulUserInitiatedChange = { [weak preferences = model.preferences] enabled in
            preferences?.launchAtLogin = enabled
        }
        _loginItems = StateObject(wrappedValue: loginItems)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPageHeader(title: "General")
            renderGroups()
        }
        .onChange(of: preferences.globalShortcut) { _, _ in
            model.configureGlobalHotkey()
        }
        .task { await loginItems.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await loginItems.refresh() }
        }
        .alert("Import Preferences?", isPresented: $presentingImport, presenting: importSource) { source in
            Button("Import") {
                importSource = nil
                Task { @MainActor in
                    do {
                        let count = try await model.importPreferences(source)
                        model.userFacingError = nil
                        model.lastNotice = "Imported \(count) preferences."
                    } catch {
                        showImportError(error)
                    }
                }
            }
            Button("Cancel", role: .cancel) { importSource = nil }
        } message: { source in
            Text("Settings found in \(source.title) will replace the corresponding Prosody settings.")
        }
    }

    private func choosePreferencesFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Prosody Preferences"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.propertyList]
        if panel.runModal() == .OK, let url = panel.url {
            prepareImport { try .file(url) }
        }
    }

    private func prepareImport(_ source: () throws -> PreferenceArchive) {
        do {
            importSource = try source()
            presentingImport = true
        } catch {
            showImportError(error)
        }
    }

    private func showImportError(_ error: any Error) {
        model.userFacingError = UserFacingError(title: "Could not import preferences", message: error.localizedDescription)
    }
}

private extension LoginItemManager {
    var visibleStatusDescription: String? {
        if errorMessage != nil { return statusDescription }
        if status == nil || status == .requiresApproval || status == .notFound || status == .unknown {
            return statusDescription
        }
        return nil
    }

    var hoverStatusDescription: String? {
        guard errorMessage == nil else { return nil }
        if status == .enabled || status == .notRegistered { return statusDescription }
        return nil
    }
}

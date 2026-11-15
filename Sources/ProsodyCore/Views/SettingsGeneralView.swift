import AppKit
import Combine
import SwiftUI

struct GeneralSettingsView: GroupedSettingsSearchPage {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: ProsodyPreferences
    @StateObject private var loginItems: LoginItemManager

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
                            .labelsHidden().toggleStyle(.switch)
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
                    .labelsHidden().toggleStyle(.switch)
            }
        ]),
        .init("Notifications", controls: [
            .init("clippy.settings.notify-finished", "Show notification when finished",
                  keywords: ["alert", "transcript ready"]) { pane, entry in
                Toggle(entry.title, isOn: pane.$preferences.notifyWhenFinished)
                    .labelsHidden().toggleStyle(.switch)
            },
            .init("clippy.settings.reveal-notes", "Automatically reveal completed notes",
                  help: "Open the output folder when processing finishes.",
                  keywords: ["Finder", "open saved folder"]) { pane, entry in
                Toggle(entry.title, isOn: pane.$preferences.automaticallyRevealNotes)
                    .labelsHidden().toggleStyle(.switch)
            }
        ])
    ]

    init(model: AppModel) {
        self.model = model
        self.preferences = model.preferences
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

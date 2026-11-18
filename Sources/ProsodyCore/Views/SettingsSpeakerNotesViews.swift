import SwiftUI

struct SpeakerSettingsView: GroupedSettingsSearchPage {
    @ObservedObject var preferences: ProsodyPreferences

    static let groups: [SettingsControlGroup<Self>] = [
        .init(controls: [
            .init("clippy.settings.speakers.mode", "Speaker differentiation",
                  help: "Basic separates your microphone from system audio.",
                  keywords: ["diarization", "speaker separation", "participants", "full basic"],
                  context: "Full separates speakers after the transcript is saved.") { pane, entry in
                Picker(entry.title, selection: pane.$preferences.speakerMode) {
                    ForEach(SpeakerMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden().pickerStyle(.menu)
            }
        ])
    ]

    init(model: AppModel) { preferences = model.preferences }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPageHeader(title: "Speakers")
            renderGroups()
        }
    }
}

struct NotesSettingsView: SettingsSearchPage {
    @Environment(\.prosodyPalette) private var palette
    @Environment(\.settingsSearchRequest) private var request
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: ProsodyPreferences
    @State private var apiKey = ""
    @State private var connectionMessage: String?

    private static let providers = [
        LLMProviderDescriptor(id: "template-local", displayName: "Offline Outline", detail: "Organizes the transcript without an AI model", isRemote: false),
        LLMProviderDescriptor(
            id: "local-openai-compatible", displayName: "Local OpenAI-Compatible",
            detail: "LM Studio, Ollama, or another local server", isRemote: false
        ),
        LLMProviderDescriptor(id: "openai", displayName: "OpenAI", detail: "Remote provider", isRemote: true)
    ]

    private static let generation = SettingsControlGroup<Self>("Generation", controls: [
        .init("clippy.settings.notes.automatic", "Generate notes automatically",
              help: "Create notes after transcription and any speaker pass.",
              keywords: ["summaries", "automatic notes"]) { pane, entry in
            Toggle(entry.title, isOn: pane.$preferences.generateNotesAutomatically)
                .labelsHidden().toggleStyle(.prosodySwitch)
        },
        .init("clippy.settings.notes.provider", "Provider",
              help: "Offline Outline needs no AI model. Use a server provider to configure a model and connection.",
              keywords: providers.flatMap { [$0.displayName, $0.detail] } + ["LLM"]) { pane, entry in
            Picker("Notes \(entry.title.lowercased())", selection: pane.$preferences.notesProviderID) {
                ForEach(providers.filter { !pane.preferences.localOnlyMode || !$0.isRemote }) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }
            .labelsHidden().pickerStyle(.menu)
        },
        .init("clippy.settings.notes.model", "Model",
              help: "Enter the model ID advertised by your server.",
              keywords: ["LLM", "model ID", "qwen", "gpt"]) { pane, entry in
            TextField("Model ID", text: pane.$preferences.notesModelID)
                .accessibilityLabel(entry.title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .disabled(!pane.usesServer)
        }
    ])

    private static let connection = SettingsControlGroup<Self>("Connection", controls: [
        .init("clippy.settings.notes.base-url", "Base URL",
              help: "For a local server, use an address such as http://127.0.0.1:1234/v1.",
              keywords: ["endpoint", "server address", "host", "port", "advanced connection"]) { pane, entry in
            TextField(entry.title, text: pane.$preferences.notesBaseURL)
                .textFieldStyle(.roundedBorder)
                .frame(width: 235)
        },
        .init("clippy.settings.notes.api-key", "API key",
              help: "Stored in the macOS Keychain and kept out of session files.",
              keywords: ["credentials", "password", "token", "advanced connection"]) { pane, entry in
            SecureField("Optional", text: pane.$apiKey)
                .accessibilityLabel(entry.title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }
    ])

    private static let connectionActions: [SettingsControl<Self>] = [
        .custom("clippy.settings.notes.save-api-key", "Save API Key", keywords: ["credentials", "keychain"]) { pane, entry in
            Button(entry.title) {
                pane.model.saveProviderAPIKey(pane.apiKey)
                pane.connectionMessage = "Saved securely"
            }
            .buttonStyle(ThemedControlButtonStyle())
            .accessibilityIdentifier(entry.id)
        },
        .custom("clippy.settings.notes.test-connection", "Test Connection", keywords: ["verify", "server", "endpoint"]) { pane, entry in
            Button(entry.title) {
                pane.connectionMessage = "Testing…"
                Task { @MainActor in
                    pane.connectionMessage = await pane.model.testNotesConnection()
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(entry.id)
        }
    ]

    private static let connectionEntries = connection.searchEntries + connectionActions.map(\.entry)
    static let controlsForSearch = generation.searchEntries + connectionEntries

    private var usesServer: Bool { preferences.notesProviderID != "template-local" }

    private var showConnection: Bool {
        usesServer || Self.connectionEntries.contains { $0.id == request?.id.control }
    }

    init(model: AppModel) {
        self.model = model
        preferences = model.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPageHeader(title: "Notes")
            Self.generation.render(in: self)
            if Self.providers.first(where: { $0.id == preferences.notesProviderID })?.isRemote == true {
                Label("Generating notes sends the transcript to the remote provider.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showConnection { connectionControls }
        }
        .onAppear { apiKey = model.providerAPIKey() }
        .onChange(of: preferences.notesProviderID) { _, provider in
            apiKey = model.providerAPIKey(for: provider)
            connectionMessage = nil
            if provider == "openai" {
                preferences.notesBaseURL = "https://api.openai.com/v1"
                preferences.notesModelID = "gpt-4o-mini"
            } else if provider == "local-openai-compatible" {
                preferences.notesBaseURL = "http://127.0.0.1:1234/v1"
                preferences.notesModelID = "qwen3-4b"
            }
        }
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Self.connection.render(in: self, context: usesServer ? nil : "Choose a server provider to enable connection settings.")
            HStack(spacing: 8) {
                ForEach(Self.connectionActions) { $0.render(in: self) }
                if let connectionMessage {
                    Text(connectionMessage)
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
            }
        }
        .disabled(!usesServer)
    }
}

struct OutputSettingsView: SettingsSearchPage {
    @Environment(\.prosodyPalette) private var palette
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: ProsodyPreferences

    private static let files = SettingsControlGroup<Self>(controls: [
        .init("clippy.settings.output.folder", "Output folder",
              help: "Default save folder for transcripts, notes, and retained audio. A primary label can override it.",
              keywords: ["save location", "destination", "choose folder", "directory", "path"]) { pane, entry in
            HStack(spacing: 8) {
                Text(pane.preferences.outputFolderPath)
                    .font(.caption).foregroundStyle(pane.palette.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 210, alignment: .trailing)
                    .settingsHelp(pane.preferences.outputFolderPath)
                Button("Choose…") { pane.model.chooseOutputFolder() }
                    .accessibilityLabel("Choose Output Folder")
                    .accessibilityIdentifier("clippy.settings.output.choose")
                    .settingsHelp(entry.help)
            }
        },
        .init("clippy.settings.output.format", "Output format",
              help: "\(AppConstants.applicationName) also saves the canonical transcript as JSON.",
              keywords: ["Markdown", "file extension", "md", "JSON"]) { _, _ in
            Text("Markdown (.md)").foregroundStyle(.secondary)
        }
    ])

    private static let reveal = SettingsControl<Self>.custom(
        "clippy.settings.output.reveal", "Reveal Output Folder", keywords: ["Finder", "open folder", "show files"]
    ) { pane, entry in
        Button(entry.title, systemImage: "folder") { pane.model.revealOutputFolder() }
            .accessibilityIdentifier(entry.id)
    }

    static var controlsForSearch: [SettingsSearchEntry] { files.searchEntries + [reveal.entry] }

    init(model: AppModel) {
        self.model = model
        preferences = model.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPageHeader(title: "Output")
            Self.files.render(in: self)
            Self.reveal.render(in: self)
        }
    }
}

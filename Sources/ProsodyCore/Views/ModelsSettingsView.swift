import AppKit
import SwiftUI

struct ModelsSettingsView: SettingsSearchPage {
    @Environment(\.prosodyPalette) private var palette
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: ProsodyPreferences
    @State private var pendingDeletion: STTModelDescriptor?

    private static let rows = SpeechModel.allCases.map { model in
        SettingsControl<Self>.custom(
            "clippy.settings.model.\(model.rawValue)", model.descriptor.displayName,
            keywords: model.descriptor.languages + ["speech model", "install", "download", "remove", "delete", "storage"]
        ) { pane, _ in
            pane.row(model)
        }
    }

    private static let folder = SettingsControl<Self>.custom(
        "clippy.settings.model.folder", "Open Models Folder", keywords: ["Finder", "storage", "files"]
    ) { pane, entry in
        Button(entry.title, systemImage: "folder") {
            Task { await pane.model.revealModelsFolder() }
        }
        .help("Open the on-device speech model cache in Finder")
    }

    static var controlsForSearch: [SettingsSearchEntry] { rows.map(\.entry) + [folder.entry] }

    init(model: AppModel) {
        self.model = model
        self.preferences = model.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPageHeader(title: "Models")
            Text("Select an installed model for recordings, dictation, and audio files.")
                .font(.callout)
                .foregroundStyle(palette.secondary)
            SettingsCard {
                ForEach(Self.rows) { row in
                    if row.id != Self.rows.first?.id { SettingsDivider() }
                    row.render(in: self)
                }
            }
            HStack {
                Self.folder.render(in: self)
                Spacer()
                Text("Model storage: \(ByteCountFormatter.string(fromByteCount: model.modelStorageUsedBytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(palette.secondary)
            }
        }
        .task { await model.refreshModelInventory() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshModelInventory() }
        }
        .alert("Delete \(pendingDeletion?.displayName ?? "model")?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { descriptor in
            Button("Delete Model", role: .destructive) { Task { await model.removeModel(descriptor) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Prosody will delete the downloaded model files. You can download the model again from this page.")
        }
    }

    private func row(_ speechModel: SpeechModel) -> some View {
        let descriptor = speechModel.descriptor
        let installed = model.installedModelIDs.contains(descriptor.id)
        let canDelete = model.cachedModelIDs.contains(descriptor.id)
        let selected = preferences.sttModelID == descriptor.id
        let mode = descriptor.supportsStreaming ? "Live and after recording" : "After recording"
        return HStack(spacing: 14) {
            Image(systemName: "cpu").foregroundStyle(palette.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(descriptor.displayName).font(.callout.weight(.medium))
                Text("\(descriptor.languages.joined(separator: ", ")) · \(mode) · \(descriptor.downloadSizeLabel)")
                    .font(.caption).foregroundStyle(palette.secondary)
            }
            Spacer()
            if model.modelDownloadingID == descriptor.id {
                ProgressView(value: model.modelDownloadProgress, total: 1)
                    .frame(width: 90)
                    .accessibilityLabel("Downloading \(descriptor.displayName)")
                Button("Cancel") { model.cancelModelDownload() }
                    .help("Cancel this model download")
            } else {
                if installed && selected {
                    Label("Selected", systemImage: "checkmark").foregroundStyle(palette.accent)
                } else if installed {
                    Button("Select") { Task { await model.selectSpeechModel(speechModel) } }
                        .help("Use \(descriptor.displayName) for new transcription")
                        .disabled(!model.canManageModelSelection)
                } else {
                    Button(canDelete ? "Repair" : "Download") { model.startModelDownload(speechModel) }
                        .help("Download the files for \(descriptor.displayName)")
                        .disabled(model.modelDownloadingID != nil)
                }
                if canDelete {
                    Button {
                        pendingDeletion = descriptor
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete \(descriptor.displayName)")
                    .help("Delete this model to free disk space")
                    .disabled(!model.canManageModelSelection)
                }
            }
        }
        .padding(16)
    }
}

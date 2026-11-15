import SwiftUI

struct MenuBarOptionsView: View {
    @Environment(\.prosodyPalette) private var palette
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: ProsodyPreferences
    let sections: [MainScreenSection]
    let openTranscript: () -> Void
    @Binding private var sessionToDelete: UUID?

    init(model: AppModel, sections: [MainScreenSection], sessionToDelete: Binding<UUID?>,
         openTranscript: @escaping () -> Void) {
        self.model = model
        self.preferences = model.preferences
        self.sections = sections
        self.openTranscript = openTranscript
        self._sessionToDelete = sessionToDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(sections) { section in
                row(section)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(palette.border)
        }
    }

    @ViewBuilder
    private func row(_ section: MainScreenSection) -> some View {
        switch section {
        case .branding:
            MenuBarBrand()
                .padding(.horizontal, 6)
                .frame(height: 28)
        case .recordingTitle:
            TextField("Recording title (optional)", text: $model.recordingTitle)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .padding(.horizontal, 5)
                .frame(height: 28)
                .accessibilityIdentifier("clippy.recording-title")
        case .labels:
            NextRecordingLabelsView(model: model)
        case .source:
            Menu {
                Picker("Audio source", selection: $preferences.captureMode) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                MenuBarOptionLabel(title: "Audio", systemImage: "mic", accessory: "chevron.down") {
                    Text(preferences.captureMode.displayName)
                        .lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(height: 28)
            .accessibilityLabel("Audio source")
            .accessibilityValue(preferences.captureMode.displayName)
            .accessibilityIdentifier("clippy.source-picker")
        case .noteTemplate:
            Menu {
                Picker("Note template", selection: $preferences.noteTemplateID) {
                    ForEach(NoteTemplateID.allCases) { template in
                        Text(template.displayName).tag(template)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                MenuBarOptionLabel(title: "Template", systemImage: "doc.text", accessory: "chevron.down") {
                    Text(preferences.noteTemplateID.displayName)
                        .lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(height: 28)
            .accessibilityLabel("Note template")
            .accessibilityValue(preferences.noteTemplateID.displayName)
            .accessibilityIdentifier("clippy.template-picker")
        case .saveLocation:
            Button {
                model.chooseOutputFolder(for: preferences.selectedRecordingLabels.first?.id)
            } label: {
                MenuBarOptionLabel(title: "Save to", systemImage: "folder", accessory: "chevron.right") {
                    Text(model.nextRecordingFolderPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.borderless)
            .frame(height: 28)
            .accessibilityLabel("Save location")
            .accessibilityValue(model.nextRecordingFolderPath)
            .accessibilityIdentifier("clippy.output-folder")
        case .recents:
            recentRecordings
        }
    }

    private var recentRecordings: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .accessibilityAddTraits(.isHeader)

            ForEach(model.recentRecordings.prefix(3)) { session in
                Button {
                    showSession(session)
                } label: {
                    MenuBarRecentRow(session: session)
                }
                .buttonStyle(.borderless)
                .disabled(!model.canBrowseSessions)
                .accessibilityIdentifier("clippy.recent-session.\(session.id.uuidString)")
                .contextMenu {
                    Button("Open Transcript") { showSession(session) }
                    Button("Copy Transcript") { model.copySession(session) }
                    Button("Reveal in Finder") { model.revealSession(session) }
                        .disabled(session.folderPath == nil)
                    Divider()
                    Button("Delete Recording…", role: .destructive) { sessionToDelete = session.id }
                        .disabled(!model.canBrowseSessions)
                }

                if sessionToDelete == session.id {
                    InlineDeleteConfirmation(title: "Delete this recording?", cancel: { sessionToDelete = nil }) {
                        model.deleteSession(session)
                        sessionToDelete = nil
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    private func showSession(_ session: SessionSummary) {
        model.selectSession(session)
        openTranscript()
    }
}

/// Shared visual label for the options, folder button, and label chooser.
struct MenuBarOptionLabel<Detail: View>: View {
    @Environment(\.prosodyPalette) private var palette
    let title: String
    let systemImage: String
    let accessory: String
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(palette.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(title)
                .fontWeight(.medium)
                .foregroundStyle(palette.text)
                .fixedSize()
            Spacer(minLength: 5)
            detail()
                .foregroundStyle(palette.secondary)
            Image(systemName: accessory)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(palette.secondary)
                .frame(width: 10)
                .accessibilityHidden(true)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .contentShape(Rectangle())
    }
}

private struct MenuBarRecentRow: View {
    @Environment(\.prosodyPalette) private var palette
    let session: SessionSummary

    var body: some View {
        let duration = ProsodyFormatters.duration(session.duration)
        let date = dateLabel
        let primary = session.labels?.first
        HStack(spacing: 7) {
            Image(systemName: "doc.text")
                .foregroundStyle(palette.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(session.title.count > 30 ? String(session.title.prefix(29)) + "…" : session.title)
                .lineLimit(1)
                .foregroundStyle(palette.text)
            if let primary {
                Circle()
                    .fill(Color(labelHex: primary.colorHex))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 4)
            Text(date)
                .font(.caption)
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .fixedSize()
            Text(duration)
                .monospacedDigit()
                .foregroundStyle(palette.secondary)
                .fixedSize()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 25)
        .contentShape(Rectangle())
        .accessibilityLabel(session.title)
        .accessibilityValue([primary?.name, date, duration].compactMap { $0 }.joined(separator: ", "))
    }

    private var dateLabel: String {
        if Calendar.current.isDateInToday(session.createdAt) {
            return session.createdAt.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(session.createdAt) { return "Yesterday" }
        return session.createdAt.formatted(date: .abbreviated, time: .omitted)
    }
}

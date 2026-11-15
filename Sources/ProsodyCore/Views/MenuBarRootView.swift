import AppKit
import SwiftUI

public struct MenuBarRootView: View {
    @Environment(\.prosodyPalette) private var palette
    @ObservedObject public var model: AppModel
    @ObservedObject private var preferences: ProsodyPreferences
    private let expands: Bool
    @State private var recoveryToDelete: UUID?
    @State private var sessionToDelete: UUID?

    public init(model: AppModel, expands: Bool = false) {
        self.model = model
        self.preferences = model.preferences
        self.expands = expands
    }

    private var state: RecordingState { model.recordingState }

    private var showsNextRecording: Bool {
        switch state {
        case .idle, .completed: true
        default: false
        }
    }

    private var sections: [MainScreenSection] {
        guard showsNextRecording else { return [] }
        return MainScreenSection.allCases.filter { section in
            guard preferences.showsOnMainScreen(section) else { return false }
            switch section {
            case .noteTemplate: return preferences.generateNotesAutomatically
            case .recents: return !model.recentRecordings.isEmpty
            default: return true
            }
        }
    }

    private var recordingFailure: UserFacingError? {
        if case .failed(let error) = state { return error }
        return nil
    }

    private var otherError: UserFacingError? {
        guard let error = model.userFacingError, error.id != recordingFailure?.id else { return nil }
        return error
    }

    private var notice: String? {
        guard let notice = model.lastNotice,
              notice != recordingFailure?.message, notice != otherError?.message else { return nil }
        return notice
    }

    private var recovery: RecoveryManifest? {
        guard !state.isBusy, !state.isRecording else { return nil }
        return model.recoverableSessions.first
    }

    public var body: some View {
        let sections = sections
        let showsHeaderBrand = showsNextRecording ? sections.first == .branding : preferences.showsOnMainScreen(.branding)
        let optionalSections = showsHeaderBrand ? Array(sections.dropFirst()) : sections

        VStack(alignment: .leading, spacing: 8) {
            MenuBarStatusHeader(model: model, showsBrand: showsHeaderBrand)
                .layoutPriority(1)
            MenuBarRecordingActions(model: model)
                .layoutPriority(1)

            if !optionalSections.isEmpty || state.isRecording || recordingFailure != nil || otherError != nil
                || notice != nil || recovery != nil {
                if expands {
                    details(sections: optionalSections)
                } else {
                    // Leave the actions, save notice, and navigation outside the scroll area.
                    // NSPopover expands an unconstrained scroll fallback to its
                    // default 320 pt content height. Size the fallback from its
                    // content up to 260 pt so small sets stay intrinsic.
                    ViewThatFits(in: .vertical) {
                        details(sections: optionalSections)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            details(sections: optionalSections)
                        }
                        .frame(maxHeight: 260)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !state.isBusy, !state.isRecording, let completion = model.recordingCompletion {
                savedBanner(completion)
                    .layoutPriority(1)
            }

            Divider()
            MenuBarNavigation(canBrowse: model.canBrowseSessions, openTranscript: openTranscript)
                .layoutPriority(1)
        }
        .padding(12)
        .frame(width: expands ? nil : 348)
        .frame(maxWidth: expands ? .infinity : nil, alignment: .leading)
        .tint(palette.accent)
        .accessibilityIdentifier("clippy.menu-popover")
    }

    @ViewBuilder
    private func details(sections: [MainScreenSection]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let recordingFailure {
                MenuBarErrorNotice(error: recordingFailure)
                    .accessibilityIdentifier("clippy.failed")
            }
            if let otherError {
                MenuBarErrorNotice(error: otherError)
                    .accessibilityIdentifier("clippy.error")
            }
            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("clippy.notice")
            }
            if let recovery {
                MenuBarRecoveryNotice(
                    manifest: recovery,
                    confirming: recoveryToDelete == recovery.id,
                    recover: {
                        recoveryToDelete = nil
                        model.recover(recovery)
                    },
                    requestDelete: { recoveryToDelete = recovery.id },
                    cancelDelete: { recoveryToDelete = nil },
                    confirmDelete: {
                        model.discardRecovery(recovery)
                        recoveryToDelete = nil
                    }
                )
            }

            if !sections.isEmpty {
                MenuBarOptionsView(model: model, sections: sections,
                                   sessionToDelete: $sessionToDelete, openTranscript: openTranscript)
            } else if state.isRecording {
                MenuBarCapturePreview(model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func savedBanner(_ completion: RecordingCompletion) -> some View {
        HStack(spacing: 8) {
            Label(completion.message, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.accent)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("View") {
                if let session = model.recentSessions.first(where: { $0.id == completion.sessionID }) {
                    model.selectSession(session)
                }
                openTranscript()
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("View saved transcript")
        }
        .prosodyPanel(padding: 6)
        .accessibilityIdentifier("clippy.saved-banner")
    }

    private func openTranscript() {
        AppWindowController.shared.showLibrary()
    }
}

private struct MenuBarNavigation: View {
    @Environment(\.prosodyPalette) private var palette
    let canBrowse: Bool
    let openTranscript: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: openTranscript) {
                Label("Transcripts", systemImage: "doc.text")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(palette.accent)
            .accessibilityIdentifier("clippy.open-transcript")

            Spacer(minLength: 6)
            Button {
                AppWindowController.shared.showSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(palette.text)
            .accessibilityIdentifier("clippy.open-settings")

            Menu {
                Button("Transcribe Audio File…", systemImage: "waveform") {
                    AppWindowController.shared.importFile()
                }
                .disabled(!canBrowse)
                .accessibilityIdentifier("clippy.import-file")
                Divider()
                Button("Quit Prosody", systemImage: "power") {
                    NSApp.terminate(nil)
                }
                .disabled(!canBrowse)
                .accessibilityIdentifier("clippy.quit")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("More actions")
            .accessibilityIdentifier("clippy.more-actions")
        }
        .font(.system(size: 12, weight: .medium))
        .frame(minHeight: 26)
    }
}

private struct MenuBarErrorNotice: View {
    @Environment(\.prosodyPalette) private var palette
    let error: UserFacingError

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(error.title, systemImage: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
            Text(error.message)
                .font(.system(size: 12))
                .foregroundStyle(palette.secondary)
            if let recoveryAction = error.recoveryAction {
                Text(recoveryAction)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .prosodyPanel(padding: 8)
    }
}

private struct MenuBarRecoveryNotice: View {
    @Environment(\.prosodyPalette) private var palette
    let manifest: RecoveryManifest
    let confirming: Bool
    let recover: () -> Void
    let requestDelete: () -> Void
    let cancelDelete: () -> Void
    let confirmDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Unfinished recording", systemImage: "arrow.uturn.backward.circle")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 5) {
                Text(manifest.session.title == "New Recording" ? "Untitled Recording" : manifest.session.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(ProsodyFormatters.duration(manifest.duration))
                    .monospacedDigit()
            }
            .font(.system(size: 12))
            .foregroundStyle(palette.secondary)

            if confirming {
                InlineDeleteConfirmation(title: "Delete unfinished recording?", cancel: cancelDelete, confirm: confirmDelete)
            } else {
                HStack(spacing: 8) {
                    Button("Recover", action: recover)
                        .accessibilityIdentifier("clippy.recovery.recover")
                    Button("Delete…", action: requestDelete)
                        .accessibilityIdentifier("clippy.recovery.delete")
                }
            }
        }
        .prosodyPanel(padding: 8)
        .accessibilityIdentifier("clippy.recovery.notice")
    }
}

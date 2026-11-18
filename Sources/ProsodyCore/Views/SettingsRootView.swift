import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Hashable, Identifiable, Sendable {
    case general
    case appearance
    case mainScreen
    case audio
    case transcription
    case transcriptExport
    case dictation
    case replacements
    case speakers
    case notes
    case models
    case output
    case labels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .mainScreen: return "Tray Elements"
        case .dictation: return "Dictation"
        case .replacements: return "Replacements"
        case .general: return "General"
        case .audio: return "Audio"
        case .transcription: return "Transcription"
        case .transcriptExport: return "Transcript Export"
        case .speakers: return "Speakers"
        case .notes: return "Notes"
        case .models: return "Models"
        case .labels: return "Labels"
        case .output: return "Output"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: return "paintpalette"
        case .mainScreen: return "rectangle.topthird.inset.filled"
        case .dictation: return "waveform"
        case .replacements: return "textformat.abc"
        case .general: return "gearshape"
        case .audio: return "speaker.wave.2"
        case .transcription: return "text.alignleft"
        case .transcriptExport: return "square.and.arrow.up"
        case .speakers: return "person.2"
        case .notes: return "note.text"
        case .models: return "shippingbox"
        case .labels: return "tag"
        case .output: return "folder"
        }
    }

    @MainActor var page: any SettingsSearchPage.Type {
        switch self {
        case .general: GeneralSettingsView.self
        case .appearance: AppearanceSettingsView.self
        case .mainScreen: MainScreenSettingsView.self
        case .audio: AudioSettingsView.self
        case .transcription: TranscriptionSettingsView.self
        case .transcriptExport: TranscriptExportSettingsView.self
        case .dictation: DictationSettingsView.self
        case .replacements: WordReplacementsSettingsView.self
        case .speakers: SpeakerSettingsView.self
        case .notes: NotesSettingsView.self
        case .models: ModelsSettingsView.self
        case .output: OutputSettingsView.self
        case .labels: LabelsSettingsSearchPage.self
        }
    }
}

public struct SettingsRootView: View {
    @Environment(\.prosodyPalette) private var palette
    @Environment(\.usesWindowMaterial) private var usesWindowMaterial
    @ObservedObject public var model: AppModel
    @State private var selection: SettingsSection = .general
    @State private var destination: SettingsSearchRequest?
    @State private var labelDrafts = RecordingLabelDraftStore()

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            SettingsSidebarView(selection: selection, select: selectSection, open: openResult)
                .frame(width: 228)
            Divider()
            VStack(spacing: 0) {
                WindowChromeDragRegion()
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.surface.opacity(usesWindowMaterial ? 0.12 : 0.42))
        }
        .tint(palette.accent)
        .environment(labelDrafts)
        .accessibilityIdentifier("clippy.settings")
        .onReceive(model.$requestedSettingsSection.compactMap { $0 }) { selectSection($0) }
    }

    private var editingSuspended: Bool {
        !model.canBrowseSessions && ![.appearance, .mainScreen, .transcription].contains(selection)
    }

    private var detail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if editingSuspended {
                        Label("Editing is unavailable while Prosody is recording or processing audio.", systemImage: "lock")
                            .font(.callout)
                            .foregroundStyle(palette.secondary)
                    }
                    AnyView(selection.page.init(model: model)).disabled(editingSuspended)
                    if let error = model.userFacingError {
                        Label(error.message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(palette.secondary)
                            .textSelection(.enabled)
                    } else if let notice = model.lastNotice {
                        Text(notice)
                            .font(.callout)
                            .foregroundStyle(palette.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .environment(\.settingsSearchRequest, destination)
            }
            .accessibilityIdentifier("clippy.settings.detail")
            .onPreferenceChange(SettingsSearchReadyKey.self) { ready in
                guard let ready, ready.request == destination else { return }
                proxy.scrollTo(ready.scrollID, anchor: ready.anchor)
            }
        }
        .id(selection)
    }

    private func selectSection(_ section: SettingsSection) {
        selection = section
        destination = nil
    }

    private func openResult(_ result: SettingsSearchResult) {
        selection = result.section
        destination = SettingsSearchRequest(id: result.id)
    }
}

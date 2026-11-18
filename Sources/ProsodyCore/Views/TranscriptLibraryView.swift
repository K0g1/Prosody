import SwiftUI

public struct TranscriptLibraryView: View {
    @Environment(\.prosodyPalette) private var palette
    @Environment(\.usesWindowMaterial) private var usesWindowMaterial
    @Environment(\.usesMonochromeControls) private var usesMonochromeControls
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var labelID: UUID?
    @State private var sort: TranscriptSort = .newest
    @State private var includeDictation = false
    @State private var showRetainedAudio = true
    @State private var showUnretainedAudio = true
    @State private var displayedSessions: [LibraryDisplayItem] = []
    @State private var availableLabels: [RecordingLabelSnapshot] = []
    @State private var hasDictations = false
    @State private var selectedSessionSummary: SessionSummary?
    @State private var deleteID: UUID?
    @State private var queryRevision = 0
    @FocusState private var searchFocused: Bool

    public init(model: AppModel) { self.model = model }

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var audioFilter: TranscriptAudioFilter {
        if showRetainedAudio && showUnretainedAudio { return .any }
        return showRetainedAudio ? .retained : .notRetained
    }

    private var retainedAudioBinding: Binding<Bool> {
        Binding(get: { showRetainedAudio }, set: { value in
            guard value || showUnretainedAudio else { return }
            showRetainedAudio = value
        })
    }

    private var unretainedAudioBinding: Binding<Bool> {
        Binding(get: { showUnretainedAudio }, set: { value in
            guard value || showRetainedAudio else { return }
            showUnretainedAudio = value
        })
    }

    private var hasNarrowingFilters: Bool {
        !trimmedSearch.isEmpty || labelID != nil || audioFilter != .any
    }

    private var hasHiddenDictations: Bool {
        !includeDictation && hasDictations
    }

    private var selectedDictationIsHidden: Bool {
        !includeDictation && selectedSessionSummary?.isDictation == true
    }

    private var shouldShowTranscript: Bool {
        !selectedDictationIsHidden
            && (model.selectedSessionID != nil || model.recordingState.isRecording || model.recordingState.isBusy)
    }

    private var emptyTitle: String {
        if displayedSessions.isEmpty && hasHiddenDictations && !hasNarrowingFilters {
            return "Dictations are hidden"
        }
        return hasNarrowingFilters ? "No matches" : "No transcripts"
    }

    private var emptyDescription: String {
        if displayedSessions.isEmpty && hasHiddenDictations && !hasNarrowingFilters {
            return "Turn on Include Dictation to browse them."
        }
        if hasNarrowingFilters {
            return "Try a different search or clear the active filters."
        }
        return "Record from the menu bar or import an audio file to get started."
    }

    private var emptySystemImage: String {
        if displayedSessions.isEmpty && hasHiddenDictations && !hasNarrowingFilters { return "waveform.slash" }
        return hasNarrowingFilters ? "magnifyingglass" : "doc.text"
    }

    public var body: some View {
        HStack(spacing: 0) {
            if model.librarySidebarVisible {
                sidebar
                Divider()
            }
            detail
        }
        .tint(palette.accent)
        .accessibilityIdentifier("clippy.library")
        .task(id: queryRevision) { await refreshResults() }
        .onChange(of: search) { _, _ in queryRevision &+= 1 }
        .onChange(of: labelID) { _, _ in queryRevision &+= 1 }
        .onChange(of: sort) { _, _ in queryRevision &+= 1 }
        .onChange(of: includeDictation) { _, _ in queryRevision &+= 1 }
        .onChange(of: showRetainedAudio) { _, _ in queryRevision &+= 1 }
        .onChange(of: showUnretainedAudio) { _, _ in queryRevision &+= 1 }
        .onAppear {
            if model.libraryShowDictationRequest > 0 { includeDictation = true }
        }
        .onChange(of: model.libraryShowDictationRequest) { _, _ in includeDictation = true }
        .onChange(of: model.libraryFindRequest) { _, _ in searchFocused = true }
        .onChange(of: model.selectedSessionID) { _, id in
            if let id, !model.librarySelection.contains(id) {
                model.librarySelection = displayedSessions.contains(where: { $0.id == id }) ? [id] : []
            }
            syncSelectedSummary()
            queryRevision &+= 1
        }
        .onChange(of: model.recentSessions) { _, _ in
            syncSelectedSummary()
            queryRevision &+= 1
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
                WindowChromeSidebarHeader {
                    HStack(spacing: 8) {
                        Text("Transcripts")
                            .font(.system(size: 14, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text("\(displayedSessions.count)")
                            .foregroundStyle(palette.secondary)
                            .monospacedDigit()
                            .help("Matching transcripts")
                            .accessibilityLabel("Matching transcripts: \(displayedSessions.count)")
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.secondary)
                            .accessibilityHidden(true)
                        TextField("Search transcripts", text: $search)
                            .textFieldStyle(.plain)
                            .focused($searchFocused)
                            .onSubmit {
                                if let first = displayedSessions.first {
                                    model.librarySelection = [first.id]
                                    model.selectSession(first.summary)
                                }
                            }
                            .help("Search transcript titles and labels")
                            .accessibilityLabel("Search transcript titles and labels")
                            .accessibilityIdentifier("clippy.library.search")
                        if !search.isEmpty {
                            Button { search = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(palette.secondary)
                            .help("Clear search")
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(palette.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

                    HStack(spacing: 8) {
                        Picker("Label", selection: $labelID) {
                            Text("All labels").tag(nil as UUID?)
                            ForEach(availableLabels) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .help("Filter transcripts by label")
                        .accessibilityLabel("Filter by label")
                        .accessibilityIdentifier("clippy.library.label")
                        Picker("Sort", selection: $sort) {
                            ForEach(TranscriptSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .help("Change the order of transcripts")
                        .accessibilityLabel("Sort transcripts")
                        .accessibilityIdentifier("clippy.library.sort")
                    }
                    .controlSize(.small)

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Include Dictation", isOn: $includeDictation)
                        Divider().padding(.vertical, 2)
                        Toggle("With retained audio", isOn: retainedAudioBinding)
                        Toggle("Without retained audio", isOn: unretainedAudioBinding)
                    }
                    .toggleStyle(.prosodyCheckbox)
                    .controlSize(.small)
                    .font(.caption)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
                Divider()
                if displayedSessions.isEmpty {
                    emptyState
                } else {
                    sessionList(displayedSessions)
                }
                Divider()
                Button("Transcribe Audio Files…", systemImage: "square.and.arrow.down") { model.chooseTranscriptionFile() }
                    .disabled(!model.canBrowseSessions)
                    .help("Transcribe one or more audio files and choose their label and filenames")
                    .accessibilityIdentifier("clippy.library.import")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .frame(width: 285)
            .background(palette.sidebar.opacity(usesWindowMaterial ? 0.24 : 0.9))
    }

    private var detail: some View {
        VStack(spacing: 0) {
                WindowChromeDragRegion()
                if model.librarySelection.count > 1 {
                    multipleSelection
                } else if selectedDictationIsHidden {
                    hiddenDictationDetail
                } else if shouldShowTranscript {
                    TranscriptWindowRootView(model: model)
                } else {
                    ContentUnavailableView("Select a transcript", systemImage: "doc.text",
                        description: Text(includeDictation
                            ? "Browse your recordings, dictations, and imported audio."
                            : "Browse your recordings and imported audio."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if !model.canBrowseSessions {
                    Text(model.isImportingAudio ? (model.lastNotice ?? "Preparing audio files…") :
                        model.dictation.isActive ? "Dictation is in progress…" : model.recordingState.statusTitle)
                        .font(.callout).foregroundStyle(palette.secondary).padding(10)
                }
                if let error = model.userFacingError {
                    Text(error.message).font(.callout).foregroundStyle(palette.secondary).padding(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.surface.opacity(usesWindowMaterial ? 0.12 : 0.42))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: emptySystemImage)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(palette.secondary)
                .accessibilityHidden(true)
            Text(emptyTitle)
                .font(.callout.weight(.semibold))
            Text(emptyDescription)
                .font(.caption)
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
            if displayedSessions.isEmpty && hasHiddenDictations && !hasNarrowingFilters {
                Button("Show Dictations") { includeDictation = true }
                    .controlSize(.small)
            } else if hasNarrowingFilters {
                Button("Clear Filters") { clearFilters() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 18)
        .accessibilityElement(children: .contain)
    }

    private var hiddenDictationDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 28))
                .foregroundStyle(palette.secondary)
                .accessibilityHidden(true)
            Text("Dictation hidden")
                .font(.title3.weight(.semibold))
            Text("Turn on Include Dictation to view this transcript.")
                .font(.callout)
                .foregroundStyle(palette.secondary)
            Button("Show Dictations") { includeDictation = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var multipleSelection: some View {
        VStack(spacing: 12) {
            Image(systemName: "document.on.document").font(.largeTitle).foregroundStyle(palette.secondary)
            Text("\(model.librarySelection.count) transcripts selected").font(.title2)
            HStack {
                Button("Copy Raw Text") { model.copySelectedTranscripts(format: .rawText) }
                    .help("Copy speech from the selected transcripts as plain text")
                Button("Copy Markdown") { model.copySelectedTranscripts(format: .markdown) }
                    .help("Copy the selected transcripts using the Markdown export settings")
                Menu("Export") {
                    Button("Separate Markdown Files…") { model.chooseExport(.separateMarkdown) }
                    Button("Combined Markdown File…") { model.chooseExport(.combinedMarkdown) }
                    Button("Retained Audio…") { model.chooseExport(.audio) }
                        .disabled(!model.selectionMayHaveAudio)
                }
                .help("Export the selected transcripts or their retained audio")
            }
            .disabled(!model.canBrowseSessions)
            if let notice = model.lastNotice, model.canBrowseSessions {
                Text(notice).font(.callout).foregroundStyle(palette.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sessionList(_ sessions: [LibraryDisplayItem]) -> some View {
        List(selection: Binding(
            get: { Set(model.librarySelection) },
            set: { ids in
                guard model.canBrowseSessions else { return }
                model.librarySelection = sessions.map(\.id).filter(ids.contains)
                if ids.count == 1, let item = sessions.first(where: { ids.contains($0.id) }) {
                    model.selectSession(item.summary)
                }
            }
        )) {
            ForEach(sessions) { item in
                sessionRow(item)
                    .padding(.horizontal, usesMonochromeControls ? 8 : 0)
                    .padding(.vertical, usesMonochromeControls ? 1 : 0)
                    .background {
                        if usesMonochromeControls && model.librarySelection.contains(item.id) { palette.surface }
                    }
                    .tag(item.id)
                    .listRowInsets(usesMonochromeControls ? EdgeInsets() : EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .disabled(!model.canBrowseSessions)
    }

    private func sessionRow(_ item: LibraryDisplayItem) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.summary.isDictation ? "waveform" : "doc.text")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.summary.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(2)
                        Text("\(item.dateText) · \(item.durationText)")
                            .font(.caption)
                            .foregroundStyle(palette.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if item.summary.hasRetainedAudio == true {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(palette.secondary)
                            .padding(.top, 3)
                            .help("Retained audio available")
                            .accessibilityLabel("Retained audio available")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.summary.title)
            .accessibilityValue("\(item.dateText), \(item.durationText)")
            .accessibilityIdentifier("clippy.library.session.\(item.id)")
            .help("Select this transcript. Shift-click for a range or Command-click to add a transcript.")
            .contextMenu {
                Button("Open Transcript") {
                    model.librarySelection = [item.id]
                    model.selectSession(item.summary)
                }
                Button("Copy Transcript") { model.copySession(item.summary) }
                Button("Reveal in Finder") { model.revealSession(item.summary) }
                    .disabled(item.summary.folderPath == nil)
                Divider()
                Button("Delete Recording…", role: .destructive) { deleteID = item.id }
            }
            if deleteID == item.id {
                InlineDeleteConfirmation(title: "Delete this transcript?", cancel: { deleteID = nil }) {
                    model.deleteSession(item.summary)
                    deleteID = nil
                }
                .padding(6)
            }
        }
    }

    private func refreshResults() async {
        let sessions = model.recentSessions
        let search = search
        let labelID = labelID
        let sort = sort
        let includeDictation = includeDictation
        let audioFilter = audioFilter
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        let filtered = await Task.detached(priority: .userInitiated) {
            TranscriptLibraryQuery.apply(
                to: sessions,
                search: search,
                labelID: labelID,
                sort: sort,
                includeDictation: includeDictation,
                audioFilter: audioFilter
            )
        }.value
        guard !Task.isCancelled else { return }
        availableLabels = Self.labels(from: includeDictation ? sessions : sessions.filter { !$0.isDictation })
        hasDictations = sessions.contains(where: \.isDictation)
        selectedSessionSummary = model.selectedSessionID.flatMap { id in
            sessions.first(where: { $0.id == id })
        }
        displayedSessions = filtered.map(LibraryDisplayItem.init)
        let selected = Set(model.librarySelection)
        model.librarySelection = filtered.map(\.id).filter(selected.contains)
        if model.librarySelection.isEmpty, let id = model.selectedSessionID, filtered.contains(where: { $0.id == id }) {
            model.librarySelection = [id]
        }
    }

    private func syncSelectedSummary() {
        selectedSessionSummary = model.selectedSessionID.flatMap { id in
            model.recentSessions.first(where: { $0.id == id })
        }
    }

    private func clearFilters() {
        search = ""
        labelID = nil
        showRetainedAudio = true
        showUnretainedAudio = true
    }

    private static func labels(from sessions: [SessionSummary]) -> [RecordingLabelSnapshot] {
        var seen: Set<UUID> = []
        return sessions.flatMap { $0.labels ?? [] }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct LibraryDisplayItem: Identifiable, Sendable {
    let summary: SessionSummary
    let dateText: String
    let durationText: String

    var id: UUID { summary.id }

    init(_ summary: SessionSummary) {
        self.summary = summary
        self.dateText = summary.createdAt.formatted(date: .abbreviated, time: .omitted)
        self.durationText = ProsodyFormatters.duration(summary.duration)
    }
}

/// Confirmation stays inside the content window, including NSStatusItem's
/// transient popover. No native alert can dismiss its own presenting surface.
struct InlineDeleteConfirmation: View {
    @Environment(\.prosodyPalette) private var palette
    let title: String
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.semibold))
            Text("The transcript, notes, and saved audio will be removed. This cannot be undone.")
                .font(.caption).foregroundStyle(palette.secondary)
            HStack {
                Button("Cancel", action: cancel)
                    .accessibilityIdentifier("clippy.delete.cancel")
                Spacer()
                Button("Delete Recording", action: confirm)
                    .accessibilityIdentifier("clippy.delete.confirm")
            }.buttonStyle(ThemedControlButtonStyle())
        }.padding(12).background(palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("clippy.delete.confirmation")
    }
}

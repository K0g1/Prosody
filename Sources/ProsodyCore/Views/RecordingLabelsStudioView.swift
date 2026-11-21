import AppKit
import SwiftUI

/// Inline label management. Drafts live here until the user explicitly saves,
/// so typing does not rewrite preferences one character at a time.
@MainActor
struct RecordingLabelsStudioView: View {
    @Environment(\.prosodyPalette) private var palette
    @Environment(RecordingLabelDraftStore.self) private var labelDrafts
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: ProsodyPreferences

    @State private var removing: RecordingLabel?
    @State private var folderError: String?
    @State private var exampleTitle = "Linear Algebra"
    @State private var previewDate = Date.now
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case colorHex
    }

    private static let nameControl = SettingsControl<Self>.custom(
        "clippy.settings.labels.name", "Label name",
        help: "Rename this label. Its saved recordings and folder keep the same label ID.",
        keywords: ["rename", "title", "name"]
    ) { pane, _ in
        pane.nameField
    }

    private static let colorControl = SettingsControl<Self>.custom(
        "clippy.settings.labels.color", "Label color",
        help: "Choose the swatch color used for this label in Prosody.",
        keywords: ["swatch", "hex", "palette"]
    ) { pane, _ in
        pane.colorField
    }

    private static let folderControl = SettingsControl<Self>.custom(
        "clippy.settings.labels.folder", "Save folder",
        help: "A custom folder applies to future recordings with this label. Use the default output folder to clear it.",
        keywords: ["destination", "directory", "output", "path", "choose folder"]
    ) { pane, _ in
        pane.folderField
    }

    private static let transcriptCopyControl = SettingsControl<Self>.custom(
        "clippy.settings.labels.transcript-copy", "Transcript Copies",
        keywords: ["export", "raw text", "markdown", "save transcript", "folder"]
    ) { pane, _ in
        if let draft = pane.selectedDraft { pane.transcriptCopyGroup(draft) }
    }

    static var searchEntries: [SettingsSearchEntry] {
        [nameControl.entry, colorControl.entry, folderControl.entry, transcriptCopyControl.entry]
    }

    private static let fieldSearchIDs = [
        "clippy.settings.labels.name",
        "clippy.settings.labels.color",
        "clippy.settings.labels.folder",
        "clippy.settings.labels.transcript-copy"
    ]

    init(model: AppModel) {
        self.model = model
        preferences = model.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader(title: "Labels")
                .settingsHelp("Select labels before recording. The first label controls the name and folder. Changes here apply to future recordings; saved recordings keep their label names, colors, and file locations.")

            ViewThatFits(in: .horizontal) {
                horizontalCard
                stackedCard
            }
        }
        .accessibilityIdentifier("clippy.settings.labels")
        .onAppear(perform: prepareSelection)
        .onChange(of: preferences.recordingLabels) { _, labels in
            synchronizeSelection(with: labels)
        }
        .alert("Delete \(removing?.name ?? "label")?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        )) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Delete Label", role: .destructive, action: deleteRemovingLabel)
        } message: {
            Text("Saved recordings and their labels will be kept. This removes the label from choices for future recordings.")
        }
    }

    private var horizontalCard: some View {
        HStack(spacing: 0) {
            libraryRail(stacked: false)
                .frame(width: 210)
            Divider()
            detailPane
                .frame(minWidth: 390, maxWidth: .infinity)
        }
        .frame(minWidth: 620)
        .prosodyPanel(padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: ProsodyDimensions.rowCornerRadius, style: .continuous))
    }

    private var stackedCard: some View {
        VStack(spacing: 0) {
            libraryRail(stacked: true)
            Divider()
            detailPane
        }
        .prosodyPanel(padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: ProsodyDimensions.rowCornerRadius, style: .continuous))
    }

    private func libraryRail(stacked: Bool) -> some View {
        let labels = libraryLabels
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SettingsGroupTitle(title: "Library")
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Button("Add Label", action: addLabel)
                    .buttonStyle(.borderless)
                    .foregroundStyle(palette.accent)
                    .accessibilityIdentifier("clippy.labels.new")
            }

            if labels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No labels yet")
                        .font(.callout.weight(.medium))
                    Text("Add a label to organize recordings.")
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(labels) { label in
                            labelRow(label)
                        }
                    }
                }
                .frame(minHeight: stacked ? 0 : 320, maxHeight: stacked ? 160 : .infinity)
                .accessibilityLabel("Label library")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(minHeight: stacked ? 0 : 420, maxHeight: stacked ? 210 : .infinity, alignment: .topLeading)
        .background(palette.sidebar.opacity(palette.dark ? 0.48 : 0.55))
    }

    private func labelRow(_ label: RecordingLabel) -> some View {
        let selected = labelDrafts.selectedID == label.id
        let dirty = hasUnsavedChanges(for: label)
        let displayName = label.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled label" : label.name
        return Button {
            select(label.id)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(labelHex: label.colorHex))
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if dirty {
                    Circle()
                        .fill(palette.accent)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? palette.accent : palette.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? palette.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(displayName)
        .accessibilityValue([selected ? "Selected" : nil, dirty ? "Unsaved changes" : nil]
            .compactMap { $0 }
            .joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("clippy.labels.row.\(label.id.uuidString)")
    }

    @ViewBuilder
    private var detailPane: some View {
        if let draft = selectedDraft, let id = labelDrafts.selectedID {
            detailForm(draft, id: id)
        } else {
            emptyDetail
        }
    }

    private func detailForm(_ draft: RecordingLabel, id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsGroupTitle(title: "Name")
                    .accessibilityAddTraits(.isHeader)
                Self.nameControl.render(in: self)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsGroupTitle(title: "Color")
                    .accessibilityAddTraits(.isHeader)
                Self.colorControl.render(in: self)
            }

            namingGroup(draft)

            VStack(alignment: .leading, spacing: 8) {
                SettingsGroupTitle(title: "Saving destination")
                    .accessibilityAddTraits(.isHeader)
                Self.folderControl.render(in: self)
            }

            Self.transcriptCopyControl.render(in: self)

            if !labelDrafts.newLabelIDs.contains(id) {
                dangerSection(draft)
            }

            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var emptyDetail: some View {
        let isEmpty = preferences.recordingLabels.isEmpty && labelDrafts.newLabelOrder.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            Text(isEmpty ? "No labels yet" : "Select a label")
                .font(.headline)
            Text(isEmpty
                 ? "Add a label to set its name, color, and save folder."
                 : "Choose a label from the library to edit it.")
                .font(.callout)
                .foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isEmpty {
                emptyAddLabelButton
                    .padding(.top, 6)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private var emptyAddLabelButton: some View {
        Button("Add Label", action: addLabel)
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Creates a label and moves focus to its name field.")
            .accessibilityIdentifier("clippy.labels.empty.add")
            .modifier(LabelSearchHighlight(ids: Set(Self.fieldSearchIDs)))
            .overlay {
                ZStack {
                    ForEach(Self.fieldSearchIDs, id: \.self) { id in
                        Color.clear
                            .frame(width: 1, height: 1)
                            .modifier(LabelSearchAnchor(id: id))
                    }
                }
                .allowsHitTesting(false)
            }
    }

    private var nameField: some View {
        TextField("Label name", text: nameBinding)
            .textFieldStyle(.roundedBorder)
            .focused($focusedField, equals: .name)
            .accessibilityIdentifier("clippy.label.name")
    }

    private var colorField: some View {
        HStack(spacing: 10) {
            ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Color")
            TextField("#5676D9", text: colorHexBinding)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .frame(width: 100)
                .focused($focusedField, equals: .colorHex)
                .accessibilityLabel("Hex color")
                .accessibilityIdentifier("clippy.label.color-hex")
        }
        .accessibilityIdentifier("clippy.label.color")
    }

    private var folderField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedDraft?.outputFolderPath == nil ? "Default output folder" : "Custom folder")
                .font(.system(size: 13, weight: .medium))
            Text(currentFolderPath)
                .font(.caption)
                .foregroundStyle(palette.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(currentFolderPath)
                .accessibilityIdentifier("clippy.label.folder.path")
            HStack(spacing: 8) {
                Button("Choose Folder…") { chooseFolder() }
                    .accessibilityLabel("Choose save folder for \(selectedDraft?.name ?? "label")")
                    .accessibilityIdentifier("clippy.label.folder.choose")
                    .help("Choose where future recordings with this label are saved.")
                if selectedDraft?.outputFolderPath != nil {
                    Button("Use Default Folder", action: resetFolder)
                        .accessibilityIdentifier("clippy.label.folder.reset")
                        .help("Use the default output folder instead of a folder just for this label.")
                }
            }
            if let folderError {
                Text(folderError)
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func namingGroup(_ draft: RecordingLabel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroupTitle(title: "Naming")
                .accessibilityAddTraits(.isHeader)
            Text("File naming pattern")
                .font(.caption)
                .foregroundStyle(palette.secondary)
            HStack(spacing: 8) {
                TextField("{date} - {title}", text: patternBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .accessibilityIdentifier("clippy.label.pattern")
                    .help("Use tokens such as {date}, {title}, {label}, and {time}.")
                    .accessibilityHint("Use tokens such as date, title, label, and time.")
                Menu("Insert") {
                    ForEach(RecordingNaming.tokens, id: \.self) { token in
                        Button(token) { appendToken(token) }
                    }
                }
                .fixedSize()
            }
            HStack(spacing: 8) {
                Text("Date format")
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                TextField("yyyy-MM-dd", text: dateFormatBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .accessibilityIdentifier("clippy.label.date-format")
                    .help("yyyy = year, MM = month, dd = day, and MMM = short month.")
                    .accessibilityHint("Use yyyy for year, MM for month, dd for day, and MMM for short month.")
                Menu("Examples") {
                    ForEach(["yyyy-MM-dd", "dd-MM-yyyy", "MMM d, yyyy", "yyyyMMdd"], id: \.self) { format in
                        Button(format) { setDateFormat(format) }
                    }
                }
                .fixedSize()
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.secondary)
                    Spacer(minLength: 8)
                    TextField("Example title", text: $exampleTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        .accessibilityLabel("Preview recording title")
                }
                Text(preview)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(RecordingNaming.transcriptFileName(for: preview))
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .prosodyPanel(padding: 10)
        }
    }

    private func dangerSection(_ label: RecordingLabel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Delete label")
                        .font(.system(size: 13, weight: .medium))
                    Text("Saved recordings keep their label and files.")
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 12)
                Button("Delete Label", role: .destructive) { removing = label }
                    .accessibilityLabel("Delete label \(label.name)")
                    .accessibilityIdentifier("clippy.labels.delete")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = validation {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isDirty {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(isNew ? "Cancel" : "Discard Changes", action: revertDraft)
                    .disabled(!isDirty)
                Button(isNew ? "Create Label" : "Save Changes", action: saveDraft)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validation != nil || !isDirty)
                    .accessibilityIdentifier("clippy.label.save")
            }
        }
    }

    private var libraryLabels: [RecordingLabel] {
        preferences.recordingLabels.map { labelDrafts.drafts[$0.id] ?? $0 }
            + labelDrafts.newLabelOrder.compactMap { labelDrafts.drafts[$0] }
    }

    private var selectedDraft: RecordingLabel? {
        guard let selectedID = labelDrafts.selectedID else { return nil }
        return labelDrafts.drafts[selectedID] ?? preferences.recordingLabels.first { $0.id == selectedID }
    }

    private var currentFolderPath: String {
        selectedDraft?.outputFolderPath ?? preferences.outputFolderPath
    }

    private var isNew: Bool {
        labelDrafts.selectedID.map(labelDrafts.newLabelIDs.contains) ?? false
    }

    private var isDirty: Bool {
        guard let id = labelDrafts.selectedID, let draft = labelDrafts.drafts[id] else { return false }
        if labelDrafts.newLabelIDs.contains(id) { return true }
        if labelDrafts.bookmarks[id] != nil || labelDrafts.transcriptBookmarks[id] != nil { return true }
        return preferences.recordingLabels.first { $0.id == id } != draft
    }

    private func hasUnsavedChanges(for label: RecordingLabel) -> Bool {
        if labelDrafts.newLabelIDs.contains(label.id) { return true }
        guard let draft = labelDrafts.drafts[label.id] else { return false }
        if labelDrafts.bookmarks[label.id] != nil || labelDrafts.transcriptBookmarks[label.id] != nil { return true }
        return preferences.recordingLabels.first { $0.id == label.id } != draft
    }

    private var validation: String? {
        guard let draft = selectedDraft, let id = labelDrafts.selectedID else { return nil }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give this label a name." }
        if name.count > 80 { return "Keep label names under 81 characters." }
        if draft.colorHex.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) == nil {
            return "Use a six-digit hex color, such as #5676D9."
        }
        if preferences.recordingLabels.contains(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return "A label with this name already exists."
        }
        if draft.namingPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a naming pattern."
        }
        let unknown = RecordingNaming.unknownTokens(in: draft.namingPattern)
        if !unknown.isEmpty { return "Unknown tokens: " + unknown.joined(separator: ", ") }
        if draft.dateFormat.isEmpty && draft.namingPattern.contains("{date}") {
            return "Enter a date format for {date}."
        }
        return nil
    }

    private var preview: String {
        guard let draft = selectedDraft else { return "" }
        return RecordingNaming.title(
            pattern: draft.namingPattern,
            title: exampleTitle,
            label: draft.name,
            date: previewDate,
            id: draft.id,
            dateFormat: draft.dateFormat
        )
    }

    private var nameBinding: Binding<String> { stringBinding(\.name) }
    private var colorHexBinding: Binding<String> { stringBinding(\.colorHex) }
    private var patternBinding: Binding<String> { stringBinding(\.namingPattern) }
    private var dateFormatBinding: Binding<String> { stringBinding(\.dateFormat) }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(labelHex: selectedDraft?.colorHex ?? "#808080") },
            set: { newColor in
                updateSelectedDraft { $0.colorHex = newColor.labelHex }
            }
        )
    }

    private func stringBinding(_ keyPath: WritableKeyPath<RecordingLabel, String>) -> Binding<String> {
        Binding(
            get: { selectedDraft.map { $0[keyPath: keyPath] } ?? "" },
            set: { newValue in
                updateSelectedDraft { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func updateSelectedDraft(_ update: (inout RecordingLabel) -> Void) {
        guard let selectedID = labelDrafts.selectedID, var draft = selectedDraft else { return }
        update(&draft)
        labelDrafts.drafts[selectedID] = draft
    }

    private func prepareSelection() {
        synchronizeSelection(with: preferences.recordingLabels)
    }

    private func synchronizeSelection(with labels: [RecordingLabel]) {
        let persistedIDs = Set(labels.map(\.id))
        let validIDs = persistedIDs.union(labelDrafts.newLabelIDs)
        labelDrafts.drafts = labelDrafts.drafts.filter { validIDs.contains($0.key) }
        labelDrafts.bookmarks = labelDrafts.bookmarks.filter { validIDs.contains($0.key) }
        labelDrafts.transcriptBookmarks = labelDrafts.transcriptBookmarks.filter { validIDs.contains($0.key) }
        labelDrafts.newLabelOrder.removeAll { !labelDrafts.newLabelIDs.contains($0) }
        if let selectedID = labelDrafts.selectedID, !validIDs.contains(selectedID) {
            labelDrafts.selectedID = labels.first?.id
        } else if labelDrafts.selectedID == nil {
            labelDrafts.selectedID = labels.first?.id
        }
    }

    private func select(_ id: UUID) {
        labelDrafts.selectedID = id
        folderError = nil
        focusedField = nil
    }

    private func addLabel() {
        if let selectedID = labelDrafts.selectedID, !labelDrafts.newLabelIDs.contains(selectedID) {
            labelDrafts.selectionBeforeNew = selectedID
        }
        let label = RecordingLabel()
        labelDrafts.drafts[label.id] = label
        labelDrafts.newLabelIDs.insert(label.id)
        labelDrafts.newLabelOrder.append(label.id)
        labelDrafts.selectedID = label.id
        folderError = nil
        Task { @MainActor in focusedField = .name }
    }

    private func appendToken(_ token: String) {
        updateSelectedDraft { $0.namingPattern += token }
    }

    private func setDateFormat(_ format: String) {
        updateSelectedDraft { $0.dateFormat = format }
    }

    private func saveDraft() {
        guard let id = labelDrafts.selectedID, let draft = selectedDraft, validation == nil else { return }
        model.saveRecordingLabel(draft, bookmarkData: labelDrafts.bookmarks[id], transcriptBookmarkData: labelDrafts.transcriptBookmarks[id])
        labelDrafts.drafts[id] = nil
        labelDrafts.bookmarks[id] = nil
        labelDrafts.transcriptBookmarks[id] = nil
        if labelDrafts.newLabelIDs.contains(id) { labelDrafts.selectionBeforeNew = nil }
        labelDrafts.newLabelIDs.remove(id)
        labelDrafts.newLabelOrder.removeAll { $0 == id }
        folderError = nil
        focusedField = nil
    }

    private func revertDraft() {
        guard let id = labelDrafts.selectedID else { return }
        if labelDrafts.newLabelIDs.contains(id) {
            cancelNewLabel(id)
        } else {
            labelDrafts.drafts[id] = nil
            labelDrafts.bookmarks[id] = nil
            labelDrafts.transcriptBookmarks[id] = nil
            folderError = nil
        }
    }

    private func cancelNewLabel(_ id: UUID) {
        labelDrafts.drafts[id] = nil
        labelDrafts.bookmarks[id] = nil
        labelDrafts.transcriptBookmarks[id] = nil
        labelDrafts.newLabelIDs.remove(id)
        labelDrafts.newLabelOrder.removeAll { $0 == id }
        if labelDrafts.selectedID == id {
            labelDrafts.selectedID = labelDrafts.selectionBeforeNew.flatMap { candidate in
                preferences.recordingLabels.contains { $0.id == candidate } ? candidate : nil
            } ?? preferences.recordingLabels.first?.id
        }
        labelDrafts.selectionBeforeNew = nil
        folderError = nil
    }

    private func transcriptCopyGroup(_ draft: RecordingLabel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroupTitle(title: "Transcript Copies")
            Text("Save a separate copy when a new transcript has this label.")
                .font(.caption).foregroundStyle(palette.secondary)
            HStack {
                Text(draft.transcriptCopy?.folderPath ?? "No copy folder selected")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose Folder…") { chooseFolder(forTranscript: true) }
                    .help("Choose where to save a transcript-only copy")
                if draft.transcriptCopy != nil {
                    Button("Remove") {
                        updateSelectedDraft { $0.transcriptCopy = nil }
                        if let id = labelDrafts.selectedID { labelDrafts.transcriptBookmarks[id] = nil }
                    }
                        .help("Stop saving separate transcript copies for this label")
                }
            }
            if let copy = draft.transcriptCopy {
                Picker("Copy Format", selection: Binding(
                    get: { selectedDraft?.transcriptCopy?.format ?? copy.format },
                    set: { format in updateSelectedDraft { $0.transcriptCopy?.format = format } }
                )) {
                    ForEach(TranscriptCopyFormat.allCases) { Text($0.title).tag($0) }
                }
                .help("Text-only Markdown and Raw Text include speech without timestamps or metadata")
            }
            if let folderError {
                Text(folderError).font(.caption).foregroundStyle(palette.secondary)
            }
        }
    }

    private func chooseFolder(forTranscript: Bool = false) {
        guard let id = labelDrafts.selectedID else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = forTranscript
            ? "Choose a folder for transcript copies with this label."
            : "Choose the save folder for recordings with this label."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try SecurityScopedFolder.bookmarkData(for: url)
            if forTranscript {
                updateSelectedDraft {
                    $0.transcriptCopy = LabelTranscriptCopy(folderPath: url.path, format: $0.transcriptCopy?.format ?? .markdown)
                }
                labelDrafts.transcriptBookmarks[id] = data
            } else {
                updateSelectedDraft { $0.outputFolderPath = url.path }
                labelDrafts.bookmarks[id] = data
            }
            folderError = nil
        } catch {
            folderError = error.localizedDescription
        }
    }

    private func resetFolder() {
        updateSelectedDraft { $0.outputFolderPath = nil }
        if let selectedID = labelDrafts.selectedID { labelDrafts.bookmarks[selectedID] = nil }
        folderError = nil
    }

    private func deleteRemovingLabel() {
        guard let label = removing else { return }
        let id = label.id
        labelDrafts.drafts[id] = nil
        labelDrafts.bookmarks[id] = nil
        labelDrafts.transcriptBookmarks[id] = nil
        labelDrafts.newLabelIDs.remove(id)
        labelDrafts.newLabelOrder.removeAll { $0 == id }
        labelDrafts.selectionBeforeNew = nil
        model.removeRecordingLabel(id: id)
        if labelDrafts.selectedID == id { labelDrafts.selectedID = preferences.recordingLabels.first?.id }
        removing = nil
        folderError = nil
    }
}

private struct LabelSearchAnchor: ViewModifier {
    @Environment(\.settingsSearchRequest) private var request
    let id: String

    func body(content: Content) -> some View {
        let match = request.flatMap { $0.id.control == id ? $0 : nil }
        content
            .id(id)
            .anchorPreference(key: SettingsSearchReadyKey.self, value: .bounds) { _ in
                match.map { SettingsSearchReady(request: $0, anchor: .center) }
            }
    }
}

private struct LabelSearchHighlight: ViewModifier {
    @Environment(\.settingsSearchRequest) private var request
    @Environment(\.prosodyPalette) private var palette
    let ids: Set<String>

    func body(content: Content) -> some View {
        content.overlay {
            if let request, ids.contains(request.id.control) {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(palette.accent, lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

import AppKit
import SwiftUI

extension Color {
    init(labelHex: String) {
        let value = UInt32(labelHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x5676D9
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }

    var labelHex: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#5676D9" }
        return String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
}

struct RecordingLabelBadge: View {
    let label: RecordingLabelSnapshot
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Color(labelHex: label.colorHex)).frame(width: 8, height: 8)
            Text(label.name).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color(labelHex: label.colorHex).opacity(0.12), in: Capsule())
        .accessibilityLabel("Label: \(label.name)")
    }
}

struct RecordingLabelBadges: View {
    let labels: [RecordingLabelSnapshot]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) { ForEach(labels) { RecordingLabelBadge(label: $0) } }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct RecordingLabelsSettingsView: View {
    @ObservedObject var model: AppModel

    init(model: AppModel) { self.model = model }

    var body: some View {
        RecordingLabelsStudioView(model: model)
    }
}

struct RecordingLabelEditor: View {
    @Environment(\.prosodyPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State var label: RecordingLabel
    let existingNames: [String]
    let save: (RecordingLabel, Data?) -> Void
    @State private var bookmarkData: Data?
    @State private var error: String?
    @State private var exampleTitle = "Linear Algebra"
    @State private var previewDate = Date.now

    private var validation: String? {
        let name = label.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give this label a name." }
        if name.count > 80 { return "Keep label names under 81 characters." }
        if label.colorHex.range(of: #"^#[0-9a-fA-F]{6}$"#, options: .regularExpression) == nil { return "Use a six-digit hex color, such as #5676D9." }
        if existingNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return "A label with this name already exists." }
        if label.namingPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a naming pattern." }
        let unknown = RecordingNaming.unknownTokens(in: label.namingPattern)
        if !unknown.isEmpty { return "Unknown tokens: " + unknown.joined(separator: ", ") }
        if label.dateFormat.isEmpty && label.namingPattern.contains("{date}") { return "Enter a date format for {date}." }
        return nil
    }

    private var preview: String {
        RecordingNaming.title(pattern: label.namingPattern, title: exampleTitle, label: label.name, date: previewDate, id: label.id, dateFormat: label.dateFormat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Label").font(.title2.weight(.semibold))
            HStack {
                TextField("Label name", text: $label.name).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("clippy.label.name")
                ColorPicker("Color", selection: Binding(get: { Color(labelHex: label.colorHex) }, set: { label.colorHex = $0.labelHex }), supportsOpacity: false)
                    .fixedSize().accessibilityIdentifier("clippy.label.color")
                TextField("#5676D9", text: $label.colorHex).textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced()).frame(width: 86).accessibilityLabel("Color hex code")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Save folder").font(.headline)
                HStack {
                    Text(label.outputFolderPath ?? "Use default output folder").font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                    if label.outputFolderPath != nil { Button("Reset") { label.outputFolderPath = nil; bookmarkData = nil } }
                }
                Text("Each recording gets its own folder for the transcript, notes, and optional audio.").font(.caption).foregroundStyle(palette.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recording name & Markdown filename").font(.headline)
                    Spacer()
                    Menu("Presets") {
                        Button("Title only") { label.namingPattern = "{title}" }
                        Button("Date · Title") { label.namingPattern = "{date} - {title}" }
                        Button("Label · Date · Title") { label.namingPattern = "{label} - {date} - {title}" }
                        Button("Date · Time") { label.namingPattern = "{date}_{time}" }
                    }.fixedSize()
                }
                TextField("{date} - {title}", text: $label.namingPattern).textFieldStyle(.roundedBorder)
                    .font(.body.monospaced()).accessibilityIdentifier("clippy.label.pattern")
                HStack {
                    Text("Insert:").font(.caption).foregroundStyle(palette.secondary)
                    ForEach(RecordingNaming.tokens, id: \.self) { token in
                        Button(token) { label.namingPattern += token }.font(.system(size: 10, design: .monospaced)).buttonStyle(.borderless)
                    }
                }
                HStack {
                    Text("Date format").font(.callout)
                    TextField("yyyy-MM-dd", text: $label.dateFormat).textFieldStyle(.roundedBorder).frame(width: 160)
                        .accessibilityIdentifier("clippy.label.date-format")
                    Menu("Examples") {
                        ForEach(["yyyy-MM-dd", "dd-MM-yyyy", "MMM d, yyyy", "yyyyMMdd"], id: \.self) { format in
                            Button(format) { label.dateFormat = format }
                        }
                    }.fixedSize()
                }
                Text("yyyy = year · MM = month · dd = day · MMM = short month. Dates use local time; {time} uses HH-mm-ss.")
                    .font(.caption).foregroundStyle(palette.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("LIVE PREVIEW").font(.caption.weight(.semibold)).foregroundStyle(palette.secondary)
                    Spacer()
                    TextField("Example title", text: $exampleTitle).textFieldStyle(.roundedBorder).frame(width: 180)
                        .accessibilityLabel("Preview recording title")
                }
                RecordingLabelBadge(label: label.snapshot)
                Text(preview).font(.headline).lineLimit(2).textSelection(.enabled)
                Text(RecordingNaming.transcriptFileName(for: preview)).font(.callout.monospaced()).foregroundStyle(palette.secondary).lineLimit(2).textSelection(.enabled)
            }.prosodyPanel(padding: 14)
            if let message = validation ?? error {
                Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(palette.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Label") { save(label, bookmarkData); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(validation != nil).accessibilityIdentifier("clippy.label.save")
            }
        }
        .padding(24).frame(width: 650)
        .background { ThemeBackground(palette: palette) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the save folder for recordings with this primary label."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try SecurityScopedFolder.bookmarkData(for: url)
            label.outputFolderPath = url.path
            bookmarkData = data
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct RecordingLabelSelectionView: View {
    @Environment(\.prosodyPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var preferences: ProsodyPreferences
    @Binding var selection: [RecordingLabelSnapshot]
    var forNewRecording = true
    let model: AppModel
    @State private var newLabel: RecordingLabel?
    @State private var previewDate = Date.now

    private var choices: [RecordingLabelSnapshot] {
        let catalog = preferences.recordingLabels.map { label in
            selection.first(where: { $0.id == label.id }) ?? label.snapshot
        }
        return catalog + selection.filter { saved in !catalog.contains { $0.id == saved.id } }
    }

    private var filenamePreview: String? {
        guard let primaryID = selection.first?.id,
              let label = preferences.recordingLabels.first(where: { $0.id == primaryID }) else { return nil }
        let title = RecordingNaming.title(pattern: label.namingPattern, title: model.recordingTitle,
            label: label.name, date: previewDate, id: label.id, dateFormat: label.dateFormat)
        return RecordingNaming.transcriptFileName(for: title)
    }

    var body: some View {
        let choices = choices
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recording labels").font(.headline)
                Spacer(minLength: 8)
                Button { newLabel = RecordingLabel() } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Create label")
                .accessibilityIdentifier("clippy.recording.labels.create")
            }

            if choices.isEmpty {
                Text("No labels yet.")
                    .font(.callout)
                    .foregroundStyle(palette.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(choices) { label in
                            selectionRow(label)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(height: min(CGFloat(choices.count) * 29, 174))
            }

            if forNewRecording {
                Divider()
                HStack(spacing: 8) {
                    Text("Filename").font(.caption.weight(.medium)).fixedSize()
                    Text(filenamePreview ?? "Uses recording title")
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 17)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("clippy.recording.labels.filename")

                HStack {
                    Spacer(minLength: 4)
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .frame(height: 22)
            } else {
                Text("Updates the labels in Markdown. Files keep their existing names and locations.")
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: forNewRecording ? 320 : 350)
        .preferredColorScheme(forNewRecording && !preferences.theme.isAdaptive ? (palette.dark ? .dark : .light) : nil)
        .background {
            if forNewRecording {
                ThemeBackground(palette: palette, isAdaptive: preferences.theme.isAdaptive, backdrop: .systemPopover)
            } else {
                ThemeBackground(palette: palette)
            }
        }
        .sheet(item: $newLabel) { label in
            RecordingLabelEditor(label: label, existingNames: preferences.recordingLabels.map(\.name)) { label, bookmark in
                model.saveRecordingLabel(label, bookmarkData: bookmark)
                selection.append(label.snapshot)
            }
        }
    }

    private func selectionRow(_ label: RecordingLabelSnapshot) -> some View {
        let isSelected = selection.contains { $0.id == label.id }
        let isPrimary = selection.first?.id == label.id
        return HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { selection.contains { $0.id == label.id } }, set: { enabled in
                if enabled {
                    selection.append(label)
                } else {
                    selection.removeAll { $0.id == label.id }
                }
            })) {
                RecordingLabelBadge(label: label)
                    .truncationMode(.middle)
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel(label.name)
            .accessibilityIdentifier("clippy.recording.labels.choice.\(label.id.uuidString)")

            Spacer(minLength: 4)
            if forNewRecording {
                Group {
                    if isPrimary {
                        Text("Primary")
                            .foregroundStyle(palette.secondary)
                            .accessibilityLabel("\(label.name), primary label")
                    } else if isSelected {
                        Button("Make Primary") {
                            selection = [label] + selection.filter { $0.id != label.id }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Make \(label.name) primary")
                        .accessibilityIdentifier("clippy.recording.labels.primary.\(label.id.uuidString)")
                    } else {
                        Color.clear.accessibilityHidden(true)
                    }
                }
                .font(.caption)
                .frame(width: 84, height: 22, alignment: .trailing)
            }
        }
        .frame(height: 27)
    }
}

struct NextRecordingLabelsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: ProsodyPreferences
    @State private var showing = false

    init(model: AppModel) {
        self.model = model
        self.preferences = model.preferences
    }

    private var selection: Binding<[RecordingLabelSnapshot]> {
        Binding(
            get: { preferences.selectedRecordingLabels.map(\.snapshot) },
            set: { preferences.selectedRecordingLabelIDs = $0.map(\.id) }
        )
    }

    var body: some View {
        let labels = preferences.selectedRecordingLabels
        Button { showing.toggle() } label: {
            MenuBarOptionLabel(title: "Labels", systemImage: "tag", accessory: "chevron.right") {
                Group {
                    if let primary = labels.first {
                        HStack(spacing: 6) {
                            RecordingLabelBadge(label: primary.snapshot)
                                .truncationMode(.middle)
                            if labels.count > 1 {
                                Text("+\(labels.count - 1)")
                                    .font(.caption.monospacedDigit())
                                    .fixedSize()
                            }
                        }
                    } else {
                        Text("None")
                    }
                }
                .frame(width: 170, alignment: .trailing)
            }
        }
        .buttonStyle(.borderless)
        // Empty, single, and multiple selections all occupy the same row.
        .frame(height: 28)
        .accessibilityLabel("Labels")
        .accessibilityValue(accessibilitySummary(labels))
        .accessibilityIdentifier("clippy.recording.labels")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            RecordingLabelSelectionView(preferences: preferences, selection: selection, model: model)
        }
    }

    private func accessibilitySummary(_ labels: [RecordingLabel]) -> String {
        guard let primary = labels.first else { return "None selected" }
        let more = labels.count - 1
        return more == 0 ? "Primary: \(primary.name)" : "Primary: \(primary.name), \(more) more selected"
    }
}

struct SavedRecordingLabelsView: View {
    @ObservedObject var model: AppModel
    @State private var showing = false
    @State private var draft: [RecordingLabelSnapshot] = []
    var body: some View {
        HStack {
            Button {
                draft = model.selectedSessionLabels
                showing = true
            } label: { Label("Labels", systemImage: "tag") }.buttonStyle(.borderless)
                .disabled(!model.canBrowseSessions || model.activeSession?.id != model.selectedSessionID || model.activeSession?.status != "completed")
                .accessibilityIdentifier("clippy.transcript.labels")
                .popover(isPresented: $showing) {
                    VStack(spacing: 0) {
                        RecordingLabelSelectionView(preferences: model.preferences, selection: $draft, forNewRecording: false, model: model)
                        HStack {
                            Spacer()
                            Button("Cancel") { showing = false }
                            Button("Save Labels") { model.setSessionLabels(draft); showing = false }.buttonStyle(.borderedProminent)
                        }.padding([.horizontal, .bottom], 16)
                    }
                }
            RecordingLabelBadges(labels: model.selectedSessionLabels)
        }
        .frame(height: 26, alignment: .leading)
    }
}

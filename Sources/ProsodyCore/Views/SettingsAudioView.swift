@preconcurrency import AVFoundation
import SwiftUI

struct AudioSettingsView: GroupedSettingsSearchPage {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: ProsodyPreferences
    @State private var requestingPermissions = false
    @State private var microphones: [String] = []

    private static let capture = SettingsControlGroup<Self>("Capture", controls: [
        .init("clippy.settings.audio.source", "Default source",
              keywords: CaptureMode.allCases.map(\.displayName) + ["capture", "input"]) { pane, entry in
            Picker(entry.title, selection: pane.$preferences.captureMode) {
                ForEach(CaptureMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden().pickerStyle(.menu)
        },
        .init("clippy.settings.audio.microphone", "Microphone",
              help: "Used when Microphone or System + Mic is selected.",
              keywords: ["mic", "input device"]) { pane, entry in
            Picker(entry.title, selection: pane.$preferences.microphoneName) {
                Text("System Default").tag("System Default")
                ForEach(pane.microphones, id: \.self) { name in Text(name).tag(name) }
            }
            .labelsHidden().pickerStyle(.menu)
        }
    ])

    private static let recording = SettingsControlGroup<Self>("Recording", controls: [
        .init("clippy.settings.audio.keep-original", "Keep original audio",
              help: "Keep the source audio for playback in Transcripts.",
              keywords: ["save recording", "retain audio"]) { pane, entry in
            Toggle(entry.title, isOn: pane.$preferences.keepAudio)
                .labelsHidden().toggleStyle(.prosodySwitch)
        },
        .init("clippy.settings.audio.quality", "Recording quality",
              help: "Efficient uses less disk space; High preserves more detail.",
              keywords: ["bitrate", "compression"]) { pane, entry in
            Picker(entry.title, selection: pane.$preferences.recordingQuality) {
                Text("Efficient").tag("efficient")
                Text("High").tag("high")
            }
            .labelsHidden().pickerStyle(.menu)
        }
    ])

    private static let permissions = SettingsControlGroup<Self>(controls: [
        .init("clippy.settings.audio.permissions", "Capture permissions",
              help: "Ask macOS for the permissions required by the selected source.",
              keywords: ["screen recording", "microphone permission", "request permissions"],
              context: "System audio requires Screen Recording permission. Microphone capture requires Microphone permission.") { pane, entry in
            Button(pane.requestingPermissions ? "Requesting…" : "Request Permissions") {
                pane.requestPermissions()
            }
            .buttonStyle(.borderedProminent)
            .disabled(pane.requestingPermissions)
            .accessibilityIdentifier("clippy.settings.audio.request-permissions")
        }
    ])

    static let groups = [capture, recording, permissions]

    init(model: AppModel) {
        self.model = model
        self.preferences = model.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsPageHeader(title: "Audio")
            renderGroups()
        }
        .onAppear {
            microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
                .devices.map(\.localizedName)
        }
    }

    private func requestPermissions() {
        requestingPermissions = true
        Task { @MainActor in
            await model.requestPermissionsForCurrentCaptureMode()
            requestingPermissions = false
        }
    }
}

import SwiftUI

struct MenuBarStatusHeader: View {
    @Environment(\.prosodyPalette) private var palette
    @ObservedObject var model: AppModel
    let showsBrand: Bool
    @State private var isPreparingSpeechModel = false

    private var state: RecordingState { model.recordingState }

    private var showsSpeechModelPreparation: Bool {
        guard isPreparingSpeechModel else { return false }
        switch state {
        case .idle, .completed:
            return true
        case .preparing, .recording, .paused, .stopping, .finalizingTranscript,
             .diarizing, .generatingNotes, .failed:
            return false
        }
    }

    private var title: String {
        if showsSpeechModelPreparation { return "Preparing speech model…" }
        return switch state {
        case .idle, .completed: model.dictation.isActive ? "Dictation in progress" : "Ready"
        default: state.statusTitle
        }
    }

    private var indicator: Color {
        switch state {
        case .recording: .red
        case .paused, .failed: .orange
        default: palette.accent
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if showsBrand {
                MenuBarBrand()
                Spacer(minLength: 4)
            }
            HStack(spacing: 6) {
                if showsSpeechModelPreparation {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 28)
                        .tint(palette.accent)
                        .accessibilityLabel("Preparing speech model…")
                        .accessibilityIdentifier("clippy.speech-model-preparation")
                } else {
                    Circle()
                        .fill(indicator)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel("Status: \(title)")
            }
            .foregroundStyle(palette.text)
            .accessibilityElement(children: .contain)

            if !showsBrand { Spacer(minLength: 4) }

            if state == .recording {
                RecordingTimerView(model: model)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize()
            } else if state == .paused {
                let duration = ProsodyFormatters.duration(model.currentDuration)
                Text(duration)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(palette.secondary)
                    .fixedSize()
                    .accessibilityLabel("Recording duration")
                    .accessibilityValue(duration)
                    .accessibilityIdentifier("clippy.recording-timer")
            }

            if model.demoMode {
                Text("Demo")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(palette.surface, in: Capsule())
                    .fixedSize()
                    .accessibilityLabel("Demo mode: sample audio and temporary history")
            }
        }
        .frame(minHeight: 26)
        .task {
            isPreparingSpeechModel = false
            let updates = await model.dictation.modelPreparationUpdates()
            for await isPreparing in updates {
                guard !Task.isCancelled else { return }
                isPreparingSpeechModel = isPreparing
            }
            guard !Task.isCancelled else { return }
            isPreparingSpeechModel = false
        }
        .onDisappear {
            isPreparingSpeechModel = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(state.isRecording ? "clippy.recording.header" : "clippy.menu.header")
    }
}

struct MenuBarBrand: View {
    var body: some View {
        HStack(spacing: 7) {
            ProsodyLogoView(size: 24)
                .accessibilityHidden(true)
            Text(AppConstants.applicationName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
        }
        .fixedSize()
    }
}

struct MenuBarRecordingActions: View {
    @Environment(\.prosodyPalette) private var palette
    @ObservedObject var model: AppModel

    private var state: RecordingState { model.recordingState }

    var body: some View {
        switch state {
        case .idle, .completed:
            Button("Start Recording", systemImage: "record.circle") { model.startRecording() }
                .buttonStyle(MenuBarActionStyle())
                .disabled(!model.canToggleRecording)
                .accessibilityIdentifier("clippy.start-recording")
        case .recording, .paused:
            let paused = state == .paused
            HStack(spacing: 7) {
                Button(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill") {
                    model.toggleRecording()
                }
                .buttonStyle(MenuBarActionStyle(prominent: paused))
                .disabled(!model.canToggleRecording)
                .accessibilityIdentifier(paused ? "clippy.resume-recording" : "clippy.pause-resume")

                Button("Finish", systemImage: "stop.fill") { model.finishRecording() }
                    .buttonStyle(MenuBarActionStyle(prominent: !paused))
                    .disabled(!model.canFinishRecording)
                    .accessibilityIdentifier("clippy.finish-recording")
            }
        case .failed:
            Button("Try Again", systemImage: "arrow.clockwise") { model.retryLastFailure() }
                .buttonStyle(MenuBarActionStyle())
                .disabled(!model.canToggleRecording)
                .accessibilityIdentifier("clippy.retry")
        case .preparing(.loadingModel(let progress)):
            progressBar(progress)
        case .diarizing(let progress), .generatingNotes(let progress):
            progressBar(progress)
        case .preparing, .stopping, .finalizingTranscript:
            progressBar(nil)
        }
    }

    @ViewBuilder
    private func progressBar(_ progress: Double?) -> some View {
        Group {
            if let progress {
                ProgressView(value: progress)
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .tint(palette.accent)
        .accessibilityLabel(state.statusTitle)
        .accessibilityIdentifier("clippy.processing")
    }
}

private struct MenuBarActionStyle: ButtonStyle {
    @Environment(\.prosodyPalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? palette.onAccent : palette.text)
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: 33)
            .background(prominent ? palette.accent : palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if !prominent { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.border) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(!isEnabled ? 0.46 : configuration.isPressed ? 0.76 : 1)
    }
}

struct MenuBarCapturePreview: View {
    @Environment(\.prosodyPalette) private var palette
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.recordingState == .recording {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach((model.activeSession?.captureMode ?? model.preferences.captureMode).sources) { source in
                        AudioMeterView(
                            title: source == .system ? "System" : "Mic",
                            level: source == .system ? model.systemMeter : model.microphoneMeter
                        )
                    }
                }
                .accessibilityIdentifier("clippy.recording.meters")
            }

            if model.activeSession?.liveTranscriptionEnabled != false {
                let latest = model.liveSegments.last { !$0.isEchoDuplicate }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live transcript")
                        .font(.system(size: 11, weight: .semibold))
                    Text(latest?.text ?? "Waiting for speech…")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(2, reservesSpace: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .prosodyPanel(padding: 7)
                .accessibilityIdentifier("clippy.live-transcript")
            } else {
                Label("Saving audio · transcript after Finish", systemImage: "waveform")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

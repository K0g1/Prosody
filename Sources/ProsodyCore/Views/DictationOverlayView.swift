import SwiftUI

enum DictationOverlayLayout {
    case standard, minimal, result

    init(state: DictationState, appearance: DictationOverlayAppearance) {
        if state == .result { self = .result }
        else { self = appearance == .minimal ? .minimal : .standard }
    }

    var size: CGSize {
        switch self {
        case .standard: CGSize(width: 340, height: 86)
        case .minimal: CGSize(width: 116, height: 36)
        case .result: CGSize(width: 440, height: 220)
        }
    }

    var cornerRadius: CGFloat { self == .minimal ? size.height / 2 : 22 }
}

struct DictationOverlayView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var preferences: ProsodyPreferences

    var body: some View {
        let layout = DictationOverlayLayout(state: controller.state, appearance: preferences.dictationOverlayAppearance)
        let palette = preferences.theme.palette
        let shape = RoundedRectangle(cornerRadius: layout.cornerRadius)
        ThemedRoot(preferences: preferences) {
            Group {
                if layout == .minimal { minimalOverlay }
                else { fullOverlay.padding(18) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: layout == .minimal ? .center : .topLeading)
            .background(palette.surface.opacity(layout == .minimal ? 0.8 : 0.6), in: shape)
            .overlay { shape.strokeBorder(layout == .minimal ? palette.border : palette.secondary.opacity(0.12)) }
        }
        .clipShape(shape)
        .accessibilityIdentifier("clippy.dictation.overlay")
    }

    @ViewBuilder private var minimalOverlay: some View {
        if controller.state == .listening {
            DictationWaveformView(meter: controller.meter, compact: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Dictation")
                .accessibilityValue(controller.message)
        } else {
            Text(controller.state == .transcribing ? "Transcribing…" : "Preparing…")
                .font(.caption.weight(.medium))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Dictation")
                .accessibilityValue(controller.message)
        }
    }

    private var fullOverlay: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if controller.state == .listening {
                    DictationWaveformView(meter: controller.meter)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Microphone level")
                } else { Image(systemName: controller.state == .result ? "text.bubble" : "waveform").font(.title3) }
                Text(controller.message).font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if controller.canFinish {
                    Button { controller.finish() } label: { Image(systemName: "stop.fill") }
                        .accessibilityLabel("Finish dictation")
                }
                Button { controller.dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Cancel dictation")
                    .accessibilityIdentifier("clippy.dictation.cancel")
            }
            if controller.state == .result, !controller.resultText.isEmpty {
                ScrollView { Text(controller.resultText).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
                Button("Copy Text", systemImage: "doc.on.doc") { controller.copyResult() }
                    .accessibilityIdentifier("clippy.dictation.copy")
            }
        }
        .buttonStyle(.borderless)
    }
}

private struct DictationWaveformView: View {
    @Environment(\.prosodyPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let meter: MeterLevel
    var compact = false

    var body: some View {
        let bars = DictationWaveform.bars(rms: meter.rms, peak: meter.peak)
        HStack(spacing: 3) {
            ForEach(bars.indices, id: \.self) { index in
                Capsule().fill(palette.accentGradient)
                    .frame(width: compact ? 2 : 3, height: bars[index] * (compact ? 0.5 : 1))
            }
        }
        .frame(width: compact ? nil : 100, height: compact ? 24 : 48)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: meter)
    }
}

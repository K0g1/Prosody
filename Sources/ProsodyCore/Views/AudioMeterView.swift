import SwiftUI

struct AudioMeterView: View {
    @Environment(\.prosodyPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let level: MeterLevel
    let isPaused: Bool

    init(title: String, level: MeterLevel, isPaused: Bool = false) {
        self.title = title
        self.level = level
        self.isPaused = isPaused
    }

    var body: some View {
        let amplitude = isPaused ? 0 : AudioMeterCalculator.displayAmplitude(rms: level.rms)
        let peak = isPaused ? 0 : AudioMeterCalculator.displayAmplitude(rms: level.peak)
        let peakIndex = min(17, max(0, Int(peak * 18) - 1))
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 58, alignment: .leading)
            HStack(spacing: 3) {
                ForEach(0..<18, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(index < Int(amplitude * 18) ? palette.accent : palette.text.opacity(0.12))
                        .frame(width: 5, height: 10 + amplitude * 14)
                        .overlay {
                            if peak > 0, index == peakIndex {
                                Capsule().fill(palette.text.opacity(0.65))
                            }
                        }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(title) level")
            .frame(height: 24)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: amplitude)
            .accessibilityValue("\(Int(amplitude * 100)) percent")
        }
        .accessibilityIdentifier("clippy.audio-meter.\(title.lowercased())")
    }
}
struct RecordingTimerView: View {
    @Environment(\.prosodyPalette) private var palette
    @ObservedObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(ProsodyFormatters.duration(model.elapsedDuration(at: context.date)))
                .monospacedDigit()
                .foregroundStyle(palette.secondary)
                .accessibilityLabel("Recording duration")
                .accessibilityValue(ProsodyFormatters.duration(model.elapsedDuration(at: context.date)))
        }
        .accessibilityIdentifier("clippy.recording-timer")
    }
}

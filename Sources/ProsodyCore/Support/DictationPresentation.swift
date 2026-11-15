import Foundation

public enum DictationOutput {
    /// Keep persisted transcripts clean; the trailing space belongs only to
    /// the text delivered to a field or copied for continued typing.
    public static func insertionText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed + " "
    }
}

public enum DictationWaveform {
    /// Speech RMS is usually far below 1. A decibel scale makes quiet speech
    /// visible without pegging the meter or amplifying the actual recording.
    public static func amplitude(rms: Double) -> Double {
        AudioMeterCalculator.displayAmplitude(rms: rms)
    }

    public static func bars(rms: Double, peak: Double, count: Int = 17) -> [Double] {
        let level = amplitude(rms: rms)
        let transient = amplitude(rms: peak)
        return (0..<count).map { index in
            let center = 1 - abs(Double(index) - Double(count - 1) / 2) / Double(max(count, 1))
            let variation = 0.58 + 0.42 * abs(sin(Double(index) * 2.3 + transient * 4))
            return 4 + 42 * min(1, level * center * variation + transient * 0.13)
        }
    }
}

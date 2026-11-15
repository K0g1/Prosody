import Foundation

public enum AudioMeterCalculator {
    /// A perceptual scale shared by recording and dictation. Ordinary speech
    /// occupies most of the display, while silence stays at zero. This changes
    /// presentation only; captured PCM and the level measurement are untouched.
    public static func displayAmplitude(rms: Double) -> Double {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 58) / 48))
    }

    public static func level(for samples: [Float]) -> MeterLevel {
        guard !samples.isEmpty else { return .zero }
        var sum: Double = 0
        var peak: Double = 0
        for sample in samples where sample.isFinite {
            let magnitude = min(1, abs(Double(sample)))
            sum += magnitude * magnitude
            peak = max(peak, magnitude)
        }
        let rms = min(1, sqrt(sum / Double(samples.count)) * 2.4)
        return MeterLevel(rms: rms, peak: peak)
    }
}

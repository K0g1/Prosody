import Foundation

/// User-tunable boundaries for the transcript blocks produced by streaming STT.
/// A block may still end earlier when sentence-ending punctuation is recognized.
public struct TranscriptSegmentationConfiguration: Sendable, Equatable {
    public static let defaultMaximumWordsPerSegment = 40
    public static let defaultPauseThreshold: TimeInterval = 1.5

    public static let maximumWordsRange = 10...100
    public static let pauseThresholdRange: ClosedRange<TimeInterval> = 0.5...5.0

    public static let maximumWordsDefaultsKey = "preferences.transcriptMaximumWordsPerSegment"
    public static let pauseThresholdDefaultsKey = "preferences.transcriptPauseThreshold"

    public let maximumWordsPerSegment: Int
    public let pauseThreshold: TimeInterval

    public init(
        maximumWordsPerSegment: Int = defaultMaximumWordsPerSegment,
        pauseThreshold: TimeInterval = defaultPauseThreshold
    ) {
        self.maximumWordsPerSegment = min(
            max(maximumWordsPerSegment, Self.maximumWordsRange.lowerBound),
            Self.maximumWordsRange.upperBound
        )
        self.pauseThreshold = min(
            max(pauseThreshold.isFinite ? pauseThreshold : Self.defaultPauseThreshold, Self.pauseThresholdRange.lowerBound),
            Self.pauseThresholdRange.upperBound
        )
    }

    /// Loads the next-session settings from the same UserDefaults store used
    /// by ProsodyPreferences. Values are clamped so corrupt defaults cannot
    /// create unbounded transcript turns or impossible pause thresholds.
    public static func persisted(in defaults: UserDefaults = .standard) -> Self {
        let maximumWords = defaults.object(forKey: maximumWordsDefaultsKey) == nil
            ? defaultMaximumWordsPerSegment
            : defaults.integer(forKey: maximumWordsDefaultsKey)
        let pauseThreshold = defaults.object(forKey: pauseThresholdDefaultsKey) == nil
            ? defaultPauseThreshold
            : defaults.double(forKey: pauseThresholdDefaultsKey)

        return Self(
            maximumWordsPerSegment: maximumWords,
            pauseThreshold: pauseThreshold
        )
    }
}

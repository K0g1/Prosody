import Foundation

public enum AppConstants {
    public static let bundleIdentifier = "com.openai.clippy"
    public static let applicationName = "Prosody"
    /// Compatibility identifiers remain tied to the shipped Clippy app.
    public static let legacyStorageFolderName = "Clippy"
    public static let repositoryURL: URL? = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "ProsodyRepositoryURL") as? String else {
            return nil
        }
        return URL(string: value)
    }()
    public static let appVersion: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.2.0"
    /// The Alpha 8 packaging key remains a compatibility contract. The staged
    /// plist supplies the release label; source fallback stays the base version.
    public static let releaseLabel: String =
        (Bundle.main.object(forInfoDictionaryKey: "ClippyReleaseLabel") as? String) ?? appVersion
    public static let buildNumber: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "12"
    // FluidAudio's `Repo.parakeetUnified.folderName` is the cache directory
    // used by `StreamingUnifiedAsrManager.loadModels(to:)`.
    public static let modelCacheFolderName = "parakeet-unified-en-0.6b"
    public static let recoveryFolderName = "Recovery"
    public static let sessionIndexFileName = "sessions.json"
    public static let recoveryManifestFileName = "manifest.json"
    public static let recoveryTranscriptFileName = "transcript.jsonl"
    public static let defaultOutputFolderName = "Prosody"
    public static let legacyDefaultOutputFolderName = "Clippy"
    public static let archiveSegmentSeconds: TimeInterval = 60

    public static var isDemoModeRequested: Bool {
        if ProcessInfo.processInfo.arguments.contains("--demo") { return true }
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["PROSODY_DEMO_MODE"] { return value == "1" }
        return environment["CLIPPY_DEMO_MODE"] == "1"
    }
}

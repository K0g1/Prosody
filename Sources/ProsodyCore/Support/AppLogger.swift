import OSLog

public enum AppLogger {
    public static let app = Logger(subsystem: AppConstants.bundleIdentifier, category: "app")
    public static let capture = Logger(subsystem: AppConstants.bundleIdentifier, category: "capture")
    public static let audio = Logger(subsystem: AppConstants.bundleIdentifier, category: "audio")
    public static let stt = Logger(subsystem: AppConstants.bundleIdentifier, category: "stt")
    static let dictationLatency = Logger(subsystem: AppConstants.bundleIdentifier, category: "dictation-latency")
    public static let diarization = Logger(subsystem: AppConstants.bundleIdentifier, category: "diarization")
    public static let notes = Logger(subsystem: AppConstants.bundleIdentifier, category: "notes")
    public static let storage = Logger(subsystem: AppConstants.bundleIdentifier, category: "storage")
    public static let security = Logger(subsystem: AppConstants.bundleIdentifier, category: "security")
    public static let permissions = Logger(subsystem: AppConstants.bundleIdentifier, category: "permissions")
    public static let recovery = Logger(subsystem: AppConstants.bundleIdentifier, category: "recovery")
}

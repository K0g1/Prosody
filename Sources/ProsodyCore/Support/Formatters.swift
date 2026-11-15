import Foundation

public enum ProsodyFormatters {
    public static func duration(_ value: TimeInterval) -> String {
        let totalSeconds = value.isFinite ? Int(min(max(0, value.rounded()), Double(Int32.max))) : 0
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public static func timestamp(_ value: TimeInterval) -> String {
        let totalSeconds = value.isFinite ? Int(min(max(0, value.rounded()), Double(Int32.max))) : 0
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func shortDuration(_ value: TimeInterval) -> String {
        duration(value)
    }
}

public enum FileNameSanitizer {
    public static func sanitize(_ value: String, fallback: String = "Recording") -> String {
        let invalid = CharacterSet(charactersIn: ":/\\\n\r\t")
        let pieces = value.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: invalid)
        var result = pieces.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(of: "  ", with: " ")
        if result.isEmpty { result = fallback }
        if result.count > 120 {
            result = String(result.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

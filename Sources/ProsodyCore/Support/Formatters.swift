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
        sanitizeComponent(value) ?? sanitizeComponent(fallback) ?? "Recording"
    }

    private static func sanitizeComponent(_ value: String) -> String? {
        let invalid = CharacterSet(charactersIn: ":/\\\n\r\t")
        let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            $0.properties.generalCategory != .control || invalid.contains($0)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        let component = cleaned.components(separatedBy: invalid).joined(separator: "-")
            .replacingOccurrences(of: "  ", with: " ")
        let result = String(component.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.contains(where: { $0 != "." }) else { return nil }
        return result
    }
}

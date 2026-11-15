import Foundation

/// A catalog entry. Folder grants live in private preferences, never in exported files.
public struct RecordingLabel: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var outputFolderPath: String?
    public var namingPattern: String
    public var dateFormat: String

    public init(id: UUID = UUID(), name: String = "New label", colorHex: String = "#808080",
                outputFolderPath: String? = nil, namingPattern: String = "{title}", dateFormat: String = "yyyy-MM-dd") {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.outputFolderPath = outputFolderPath
        self.namingPattern = namingPattern
        self.dateFormat = dateFormat
    }

    public var snapshot: RecordingLabelSnapshot { .init(id: id, name: name, colorHex: colorHex) }
}

public struct RecordingLabelSnapshot: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let colorHex: String

    public init(id: UUID, name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}

public struct RecordingDestination: Codable, Equatable, Sendable {
    public var path: String
    public var bookmarkData: Data?
    public init(path: String, bookmarkData: Data? = nil) {
        self.path = path
        self.bookmarkData = bookmarkData
    }
}

public enum RecordingNaming {
    public static let tokens = ["{title}", "{label}", "{date}", "{time}", "{year}", "{month}", "{day}", "{weekday}", "{id}"]

    public static func unknownTokens(in pattern: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"\{[^{}]*\}"#)
        return expression.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)).compactMap {
            guard let range = Range($0.range, in: pattern) else { return nil }
            let token = String(pattern[range])
            return tokens.contains(token) ? nil : token
        }
    }

    public static func title(pattern: String, title: String, label: String, date: Date, id: UUID,
                             dateFormat: String = "yyyy-MM-dd", timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        func formatted(_ format: String) -> String {
            formatter.dateFormat = String(format.prefix(100))
            return formatter.string(from: date)
        }
        let values = ["{title}": title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Recording" : title,
                      "{label}": label, "{date}": formatted(dateFormat), "{time}": formatted("HH-mm-ss"),
                      "{year}": formatted("yyyy"), "{month}": formatted("MM"), "{day}": formatted("dd"),
                      "{weekday}": formatted("EEEE"), "{id}": id.uuidString]
        // Replace matches from the original template only: user text containing tokens is literal.
        let source = String(pattern.prefix(500))
        let expression = try! NSRegularExpression(pattern: #"\{[^{}]*\}"#)
        var result = source
        for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let token = String(result[range])
            if let value = values[token] { result.replaceSubrange(range, with: value) }
        }
        result = result.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "New Recording" : String(result.prefix(300))
    }

    /// A single portable filename; never a path or a name used by another session artifact.
    public static func transcriptFileName(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var stem = title.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if stem.lowercased().hasSuffix(".md") { stem = String(stem.dropLast(3)) }
        while stem.utf8.count > 180 { stem.removeLast() }
        if stem.isEmpty { stem = "Recording" }
        if ["notes", "transcript", "session", "index"].contains(stem.lowercased()) { stem += " - recording" }
        return stem + ".md"
    }

    public static func safeTranscriptFileName(_ proposed: String?) -> String {
        guard let proposed, !proposed.isEmpty else { return "transcript.md" }
        return transcriptFileName(for: proposed)
    }
}

import Foundation

public struct WordReplacement: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var original: String
    public var replacement: String

    public init(id: UUID = UUID(), original: String = "", replacement: String = "") {
        self.id = id
        self.original = original
        self.replacement = replacement
    }
}

/// Literal, case-insensitive whole-word/phrase substitutions. Matching the
/// original text in one pass prevents cascades (A → B, B → C) and treats user
/// punctuation and replacement dollars/backslashes as text, never regex code.
public struct WordReplacementProcessor: Sendable {
    private let expression: NSRegularExpression?
    private let replacements: [String]

    public init(rules: [WordReplacement]) {
        var seen: Set<String> = []
        let rules = rules.compactMap { rule -> (original: String, replacement: String)? in
            let original = rule.original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty, seen.insert(original.lowercased()).inserted else { return nil }
            return (original, rule.replacement)
        }.sorted { $0.original.count > $1.original.count }
        replacements = rules.map(\.replacement)
        let alternatives = rules.map {
            "(" + NSRegularExpression.escapedPattern(for: $0.original) + ")"
        }.joined(separator: "|")
        expression = alternatives.isEmpty ? nil : try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{M}\\p{N}_])(?:" + alternatives + ")(?![\\p{L}\\p{M}\\p{N}_])",
            options: [.caseInsensitive]
        )
    }

    public func apply(to text: String) -> String {
        guard let expression else { return text }
        let result = NSMutableString(string: text)
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            for index in replacements.indices where match.range(at: index + 1).location != NSNotFound {
                result.replaceCharacters(in: match.range, with: replacements[index])
                break
            }
        }
        return result as String
    }

    public func apply(to transcript: Transcript) -> Transcript {
        var result = transcript
        result.segments = transcript.segments.map { segment in
            var updated = segment
            updated.text = apply(to: segment.text)
            return updated
        }
        return result
    }
}

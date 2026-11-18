import Foundation

public struct LectureSection: Codable, Equatable, Sendable {
    public var title: String
    public var body: String
    public var bullets: [String]

    public init(title: String, body: String = "", bullets: [String] = []) {
        self.title = title
        self.body = body
        self.bullets = bullets
    }
}

public struct KeyTerm: Codable, Equatable, Sendable {
    public var term: String
    public var definition: String

    public init(term: String, definition: String) {
        self.term = term
        self.definition = definition
    }
}

public struct LectureNotesDraft: Codable, Equatable, Sendable {
    public var overview: String
    public var sections: [LectureSection]
    public var keyTerms: [KeyTerm]
    public var questions: [String]
    public var summary: String

    public init(
        overview: String = "",
        sections: [LectureSection] = [],
        keyTerms: [KeyTerm] = [],
        questions: [String] = [],
        summary: String = ""
    ) {
        self.overview = overview
        self.sections = sections
        self.keyTerms = keyTerms
        self.questions = questions
        self.summary = summary
    }
}

public enum MarkdownRenderer {
    public static func render(
        transcript: Transcript,
        title: String,
        date: Date,
        duration: TimeInterval,
        labels: [RecordingLabelSnapshot] = [],
        includeEchoDuplicates: Bool = false
    ) -> String {
        let segments = transcript.segments
            .filter { includeEchoDuplicates || !$0.isEchoDuplicate }
            .sorted(by: transcriptOrder)

        var lines = [
            "---",
            "title: \"\(yamlQuote(title))\"",
            "date: \(dateOnly(date))",
            "duration: \(ProsodyFormatters.duration(duration))",
            "---",
            "",
            "# Transcript",
            ""
        ]

        if !labels.isEmpty {
            let metadata = ["labels:"] + labels.flatMap { label in
                ["  - name: \"\(yamlQuote(label.name))\"", "    color: \"\(yamlQuote(label.colorHex))\"", "    id: \"\(label.id.uuidString)\""]
            }
            lines.insert(contentsOf: metadata, at: 4)
            lines.append("**Labels:** " + labels.map { escapeInline($0.name.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")) }.joined(separator: ", "))
            lines.append("")
        }

        for segment in segments where !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let timestamp = ProsodyFormatters.timestamp(segment.start)
            let speaker = escapeInline(segment.visibleSpeakerName)
            let text = escapeInline(segment.text.replacingOccurrences(of: "\n", with: " "))
            lines.append("**[\(timestamp)] \(speaker):** \(text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func render(
        _ transcript: Transcript,
        title: String,
        date: Date = .now,
        duration: TimeInterval? = nil,
        labels: [RecordingLabelSnapshot] = [],
        includeEchoDuplicates: Bool = false
    ) -> String {
        render(
            transcript: transcript,
            title: title,
            date: date,
            duration: duration ?? transcriptDuration(transcript),
            labels: labels,
            includeEchoDuplicates: includeEchoDuplicates
        )
    }

    public static func render(
        _ draft: LectureNotesDraft,
        title: String,
        date: Date = .now,
        duration: TimeInterval = 0
    ) -> String {
        var lines = [
            "# \(escapeHeading(title))",
            "",
            "**Date:** \(dateOnly(date))  ",
            "**Duration:** \(ProsodyFormatters.duration(duration))",
            ""
        ]

        appendSection(title: "Overview", body: draft.overview, to: &lines)
        for section in draft.sections {
            appendSection(title: section.title, body: section.body, bullets: section.bullets, to: &lines)
        }
        if !draft.keyTerms.isEmpty {
            lines.append("## Key terms")
            lines.append("")
            for term in draft.keyTerms {
                lines.append("- **\(escapeInline(term.term)):** \(escapeInline(term.definition))")
            }
            lines.append("")
        }
        if !draft.questions.isEmpty {
            lines.append("## Questions to review")
            lines.append("")
            lines.append(contentsOf: draft.questions.map { "- \(escapeInline($0))" })
            lines.append("")
        }
        appendSection(title: "Summary", body: draft.summary, to: &lines)
        return lines.joined(separator: "\n")
    }

    private static func appendSection(
        title: String,
        body: String,
        bullets: [String] = [],
        to lines: inout [String]
    ) {
        guard !body.isEmpty || !bullets.isEmpty else { return }
        lines.append("## \(escapeHeading(title))")
        lines.append("")
        if !body.isEmpty {
            lines.append(escapeParagraph(body))
            lines.append("")
        }
        lines.append(contentsOf: bullets.map { "- \(escapeInline($0))" })
        if !bullets.isEmpty { lines.append("") }
    }

    private static func transcriptDuration(_ transcript: Transcript) -> TimeInterval {
        transcript.segments.map(\.end).max() ?? 0
    }

    private static func transcriptOrder(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func dateOnly(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }

    private static func yamlQuote(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func escapeHeading(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "#", with: "\\#")
    }

    private static func escapeParagraph(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    static func escapeInline(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        for character in ["\\", "`", "*", "_", "[", "]"] {
            result = result.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return result
    }
}

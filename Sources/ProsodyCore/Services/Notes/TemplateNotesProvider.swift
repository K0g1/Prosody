import Foundation

/// A deterministic, offline provider. It gives users useful notes before a
/// local LLM is configured and is also the safe fallback after a provider
/// request fails.
public struct TemplateNotesProvider: NotesProvider {
    public let id = "template-local"

    public init() {}

    public func generate(request: NotesRequest, modelID: String) async throws -> NotesResult {
        let segments = request.transcript.visibleSegments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        guard !segments.isEmpty else { throw NotesProviderError.emptyTranscript }

        let markdown: String
        switch request.template {
        case .lectureNotes:
            let overview = "Captured lecture transcript with \(segments.count) speaker turn\(segments.count == 1 ? "" : "s")."
            let body = segments.map { "**\($0.visibleSpeakerName):** \($0.text)" }.joined(separator: " ")
            markdown = MarkdownRenderer.render(
                LectureNotesDraft(
                    overview: overview,
                    sections: [LectureSection(title: "Transcript highlights", body: body)],
                    summary: "Review the timestamped transcript for the complete discussion."
                ),
                title: request.title,
                duration: request.duration
            )
        case .meetingMinutes:
            markdown = renderMeetingMinutes(request: request, segments: segments)
        case .studyNotes:
            markdown = renderStudyNotes(request: request, segments: segments)
        case .cornellNotes:
            markdown = renderCornellNotes(request: request, segments: segments)
        case .summary:
            markdown = renderSummary(request: request, segments: segments)
        case .actionItems:
            markdown = renderActionItems(request: request, segments: segments)
        case .transcriptOnly:
            markdown = MarkdownRenderer.render(
                request.transcript,
                title: request.title,
                date: .now,
                duration: request.duration
            )
        }
        return NotesResult(markdown: markdown)
    }

    private func renderMeetingMinutes(request: NotesRequest, segments: [TranscriptSegment]) -> String {
        var lines = header(request)
        lines += ["## Discussion", ""]
        lines += segments.map { "- **\($0.visibleSpeakerName)** (\(ProsodyFormatters.timestamp($0.start))): \($0.text)" }
        lines += ["", "## Decisions and follow-ups", "", "- Review the transcript and record any decisions or owners.", ""]
        return lines.joined(separator: "\n")
    }

    private func renderStudyNotes(request: NotesRequest, segments: [TranscriptSegment]) -> String {
        var lines = header(request)
        lines += ["## Key ideas", ""]
        lines += segments.map { "- \($0.text)" }
        lines += ["", "## Questions to review", "", "- What are the main concepts and examples in this session?", ""]
        return lines.joined(separator: "\n")
    }

    private func renderCornellNotes(request: NotesRequest, segments: [TranscriptSegment]) -> String {
        var lines = header(request)
        lines += ["## Cue column", "", "| Cue | Notes |", "| --- | --- |"]
        lines += segments.map { "| \($0.visibleSpeakerName) · \(ProsodyFormatters.timestamp($0.start)) | \($0.text.replacingOccurrences(of: "|", with: "\\|")) |" }
        lines += ["", "## Summary", "", "Summarize the most important ideas after reviewing the notes.", ""]
        return lines.joined(separator: "\n")
    }

    private func renderSummary(request: NotesRequest, segments: [TranscriptSegment]) -> String {
        var lines = header(request)
        lines += ["## Summary", "", segments.map(\.text).joined(separator: " "), ""]
        return lines.joined(separator: "\n")
    }

    private func renderActionItems(request: NotesRequest, segments: [TranscriptSegment]) -> String {
        var lines = header(request)
        lines += ["## Action items", "", "- Review the transcript for explicit tasks, owners, and due dates.", "", "## Relevant transcript", ""]
        lines += segments.map { "- [\(ProsodyFormatters.timestamp($0.start))] \($0.text)" }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func header(_ request: NotesRequest) -> [String] {
        [
            "# \(request.title)",
            "",
            "**Template:** \(request.template.displayName)  ",
            "**Duration:** \(ProsodyFormatters.duration(request.duration))",
            ""
        ]
    }
}

import Foundation

public enum TranscriptExportFormatter {
    public static func render(_ document: SessionDocument, format: TranscriptCopyFormat = .markdown,
                              options: TranscriptExportOptions = .init()) -> String {
        let transcript = document.transcript
        let session = document.session
        if format == .rawText { return transcript.rawText }
        if format == .textOnlyMarkdown {
            return transcript.rawText.components(separatedBy: "\n\n").map(escape).joined(separator: "\n\n")
        }
        var blocks: [String] = []
        if options.title { blocks.append("# \(escape(session.title))") }

        var metadata: [String] = []
        if options.date { metadata.append("**Date:** \(session.createdAt.formatted(date: .abbreviated, time: .omitted))") }
        if options.time { metadata.append("**Time:** \(session.createdAt.formatted(date: .omitted, time: .shortened))") }
        if options.duration { metadata.append("**Duration:** \(ProsodyFormatters.duration(session.duration))") }
        if options.originalAudioFileName, let name = session.originalAudioFileName {
            metadata.append("**Source audio:** \(escape(name))")
        }
        if options.labels, let labels = session.labels, !labels.isEmpty {
            metadata.append("**Labels:** " + labels.map { escape($0.name) }.joined(separator: ", "))
        }
        if !metadata.isEmpty { blocks.append(metadata.joined(separator: "  \n")) }
        blocks += transcript.visibleSegments.sorted { ($0.start, $0.end, $0.id.uuidString) < ($1.start, $1.end, $1.id.uuidString) }
            .compactMap { segment in
                let speech = escape(segment.text)
                guard !speech.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                var attribution: [String] = []
                if options.timestamps { attribution.append("[\(ProsodyFormatters.timestamp(segment.start))]") }
                if options.speakerNames { attribution.append(escape(segment.visibleSpeakerName)) }
                if attribution.isEmpty { return speech }
                return "**\(attribution.joined(separator: " ")):** \(speech)"
            }
        return blocks.joined(separator: "\n\n")
    }

    private static func escape(_ text: String) -> String {
        var escaped = MarkdownRenderer.escapeInline(text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " "))
        if let first = escaped.first, "#>-+!".contains(first) { escaped = "\\" + escaped }
        if let period = escaped.firstIndex(of: "."), period != escaped.startIndex,
           escaped[..<period].allSatisfy(\.isNumber) {
            escaped.insert("\\", at: period)
        }
        return escaped
    }
}

enum LibraryExport: Sendable { case separateMarkdown, combinedMarkdown, audio }

enum TranscriptExporter {
    struct Report: Sendable {
        var exported = 0
        var skipped = 0
        var failures: [String] = []
    }

    @discardableResult
    static func writeCopy(_ content: String, fileName: String, in directory: URL) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".prosody-\(UUID())")
        defer { try? manager.removeItem(at: staging) }
        try Data(content.utf8).write(to: staging, options: .atomic)
        return try publish(staging, as: fileName, in: directory)
    }

    static func copyAudio(from sessionDirectory: URL, title: String, into directory: URL) throws -> Bool {
        let tracks = SessionAssetResolver.allAudioTracks(in: sessionDirectory)
        guard !tracks.isEmpty else { return false }
        let manager = FileManager.default
        let staging = directory.appendingPathComponent(".prosody-\(UUID())", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        for (source, files) in tracks {
            let track = staging.appendingPathComponent(source.rawValue, isDirectory: true)
            try manager.createDirectory(at: track, withIntermediateDirectories: true)
            for file in files {
                try Task.checkCancellation()
                let safeName = Self.fileStem(for: title)
                let name = files.count == 1 ? "\(safeName).\(file.pathExtension)" : file.lastPathComponent
                try manager.copyItem(at: file, to: track.appendingPathComponent(name))
            }
        }
        _ = try publish(staging, as: fileStem(for: title), in: directory, isDirectory: true)
        return true
    }

    static func fileStem(for title: String) -> String {
        String(RecordingNaming.transcriptFileName(for: title).dropLast(3))
    }

    static func fileName(for session: RecordingSession, format: TranscriptCopyFormat = .markdown) -> String {
        let name = session.transcriptFileName ?? RecordingNaming.transcriptFileName(for: session.title)
        let safeName = RecordingNaming.safeTranscriptFileName(name)
        return String(safeName.dropLast(3)) + "." + format.fileExtension
    }

    private static func publish(_ staging: URL, as name: String, in directory: URL, isDirectory: Bool = false) throws -> URL {
        let fileManager = FileManager.default
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var index = 1
        while true {
            let suffix = index == 1 ? "" : " (\(index))"
            let fileName = stem + suffix + (ext.isEmpty ? "" : "." + ext)
            let destination = directory.appendingPathComponent(fileName, isDirectory: isDirectory)
            do {
                try fileManager.moveItem(at: staging, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                index += 1
            }
        }
    }
}

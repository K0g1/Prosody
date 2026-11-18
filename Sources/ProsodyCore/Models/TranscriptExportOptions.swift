import Foundation

public struct TranscriptExportOptions: Codable, Sendable, Equatable {
    public var title = true
    public var date = true
    public var time = false
    public var originalAudioFileName = false
    public var duration = true
    public var timestamps = true
    public var speakerNames = true
    public var labels = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case title, date, time, originalAudioFileName, duration, timestamps, speakerNames, labels
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(Bool.self, forKey: .title) ?? title
        date = try values.decodeIfPresent(Bool.self, forKey: .date) ?? date
        time = try values.decodeIfPresent(Bool.self, forKey: .time) ?? time
        originalAudioFileName = try values.decodeIfPresent(Bool.self, forKey: .originalAudioFileName) ?? originalAudioFileName
        duration = try values.decodeIfPresent(Bool.self, forKey: .duration) ?? duration
        timestamps = try values.decodeIfPresent(Bool.self, forKey: .timestamps) ?? timestamps
        speakerNames = try values.decodeIfPresent(Bool.self, forKey: .speakerNames) ?? speakerNames
        labels = try values.decodeIfPresent(Bool.self, forKey: .labels) ?? labels
    }
}

public enum TranscriptCopyFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case markdown
    case textOnlyMarkdown
    case rawText

    public var id: Self { self }
    public var title: String {
        switch self {
        case .markdown: "Formatted Markdown"
        case .textOnlyMarkdown: "Text-only Markdown"
        case .rawText: "Raw Text"
        }
    }

    var fileExtension: String { self == .rawText ? "txt" : "md" }
}

/// Folder bookmarks stay in preferences. The session snapshots the export
/// destination and format so an unfinished recording can be recovered.
public struct LabelTranscriptCopy: Codable, Equatable, Sendable {
    public var folderPath: String
    public var format: TranscriptCopyFormat

    public init(folderPath: String, format: TranscriptCopyFormat = .markdown) {
        self.folderPath = folderPath
        self.format = format
    }

    private enum CodingKeys: String, CodingKey { case folderPath, format }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        folderPath = try values.decode(String.self, forKey: .folderPath)
        format = try values.decodeIfPresent(String.self, forKey: .format)
            .flatMap(TranscriptCopyFormat.init(rawValue:)) ?? .markdown
    }
}

import Foundation

public enum AtomicFileWriterError: Error, Equatable, Sendable {
    case parentDirectoryUnavailable
    case replacementFailed
}

/// Small, dependency-free atomic file primitive used by both session stores.
public enum AtomicFileWriter {
    @discardableResult
    public static func write(_ data: Data, to url: URL) throws -> URL {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try data.write(to: temporaryURL, options: [.atomic])

        if fileManager.fileExists(atPath: url.path) {
            guard try fileManager.replaceItemAt(url, withItemAt: temporaryURL) != nil else {
                throw AtomicFileWriterError.replacementFailed
            }
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
        return url
    }

    public static func encode<T: Encodable>(
        _ value: T,
        to url: URL,
        encoder: JSONEncoder = AtomicFileWriter.makeEncoder()
    ) throws {
        try write(encoder.encode(value), to: url)
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

import Darwin
import Foundation

public enum AtomicFileWriterError: Error, Equatable, Sendable {
    case parentDirectoryUnavailable
    case replacementFailed
}

/// Small, dependency-free atomic file primitive used by both session stores.
public enum AtomicFileWriter {
    @discardableResult
    public static func write(_ data: Data, to url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw posixError() }
        defer { _ = close(directoryFD) }

        let temporaryName = ".prosody-\(UUID().uuidString).tmp"
        let fileFD = openat(
            directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
        )
        guard fileFD >= 0 else { throw posixError() }
        var renamed = false
        defer {
            if !renamed { _ = unlinkat(directoryFD, temporaryName, 0) }
        }

        let file = FileHandle(fileDescriptor: fileFD, closeOnDealloc: true)
        try file.write(contentsOf: data)
        if fcntl(fileFD, F_FULLFSYNC) == -1 {
            let error = posixError()
            // Some file systems only support the standard sync operation.
            guard error.code == .EINVAL || error.code == .ENOTSUP || error.code == .ENOTTY else { throw error }
            guard fsync(fileFD) == 0 else { throw posixError() }
        }
        try file.close()

        guard renameat(directoryFD, temporaryName, directoryFD, url.lastPathComponent) == 0 else {
            throw posixError()
        }
        renamed = true
        if fsync(directoryFD) == -1 {
            let error = posixError()
            // The rename has already published the file. A directory sync
            // error can mean the rename may not survive a power loss.
            guard error.code == .EINVAL || error.code == .ENOTSUP else { throw error }
        }
        return url
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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

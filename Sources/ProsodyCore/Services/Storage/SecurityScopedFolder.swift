import Foundation

public enum SecurityScopedFolderError: Error, LocalizedError, Equatable, Sendable {
    case invalidBookmark
    case staleBookmark
    case inaccessible

    public var errorDescription: String? {
        switch self {
        case .invalidBookmark: return "The saved output-folder bookmark is invalid."
        case .staleBookmark: return "The saved output-folder bookmark is stale. Choose the folder again."
        case .inaccessible: return "Prosody cannot access that output folder."
        }
    }
}

public enum SecurityScopedFolder {
    public static func withSynchronousAccess<T>(to url: URL, bookmarkData: Data?, operation: (URL) throws -> T) throws -> T {
        let resolved = try resolve(url: url, bookmarkData: bookmarkData)
        let didStart = resolved.startAccessingSecurityScopedResource()
        defer { if didStart { resolved.stopAccessingSecurityScopedResource() } }
        return try operation(resolved)
    }

    public static func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public static func resolve(url: URL, bookmarkData: Data?) throws -> URL {
        guard let bookmarkData else { return url }
        var isStale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else { throw SecurityScopedFolderError.staleBookmark }
        return resolved
    }

    public static func withAccess<T: Sendable>(
        to url: URL,
        bookmarkData: Data?,
        operation: @escaping @Sendable (URL) async throws -> T
    ) async throws -> T {
        let resolved = try resolve(url: url, bookmarkData: bookmarkData)
        let didStart = resolved.startAccessingSecurityScopedResource()
        defer {
            if didStart { resolved.stopAccessingSecurityScopedResource() }
        }
        return try await operation(resolved)
    }
}

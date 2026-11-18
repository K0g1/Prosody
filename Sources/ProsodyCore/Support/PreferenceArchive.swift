import Foundation

enum PreferenceArchiveError: LocalizedError {
    case unreadable
    case tooLarge
    case noSettings

    var errorDescription: String? {
        switch self {
        case .unreadable: "Choose a Prosody or Clippy preferences property list."
        case .tooLarge: "The preferences file exceeds 8 MB."
        case .noSettings: "This source has no recognized Prosody preferences."
        }
    }
}

/// Reads previous app domains only after a person chooses an import source.
@MainActor
struct PreferenceArchive {
    let title: String
    let values: [String: Any]

    static func previousInstallation() throws -> Self {
        let values = UserDefaults.standard.persistentDomain(forName: AppConstants.bundleIdentifier) ?? [:]
        return try Self(title: "Previous Prosody", values: values)
    }

    static func sandboxInstallation(in container: URL = ProsodyStorage.legacyDataDirectory) throws -> Self {
        let url = container.appendingPathComponent("Library/Preferences/\(AppConstants.bundleIdentifier).plist")
        var values = try read(url)
        let outputKey = "preferences.outputFolder"
        let folder = container.appendingPathComponent("Clippy", isDirectory: true)
        let path = values[outputKey] as? String
        if (path == nil || path == "~/Clippy"), (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            values[outputKey] = folder.path
            values.removeValue(forKey: "preferences.outputBookmark")
        }
        return try Self(title: "Sandboxed Clippy", values: values)
    }

    static func file(_ url: URL) throws -> Self {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try Self(title: url.lastPathComponent, values: read(url))
    }

    init(title: String, values: [String: Any]) throws {
        guard values.keys.contains(where: { $0.hasPrefix("preferences.") }) else {
            throw PreferenceArchiveError.noSettings
        }
        self.title = title
        self.values = values
    }

    private static func read(_ url: URL) throws -> [String: Any] {
        let limit = 8 * 1024 * 1024
        guard let file = try? FileHandle(forReadingFrom: url) else { throw PreferenceArchiveError.unreadable }
        defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw PreferenceArchiveError.tooLarge }
        guard let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw PreferenceArchiveError.unreadable
        }
        return values
    }
}

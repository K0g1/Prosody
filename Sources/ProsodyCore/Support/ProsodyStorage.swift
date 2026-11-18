import Foundation

/// Direct distribution is needed for Accessibility-based dictation. Reuse the
/// previous sandbox's support directory when present, avoiding duplicate model
/// downloads or moving/deleting any existing user recordings during upgrade.
@_spi(Validation)
public enum ProsodyStorage {
    @_spi(Validation)
    public static var legacyDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(AppConstants.bundleIdentifier)/Data", isDirectory: true)
    }

    static var applicationSupportDirectory: URL {
        let previous = legacyDataDirectory.appendingPathComponent(
            "Library/Application Support/\(AppConstants.legacyStorageFolderName)", isDirectory: true
        )
        if FileManager.default.fileExists(atPath: previous.path) { return previous }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppConstants.legacyStorageFolderName, isDirectory: true)
    }

    @_spi(Validation)
    public static func defaultOutputFolderPath(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> String {
        let legacy = homeDirectory.appendingPathComponent(
            AppConstants.legacyDefaultOutputFolderName, isDirectory: true
        )
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "~/\(AppConstants.legacyDefaultOutputFolderName)"
        }
        return "~/\(AppConstants.defaultOutputFolderName)"
    }
}

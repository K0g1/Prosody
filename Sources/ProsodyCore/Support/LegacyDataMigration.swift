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

@_spi(Validation)
public enum LegacyDataMigration {
    @_spi(Validation)
    public static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        legacyDataDirectory: URL = ProsodyStorage.legacyDataDirectory
    ) {
        let key = "migration.directDistribution.v1"
        guard !defaults.bool(forKey: key) else { return }
        let outputKey = "preferences.outputFolder"
        let hadDirectOutputPreference = defaults.object(forKey: outputKey) != nil
        let preferencesURL = legacyDataDirectory.appendingPathComponent(
            "Library/Preferences/\(AppConstants.bundleIdentifier).plist"
        )
        var importedValues: [String: Any]?
        if let data = try? Data(contentsOf: preferencesURL),
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            importedValues = values
        }
        if let values = importedValues {
            for (name, value) in values where name.hasPrefix("preferences.") && defaults.object(forKey: name) == nil {
                defaults.set(value, forKey: name)
            }
        }
        let importedOutput = importedValues?[outputKey] as? String
        if !hadDirectOutputPreference, importedOutput == nil || importedOutput == "~/Clippy" {
            let sandboxOutput = legacyDataDirectory.appendingPathComponent("Clippy", isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: sandboxOutput.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                defaults.set(sandboxOutput.path, forKey: outputKey)
            }
        }
        defaults.set(true, forKey: key)
    }
}

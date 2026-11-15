import Foundation
import FluidAudio

public enum STTModelManagerError: Error, LocalizedError, Equatable, Sendable {
    case invalidModel
    case modelNotFound
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidModel: return "The selected speech model is not supported."
        case .modelNotFound: return "The selected speech model is not installed."
        case .downloadFailed(let message): return message
        }
    }
}

/// Filesystem ownership for downloaded speech models. Actual model loading is
/// kept in the engine adapter; this actor only answers installation and disk
/// lifecycle questions.
public actor STTModelManager {
    public let rootURL: URL

    public init(rootURL: URL? = nil) {
        self.rootURL = rootURL
            ?? ProsodyStorage.applicationSupportDirectory
                .appendingPathComponent("Models", isDirectory: true)
    }

    public func modelURL(for descriptor: STTModelDescriptor) -> URL {
        if descriptor.id == "parakeet-unified" {
            return rootURL.appendingPathComponent(AppConstants.modelCacheFolderName, isDirectory: true)
        }
        return rootURL.appendingPathComponent(descriptor.id, isDirectory: true)
    }

    public func isInstalled(_ descriptor: STTModelDescriptor) -> Bool {
        let url = modelURL(for: descriptor)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if descriptor.id == "parakeet-unified" {
            let required = [
                ModelNames.ParakeetUnified.streamingEncoderFile(precision: .int8, contextSuffix: UnifiedConfig().contextSuffix),
                ModelNames.ParakeetUnified.decoderFile,
                ModelNames.ParakeetUnified.jointDecisionFile,
                ModelNames.ParakeetUnified.vocab
            ]
            return required.allSatisfy { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
        }
        return true
    }

    public func markInstalled(_ descriptor: STTModelDescriptor) throws {
        let url = modelURL(for: descriptor)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("installed".utf8).write(to: url.appendingPathComponent(".installed"), options: [.atomic])
    }

    public func remove(_ descriptor: STTModelDescriptor) throws {
        let url = modelURL(for: descriptor)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func storageUsed() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }
}

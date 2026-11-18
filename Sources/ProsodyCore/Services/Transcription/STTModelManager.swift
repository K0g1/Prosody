import Foundation
import FluidAudio

public enum STTModelManagerError: Error, LocalizedError, Equatable, Sendable {
    case invalidModel
    case modelNotFound
    case operationInProgress
    case downloadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidModel: return "The selected speech model is unsupported."
        case .modelNotFound: return "Download the selected speech model in Settings → Models."
        case .operationInProgress: return "A model download is already in progress."
        case .downloadFailed(let message): return message
        }
    }
}

/// Owns the model cache. A validated staging directory is published only
/// after every asset finishes, so interrupted installs cannot become selectable.
public actor STTModelManager {
    public let rootURL: URL
    private var installing: SpeechModel?

    public init(rootURL: URL? = nil) {
        self.rootURL = rootURL
            ?? ProsodyStorage.applicationSupportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    public func modelURL(for descriptor: STTModelDescriptor) -> URL {
        rootURL.appendingPathComponent(SpeechModel(descriptor: descriptor)?.folderName ?? "Unsupported", isDirectory: true)
    }

    public func isInstalled(_ descriptor: STTModelDescriptor) -> Bool {
        guard let model = SpeechModel(descriptor: descriptor) else { return false }
        return Self.isComplete(model, at: modelURL(for: descriptor))
    }

    func installedURL(for model: SpeechModel) throws -> URL {
        let url = modelURL(for: model.descriptor)
        guard Self.isComplete(model, at: url) else { throw STTModelManagerError.modelNotFound }
        return url
    }

    func createModelsDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    func inventory() -> (installed: Set<String>, cached: Set<String>, storedBytes: Int64) {
        let installed = SpeechModel.allCases.filter { isInstalled($0.descriptor) }
        let cached = SpeechModel.allCases.filter { canRemove($0) }
        return (Set(installed.map(\.rawValue)), Set(cached.map(\.rawValue)), storageUsed())
    }

    private func canRemove(_ model: SpeechModel) -> Bool {
        FileManager.default.fileExists(atPath: modelURL(for: model.descriptor).path)
    }

    public func install(_ descriptor: STTModelDescriptor, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let model = SpeechModel(descriptor: descriptor) else { throw STTModelManagerError.invalidModel }
        guard installing == nil else { throw STTModelManagerError.operationInProgress }
        guard !isInstalled(descriptor) else { progress(1); return }

        installing = model
        let manager = FileManager.default
        let staging = rootURL.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? manager.removeItem(at: staging)
            installing = nil
        }
        let stagedModel = staging.appendingPathComponent(model.folderName, isDirectory: true)
        try manager.createDirectory(at: stagedModel, withIntermediateDirectories: true)
        if model == .unified {
            try await ModelHub.download(
                .parakeetUnified, to: staging, additionalModelNames: [Self.unifiedEncoder],
                progressHandler: { progress($0.fractionCompleted) }
            )
        } else if let package = SpeechModelPackage.package(for: model) {
            try await package.download(to: stagedModel, progress: progress)
        } else {
            throw STTModelManagerError.invalidModel
        }

        try Task.checkCancellation()
        guard Self.isComplete(model, at: stagedModel) else {
            throw STTModelManagerError.downloadFailed("The downloaded model is missing required files.")
        }
        let destination = modelURL(for: descriptor)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: stagedModel)
        } else {
            try manager.moveItem(at: stagedModel, to: destination)
        }
        progress(1)
    }

    public func remove(_ descriptor: STTModelDescriptor) throws {
        guard let model = SpeechModel(descriptor: descriptor) else { throw STTModelManagerError.invalidModel }
        guard installing != model else { throw STTModelManagerError.operationInProgress }
        let url = modelURL(for: descriptor)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func storageUsed() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        return enumerator.reduce(Int64.zero) { total, entry in
            guard let url = entry as? URL, let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize else { return total }
            return total + Int64(size)
        }
    }

    private static let unifiedEncoder = ModelNames.ParakeetUnified.streamingEncoderFile(
        precision: .int8, contextSuffix: UnifiedConfig().contextSuffix
    )

    private static func isComplete(_ model: SpeechModel, at directory: URL) -> Bool {
        if model != .unified { return SpeechModelPackage.package(for: model)?.isComplete(at: directory) == true }
        let names = ModelNames.ParakeetUnified.self
        let files = [unifiedEncoder, names.decoderFile, names.jointDecisionFile].flatMap {
            ["\($0)/coremldata.bin", "\($0)/weights/weight.bin"]
        } + [names.vocab]
        return files.allSatisfy {
            let values = try? directory.appendingPathComponent($0).resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
        }
    }
}

import Foundation

/// Stable identifiers are persisted in preferences and session manifests.
public enum SpeechModel: String, CaseIterable, Sendable {
    case unified = "parakeet-unified"
    case tdtV3 = "parakeet-v3"
    case fluidSpeechPro = "fluid-speech-pro"

    public var descriptor: STTModelDescriptor {
        let name: String
        let bytes: Int64
        switch self {
        case .unified: (name, bytes) = ("Parakeet Unified", 565_000_000)
        case .tdtV3: (name, bytes) = ("Parakeet TDT v3", 483_000_000)
        case .fluidSpeechPro: (name, bytes) = ("Fluid Speech Pro", 652_000_000)
        }
        return STTModelDescriptor(
            id: rawValue, engineID: .parakeet, displayName: name,
            languages: self == .unified ? ["English"] : ["25 languages"],
            supportsStreaming: self == .unified, supportsWordTimestamps: true,
            estimatedDownloadBytes: bytes
        )
    }

    var folderName: String { self == .unified ? AppConstants.modelCacheFolderName : rawValue }

    init?(descriptor: STTModelDescriptor) {
        guard descriptor.engineID == .parakeet else { return nil }
        self.init(rawValue: descriptor.id)
    }
}

/// Keeps the existing engine lookup API while exposing only shipped adapters.
public struct STTRegistry: Sendable {
    public init() {}

    public func availableEngines() async -> [STTEngineDescriptor] {
        [STTEngineDescriptor(id: .parakeet, displayName: "Parakeet", detail: "On-device speech recognition")]
    }

    public func availableModels(for engine: STTEngineID) async -> [STTModelDescriptor] {
        engine == .parakeet ? SpeechModel.allCases.map(\.descriptor) : []
    }

    public func descriptor(for engine: STTEngineID) async -> STTEngineDescriptor? {
        await availableEngines().first { $0.id == engine }
    }

    public func model(id: String, for engine: STTEngineID) async -> STTModelDescriptor? {
        await availableModels(for: engine).first { $0.id == id }
    }
}

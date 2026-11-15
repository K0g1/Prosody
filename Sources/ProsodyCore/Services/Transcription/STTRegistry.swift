import Foundation

/// The single source of truth for speech engines and models exposed by the UI.
/// Engine-specific availability and package details stay behind this registry.
public actor STTRegistry {
    public init() {}

    public func availableEngines() -> [STTEngineDescriptor] {
        [
            STTEngineDescriptor(
                id: .parakeet,
                displayName: "Parakeet",
                detail: "Fast local streaming transcription"
            ),
            STTEngineDescriptor(
                id: .whisper,
                displayName: "Whisper",
                detail: "Multilingual transcription adapter"
            )
        ]
    }

    public func availableModels(for engine: STTEngineID) -> [STTModelDescriptor] {
        switch engine {
        case .parakeet:
            return [
                STTModelDescriptor(
                    id: "parakeet-unified",
                    engineID: .parakeet,
                    displayName: "Parakeet Unified",
                    languages: ["English", "Streaming"],
                    supportsStreaming: true,
                    supportsWordTimestamps: true,
                    estimatedDownloadBytes: 565_000_000
                ),
                STTModelDescriptor(
                    id: "parakeet-v2",
                    engineID: .parakeet,
                    displayName: "Parakeet v2",
                    languages: ["English", "Batch"],
                    supportsStreaming: false,
                    supportsWordTimestamps: true,
                    estimatedDownloadBytes: 1_100_000_000
                ),
                STTModelDescriptor(
                    id: "parakeet-v3",
                    engineID: .parakeet,
                    displayName: "Parakeet v3",
                    languages: ["25 languages", "Batch"],
                    supportsStreaming: false,
                    supportsWordTimestamps: true,
                    estimatedDownloadBytes: 1_100_000_000
                )
            ]
        case .whisper:
            return [
                STTModelDescriptor(
                    id: "whisper-large-v3-turbo",
                    engineID: .whisper,
                    displayName: "Whisper Large v3 Turbo",
                    languages: ["Multilingual"],
                    supportsStreaming: true,
                    supportsWordTimestamps: true,
                    estimatedDownloadBytes: 800_000_000
                ),
                STTModelDescriptor(
                    id: "whisper-small",
                    engineID: .whisper,
                    displayName: "Whisper Small",
                    languages: ["Multilingual"],
                    supportsStreaming: true,
                    supportsWordTimestamps: true,
                    estimatedDownloadBytes: 500_000_000
                )
            ]
        case .appleSpeech:
            // Apple SpeechAnalyzer is deliberately not advertised on the
            // Sequoia baseline. It can be added here behind an availability
            // check without changing the rest of Prosody's pipeline.
            return []
        }
    }

    public func descriptor(for engine: STTEngineID) -> STTEngineDescriptor? {
        availableEngines().first { $0.id == engine }
    }

    public func model(id: String, for engine: STTEngineID) -> STTModelDescriptor? {
        availableModels(for: engine).first { $0.id == id }
    }
}

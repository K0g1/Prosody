import Foundation

public actor UnavailableSTTEngine: STTEngine {
    public nonisolated let descriptor: STTEngineDescriptor

    public init(id: STTEngineID, displayName: String, detail: String) {
        self.descriptor = STTEngineDescriptor(id: id, displayName: displayName, detail: detail)
    }

    public func prepare(
        model: STTModelDescriptor,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        throw STTError.unsupportedModel(model.id)
    }

    public func makeSession(source: AudioSource) async throws -> any STTSession {
        throw STTError.modelNotLoaded
    }

    public func unload() async {}
}

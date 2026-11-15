import Foundation

/// A permission-free STT implementation. It intentionally does not invent
/// speech from PCM; callers inject realistic updates from fixtures or a
/// platform adapter while the rest of the pipeline remains exercised.
public actor MockSTTEngine: STTEngine {
    public nonisolated let descriptor: STTEngineDescriptor

    public init(
        descriptor: STTEngineDescriptor = STTEngineDescriptor(
            id: .parakeet,
            displayName: "Mock transcription",
            detail: "In-process test and fallback engine"
        )
    ) {
        self.descriptor = descriptor
    }

    public func prepare(
        model: STTModelDescriptor,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard model.engineID == descriptor.id else {
            throw STTError.unsupportedModel(model.id)
        }
        progress(1)
    }

    public func makeSession(source: AudioSource) async throws -> any STTSession {
        MockSTTSession(source: source)
    }

    public func unload() async {}
}

public actor MockSTTSession: STTSession {
    public nonisolated let updates: AsyncStream<STTUpdate>

    private let continuation: AsyncStream<STTUpdate>.Continuation
    private let source: AudioSource
    private var isFinished = false
    private var injectedSegments: [TranscriptSegment] = []

    public init(source: AudioSource) {
        var continuation: AsyncStream<STTUpdate>.Continuation!
        self.updates = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.source = source
    }

    public func append(samples: [Float], startTime: TimeInterval) async throws {
        guard !isFinished else { throw STTError.sessionFinished }
        guard samples.allSatisfy(\Float.isFinite), startTime.isFinite, startTime >= 0 else {
            throw STTError.invalidAudio
        }
    }

    @discardableResult
    public func emit(_ segment: TranscriptSegment, isFinal: Bool = false) -> Bool {
        guard !isFinished else { return false }
        var segment = segment
        segment.source = source
        segment.isFinal = isFinal
        injectedSegments.append(segment)
        continuation.yield(isFinal
            ? .final(source: source, segment: segment)
            : .provisional(source: source, segment: segment))
        return true
    }

    public func finish() async throws -> FinalTranscript {
        guard !isFinished else { throw STTError.sessionFinished }
        isFinished = true
        continuation.yield(.status(.finished))
        continuation.finish()
        return FinalTranscript(segments: injectedSegments.filter(\.isFinal))
    }

    public func cancel() async {
        guard !isFinished else { return }
        isFinished = true
        continuation.finish()
    }
}

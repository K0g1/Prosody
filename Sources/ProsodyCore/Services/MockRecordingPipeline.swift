import Foundation

public enum RecordingPipelineError: Error, Equatable, Sendable {
    case invalidState(String)
    case sourceNotEnabled(AudioSource)
    case clockFailure(String)
}

public struct MockRecordingPipelineConfiguration: Sendable, Equatable {
    public var title: String
    public var captureMode: CaptureMode
    public var sttEngineID: STTEngineID
    public var sttModelID: String
    public var speakerMode: SpeakerMode
    public var notesProviderID: String
    public var notesModelID: String
    public var noteTemplateID: NoteTemplateID
    public var keepAudio: Bool

    public init(
        title: String = "Mock Recording",
        captureMode: CaptureMode = .both,
        sttEngineID: STTEngineID = .parakeet,
        sttModelID: String = "parakeet-unified",
        speakerMode: SpeakerMode = .basic,
        notesProviderID: String = "local-openai-compatible",
        notesModelID: String = "qwen3-4b",
        noteTemplateID: NoteTemplateID = .lectureNotes,
        keepAudio: Bool = false
    ) {
        self.title = title
        self.captureMode = captureMode
        self.sttEngineID = sttEngineID
        self.sttModelID = sttModelID
        self.speakerMode = speakerMode
        self.notesProviderID = notesProviderID
        self.notesModelID = notesModelID
        self.noteTemplateID = noteTemplateID
        self.keepAudio = keepAudio
    }
}

public struct RecordingResult: Codable, Equatable, Sendable {
    public let session: RecordingSession
    public let transcript: Transcript

    public init(session: RecordingSession, transcript: Transcript) {
        self.session = session
        self.transcript = transcript
    }
}

public struct MockRecordingSnapshot: Equatable, Sendable {
    public let state: RecordingState
    public let session: RecordingSession?
    public let transcript: TranscriptSnapshot
    public let elapsed: TimeInterval

    public init(
        state: RecordingState,
        session: RecordingSession?,
        transcript: TranscriptSnapshot,
        elapsed: TimeInterval
    ) {
        self.state = state
        self.session = session
        self.transcript = transcript
        self.elapsed = elapsed
    }
}

public enum RecordingPipelineEvent: Sendable {
    case state(RecordingState)
    case audio(AudioFrame)
    case transcript(TranscriptSnapshot)
    case completed(RecordingResult)
}

/// An in-process recording substitute for previews, tests, and permission or
/// model failures. It preserves the same clock, transcript, speaker, and
/// event semantics that a ScreenCaptureKit-backed controller should use.
public actor MockRecordingPipeline {
    public nonisolated let events: AsyncStream<RecordingPipelineEvent>

    private let eventContinuation: AsyncStream<RecordingPipelineEvent>.Continuation
    private let configuration: MockRecordingPipelineConfiguration
    private var clock = SessionClock()
    private var transcriptCoordinator: TranscriptCoordinator
    private var session: RecordingSession?
    private var lastPresentationTime: TimeInterval?
    private var state: RecordingState = .idle

    public init(configuration: MockRecordingPipelineConfiguration = MockRecordingPipelineConfiguration()) {
        self.configuration = configuration
        self.transcriptCoordinator = TranscriptCoordinator(speakerMode: configuration.speakerMode)

        var continuation: AsyncStream<RecordingPipelineEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    public func recordingState() -> RecordingState {
        state
    }

    public func start(firstPTS: TimeInterval = 0) async throws -> RecordingSession {
        guard !state.isRecording && !state.isBusy else {
            throw RecordingPipelineError.invalidState("A recording is already active")
        }

        do {
            clock.reset()
            try clock.start(firstPTS: firstPTS)
        } catch {
            throw RecordingPipelineError.clockFailure(String(describing: error))
        }

        await transcriptCoordinator.reset()
        let newSession = RecordingSession(
            title: configuration.title,
            captureMode: configuration.captureMode,
            sttEngineID: configuration.sttEngineID,
            sttModelID: configuration.sttModelID,
            speakerMode: configuration.speakerMode,
            notesProviderID: configuration.notesProviderID,
            notesModelID: configuration.notesModelID,
            noteTemplateID: configuration.noteTemplateID,
            keepAudio: configuration.keepAudio,
            status: "recording"
        )
        session = newSession
        lastPresentationTime = firstPTS
        state = .recording
        emit(.state(state))
        return newSession
    }

    public func pause(atPTS: TimeInterval? = nil) async throws {
        guard state == .recording, var session else {
            throw RecordingPipelineError.invalidState("Only an active recording can be paused")
        }
        do {
            _ = try clock.pause(atPTS: atPTS ?? lastPresentationTime ?? 0)
        } catch {
            throw RecordingPipelineError.clockFailure(String(describing: error))
        }
        session.duration = clock.elapsed
        session.status = "paused"
        self.session = session
        state = .paused
        emit(.state(state))
    }

    public func resume(firstPTS: TimeInterval) async throws {
        guard state == .paused, var session else {
            throw RecordingPipelineError.invalidState("Only a paused recording can be resumed")
        }
        do {
            try clock.resume(firstPTS: firstPTS)
        } catch {
            throw RecordingPipelineError.clockFailure(String(describing: error))
        }
        session.status = "recording"
        self.session = session
        lastPresentationTime = firstPTS
        state = .recording
        emit(.state(state))
    }

    @discardableResult
    public func submit(audio input: MockAudioInput) async throws -> AudioFrame {
        guard state == .recording, let epochID = clock.currentEpochID else {
            throw RecordingPipelineError.invalidState("Audio can only be submitted while recording")
        }
        guard configuration.captureMode.sources.contains(input.source) else {
            throw RecordingPipelineError.sourceNotEnabled(input.source)
        }
        guard input.presentationTime.isFinite, input.presentationTime >= 0 else {
            throw RecordingPipelineError.clockFailure("Invalid presentation timestamp")
        }

        lastPresentationTime = max(lastPresentationTime ?? input.presentationTime, input.presentationTime)
        let frame = AudioFrame(
            source: input.source,
            epochID: epochID,
            startTime: clock.time(forPTS: input.presentationTime, epochID: epochID),
            samples: input.samples
        )
        emit(.audio(frame))
        return frame
    }

    @discardableResult
    public func submit(_ update: STTUpdate) async throws -> TranscriptSnapshot {
        guard state == .recording else {
            throw RecordingPipelineError.invalidState("Transcript updates can only be submitted while recording")
        }
        let snapshot = await transcriptCoordinator.ingest(update)
        emit(.transcript(snapshot))
        return snapshot
    }

    @discardableResult
    public func submit(segment: TranscriptSegment, isFinal: Bool = false) async throws -> TranscriptSnapshot {
        try await submit(isFinal
            ? .final(source: segment.source, segment: segment)
            : .provisional(source: segment.source, segment: segment))
    }

    @discardableResult
    public func finish(atPTS: TimeInterval? = nil) async throws -> RecordingResult {
        guard state == .recording || state == .paused, var session else {
            throw RecordingPipelineError.invalidState("Only an active or paused recording can be finished")
        }
        let wasRecording = state == .recording
        state = .stopping
        emit(.state(state))

        do {
            try clock.stop(atPTS: wasRecording ? (atPTS ?? lastPresentationTime ?? 0) : nil)
        } catch {
            throw RecordingPipelineError.clockFailure(String(describing: error))
        }

        _ = await transcriptCoordinator.finalize()
        let transcript = await transcriptCoordinator.deduplicatedTranscript()
        session.duration = clock.elapsed
        session.status = "completed"
        self.session = session

        let result = RecordingResult(session: session, transcript: transcript)
        state = .completed(session.id)
        emit(.state(state))
        emit(.completed(result))
        return result
    }

    public func snapshot() async -> MockRecordingSnapshot {
        MockRecordingSnapshot(
            state: state,
            session: session,
            transcript: await transcriptCoordinator.snapshot(),
            elapsed: clock.elapsed(atPTS: lastPresentationTime)
        )
    }

    public func reset() async {
        clock.reset()
        session = nil
        lastPresentationTime = nil
        await transcriptCoordinator.reset()
        state = .idle
        emit(.state(state))
    }

    private func emit(_ event: RecordingPipelineEvent) {
        eventContinuation.yield(event)
    }
}

public typealias InProcessRecordingPipeline = MockRecordingPipeline

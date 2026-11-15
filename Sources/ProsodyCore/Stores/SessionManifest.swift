import Foundation

public struct SessionTranscriptionManifest: Codable, Equatable, Sendable {
    public let engine: STTEngineID
    public let model: String

    public init(engine: STTEngineID, model: String) {
        self.engine = engine
        self.model = model
    }
}

public struct SessionSpeakersManifest: Codable, Equatable, Sendable {
    public let mode: SpeakerMode

    public init(mode: SpeakerMode) {
        self.mode = mode
    }
}

public struct SessionNotesManifest: Codable, Equatable, Sendable {
    public let provider: String
    public let model: String
    public let template: NoteTemplateID

    public init(provider: String, model: String, template: NoteTemplateID) {
        self.provider = provider
        self.model = model
        self.template = template
    }
}

public struct SessionManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let title: String
    public let createdAt: Date
    public let duration: TimeInterval
    public let captureMode: CaptureMode
    public let transcription: SessionTranscriptionManifest
    public let speakers: SessionSpeakersManifest
    public let notes: SessionNotesManifest
    public let keepAudio: Bool
    public let status: String
    public let labels: [RecordingLabelSnapshot]?
    public let destinationRootPath: String?
    public let transcriptFileName: String?
    public let outputFolderPath: String?
    /// Nil in manifests written before source kinds were persisted.
    public let sourceKind: String?

    public init(
        schemaVersion: Int = 1,
        id: UUID,
        title: String,
        createdAt: Date,
        duration: TimeInterval,
        captureMode: CaptureMode,
        transcription: SessionTranscriptionManifest,
        speakers: SessionSpeakersManifest,
        notes: SessionNotesManifest,
        keepAudio: Bool,
        status: String,
        outputFolderPath: String? = nil,
        labels: [RecordingLabelSnapshot]? = nil,
        destinationRootPath: String? = nil,
        transcriptFileName: String? = nil,
        sourceKind: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = max(0, duration)
        self.captureMode = captureMode
        self.transcription = transcription
        self.speakers = speakers
        self.notes = notes
        self.keepAudio = keepAudio
        self.status = status
        self.outputFolderPath = outputFolderPath
        self.labels = labels
        self.destinationRootPath = destinationRootPath
        self.transcriptFileName = transcriptFileName
        self.sourceKind = sourceKind
    }

    public init(session: RecordingSession) {
        self.init(
            id: session.id,
            title: session.title,
            createdAt: session.createdAt,
            duration: session.duration,
            captureMode: session.captureMode,
            transcription: SessionTranscriptionManifest(
                engine: session.sttEngineID,
                model: session.sttModelID
            ),
            speakers: SessionSpeakersManifest(mode: session.speakerMode),
            notes: SessionNotesManifest(
                provider: session.notesProviderID,
                model: session.notesModelID,
                template: session.noteTemplateID
            ),
            keepAudio: session.keepAudio,
            status: session.status,
            outputFolderPath: session.outputFolderPath,
            labels: session.labels,
            destinationRootPath: session.destinationRootPath,
            transcriptFileName: session.transcriptFileName,
            sourceKind: session.sourceKind
        )
    }

    public var recordingSession: RecordingSession {
        var session = RecordingSession(
            id: id,
            title: title,
            createdAt: createdAt,
            duration: duration,
            captureMode: captureMode,
            sttEngineID: transcription.engine,
            sttModelID: transcription.model,
            speakerMode: speakers.mode,
            notesProviderID: notes.provider,
            notesModelID: notes.model,
            noteTemplateID: notes.template,
            keepAudio: keepAudio,
            status: status,
            outputFolderPath: outputFolderPath,
            labels: labels,
            destinationRootPath: destinationRootPath,
            transcriptFileName: transcriptFileName
        )
        session.sourceKind = sourceKind
        return session
    }
}

public struct SessionDocument: Codable, Equatable, Sendable {
    public let session: RecordingSession
    public let transcript: Transcript
    public let transcriptMarkdown: String?
    public let notesMarkdown: String?

    public init(
        session: RecordingSession,
        transcript: Transcript,
        transcriptMarkdown: String? = nil,
        notesMarkdown: String? = nil
    ) {
        self.session = session
        self.transcript = transcript
        self.transcriptMarkdown = transcriptMarkdown
        self.notesMarkdown = notesMarkdown
    }
}

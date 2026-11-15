import Foundation

public enum AudioSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case microphone

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System Audio"
        case .microphone: return "Microphone"
        }
    }
}

public enum CaptureMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case microphone
    case both

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System Audio"
        case .microphone: return "Microphone"
        case .both: return "System + Mic"
        }
    }

    public var sources: [AudioSource] {
        switch self {
        case .system: return [.system]
        case .microphone: return [.microphone]
        case .both: return [.system, .microphone]
        }
    }
}

public enum SpeakerMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    case basic
    case full

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .basic: return "Basic"
        case .full: return "Full"
        }
    }

    public var detail: String {
        switch self {
        case .off: return "No speaker labels"
        case .basic: return "You vs system audio"
        case .full: return "Separate individual speakers"
        }
    }
}

public enum PreparationStep: Equatable, Sendable {
    case requestingPermissions
    case loadingModel(progress: Double)
    case startingCapture

    public var title: String {
        switch self {
        case .requestingPermissions: return "Requesting audio permissions…"
        case .loadingModel: return "Preparing transcription…"
        case .startingCapture: return "Starting capture…"
        }
    }
}

public struct UserFacingError: LocalizedError, Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let message: String
    public let recoveryAction: String?

    public var errorDescription: String? { message }

    public init(title: String, message: String, recoveryAction: String? = nil) {
        self.id = UUID()
        self.title = title
        self.message = message
        self.recoveryAction = recoveryAction
    }
}

public enum RecordingState: Equatable, Sendable {
    case idle
    case preparing(PreparationStep)
    case recording
    case paused
    case stopping
    case finalizingTranscript
    case diarizing(progress: Double?)
    case generatingNotes(progress: Double?)
    case completed(UUID)
    case failed(UserFacingError)

    public var isRecording: Bool {
        switch self {
        case .recording, .paused: return true
        default: return false
        }
    }

    public var isBusy: Bool {
        switch self {
        case .preparing, .stopping, .finalizingTranscript, .diarizing, .generatingNotes: return true
        default: return false
        }
    }

    public var statusTitle: String {
        switch self {
        case .idle: return "Ready"
        case .preparing(let step): return step.title
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .stopping: return "Finishing…"
        case .finalizingTranscript: return "Finalizing transcript…"
        case .diarizing: return "Separating speakers…"
        case .generatingNotes: return "Generating notes…"
        case .completed: return "Completed"
        case .failed: return "Needs attention"
        }
    }
}

public struct MeterLevel: Equatable, Sendable {
    public var rms: Double
    public var peak: Double

    public static let zero = MeterLevel(rms: 0, peak: 0)

    public init(rms: Double, peak: Double) {
        self.rms = min(max(rms, 0), 1)
        self.peak = min(max(peak, 0), 1)
    }
}

public struct CaptureEpoch: Codable, Sendable, Equatable {
    public let id: UUID
    public let sessionOffset: TimeInterval
    public let firstPTS: TimeInterval

    public init(id: UUID = UUID(), sessionOffset: TimeInterval, firstPTS: TimeInterval) {
        self.id = id
        self.sessionOffset = sessionOffset
        self.firstPTS = firstPTS
    }
}

public struct RecordingSession: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var duration: TimeInterval
    public let captureMode: CaptureMode
    public let sttEngineID: STTEngineID
    public let sttModelID: String
    public var speakerMode: SpeakerMode
    public let notesProviderID: String
    public let notesModelID: String
    public let noteTemplateID: NoteTemplateID
    public let keepAudio: Bool
    public var status: String
    public var labels: [RecordingLabelSnapshot]?
    public var destinationRootPath: String?
    public var transcriptFileName: String?
    public var outputFolderPath: String?
    /// Nil in legacy sessions, which always performed live recognition.
    public var liveTranscriptionEnabled: Bool?
    public var sourceKind: String?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        duration: TimeInterval = 0,
        captureMode: CaptureMode,
        sttEngineID: STTEngineID,
        sttModelID: String,
        speakerMode: SpeakerMode,
        notesProviderID: String,
        notesModelID: String,
        noteTemplateID: NoteTemplateID,
        keepAudio: Bool,
        status: String = "recording",
        outputFolderPath: String? = nil,
        labels: [RecordingLabelSnapshot]? = nil,
        destinationRootPath: String? = nil,
        transcriptFileName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.captureMode = captureMode
        self.sttEngineID = sttEngineID
        self.sttModelID = sttModelID
        self.speakerMode = speakerMode
        self.notesProviderID = notesProviderID
        self.notesModelID = notesModelID
        self.noteTemplateID = noteTemplateID
        self.keepAudio = keepAudio
        self.status = status
        self.labels = labels
        self.destinationRootPath = destinationRootPath
        self.transcriptFileName = transcriptFileName
        self.outputFolderPath = outputFolderPath
    }
}

public struct SessionSummary: Codable, Identifiable, Sendable, Equatable {
    /// Visible legacy metadata whose source kind predates manifest persistence.
    public static let legacySourceKind = "legacy"

    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var duration: TimeInterval
    public var labels: [RecordingLabelSnapshot]?
    public var folderPath: String?
    /// Nil in indexes written before source kinds were persisted.
    public var sourceKind: String?
    /// Nil until the library has inspected the session's retained assets.
    public var hasRetainedAudio: Bool?

    public init(
        id: UUID,
        title: String,
        createdAt: Date,
        duration: TimeInterval,
        folderPath: String? = nil,
        labels: [RecordingLabelSnapshot]? = nil,
        sourceKind: String? = nil,
        hasRetainedAudio: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.folderPath = folderPath
        self.labels = labels
        self.sourceKind = sourceKind
        self.hasRetainedAudio = hasRetainedAudio
    }

    public var isDictation: Bool { sourceKind == "dictation" }
}

public enum ProcessingStatus: Equatable, Sendable {
    case saved
    case diarizing(Double)
    case generatingNotes(Double)
    case completed
    case warning(String)

    public var message: String {
        switch self {
        case .saved: return "Recording saved"
        case .diarizing: return "Separating speakers…"
        case .generatingNotes: return "Generating notes…"
        case .completed: return "Transcript and notes saved"
        case .warning(let text): return text
        }
    }
}

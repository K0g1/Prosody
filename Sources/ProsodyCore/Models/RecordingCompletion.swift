import Foundation

public struct RecordingCompletion: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let message: String
    public init(sessionID: UUID, message: String) {
        id = UUID(); self.sessionID = sessionID; self.message = message
    }
}

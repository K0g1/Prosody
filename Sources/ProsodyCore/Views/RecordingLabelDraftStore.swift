import Foundation
import Observation

/// Settings-window state for unsaved label edits. Persisted labels remain in
/// ProsodyPreferences; this store only bridges page recreation and tab changes.
@Observable
final class RecordingLabelDraftStore {
    var selectedID: UUID?
    var drafts: [UUID: RecordingLabel] = [:]
    var bookmarks: [UUID: Data] = [:]
    var transcriptBookmarks: [UUID: Data] = [:]
    var newLabelIDs: Set<UUID> = []
    var newLabelOrder: [UUID] = []
    var selectionBeforeNew: UUID?
}

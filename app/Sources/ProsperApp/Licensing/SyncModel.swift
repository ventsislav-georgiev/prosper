import Foundation

/// What a sync run included or excluded — drives the Sync status pane.
struct SyncReport: Sendable {
    struct Item: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let detail: String   // "synced …" for included, or the exclusion reason
        let bytes: Int
    }

    var includedDefaults = 0
    var includedFiles: [Item] = []
    var excluded: [Item] = []
}

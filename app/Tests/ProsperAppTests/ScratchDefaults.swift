import Foundation
import XCTest

extension XCTestCase {
    /// A throwaway `UserDefaults` suite that never touches ~/Library/Preferences.
    /// A plain suite name makes cfprefsd write ~/Library/Preferences/<suite>.plist,
    /// and it re-writes an empty 42-byte plist asynchronously even after
    /// removePersistentDomain + deleting the file. An absolute-path suite name
    /// is stored at that path instead, so the plist lands in $TMPDIR.
    func scratchDefaults(_ prefix: String) -> UserDefaults {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosper-test-defaults", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = dir.appendingPathComponent("\(prefix)-\(UUID().uuidString)").path
        addTeardownBlock {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(atPath: name + ".plist")
        }
        return UserDefaults(suiteName: name)!
    }
}

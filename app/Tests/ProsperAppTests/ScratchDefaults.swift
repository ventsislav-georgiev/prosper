import Foundation
import XCTest
@testable import ProsperApp

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

/// #305: under XCTest the app's one store is a per-process scratch suite, never the real
/// `com.apple.dt.xctest.tool` domain that `.standard` resolves to here.
final class PreferencesScratchStoreTests: XCTestCase {
    func testPreferencesStoreIsAPerProcessScratchSuite() {
        XCTAssertFalse(Preferences.defaults === UserDefaults.standard)
        XCTAssertTrue(Preferences.scratchSuitePath.hasSuffix("prosper-xctest-defaults-\(getpid())"))
        let key = "prosper.scratchProbe.\(UUID().uuidString)"
        Preferences.defaults.set(true, forKey: key)
        defer { Preferences.defaults.removeObject(forKey: key) }
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }
}

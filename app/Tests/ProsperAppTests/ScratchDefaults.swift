import Foundation
import XCTest
@testable import ProsperApp

/// #341: every test file and dir lives under $TMPDIR/prosper-tests/, never the $TMPDIR root
/// (millions of entries on a dev Mac, 30-100 ms per create there, and leaks pile up).
let testTempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("prosper-tests", isDirectory: true)

extension XCTestCase {
    /// A fresh, existing directory `prosper-tests/<label>-<8 hex>/`, removed at teardown.
    /// Short suffix keeps unix-socket paths under the 104-byte sun_path limit.
    func tempDir(_ label: String = #function) -> URL {
        let name = label.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let dir = testTempRoot.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

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
        // #339: never the $TMPDIR root, where each synchronous plist rewrite scales with its size.
        XCTAssertNotEqual(URL(fileURLWithPath: Preferences.scratchSuitePath).deletingLastPathComponent().standardizedFileURL,
                          FileManager.default.temporaryDirectory.standardizedFileURL)
        // #381: test dirs live in a prosper-tests subdirectory, never the $TMPDIR root itself.
        XCTAssertNotEqual(testTempRoot.standardizedFileURL, FileManager.default.temporaryDirectory.standardizedFileURL,
                          "testTempRoot must not be the $TMPDIR root")
        XCTAssertEqual(testTempRoot.lastPathComponent, "prosper-tests")
        let key = "prosper.scratchProbe.\(UUID().uuidString)"
        Preferences.defaults.set(true, forKey: key)
        defer { Preferences.defaults.removeObject(forKey: key) }
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
    }

    /// #381 leak detector: a direct child of testTempRoot older than 10 minutes is a leftover
    /// from a previous run (a dropped tempDir teardown or an unwaited async writer). 10 minutes
    /// is above any single suite's length (about 2 minutes), so a concurrent or in-flight run's
    /// live dirs are ignored, and below the gap between QA runs. A bundle-end observer is not
    /// possible in a SwiftPM test target without a principal class, so this row is the stand-in.
    /// It deletes nothing: it reports, the operator cleans (OQ-30). No root = pass.
    func testTempRootHoldsNoStaleEntries() throws {
        let staleAfter: TimeInterval = 10 * 60
        let fm = FileManager.default
        guard fm.fileExists(atPath: testTempRoot.path) else { return }
        let children = try fm.contentsOfDirectory(at: testTempRoot, includingPropertiesForKeys: [.contentModificationDateKey])
        let stale = children.filter {
            let mtime = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return Date().timeIntervalSince(mtime) > staleAfter
        }.map(\.lastPathComponent).sorted()
        XCTAssertEqual(stale, [], "stale entries under \(testTempRoot.path) (leaked by an earlier run)")
    }

    /// #342 (#305 M1): `Preferences.defaults` is the suite at `scratchSuitePath`, not just
    /// "something other than .standard" — a probe key lands in that plist file.
    func testPreferencesStorePersistsToTheScratchSuitePlist() throws {
        let key = "prosper.scratchPlistProbe.\(UUID().uuidString)"
        Preferences.defaults.set("probe", forKey: key)
        defer { Preferences.defaults.removeObject(forKey: key); Preferences.defaults.synchronize() }
        Preferences.defaults.synchronize()
        let data = try Data(contentsOf: URL(fileURLWithPath: Preferences.scratchSuitePath + ".plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist[key] as? String, "probe", "Preferences.defaults must write the plist at scratchSuitePath")
    }

    /// #342 (#305 M4): no ProsperApp source other than Preferences.swift opens its own defaults
    /// store, so every settings reader (CompletionStats, AnalyticsStore, ...) goes through
    /// `Preferences.defaults` and inherits the XCTest scratch suite. Exact-line allowlist.
    func testOnlyPreferencesOpensAnAppDefaultsStore() throws {
        let allowed: [String: String] = [
            // Migrates the legacy bundle-id domain into the real one; runs only in a bundled launch.
            "DefaultsMigration.swift: let defaults = UserDefaults.standard": "legacy-domain migration",
            // Reads the system hotkey domain, never writes.
            "SpotlightShortcutConflict.swift: guard let keys = UserDefaults(suiteName: \"com.apple.symbolichotkeys\")?": "system-domain read",
            // Reads Safari's domain for search-engine import, never writes.
            "BrowserSearchImporter.swift: let suite = UserDefaults(suiteName: \"com.apple.Safari\")": "system-domain read",
            // e2e-only throwaway suite (PROSPER_HOME set); otherwise Preferences.defaults.
            "SnippetStore.swift: if E2EConfig.isolated, let suite = UserDefaults(suiteName: suiteName) {": "e2e isolation suite",
            // #344: menu-bar item spacing is a system-wide (AnyApplication) setting the user opts into.
            "MenuBarSpacing.swift: CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication,": "global menu-bar spacing read",
            "MenuBarSpacing.swift: CFPreferencesSetValue(key as CFString, value as CFNumber, kCFPreferencesAnyApplication,": "global menu-bar spacing write",
            "MenuBarSpacing.swift: CFPreferencesSetValue(key as CFString, nil, kCFPreferencesAnyApplication,": "global menu-bar spacing reset",
        ]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        // #385 (QA #155): matched over the whole comment-stripped file, so a call wrapped across lines
        // (`UserDefaults` / `.standard`, `UserDefaults(` / `suiteName:`) still counts, reported at the
        // line the match starts on. Spellings: `UserDefaults.standard`, a typed `UserDefaults = .standard`,
        // `UserDefaults(` and `UserDefaults.init(`, CFPreferences{Set,Copy,Get}, and `@AppStorage` with
        // no `store:` or with `store: .standard`. A wrap can also start a fail-safe false hit on an
        // innocent line; accepted, the same cost-of-an-exact-scan stance as #383. No NSUserDefaults
        // rule: that name does not compile in Swift.
        let rule = /UserDefaults\s*(\.\s*standard\b|(\.\s*init\s*)?\(|=\s*\.standard\b)|CFPreferences(Set|Copy|Get)|@AppStorage\s*\((?![^)]*store:)|@AppStorage\s*\([^)]*store:\s*\.standard\b/
        var hits: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "Preferences.swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let text = lines.map { $0.hasPrefix("//") ? "" : $0 }.joined(separator: "\n")
            var seen = Set<Int>()
            for match in text.matches(of: rule) {
                let i = text[..<match.range.lowerBound].filter { $0 == "\n" }.count
                if seen.insert(i).inserted { hits.append("\(url.lastPathComponent): \(lines[i])") }
            }
        }
        XCTAssertEqual(hits.filter { allowed[$0] == nil }, [], "a source outside Preferences.swift opens its own UserDefaults store")
        // #385 (QA #153): a stale key (renamed file, edited or re-indented line) or a duplicated line fails by name.
        for key in allowed.keys.sorted() {
            let n = hits.filter { $0 == key }.count
            XCTAssertEqual(n, 1, "allowlist key matched \(n) times, want exactly once: \(key)")
        }
    }
}

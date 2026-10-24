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

/// #528: on some CI runs `Preferences.defaults` stops taking writes mid-run (sets and removes no
/// longer read back, the last value before that point stays), and every later test that reads a
/// leaked value fails far from the cause. This probe runs before EVERY test in the bundle and fails
/// the first victim with the store's state, so one red run names the cause.
enum DefaultsProbe {
    /// No app key lives under `prosper.test.`; the probe removes it again after the read-back.
    static let key = "prosper.test.defaultsProbe"

    /// nil when a fresh value written to `defaults` syncs and reads back; else one line of evidence.
    static func failure(_ defaults: UserDefaults, path: String, previousTest: String? = nil) -> String? {
        let value = UUID().uuidString
        defaults.set(value, forKey: key)
        let synced = defaults.synchronize()
        let back = defaults.string(forKey: key)
        defer { defaults.removeObject(forKey: key) }
        if synced && back == value { return nil }
        // Failure path only from here: nothing below runs on a healthy store.
        let fm = FileManager.default
        func describe(_ p: String) -> String {
            guard let a = try? fm.attributesOfItem(atPath: p) else { return "missing" }
            let mode = String((a[.posixPermissions] as? NSNumber)?.intValue ?? -1, radix: 8)
            return "mode \(mode) owner \(a[.ownerAccountName] ?? "?") size \(a[.size] ?? "?")"
        }
        let dir = (path as NSString).deletingLastPathComponent
        let free = (try? fm.attributesOfFileSystem(forPath: dir))?[.systemFreeSize] ?? "?"
        let onDisk = (try? Data(contentsOf: URL(fileURLWithPath: path + ".plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let keys = (defaults.persistentDomain(forName: path) ?? [:]).keys.filter { $0 != key }.sorted()
        return "Preferences.defaults stopped taking writes (#528): synchronize()=\(synced), "
            + "read back \(back.map { "\"\($0)\"" } ?? "nil") for \"\(value)\", "
            + "plist on disk has it: \(onDisk?[key] as? String == value); "
            + "suite \(path); dir \(describe(dir)); plist \(describe(path + ".plist")); free \(free) bytes; "
            + "pid \(getpid()); cfprefsd \(cfprefsdPIDs()) (at first probe \(firstCfprefsd ?? "?")); "
            + "previous test \(previousTest ?? "none"); \(keys.count) app keys held: "
            + keys.prefix(40).joined(separator: ",")
    }

    /// The user's cfprefsd pids. A different value than at the first probe means cfprefsd restarted
    /// mid-run, the lead the QA read points at (a path suite frozen at its last good state).
    static func cfprefsdPIDs() -> String {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-U", "\(getuid())", "-x", "cfprefsd"]
        p.standardOutput = out
        guard (try? p.run()) != nil else { return "?" }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").joined(separator: "+")
    }
    nonisolated(unsafe) static var firstCfprefsd: String?
}

/// Registered once at bundle load (below); probes `Preferences.defaults` before each test starts.
final class DefaultsProbeObserver: NSObject, XCTestObservation {
    nonisolated(unsafe) static let shared = DefaultsProbeObserver()
    /// The test the probe last ran before: a test reading its own name here proves the observer ran.
    private(set) var lastProbed: String?
    /// One report per run: a frozen store stays frozen, and ~1000 copies of the line bury the log.
    private(set) var reported = false

    func testCaseWillStart(_ testCase: XCTestCase) {
        if DefaultsProbe.firstCfprefsd == nil { DefaultsProbe.firstCfprefsd = DefaultsProbe.cfprefsdPIDs() }
        check(testCase, Preferences.defaults, path: Preferences.scratchSuitePath, previousTest: lastProbed)
        lastProbed = testCase.name
    }

    func check(_ testCase: XCTestCase, _ defaults: UserDefaults, path: String, previousTest: String?) {
        guard !reported, let message = DefaultsProbe.failure(defaults, path: path, previousTest: previousTest) else { return }
        reported = true
        // An explicit location: a captured call stack costs ~6 s of symbolication on this bundle.
        let here = XCTSourceCodeContext(location: XCTSourceCodeLocation(filePath: #filePath, lineNumber: #line))
        testCase.record(XCTIssue(type: .assertionFailure, compactDescription: message + "; later tests are not probed",
                                 sourceCodeContext: here))
    }
}

// A SwiftPM test bundle has no Info.plist principal class, so the observer registers from a
// module initializer (SE-0492 `@section`/`@used`): it runs when xctest loads the bundle, on the
// main thread, before any test, under any --filter. `hasAttribute(section)` reads false on 6.4 even
// though the attribute compiles, hence the compiler gate (6.4 = local and CI). An older compiler
// leaves the observer unregistered and testObserverProbedBeforeThisTest fails.
#if compiler(>=6.4)
@used @section("__DATA,__mod_init_func")
private let registerDefaultsProbe: @convention(c) () -> Void = {
    MainActor.assumeIsolated { XCTestObservationCenter.shared.addTestObserver(DefaultsProbeObserver.shared) }
}
#endif

/// #528: the probe itself, driven on private suites under tempDir(), never on Preferences.defaults.
final class DefaultsProbeTests: XCTestCase {
    /// A store whose writes never land: the in-memory read-back the CI flake shows.
    private final class WriteDroppingDefaults: UserDefaults, @unchecked Sendable {
        override func set(_ value: Any?, forKey defaultName: String) {}
    }

    private func privateSuite() -> String {
        let path = tempDir().appendingPathComponent("suite").path
        addTeardownBlock { UserDefaults(suiteName: path)?.removePersistentDomain(forName: path) }
        return path
    }

    /// The observer probed before THIS test started, so it is registered bundle-wide, not per class.
    func testObserverProbedBeforeThisTest() {
        XCTAssertEqual(DefaultsProbeObserver.shared.lastProbed, name)
    }

    func testHealthyStorePassesAndTheProbeKeyIsRemoved() throws {
        let path = privateSuite()
        let d = try XCTUnwrap(UserDefaults(suiteName: path))
        XCTAssertNil(DefaultsProbe.failure(d, path: path))
        XCTAssertNil(d.object(forKey: DefaultsProbe.key))
        XCTAssertNil(d.persistentDomain(forName: path)?[DefaultsProbe.key])
    }

    /// A read-only suite dir: the write fails on disk (synchronize() is false) and the message names it.
    func testReadOnlySuiteDirFiresWithTheStoreState() throws {
        let path = privateSuite()
        let dir = (path as NSString).deletingLastPathComponent
        let d = try XCTUnwrap(UserDefaults(suiteName: path))
        d.set("leaked", forKey: "userName")
        XCTAssertTrue(d.synchronize())
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        let message = try XCTUnwrap(DefaultsProbe.failure(d, path: path, previousTest: "-[X testBefore]"))
        for part in ["synchronize()=false", "suite \(path);", "dir mode 555 owner \(NSUserName())", "plist mode ",
                     "free ", "pid \(getpid());", "cfprefsd ", "previous test -[X testBefore]", "1 app keys held: userName"] {
            XCTAssertTrue(message.contains(part), "missing \"\(part)\" in: \(message)")
        }
    }

    /// Writes that never read back fire even when synchronize() reports success.
    func testWritesThatDoNotReadBackFire() throws {
        let path = privateSuite()
        let d = try XCTUnwrap(WriteDroppingDefaults(suiteName: path))
        let message = try XCTUnwrap(DefaultsProbe.failure(d, path: path))
        XCTAssertTrue(message.contains("synchronize()=true, read back nil"), message)
    }

    /// Catches the issues recorded on it (XCTExpectFailure works too, but costs ~4 s per use here).
    private final class IssueSpy: XCTestCase {
        var issues: [XCTIssue] = []
        override func record(_ issue: XCTIssue) { issues.append(issue) }
    }

    /// The observer turns a probe failure into a failure of the test that is starting.
    /// A private observer: tripping the shared one would silence the real probe for the run.
    func testObserverFailsTheStartingTest() throws {
        let path = privateSuite()
        let d = try XCTUnwrap(WriteDroppingDefaults(suiteName: path))
        let spy = IssueSpy()
        DefaultsProbeObserver().check(spy, d, path: path, previousTest: nil)
        XCTAssertEqual(spy.issues.count, 1)
        XCTAssertEqual(spy.issues.first?.type, .assertionFailure)
        XCTAssertTrue(spy.issues.first?.compactDescription.contains("stopped taking writes") == true)
        XCTAssertTrue(spy.issues.first?.compactDescription.contains(path) == true)
    }

    /// Once per run: after the first report, a still-frozen store fails no further test.
    func testObserverReportsOnlyTheFirstFailure() throws {
        let path = privateSuite()
        let d = try XCTUnwrap(WriteDroppingDefaults(suiteName: path))
        let observer = DefaultsProbeObserver(), first = IssueSpy(), second = IssueSpy()
        observer.check(first, d, path: path, previousTest: nil)
        observer.check(second, d, path: path, previousTest: nil)
        XCTAssertEqual(first.issues.count, 1)
        XCTAssertEqual(second.issues.count, 0)
        XCTAssertTrue(observer.reported)
        XCTAssertFalse(DefaultsProbeObserver.shared.reported, "the real probe already fired this run")
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

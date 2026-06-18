import XCTest
@testable import ProsperApp

/// Unit tests for `AppIndex` ranking + the `ModeTrigger` prefix parser. Ranking
/// is tested against a synthetic app list so it doesn't depend on what's actually
/// installed; a couple of integration checks exercise the live machine index.
final class AppIndexTests: XCTestCase {

    private func entry(_ name: String) -> AppEntry {
        AppEntry(name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"), bundleId: nil)
    }

    private var sample: [AppEntry] {
        ["Safari", "System Settings", "Calculator", "Calendar",
         "Activity Monitor", "Audio MIDI Setup", "Music", "Mail"].map(entry)
    }

    func testExactNameRanksFirst() {
        let r = AppIndex.rank(query: "music", in: sample, limit: 6)
        XCTAssertEqual(r.first?.name, "Music")
    }

    func testPrefixMatch() {
        let r = AppIndex.rank(query: "cal", in: sample, limit: 6).map(\.name)
        // Both Calculator and Calendar start with "cal"; shorter name wins the tie.
        XCTAssertEqual(Set(r.prefix(2)), Set(["Calculator", "Calendar"]))
        XCTAssertEqual(r.first, "Calendar") // shorter than "Calculator"
    }

    func testAliasSystemPreferencesResolvesToSystemSettings() {
        let r = AppIndex.rank(query: "system preferences", in: sample, limit: 6)
        XCTAssertEqual(r.first?.name, "System Settings",
                       "the legacy name must resolve to the shipping app")
    }

    func testAliasCalcResolvesToCalculator() {
        let r = AppIndex.rank(query: "calc", in: sample, limit: 6)
        XCTAssertEqual(r.first?.name, "Calculator")
    }

    func testWordPrefixMatch() {
        // "midi" matches the second word of "Audio MIDI Setup".
        let r = AppIndex.rank(query: "midi", in: sample, limit: 6).map(\.name)
        XCTAssertTrue(r.contains("Audio MIDI Setup"))
    }

    func testFuzzySubsequence() {
        XCTAssertTrue(AppIndex.isSubsequence("amsetup", of: "audio midi setup"))
        XCTAssertTrue(AppIndex.isSubsequence("setup", of: "audio midi setup"))
        XCTAssertFalse(AppIndex.isSubsequence("zzz", of: "safari"))
        XCTAssertFalse(AppIndex.isSubsequence("ssetup", of: "audio midi setup")) // only one 's'
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(AppIndex.rank(query: "zzzznomatch", in: sample, limit: 6).isEmpty)
    }

    func testEmptyQueryReturnsEmpty() {
        XCTAssertTrue(AppIndex.rank(query: "   ", in: sample, limit: 6).isEmpty)
    }

    // MARK: - ModeTrigger

    // Translate, shell and open-app all migrated to system extensions
    // (com.prosper.translate / .shell / .open), so none are built-in ModeTriggers
    // anymore — they're contributed via their manifests and resolved through the
    // extension registry (covered in extension routing tests). `match` (built-ins
    // only) therefore returns nil for all of their prefixes.
    func testTranslateNoLongerBuiltinTrigger() {
        XCTAssertNil(ModeTrigger.match("l hello world"))
    }

    func testShellNoLongerBuiltinTrigger() {
        XCTAssertNil(ModeTrigger.match("! ls -la"))
        XCTAssertNil(ModeTrigger.match("!ls"))
        XCTAssertNil(ModeTrigger.match("> echo hi"))
    }

    func testOpenAppNoLongerBuiltinTrigger() {
        XCTAssertNil(ModeTrigger.match("o safari"))
    }

    func testNonTriggerStaysUniversal() {
        XCTAssertNil(ModeTrigger.match("hello"))
        XCTAssertNil(ModeTrigger.match("lo and behold")) // "lo " is not "l "
    }

    // MARK: - Live index integration

    @MainActor
    func testLiveIndexFindsSystemSettings() throws {
        let apps = AppIndex.shared.search("system preferences", limit: 3)
        try XCTSkipIf(AppIndex.shared.apps.isEmpty, "no apps scanned in this environment")
        XCTAssertEqual(apps.first?.name, "System Settings")
    }
}

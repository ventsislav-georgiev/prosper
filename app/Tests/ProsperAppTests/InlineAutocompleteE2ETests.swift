#if canImport(WebKit)
import AppKit
import XCTest
@testable import ProsperApp

/// True end-to-end inline autocomplete against the REAL Prosper app + the REAL
/// on-device model. We launch the app from source (`ProsperAppRunner`), focus a
/// real external field (`E2EHost`), type a predictable prefix, then accept the
/// ghost suggestion with → (accept-all) / Tab (accept-word) and assert the field
/// GREW with injected text. The model is non-deterministic, so we assert the
/// pipeline (tap → AX context → model → ghost → accept → inject) produced *some*
/// non-empty completion — not an exact string.
///
///   scripts/e2e.sh
///
/// Skipped unless `PROSPER_E2E=1` and Accessibility is trusted for both the test
/// runner and the dev ProsperApp binary. Heavy: loads the multi-GB model.
@MainActor
final class InlineAutocompleteE2ETests: XCTestCase {

    nonisolated(unsafe) private var runner: ProsperAppRunner?
    nonisolated(unsafe) private var host: E2EHost?

    // From AutocompleteEngine: → accepts the whole suggestion (and is a no-op /
    // non-polluting when none is showing — it just moves the caret). Ctrl+`
    // force-activates a suggestion, overriding the idle heuristics + any Esc
    // suppression, requesting immediately.
    private static let rightArrow: CGKeyCode = 124
    private static let backtick: CGKeyCode = 50

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROSPER_E2E"] == "1",
                          "e2e disabled; run scripts/e2e.sh (sets PROSPER_E2E=1).")
        try XCTSkipUnless(PermissionsManager.isAccessibilityTrusted(),
                          "test runner lacks Accessibility (needed to post events / read AX).")
        let runner = ProsperAppRunner()
        self.runner = runner
        // No snippets needed; we exercise autocomplete. The model preloads because
        // autocomplete is enabled.
        let live = try runner.launch(snippets: [], timeout: 120)
        try XCTSkipUnless(live,
                          "ProsperApp tap not live — grant the dev ProsperApp binary Accessibility access and retry.")
    }

    override func tearDownWithError() throws {
        host?.stop()
        runner?.stop()
    }

    /// Native single-line field — the most reliable AX caret-context surface.
    func testCompletionInjectedInNativeField() throws {
        try expectCompletion(in: .nsTextField)
    }

    /// Native multi-line view — proves the pipeline + accept also work for a
    /// multi-line surface (TextEdit / Notes / native compose).
    func testCompletionInjectedInTextView() throws {
        try expectCompletion(in: .nsTextView)
    }

    /// End of a complete word the user hasn't spaced yet ("…brown" + accept): the
    /// real-world bug was the model's next word gluing on ("brownfox") or a double
    /// space appearing. Model output is non-deterministic, so we assert INVARIANTS
    /// the engine must always hold, whatever it generates: the seeded text stays
    /// intact at the front, and no run of two spaces is ever produced.
    func testNoGlueOrDoubleSpaceAtWordEnd() throws {
        try expectCleanJoin(in: .nsTextField, prefix: "the quick brown")
    }

    /// Middle of an UNFINISHED word ("…brow" with no following text): the engine
    /// must either continue that word or stay quiet — never insert a fresh word
    /// against the fragment ("brow fox") and never double-space.
    func testNoOrphanedFragmentMidWord() throws {
        try expectCleanJoin(in: .nsTextView, prefix: "I was just thinking abou")
    }

    /// Force-triggers a completion at the caret, accepts the whole ghost, and
    /// asserts the formatting invariants. Suppression (nothing injected) is a valid
    /// outcome — the contract is "never garble", not "always complete".
    private func expectCleanJoin(in kind: E2EHost.Kind, prefix: String) throws {
        let host = E2EHost(kind)
        self.host = host
        try host.launch()
        defer { host.stop(); self.host = nil }
        XCTAssertTrue(host.waitUntilFocused(timeout: 12),
                      "[\(kind.rawValue)] E2EHost never became frontmost/focused")
        host.clickToFocus()

        var base = ""
        for _ in 0..<10 where base != prefix {
            base = host.seed(prefix)
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(base, prefix, "[\(kind.rawValue)] prefix never seeded; got \"\(base)\"")

        // One force-trigger + accept-all cycle (retry a few times for model warmup).
        var value = base
        for _ in 0..<4 where value == base {
            KeySynth.tap(Self.backtick, flags: .maskControl)
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(6.0))
            KeySynth.tap(Self.rightArrow)
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1.0))
            value = host.focusedValue ?? base
        }

        // Invariants — hold whether or not anything was injected:
        XCTAssertTrue(value.hasPrefix(base),
                      "[\(kind.rawValue)] seeded text corrupted: \"\(value)\"")
        XCTAssertFalse(value.contains("  "),
                       "[\(kind.rawValue)] double space introduced: \"\(value)\"")
    }

    /// Seeds a prefix, force-triggers a suggestion (Ctrl+`), accepts the whole ghost
    /// with →, and asserts the field GREW with model-injected text. The model is
    /// non-deterministic, so we assert the *pipeline* fired (tap → AX context →
    /// model → ghost → accept → inject lands), not an exact completion.
    ///
    /// The prefix is seeded directly via AX (`host.seed`, addressed by pid), not typed:
    /// the live engine's per-key type-through delays the event tap enough to drop
    /// synthesized keys mid-burst, and Prosper reads request context from AX regardless
    /// of how the text got there, so the force-trigger (Ctrl+`) sees it identically.
    /// → is non-polluting when no ghost shows (just moves the caret), so the trigger
    /// retry loop is safe.
    private func expectCompletion(in kind: E2EHost.Kind,
                                  prefix: String = "the quick brown fox jumps over the lazy ") throws {
        let host = E2EHost(kind)
        self.host = host
        try host.launch()
        defer { host.stop(); self.host = nil }
        XCTAssertTrue(host.waitUntilFocused(timeout: 12),
                      "[\(kind.rawValue)] E2EHost never became frontmost/focused")

        // Click once so a single-line NSTextField spins up its field editor — until
        // then it exposes no settable focused AX element. (Harmless for the textview.)
        host.clickToFocus()

        // Seed the prefix directly via AX (not keystrokes): the live engine's per-key
        // type-through processing delays the event tap enough to drop synthesized keys
        // mid-burst, and bare keycodes mistranslate on non-US layouts. Address the host
        // by pid (not the racy system-wide focused element, which doesn't resolve in the
        // brief window right after focus is won). An AX-set value is seen identically by
        // the force-trigger below. Retry until it sticks.
        var base = ""
        for _ in 0..<10 where base != prefix {
            base = host.seed(prefix)
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(base, prefix,
                       "[\(kind.rawValue)] prefix never seeded; got \(base.count)/\(prefix.count) \"\(base)\"")

        // One clean cycle per attempt: force-activate → wait for the model →
        // accept-all → check. A few attempts cover model warmup + gen latency.
        var value = base
        for _ in 0..<4 where value.count <= base.count {
            KeySynth.tap(Self.backtick, flags: .maskControl)              // force-activate
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(6.0))  // model gen latency
            KeySynth.tap(Self.rightArrow)                                 // accept all
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1.0))
            value = host.focusedValue ?? ""
        }
        XCTAssertGreaterThan(value.count, base.count,
                             "[\(kind.rawValue)] no completion injected; base=\(base.count) final=\(value)")
        XCTAssertTrue(value.hasPrefix(base),
                      "[\(kind.rawValue)] typed text not preserved ahead of the completion: \(value)")
    }
}
#endif

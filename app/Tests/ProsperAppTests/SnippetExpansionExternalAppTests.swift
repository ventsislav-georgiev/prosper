#if canImport(WebKit)
import AppKit
import XCTest
@testable import ProsperApp

/// True end-to-end inline snippet expansion across every input KIND we care about
/// — native single-line, native rich text view, web `<input>`, web `<textarea>`,
/// and Chromium `contenteditable`. The REAL Prosper app is built and launched from
/// source (`ProsperAppRunner`, isolated HOME, auto-update off, snippets seeded);
/// its own keystroke tap does the expansion. Each kind is an `E2EHost` instance
/// launched as a real frontmost process. We synthesize real keystrokes and read
/// the result back through the system-wide AX focused element. No real third-party
/// apps (TextEdit / Slack / Telegram / Safari / Chrome) are launched — the host
/// stands in for their insertion sites.
///
///   scripts/e2e.sh            # builds from source, then runs the e2e suites
///
/// Skipped unless `PROSPER_E2E=1` and Accessibility is trusted for BOTH the test
/// runner (posts events / reads AX) and the dev ProsperApp binary (installs the tap).
@MainActor
final class SnippetExpansionExternalAppTests: XCTestCase {

    // nonisolated so the nonisolated tearDown override can stop them.
    nonisolated(unsafe) private var runner: ProsperAppRunner?
    nonisolated(unsafe) private var host: E2EHost?
    private var savedClipboard: String?

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROSPER_E2E"] == "1",
                          "e2e disabled; run scripts/e2e.sh (sets PROSPER_E2E=1).")
        try XCTSkipUnless(PermissionsManager.isAccessibilityTrusted(),
                          "test runner lacks Accessibility (needed to post events / read AX).")

        savedClipboard = NSPasteboard.general.string(forType: .string)
        let runner = ProsperAppRunner()
        self.runner = runner
        let live = try runner.launch(snippets: [
            .init(name: "Sig", keyword: ";;sig", text: "Best regards"),
            .init(name: "Date", keyword: ";;date", text: "{date:yyyy-MM-dd}"),
            .init(name: "Clip", keyword: ";;clip", text: "[{clipboard}]"),
            .init(name: "Cursor", keyword: ";;cur", text: "ab{cursor}cd"),
        ])
        try XCTSkipUnless(live,
                          "ProsperApp tap not live — grant the dev ProsperApp binary Accessibility access and retry.")
    }

    override func tearDownWithError() throws {
        host?.stop()
        runner?.stop()
        MainActor.assumeIsolated {
            NSPasteboard.general.clearContents()
            if let savedClipboard { NSPasteboard.general.setString(savedClipboard, forType: .string) }
        }
    }

    func testExpansionAcrossInputKinds() throws {
        for kind in E2EHost.Kind.allCases { try runKind(kind) }
    }

    private func runKind(_ kind: E2EHost.Kind) throws {
        let host = E2EHost(kind)
        self.host = host
        try host.launch()
        defer { host.stop(); self.host = nil }
        // Best-effort readiness wait. NOT asserted: a freshly-focused NSTextField
        // exposes no AX focused element until its field editor spins up, so the gate
        // can read "not focused" while keystrokes already land. The per-case value
        // assertions below are the real verification.
        _ = host.waitUntilFocused()

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("HELLO", forType: .string)

        let cases: [(keyword: String, expected: String)] = [
            (";;sig", "Best regards"),
            (";;date", df.string(from: Date())),
            (";;clip", "[HELLO]"),
            (";;cur", "abcd"),              // {cursor} sets the caret; resulting text is "abcd"
        ]
        // A contenteditable div's `innerText` always reports a trailing newline,
        // so normalise it away before comparing (the inserted text is otherwise exact).
        func normalize(_ s: String?) -> String? {
            guard kind == .contentEditable else { return s }
            return s.map { $0.hasSuffix("\n") ? String($0.dropLast()) : $0 }
        }

        for c in cases {
            KeySynth.clearFocusedField()
            KeySynth.type(c.keyword)
            let deadline = Date().addingTimeInterval(3)
            var value = normalize(host.focusedValue)
            while value != c.expected, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                value = normalize(host.focusedValue)
            }
            XCTAssertEqual(value, c.expected,
                           "[\(kind.rawValue)] \(c.keyword) expansion not observed; read back: \(value ?? "nil")")
        }
    }
}
#endif

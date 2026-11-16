import AppKit
import XCTest
@testable import ProsperApp

/// #923 (design rule 10): the Agent Sessions Diagnostics pane's text, its parse-error ring, its Copy (a private named
/// pasteboard, never the user's) and its sidebar "..." item. Values only: no window, no menu, no real dch.
final class AgentDiagnosticsTests: XCTestCase {
    static let secret = "transcript words that must stay out"

    func line(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) + Data("\n".utf8) }

    func say(_ text: String, version: String) -> Data {
        line(["type": "assistant", "sessionId": "s-1", "version": version, "cwd": "/Users/example/api",
              "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    func failed(_ reason: String) -> DecodedEntry {
        DecodedEntry(version: "2.1.300", items: [.block(.failed(reason: reason, raw: nil), .generic)])
    }

    func text(_ a: TranscriptAssembler) -> String {
        AgentDiagnostics.text(prosper: "1.2.3", dch: "1.38.0", version: a.latestVersion, counts: a.counts(),
                              errors: a.parseErrors)
    }

    func testTextListsEveryFieldWithAndWithoutNewerThanTested() {
        var a = TranscriptAssembler()
        a.add(TranscriptDecoder.decode(line: say(Self.secret, version: "2.1.300")), source: nil)
        a.add(TranscriptDecoder.decode(line: Data("{not json \(Self.secret)".utf8)), source: nil)
        XCTAssertEqual(text(a), [
            "Prosper 1.2.3",
            "dch 1.38.0",
            "Claude Code tested: \(ClaudeCodeCompat.lower)-\(ClaudeCodeCompat.upper)",
            "Claude Code (session): 2.1.300",
            "Tiers: specific=1 generic=0 degraded=0 failed=1 hidden=0",
            "Last parse errors:",
            "  2.1.300: Unreadable entry",
        ].joined(separator: "\n"))

        var newer = TranscriptAssembler()
        newer.add(TranscriptDecoder.decode(line: say("hi", version: "2.1.400")), source: nil)
        let t = text(newer)
        XCTAssertTrue(t.contains("\nClaude Code (session): 2.1.400 (newer than tested)\n"), t)
        XCTAssertTrue(t.hasSuffix("Last parse errors:\n  none"), t)

        let none = AgentDiagnostics.text(prosper: "1.2.3", dch: "", version: nil, counts: [:], errors: [])
        XCTAssertTrue(none.contains("\ndch unknown\n") && none.contains("\nClaude Code (session): unknown\n"), none)
    }

    func testParseErrorsAreCappedAtFiveNewestFirstEachOnOneLine() {
        var a = TranscriptAssembler()
        for i in 1...7 { a.add(failed("bad \(i)\nsecond line"), source: nil) }
        XCTAssertEqual(a.parseErrors.count, 5)
        XCTAssertEqual(a.parseErrors.first, "2.1.300: bad 3\nsecond line")
        let lines = text(a).components(separatedBy: "\n")
        let errors = Array(lines.drop(while: { $0 != "Last parse errors:" }).dropFirst())
        XCTAssertEqual(errors, (3...7).reversed().map { "  2.1.300: bad \($0)second line" })
        XCTAssertTrue(text(a).hasPrefix("Prosper 1.2.3\n"))
        // the pane caps too, whatever it is handed
        let many = AgentDiagnostics.text(prosper: "1", dch: "", version: nil, counts: [:], errors: (1...9).map { "e\($0)" })
        XCTAssertEqual(many.components(separatedBy: "\n").suffix(6), ["Last parse errors:", "  e9", "  e8", "  e7", "  e6", "  e5"])
    }

    func testCopyPutsTheShownTextOnThePasteboardItIsHandedWithNoContentOrPath() throws {
        var a = TranscriptAssembler()
        a.add(TranscriptDecoder.decode(line: say(Self.secret, version: "2.1.400")), source: nil)
        a.add(TranscriptDecoder.decode(line: Data("{\"cwd\":\"/Users/example/api\" \(Self.secret)".utf8)), source: nil)
        let shown = text(a)
        let pb = NSPasteboard(name: NSPasteboard.Name("com.example.diag-test.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        AgentDiagnostics.copy(shown, to: pb)
        let copied = try XCTUnwrap(pb.string(forType: .string))
        XCTAssertEqual(copied, shown)
        XCTAssertFalse(copied.contains("transcript words"), copied)
        XCTAssertFalse(copied.contains("/Users/"), copied)
        XCTAssertFalse(copied.contains("example"), copied)
    }

    @MainActor
    func testSidebarMenuHasTheDiagnosticsItemLastOn() {
        let st = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        st.controlDch = nil
        let e = AgentWindowControls.sidebarMenu(store: st, autoAllow: false)
        let item = AgentSidebarMenuEntry.item("Diagnostics\u{2026}", enabled: true, checked: nil, verb: .diagnostics)
        XCTAssertEqual(e.filter { $0 == item }.count, 1, "\(e)")
        XCTAssertEqual(e.last(where: { if case .item = $0 { true } else { false } }), item, "the last item, after Agent Island Settings")
    }
}

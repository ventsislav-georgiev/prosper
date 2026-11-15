import XCTest
import os
@testable import ProsperApp

final class PerfSignpostTests: XCTestCase {
    /// The operator's verify predicate is `subsystem == "eu.illegible.prosper"`.
    func testSubsystemAndCategoryArePinned() {
        XCTAssertEqual(Perf.subsystem, "eu.illegible.prosper")
        XCTAssertEqual(Perf.category, "perf")
    }

    func testBeginEndAndEventDoNotTrap() {
        let state = Perf.signposter.beginInterval("test.interval", id: Perf.signposter.makeSignpostID())
        Perf.signposter.emitEvent("test.event")
        Perf.signposter.endInterval("test.interval", state)
    }

    /// #337: ending the same state twice traps under -Onone; Perf.end consumes it.
    func testPerfEndTwiceIsANoOpAndNilsTheState() {
        var state: OSSignpostIntervalState? = Perf.signposter.beginInterval(
            "test.interval", id: Perf.signposter.makeSignpostID())
        Perf.end("test.interval", &state)
        XCTAssertNil(state)
        Perf.end("test.interval", &state)
        XCTAssertNil(state)
    }

    /// #337: optional interval states end only through Perf.end. Direct endInterval calls
    /// are allowed only on non-optional, same-scope states (defer / CATransaction pairs).
    func testNoDirectEndIntervalOnOptionalState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Perf.swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            for (name, line) in try Self.directEndLines(in: String(contentsOf: file, encoding: .utf8)) {
                XCTFail("\(file.lastPathComponent): optional state `\(name)` ended directly: \(line)")
            }
        }
    }

    /// (name, line) for every `endInterval(` line that ends an optional interval state directly.
    /// #1273: a file without the literal "OSSignpostIntervalState?" declares no optional state, so it skips the work;
    /// each name's regex is built once per file, not per line.
    static func directEndLines(in source: String) throws -> [(String, Substring)] {
        guard source.range(of: "OSSignpostIntervalState?", options: .literal) != nil else { return [] }
        // Names declared as optional interval states in this file.
        let optionals = source.matches(of: /(\w+)\s*:\s*OSSignpostIntervalState\?/).map { String($0.1) }
        let directs = try optionals.map { name in
            (name, try Regex("[ ,.]\(name)\\)|let \(name)\\b|= \(name)\\b"))
        }
        var out: [(String, Substring)] = []
        for line in source.split(separator: "\n") where line.contains("endInterval(") {
            // `..., state)`, `..., self.state)`, `if let state`, `let s = state` on an endInterval line.
            for (name, direct) in directs where line.contains(direct) { out.append((name, line)) }
        }
        return out
    }

    /// #1273: literal inputs for the helper above.
    func testDirectEndLinesHelperReportsTheDirectEnds() throws {
        func found(_ text: String) throws -> [String] { try Self.directEndLines(in: text).map { "\($0.0)|\($0.1)" } }
        let decl = "var state: OSSignpostIntervalState?\n"
        XCTAssertEqual(try found(decl + "x.endInterval(\"n\", state)\nok()"), ["state|x.endInterval(\"n\", state)"])
        XCTAssertEqual(try found(decl + "if let state { s.endInterval(\"n\", state) }"),
                       ["state|if let state { s.endInterval(\"n\", state) }"])
        XCTAssertEqual(try found(decl + "let s = state; endInterval(\"n\", s) = state"), ["state|let s = state; endInterval(\"n\", s) = state"])
        // holds the literal, the end is not direct; or an end with no optional declared
        XCTAssertEqual(try found(decl + "x.endInterval(\"n\", other)\nstate = nil"), [])
        XCTAssertEqual(try found("let state: OSSignpostIntervalState\nx.endInterval(\"n\", state)"), [])
        XCTAssertEqual(try found("let note = \"OSSignpostIntervalState?\"\nx.endInterval(\"n\", state)"), [])
        // first and last line, no trailing newline; multi-byte characters before the match
        XCTAssertEqual(try found("s: OSSignpostIntervalState? = nil; endInterval(\"n\", s)"),
                       ["s|s: OSSignpostIntervalState? = nil; endInterval(\"n\", s)"])
        XCTAssertEqual(try found(decl + "a\nb\n\u{E9}\u{1F600} endInterval(\"n\", state)"), ["state|\u{E9}\u{1F600} endInterval(\"n\", state)"])
    }

    /// #370 (source scan; the engine builds overlay windows in init, so it is not
    /// constructed here). A token bump makes the in-flight callback stale, and a stale
    /// callback returns before its `endRequestSignpost` defer, so the only bump lives
    /// in `invalidateRequest()`, directly followed by the end.
    func testRequestTokenBumpLivesOnlyInInvalidateRequest() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var hits: [(file: String, lines: [Substring], index: Int)] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let bumps = Self.requestTokenBumpIndices(in: source, fileName: file.lastPathComponent)
            if bumps.isEmpty { continue }
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            for i in bumps { hits.append((file.lastPathComponent, lines, i)) }
        }
        // Row 1: exactly one bump under Sources, in AutocompleteEngine.swift.
        XCTAssertEqual(hits.count, 1,
                       "requestToken bumps: \(hits.map { "\($0.file):\($0.index + 1)" })")
        guard hits.count == 1, let hit = hits.first else { return }
        XCTAssertEqual(hit.file, "AutocompleteEngine.swift")
        // Row 2: it is the body of invalidateRequest(), and the very next line ends the interval.
        let above = hit.lines[max(0, hit.index - 3)..<hit.index]
        XCTAssertTrue(above.contains { $0.contains("func invalidateRequest()") },
                      "bump at :\(hit.index + 1) is not inside invalidateRequest()")
        let next = hit.index + 1 < hit.lines.count ? hit.lines[hit.index + 1] : ""
        XCTAssertEqual(next.trimmingCharacters(in: .whitespaces), "endRequestSignpost()")
    }

    /// 0-based line indices of the requestToken bumps in `source`. #1273: every pattern below needs the literal
    /// "requestToken" (the bump, the declaration, and the `var requestToken` skip), so a file without it has no
    /// bump and no skip and passes over the per-line work.
    static func requestTokenBumpIndices(in source: String, fileName: String) -> [Int] {
        guard source.range(of: "requestToken", options: .literal) != nil else { return [] }
        // Other types own an unrelated `requestToken` (RunnerPanel); an engine
        // extension in another file would not redeclare it, so it is still caught.
        if fileName != "AutocompleteEngine.swift", source.contains(/var requestToken\b/) { return [] }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        // #385 (QA #191): any assignment counts as a bump (`&+=`, `+=`, `= requestToken &+ 1`, ...);
        // `==` / `!=` reads and the declaration do not.
        return lines.indices.filter {
            lines[$0].contains(/requestToken\s*(&?[-+*\/%|^&])?=(?!=)/)
                && !lines[$0].contains(/\b(var|let)\s+requestToken\b/)
        }
    }

    /// #1273: literal inputs for the helper above.
    func testRequestTokenBumpIndicesHelperReportsTheBumps() {
        func found(_ text: String, _ name: String = "AutocompleteEngine.swift") -> [Int] {
            Self.requestTokenBumpIndices(in: text, fileName: name)
        }
        XCTAssertEqual(found("var requestToken = 0\nfunc f() {\n  requestToken &+= 1\n}\n"), [2])
        XCTAssertEqual(found("requestToken += 1\nx\nrequestToken = requestToken &+ 1"), [0, 2])
        // holds the literal, no bump: a read, a comparison, the declaration
        XCTAssertEqual(found("if requestToken == t { }\nif requestToken != t { }\nvar requestToken = 0\nlet requestToken = 1"), [])
        XCTAssertEqual(found("let x = 1\nlet y = 2"), [])
        // another file that declares its own requestToken is skipped whole; the engine file is not
        XCTAssertEqual(found("var requestToken = 0\nrequestToken += 1", "RunnerPanel.swift"), [])
        XCTAssertEqual(found("requestToken += 1\nvar x = 0", "RunnerPanel.swift"), [0])
        // first line and last line, no trailing newline; multi-byte characters before the match
        XCTAssertEqual(found("requestToken = 5"), [0])
        XCTAssertEqual(found("a\nb\nrequestToken -= 1"), [2])
        XCTAssertEqual(found("caf\u{E9} \u{1F600}\n\u{E9} requestToken |= 1"), [1])
    }
}

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
            let source = try String(contentsOf: file, encoding: .utf8)
            // Names declared as optional interval states in this file.
            let optionals = source.matches(of: /(\w+)\s*:\s*OSSignpostIntervalState\?/).map { String($0.1) }
            for line in source.split(separator: "\n") where line.contains("endInterval(") {
                for name in optionals {
                    // `…, state)`, `…, self.state)`, `if let state`, `let s = state` on an endInterval line.
                    let direct = try Regex("[ ,.]\(name)\\)|let \(name)\\b|= \(name)\\b")
                    XCTAssertFalse(line.contains(direct),
                                   "\(file.lastPathComponent): optional state `\(name)` ended directly: \(line)")
                }
            }
        }
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
            // Other types own an unrelated `requestToken` (RunnerPanel); an engine
            // extension in another file would not redeclare it, so it is still caught.
            if file.lastPathComponent != "AutocompleteEngine.swift",
               source.contains(/var requestToken\b/) { continue }
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            for i in lines.indices where lines[i].contains(/requestToken\s*&?\+=/) {
                hits.append((file.lastPathComponent, lines, i))
            }
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
}

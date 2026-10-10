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

    /// #365 (source scan, no seam: the engine is not constructible in tests). A token bump
    /// makes the in-flight callback stale, and a stale callback returns before its
    /// `endRequestSignpost` defer, so every bump must end the request interval itself
    /// within the next few lines (supersede, acceptFirstWord, clearSuggestion).
    func testEveryRequestTokenBumpEndsTheRequestSignpost() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Autocomplete/AutocompleteEngine.swift")
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        let bumps = lines.indices.filter { lines[$0].contains(/requestToken\s*&?\+=/) }
        XCTAssertGreaterThanOrEqual(bumps.count, 3)
        for i in bumps {
            let window = lines[(i + 1)..<min(i + 16, lines.count)]
            XCTAssertTrue(window.contains { $0.contains("endRequestSignpost()") },
                          "AutocompleteEngine.swift:\(i + 1): requestToken bump without endRequestSignpost()")
        }
    }
}

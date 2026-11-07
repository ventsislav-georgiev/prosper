import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #786 Agent window spike A: transcript decoding, tiers, version banner, health,
/// mapping, bounded tail, the compat corpus and canary, and offscreen renders.
/// Fixtures are synthetic (Tests/Fixtures/claude-code/<version>/), shapes only.
/// Offscreen only: ImageRenderer, no window, no input events.
final class AgentWindowTests: XCTestCase {

    static let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/claude-code", isDirectory: true)

    static func fixtures() -> [URL] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: corpus, includingPropertiesForKeys: nil)) ?? []
        return dirs.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
    }

    func line(_ o: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: o) + Data("\n".utf8)
    }

    func entry(_ type: String, version: String = "2.1.300", _ extra: [String: Any] = [:]) -> [String: Any] {
        var o: [String: Any] = ["type": type, "sessionId": "s-1", "version": version]
        o.merge(extra) { $1 }
        return o
    }

    func assistant(_ blocks: [[String: Any]], version: String = "2.1.300", _ extra: [String: Any] = [:]) -> [String: Any] {
        entry("assistant", version: version, ["message": ["role": "assistant", "content": blocks]].merging(extra) { $1 })
    }

    func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        assistant([["type": "tool_use", "id": id, "name": name, "input": input]])
    }

    func toolResult(_ id: String, _ text: String, extra: Any? = nil, error: Bool = false) -> [String: Any] {
        var o = entry("user", ["message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": id, "content": text, "is_error": error]]]])
        if let extra { o["toolUseResult"] = extra }
        return o
    }

    /// The text of each top-level block (user/assistant), "" for others.
    @MainActor func texts(_ m: AgentTranscriptModel) -> [String] {
        m.blocks.map { b in
            switch b.body {
            case .assistant(let c), .user(let c): c.text
            default: ""
            }
        }
    }

    func assemble(_ entries: [[String: Any]]) -> TranscriptAssembler {
        var a = TranscriptAssembler()
        for e in entries { a.add(TranscriptDecoder.decode(line: line(e)), source: nil) }
        return a
    }

    func write(_ url: URL, _ entries: [[String: Any]], append: Bool = false) throws {
        let data = entries.map(line).reduce(Data(), +)
        if append, let h = try? FileHandle(forWritingTo: url) {
            try h.seekToEnd()
            try h.write(contentsOf: data)
            try h.close()
        } else {
            try data.write(to: url)
        }
    }

    @MainActor
    func model(_ path: String?, dch: String = "1.30.0", state: String = "idle", sid: String? = "s-1",
               clock: @escaping () -> Date = Date.init) -> AgentTranscriptModel {
        let m = AgentTranscriptModel()
        m.makeWatch = { _, _ in NSObject() }
        m.tickInterval = 3600
        m.now = clock
        m.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: "s"), dchVersion: dch, dchState: state,
                                       sessionId: path == nil ? nil : sid, transcriptPath: path))
        return m
    }

    // MARK: - Rule 1: line isolation and partial lines

    func testPartialTrailingLineIsBufferedUntilItsNewline() {
        var b = LineBuffer()
        XCTAssertEqual(b.feed(Data("abc".utf8), at: 0), [])
        XCTAssertEqual(b.feed(Data("def\ngh".utf8), at: 3), [.line(Data("abcdef".utf8), 0..<6)])
        XCTAssertEqual(b.feed(Data("i\n\n  \n".utf8), at: 9), [.line(Data("ghi".utf8), 7..<10)], "blank lines are skipped")
    }

    func testAnOversizedLineBecomesOneMarkerAndTheNextLineSurvives() {
        var b = LineBuffer(maxLine: 8)
        XCTAssertEqual(b.feed(Data("0123456789".utf8), at: 0), [])
        XCTAssertEqual(b.feed(Data("ab\n{}\n".utf8), at: 10), [.oversized(0..<12), .line(Data("{}".utf8), 13..<15)])
    }

    func testABadLineCostsOnlyItsOwnBlock() {
        var a = TranscriptAssembler()
        let lines = [line(assistant([["type": "text", "text": "first"]])), Data("{\"type\":\"assistant\",\"mess".utf8),
                     Data("[1,2]".utf8), line(assistant([["type": "text", "text": "second"]]))]
        for l in lines { a.add(TranscriptDecoder.decode(line: l), source: nil) }
        XCTAssertEqual(a.blocks.count, 4)
        XCTAssertEqual(a.blocks.map(\.failed), [false, true, true, false])
        XCTAssertEqual(a.blocks.last?.body, .assistant(Clip("second", cap: 100)))
    }

    @MainActor
    func testTheModelWaitsForTheRestOfAPartialLine() throws {
        let url = tempDir().appendingPathComponent("t.jsonl")
        let full = line(assistant([["type": "text", "text": "whole line"]]))
        try (line(entry("user", ["message": ["role": "user", "content": "hi"]])) + full.prefix(20)).write(to: url)
        let m = model(url.path)
        m.start()
        defer { m.stop() }
        XCTAssertEqual(m.blocks.count, 1, "the partial line is not decoded yet")
        XCTAssertFalse(m.blocks.contains(where: \.failed))
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: full.dropFirst(20))
        try h.close()
        m.poll()
        XCTAssertEqual(m.blocks.count, 2)
        XCTAssertEqual(texts(m).last, "whole line")
        XCTAssertFalse(m.blocks.contains(where: \.failed))
    }

    // MARK: - Rule 2: tolerant decoding through aliases

    func testAliasesReadRenamedKeys() {
        let a = assemble([
            ["type": "assistant", "session_id": "s", "version": "2.4.0", "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "t1", "name": "Edit", "input": ["filePath": "/x/a.swift", "oldString": "a", "newString": "b"]]]]],
            ["type": "user", "session_id": "s", "message": ["role": "user", "content": [
                ["type": "tool_result", "toolUseId": "t1", "content": "ok", "isError": false]]],
             "tool_use_result": ["structured_patch": [["lines": [" k", "-a", "+b"]]]]],
            ["type": "assistant", "is_sidechain": true, "agent_id": "ag", "message": ["role": "assistant", "content": [
                ["type": "text", "text": "side"]]]],
        ])
        XCTAssertEqual(TranscriptDecoder.decode(line: line(["type": "user", "session_id": "abc"])).sessionId, "abc")
        XCTAssertEqual(a.blocks.count, 2)
        guard case .diff(_, let path, let lines, _, false) = a.blocks[0].body else { return XCTFail("\(a.blocks[0].body)") }
        XCTAssertEqual(path, "/x/a.swift")
        XCTAssertEqual(lines.map(\.text), ["k", "a", "b"], "the result paired through toolUseId and its structured_patch")
        XCTAssertEqual(a.blocks[0].tier, .specific)
        guard case .thread(let agent, _) = a.blocks[1].body else { return XCTFail("sidechain nests") }
        XCTAssertEqual(agent, "ag")
        XCTAssertEqual(a.blocks[1].children.count, 1)
    }

    func testUnknownKeysAndNumbersOfTheWrongTypeAreIgnored() {
        let a = assemble([entry("system", ["subtype": "compact_boundary", "extra": ["x": 1],
                                           "compactMetadata": ["trigger": 7, "preTokens": "many"]])])
        XCTAssertEqual(a.blocks.first?.body, .compaction(trigger: nil, preTokens: nil, summary: nil))
        XCTAssertNil(TranscriptKeys.int(["n": true], "n"), "a Bool is not a number")
    }

    // MARK: - Rule 3: tiers

    func testATierOneRendererThatCannotFillItselfFallsBackToTheGenericCard() {
        for (name, input) in [("Bash", ["cmd": "make"]), ("Bash", ["command": "  "]), ("Read", ["path": 3]),
                              ("Edit", ["file_path": "/a"]), ("Grep", ["query": "x"]), ("Write", ["file_path": "/a"])] as [(String, [String: Any])] {
            let (body, tier) = ToolRenderer.render(name: name, input: input, result: nil)
            XCTAssertEqual(tier, .generic, name)
            guard case .card(let title, _, _, _, _) = body else { return XCTFail("\(name): \(body)") }
            XCTAssertEqual(title, name)
        }
        let (bash, tier) = ToolRenderer.render(name: "Bash", input: ["command": "ls"], result: nil)
        XCTAssertEqual(tier, .specific)
        XCTAssertEqual(bash, .bash(command: "ls", description: nil, output: nil, isError: false))
    }

    func testUnknownTypesShowAsFoldedGenericCardsAndNoiseIsHiddenWithACount() {
        let a = assemble([entry("checkpoint", ["label": "x"]), entry("queue-operation"), entry("atis-latch"),
                          entry("attachment", ["attachment": ["type": "hook_success"]]),
                          entry("system", ["subtype": "turn_duration"]),
                          assistant([["type": "citation", "source": "d"]])])
        XCTAssertEqual(a.blocks.count, 2)
        guard case .card(let title, _, _, let raw?, _) = a.blocks[0].body else { return XCTFail("\(a.blocks[0].body)") }
        XCTAssertEqual(title, "Unrecognized entry (checkpoint)")
        XCTAssertTrue(raw.text.contains("\"label\""), "raw JSON on expand")
        guard case .card(let t2, _, _, _, _) = a.blocks[1].body else { return XCTFail() }
        XCTAssertEqual(t2, "Unrecognized entry (content citation)")
        XCTAssertEqual(a.hiddenTotal, 4)
        XCTAssertEqual(a.counts()["2.1.300"], TierCounts(specific: 0, generic: 2, failed: 0, hidden: 4, degraded: 2))
    }

    func testMetaUserLinesAreHiddenAndCountedNeverShownAsYou() {
        let a = assemble([entry("user", ["isMeta": true, "message": ["role": "user", "content": "meta string"]]),
                          entry("user", ["isMeta": true, "message": ["role": "user", "content": [
                              ["type": "text", "text": "meta array"]]]]),
                          entry("user", ["is_meta": true, "message": ["role": "user", "content": "meta alias"]]),
                          entry("user", ["message": ["role": "user", "content": "real prompt"]])])
        XCTAssertEqual(a.blocks.map(\.body), [.user(Clip("real prompt", cap: 6000, source: nil))],
                       "only the non-meta line shows as a You block")
        XCTAssertEqual(a.hiddenTotal, 3)
        XCTAssertEqual(a.counts()["2.1.300"], TierCounts(specific: 1, generic: 0, failed: 0, hidden: 3, degraded: 0))
    }

    func testToolsPairByIdAndAnUnpairedResultStillShows() {
        let a = assemble([toolUse("t1", "Bash", ["command": "echo hi", "description": "Say hi"]),
                          toolResult("t1", "hi", extra: ["stdout": "hi", "stderr": "warn", "interrupted": false]),
                          toolResult("t9", "lost")])
        XCTAssertEqual(a.blocks.count, 2)
        guard case .bash("echo hi", "Say hi", let out?, false) = a.blocks[0].body else { return XCTFail("\(a.blocks[0].body)") }
        XCTAssertEqual(out.text, "hi\nwarn")
        guard case .card("Tool result", _, let body?, _, _) = a.blocks[1].body else { return XCTFail() }
        XCTAssertEqual(body.text, "lost")
    }

    func testCompactionIsAMarkerCarryingItsSummary() {
        let a = assemble([entry("system", ["subtype": "compact_boundary", "compactMetadata": ["trigger": "auto", "preTokens": 150000]]),
                          entry("user", ["isCompactSummary": true, "message": ["role": "user", "content": "Summary text"]])])
        XCTAssertEqual(a.blocks.count, 1)
        guard case .compaction("auto", 150000, let s?) = a.blocks[0].body else { return XCTFail("\(a.blocks[0].body)") }
        XCTAssertEqual(s.text, "Summary text")
    }

    func testSidechainEntriesNestUnderTheAgentThatSpawnedThem() {
        let a = assemble([toolUse("t1", "Agent", ["description": "Audit the lexer", "prompt": "p"]),
                          toolResult("t1", "done", extra: ["agentId": "ag1", "status": "completed"]),
                          assistant([["type": "text", "text": "inside"]], ["isSidechain": true, "agentId": "ag1"]),
                          assistant([["type": "text", "text": "inside 2"]], ["isSidechain": true, "agentId": "ag1"])])
        XCTAssertEqual(a.blocks.count, 2)
        XCTAssertEqual(a.blocks[1].body, .thread(agentId: "ag1", title: "Audit the lexer"))
        XCTAssertEqual(a.blocks[1].children.count, 2)
        // The usual order: the sidechain streams before the Agent result names it.
        let b = assemble([toolUse("t1", "Agent", ["description": "Audit the lexer", "prompt": "p"]),
                          assistant([["type": "text", "text": "inside"]], ["isSidechain": true, "agentId": "ag2"]),
                          toolUse("t2", "Agent", ["description": "Second agent", "prompt": "p"]),
                          toolResult("t2", "done", extra: ["agentId": "ag3"]),
                          toolResult("t1", "done", extra: ["agentId": "ag2"])])
        XCTAssertEqual(b.blocks[1].body, .thread(agentId: "ag2", title: "Audit the lexer"))
        let unnamed = assemble([assistant([["type": "text", "text": "x"]], ["isSidechain": true, "agentId": "ag9"])])
        XCTAssertEqual(unnamed.blocks[0].body, .thread(agentId: "ag9", title: "Subagent"))
    }

    // MARK: - Rule 4: version

    func testTheBannerShowsOnlyAboveTheTestedRange() {
        XCTAssertFalse(ClaudeCodeCompat.isNewer(ClaudeCodeCompat.upper))
        XCTAssertFalse(ClaudeCodeCompat.isNewer(ClaudeCodeCompat.lower))
        XCTAssertFalse(ClaudeCodeCompat.isNewer("2.1.100"))
        XCTAssertFalse(ClaudeCodeCompat.isNewer("junk"))
        XCTAssertTrue(ClaudeCodeCompat.isNewer("2.1.319"))
        XCTAssertTrue(ClaudeCodeCompat.isNewer("2.2.0"))
        XCTAssertEqual(ClaudeCodeCompat.sanitized("2.1.300; rm"), "unknown")
    }

    @MainActor
    func testTheModelRaisesTheBannerForANewerVersionOnly() throws {
        let url = tempDir().appendingPathComponent("v.jsonl")
        try write(url, [assistant([["type": "text", "text": "a"]], version: ClaudeCodeCompat.upper)])
        let m = model(url.path)
        m.start()
        defer { m.stop() }
        XCTAssertNil(m.banner)
        try write(url, [assistant([["type": "text", "text": "b"]], version: "2.1.319")], append: true)
        m.poll()
        XCTAssertEqual(m.banner, ClaudeCodeCompat.newerBanner)
        XCTAssertEqual(m.latestVersion, "2.1.319")
        XCTAssertEqual(m.counts["2.1.319"]?.specific, 1, "tier counts per version")
        XCTAssertEqual(m.mode, .conversation, "the banner never blocks")
    }

    func testTheTestedRangeMatchesTheCorpus() throws {
        let versions = Set(Self.fixtures().map { $0.deletingLastPathComponent().lastPathComponent })
        XCTAssertTrue(versions.contains(ClaudeCodeCompat.lower))
        XCTAssertTrue(versions.contains(ClaudeCodeCompat.upper))
        XCTAssertTrue(versions.contains { ClaudeCodeCompat.isNewer($0) }, "a future-version fixture")
    }

    // MARK: - Rule 5: health

    func testHealthFallsBackToTheTerminalWhenMostBlocksAreSimplified() {
        let s = AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: "s"), dchVersion: "1.30.0", dchState: "idle",
                                      sessionId: "s", transcriptPath: "/p")
        func mode(_ c: TierCounts, state: String = "idle", growth: TimeInterval = 0, pending: Bool = false) -> AgentWindowMode {
            var src = s
            src.dchState = state
            return AgentTranscriptModel.mode(source: src, hasView: true, nullSince: nil, missing: false, live: c,
                                             lastGrowth: Date(timeIntervalSince1970: 1000 - growth), toolPending: pending,
                                             now: Date(timeIntervalSince1970: 1000))
        }
        XCTAssertEqual(mode(TierCounts(specific: 6, generic: 5, failed: 1, degraded: 5)), .terminalFirst(
            "Most entries show simplified (50%): this transcript format is not recognized"))
        XCTAssertEqual(mode(TierCounts(specific: 7, generic: 5, degraded: 5)), .conversation, "under the threshold")
        XCTAssertEqual(mode(TierCounts(specific: 1, generic: 10, degraded: 10)), .conversation, "too few blocks to judge")
        XCTAssertEqual(mode(TierCounts(specific: 2, generic: 30)), .conversation,
                       "generic cards for tools with no specific renderer are by design, not drift")
        let stale = AgentWindowMode.terminalFirst("The transcript stopped updating while the agent works")
        XCTAssertEqual(mode(TierCounts(specific: 20), state: "working", growth: 181), stale)
        XCTAssertEqual(mode(TierCounts(specific: 20), state: "working", growth: 179), .conversation)
        XCTAssertEqual(mode(TierCounts(specific: 20), state: "working", growth: 600, pending: true), .conversation,
                       "a running tool keeps the file quiet")
        XCTAssertEqual(mode(TierCounts(specific: 20), state: "idle", growth: 600), .conversation)
    }

    @MainActor
    func testAWorkingSessionWhoseFileStopsGrowingGoesTerminalFirst() throws {
        let url = tempDir().appendingPathComponent("s.jsonl")
        try write(url, [assistant([["type": "text", "text": "a"]])])
        var t = Date(timeIntervalSince1970: 1000)
        let m = model(url.path, state: "working", clock: { t })
        m.start()
        defer { m.stop() }
        XCTAssertEqual(m.mode, .conversation)
        t += 200
        m.tick()
        XCTAssertEqual(m.mode, .terminalFirst("The transcript stopped updating while the agent works"))
        try write(url, [assistant([["type": "text", "text": "b"]])], append: true)
        m.tick()
        XCTAssertEqual(m.mode, .conversation, "growth clears staleness")
    }

    // MARK: - Rule 6: mapping

    @MainActor
    func testAnOldDchOrANullMappingIsTerminalFirst() throws {
        let url = tempDir().appendingPathComponent("m.jsonl")
        try write(url, [assistant([["type": "text", "text": "a"]])])
        for v in ["1.29.2", "", "1.3"] {
            let m = model(url.path, dch: v)
            m.start()
            guard case .terminalFirst(let why) = m.mode else { return XCTFail(v) }
            XCTAssertTrue(why.contains("1.30.0"), why)
            XCTAssertTrue(m.blocks.isEmpty, "\(v): never reads a transcript dch did not name")
            m.stop()
        }
        let none = model(nil)
        none.start()
        XCTAssertEqual(none.mode, .terminalFirst("No transcript matched this session"))
        none.stop()
        let ok = model(url.path, dch: "1.30.0")
        ok.start()
        XCTAssertEqual(ok.mode, .conversation)
        XCTAssertEqual(ok.blocks.count, 1)
        ok.stop()
    }

    @MainActor
    func testABriefNullAfterClearKeepsTheViewThenFallsBack() throws {
        let url = tempDir().appendingPathComponent("c.jsonl")
        try write(url, [assistant([["type": "text", "text": "a"]])])
        var t = Date(timeIntervalSince1970: 1000)
        let m = model(url.path, clock: { t })
        m.start()
        defer { m.stop() }
        let key = AgentSessionKey(dir: "/d", name: "s")
        m.update(AgentTranscriptSource(key: key, dchVersion: "1.30.0", dchState: "working", sessionId: nil, transcriptPath: nil))
        XCTAssertEqual(m.mode, .waiting("Waiting for the next turn"))
        XCTAssertEqual(m.blocks.count, 1, "the last view stays")
        t += AgentTranscriptModel.nullGrace + 1
        m.tick()
        XCTAssertEqual(m.mode, .terminalFirst("No transcript matched this session"))
    }

    @MainActor
    func testARotatedIdFollowsTheNewFileAndCompactionStaysInTheSameView() throws {
        let dir = tempDir()
        let a = dir.appendingPathComponent("a.jsonl"), b = dir.appendingPathComponent("b.jsonl")
        try write(a, [assistant([["type": "text", "text": "old conversation"]])])
        try write(b, [assistant([["type": "text", "text": "new 1"]]), assistant([["type": "text", "text": "new 2"]])])
        let m = model(a.path, sid: "id-a")
        m.start()
        defer { m.stop() }
        XCTAssertEqual(m.blocks.count, 1)
        // Compaction: same id, same file, a boundary appended.
        try write(a, [entry("system", ["subtype": "compact_boundary"])], append: true)
        m.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: "s"), dchVersion: "1.30.0", dchState: "idle",
                                       sessionId: "id-a", transcriptPath: a.path))
        m.poll()
        XCTAssertEqual(m.blocks.count, 2, "compaction is a marker in the same view")
        // /clear: a new id and file.
        m.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: "s"), dchVersion: "1.30.0", dchState: "idle",
                                       sessionId: "id-b", transcriptPath: b.path))
        XCTAssertEqual(texts(m), ["new 1", "new 2"])
    }

    @MainActor
    func testAShrinkOrAReplacedFileReopens() throws {
        let url = tempDir().appendingPathComponent("r.jsonl")
        try write(url, (0..<5).map { assistant([["type": "text", "text": "line \($0)"]]) })
        let m = model(url.path)
        m.start()
        defer { m.stop() }
        XCTAssertEqual(m.blocks.count, 5)
        // Truncate in place (same inode, smaller size).
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: 0)
        try h.close()
        try write(url, [assistant([["type": "text", "text": "fresh"]])], append: true)
        m.poll()
        XCTAssertEqual(texts(m), ["fresh"])
        // Replace by rename (new inode, larger file).
        let tmp = url.deletingLastPathComponent().appendingPathComponent("r2.jsonl")
        try write(tmp, (0..<3).map { assistant([["type": "text", "text": "replaced \($0)"]]) })
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        m.poll()
        XCTAssertEqual(m.blocks.count, 3)
        XCTAssertEqual(texts(m).first, "replaced 0")
    }

    // MARK: - Rule 9: bounded cost

    @MainActor
    func testTheTailReadsOnlyNewBytes() throws {
        let url = tempDir().appendingPathComponent("i.jsonl")
        try write(url, [assistant([["type": "text", "text": "a"]])])
        let m = model(url.path)
        m.start()
        defer { m.stop() }
        let first = try XCTUnwrap(m.tail?.offset)
        m.poll()
        XCTAssertEqual(m.tail?.offset, first, "no growth, nothing read")
        XCTAssertEqual(m.blocks.count, 1)
        try write(url, [assistant([["type": "text", "text": "b"]])], append: true)
        m.poll()
        XCTAssertEqual(m.blocks.count, 2)
        XCTAssertEqual(m.blocks.map(\.id), [0, 1], "the first block was not re-decoded")
    }

    @MainActor
    func testALongFileOpensOnItsLastPageAndPagesBackWithoutBrokenLines() throws {
        let url = tempDir().appendingPathComponent("p.jsonl")
        try write(url, (0..<200).map { assistant([["type": "text", "text": "message number \($0) " + String(repeating: "x", count: 40)]]) })
        let m = AgentTranscriptModel()
        m.makeWatch = { _, _ in NSObject() }
        m.tickInterval = 3600
        m.pageBytes = 4096
        m.update(AgentTranscriptSource(key: AgentSessionKey(dir: "/d", name: "s"), dchVersion: "1.30.0", dchState: "idle",
                                       sessionId: "s", transcriptPath: url.path))
        m.start()
        defer { m.stop() }
        let first = m.blocks.count
        XCTAssertGreaterThan(first, 10)
        XCTAssertLessThan(first, 200)
        XCTAssertTrue(m.olderAvailable)
        XCTAssertFalse(m.blocks.contains(where: \.failed), "the cut first line is dropped, not decoded")
        var guardN = 0
        while m.olderAvailable && guardN < 100 { m.loadEarlier(); guardN += 1 }
        XCTAssertEqual(m.blocks.count, 200)
        XCTAssertFalse(m.blocks.contains(where: \.failed))
        XCTAssertEqual(m.blocks.map(\.id), m.blocks.map(\.id).sorted())
        guard case .assistant(let c) = m.blocks[0].body else { return XCTFail() }
        XCTAssertTrue(c.text.hasPrefix("message number 0 "))
    }

    func testPagingPairsAToolCallWithItsResultAcrossThePageBoundary() {
        var later = TranscriptAssembler()
        later.add(TranscriptDecoder.decode(line: line(toolResult("t1", "out", extra: ["stdout": "out"]))), source: nil)
        XCTAssertEqual(later.counts().values.first?.generic, 1, "an orphan until its call pages in")
        var page = TranscriptAssembler()
        page.add(TranscriptDecoder.decode(line: line(toolUse("t1", "Bash", ["command": "ls"]))), source: nil)
        later.prepend(page)
        XCTAssertEqual(later.blocks.count, 1)
        guard case .bash("ls", _, let out?, _) = later.blocks[0].body else { return XCTFail("\(later.blocks)") }
        XCTAssertEqual(out.text, "out")
    }

    func testMemoryIsBoundedPerSessionAndDroppedBlocksStayCounted() {
        var a = TranscriptAssembler()
        a.maxBlocks = 10
        for i in 0..<50 { a.add(TranscriptDecoder.decode(line: line(assistant([["type": "text", "text": "m\(i)"]]))), source: nil) }
        XCTAssertEqual(a.blocks.count, 10)
        XCTAssertEqual(a.dropped, 40)
        XCTAssertEqual(a.counts()["2.1.300"]?.specific, 50)
        XCTAssertEqual(a.liveCounts().specific, 10)
    }

    @MainActor
    func testAHugeResultIsCappedAndExpandsLazilyFromTheFile() throws {
        let url = tempDir().appendingPathComponent("h.jsonl")
        let big = (0..<2000).map { "output line \($0)" }.joined(separator: "\n")
        try write(url, [toolUse("t1", "Bash", ["command": "seq"]), toolResult("t1", big, extra: ["stdout": big, "stderr": ""])])
        let m = model(url.path)
        m.start()
        defer { m.stop() }
        guard case .bash(_, _, let out?, _) = m.blocks.first?.body else { return XCTFail() }
        XCTAssertTrue(out.capped)
        XCTAssertEqual(out.text.count, TranscriptDecoder.outputCap)
        XCTAssertEqual(out.total, big.count)
        XCTAssertEqual(m.fullText(out), big)
    }

    @MainActor
    func testNothingRunsWhileTheViewIsClosed() throws {
        let url = tempDir().appendingPathComponent("n.jsonl")
        try write(url, [assistant([["type": "text", "text": "a"]])])
        let m = model(url.path)
        XCTAssertTrue(m.blocks.isEmpty, "update alone reads nothing")
        XCTAssertEqual(m.watchArms, 0)
        m.tick()
        m.poll()
        XCTAssertTrue(m.blocks.isEmpty)
        m.start()
        XCTAssertEqual(m.blocks.count, 1)
        XCTAssertEqual(m.watchArms, 1)
        m.stop()
        XCTAssertTrue(m.blocks.isEmpty, "closing frees the blocks")
        try write(url, [assistant([["type": "text", "text": "b"]])], append: true)
        m.tick()
        m.poll()
        XCTAssertTrue(m.blocks.isEmpty)
        XCTAssertEqual(m.watchArms, 1)
        m.start()
        XCTAssertEqual(m.blocks.count, 2, "reopening reads the file again")
        m.stop()
    }

    @MainActor
    func testTheRealWatchFiresOnAppend() throws {
        let url = tempDir().appendingPathComponent("w.jsonl")
        try write(url, [assistant([["type": "text", "text": "a"]])])
        var fired = 0
        let w = try XCTUnwrap(TranscriptWatch(path: url.path) { fired += 1 })
        try write(url, [assistant([["type": "text", "text": "b"]])], append: true)
        let deadline = Date().addingTimeInterval(3)
        while fired == 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertGreaterThan(fired, 0)
        withExtendedLifetime(w) {}
        XCTAssertNil(TranscriptWatch(path: url.path + ".missing") {})
    }

    // MARK: - Rule 11: corpus and canary

    @MainActor
    func testEveryFixtureDecodesAndRendersWithNoBlankBlock() throws {
        let files = Self.fixtures()
        XCTAssertGreaterThanOrEqual(files.count, 7)
        var perVersion: [String: Int] = [:]
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for f in files {
            let v = f.deletingLastPathComponent().lastPathComponent
            perVersion[v, default: 0] += 1
            let m = model(f.path)
            m.start()
            defer { m.stop() }
            XCTAssertFalse(m.blocks.isEmpty, f.lastPathComponent)
            let all = m.blocks.flatMap { [$0] + $0.children }
            let failed = all.filter(\.failed).count
            XCTAssertEqual(failed, f.lastPathComponent.contains("bad-lines") ? 2 : 0, "\(v)/\(f.lastPathComponent)")
            if !ClaudeCodeCompat.isNewer(v) {
                XCTAssertEqual(m.mode, .conversation, "\(v)/\(f.lastPathComponent): a tested version stays structured")
                XCTAssertNil(m.banner)
                XCTAssertGreaterThan(m.hiddenCount, 0)
                for b in all {
                    switch b.body {
                    case .card(let t, _, _, _, _):
                        XCTAssertFalse(["Bash", "Edit", "Write", "Read", "Grep", "Glob"].contains(t), "\(f.lastPathComponent): \(t) fell back")
                    default: break
                    }
                }
            } else {
                XCTAssertEqual(m.banner, ClaudeCodeCompat.newerBanner)
                XCTAssertGreaterThan(m.counts[v]?.degraded ?? 0, 0)
            }
            for scale: CGFloat in [0.85, 1.0] {
                ThemeRuntime.scale = scale
                for b in all {
                    for expanded in [false, true] {
                        let ink = try inkPixels(TranscriptBlockView(block: b, expanded: expanded))
                        XCTAssertGreaterThan(ink, 30, "\(f.lastPathComponent) block \(b.id) \(b.body) at \(scale) renders blank")
                    }
                }
            }
        }
        for (v, n) in perVersion where !ClaudeCodeCompat.isNewer(v) {
            XCTAssertGreaterThanOrEqual(n, 2, "two shapes per known version (\(v))")
        }
    }

    @MainActor
    func testTheCanaryLogsTierCountsOncePerNewVersionWithoutContent() throws {
        TranscriptCanary.resetForTests()
        defer { TranscriptCanary.resetForTests() }
        let f = Self.corpus.appendingPathComponent("2.4.0/future-renamed-and-unknown.jsonl")
        var lines: [String] = []
        let line = try XCTUnwrap(TranscriptCanary.runIfNew(version: "2.4.0", path: f.path) { lines.append($0) })
        XCTAssertNil(TranscriptCanary.runIfNew(version: "2.4.0", path: f.path) { lines.append($0) }, "once per version")
        XCTAssertNil(TranscriptCanary.runIfNew(version: "not a version", path: f.path) { lines.append($0) })
        XCTAssertEqual(lines, [line])
        XCTAssertTrue(line.hasPrefix("claude-code 2.4.0 (newer than tested): specific="), line)
        let re = try NSRegularExpression(pattern: #"^claude-code [0-9.]+( \(newer than tested\))?: specific=\d+ generic=\d+ degraded=\d+ failed=\d+ hidden=\d+ tested=[0-9.]+-[0-9.]+$"#)
        XCTAssertNotNil(re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), "numbers and versions only")
        let c = TranscriptCanary.scan(path: f.path)["2.4.0"]
        XCTAssertEqual(c?.generic ?? 0 > 0, true, "the future shape shows up as tier 2, not as a break")
        XCTAssertEqual(c?.failed, 0)
        XCTAssertGreaterThan(c?.degraded ?? 0, 0, "renamed keys and unknown types count as drift")
    }

    // MARK: - Offscreen renders (no window)

    @MainActor
    func inkPixels<V: View>(_ v: V, width: CGFloat = 520, write name: String? = nil) throws -> Int {
        let r = ImageRenderer(content: v.frame(width: sz(width)).padding(sz(10)).background(Neon.bgBottom)
            .environment(\.colorScheme, .dark))
        r.scale = 2
        let cg = try XCTUnwrap(r.cgImage)
        let rep = NSBitmapImageRep(cgImage: cg)
        if let name {
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: renderDir.appendingPathComponent("\(name).png"))
            if let extra = ProcessInfo.processInfo.environment["PROSPER_RENDER_DIR"] {
                try png.write(to: URL(fileURLWithPath: extra).appendingPathComponent("\(name).png"))
            }
        }
        guard let bg = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return 0 }
        var ink = 0
        let step = 2
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent)
                    + abs(c.blueComponent - bg.blueComponent) > 0.15 { ink += 1 }
            }
        }
        return ink
    }

    lazy var renderDir: URL = tempDir("agent-window-renders")

    @MainActor
    func testRendersEveryBlockKindTheBannerAndTheTerminalFirstStateOffscreen() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let longOut = (0..<8).map { "test \($0) passed" }.joined(separator: "\n")
        let kinds: [(String, BlockBody, TranscriptTier)] = [
            ("user", .user(Clip("Please tidy the parser and run the checks.", cap: 999)), .specific),
            ("assistant", .assistant(Clip("Done. The parser now uses **`let b = 3`** and the tests pass.", cap: 999)), .specific),
            ("thinking", .thinking(Clip("Read the file first, then edit, then run the tests.", cap: 999)), .specific),
            ("bash", .bash(command: "swift test --filter ParserTests", description: "Run the parser tests",
                           output: Clip(longOut, cap: 999), isError: false), .specific),
            ("bash-error", .bash(command: "make lint", description: nil, output: Clip("Exit code 2", cap: 999), isError: true), .specific),
            ("diff", .diff(tool: "Edit", path: "/Users/example/project/Sources/Parser.swift",
                           lines: [DiffLine(kind: .context, text: "let a = 1"), DiffLine(kind: .removed, text: "let b = 2"),
                                   DiffLine(kind: .added, text: "let b = 3")], more: 0, isError: false), .specific),
            ("read", .read(path: "/Users/example/project/Sources/Parser.swift", detail: "lines 1–40 of 120"), .specific),
            ("search", .search(tool: "Grep", pattern: "func parse", scope: "Sources",
                               results: ["Sources/Parser.swift", "Sources/Lexer.swift"], more: 3), .specific),
            ("compaction", .compaction(trigger: "auto", preTokens: 167000, summary: Clip("The parser was tidied.", cap: 999)), .specific),
            ("notice", .notice("Auto-update available."), .specific),
            ("image", .image, .specific),
            ("generic-tool", .card(title: "WebFetch", fields: [CardField(key: "url", value: "https://example.com/docs")],
                                   body: Clip("The page describes an example API.", cap: 999), raw: nil, isError: false), .generic),
            ("unrecognized", .card(title: "Unrecognized entry (checkpoint)", fields: [], body: nil,
                                   raw: Clip("{\n  \"label\" : \"before refactor\"\n}", cap: 999), isError: false), .generic),
            ("failed", .failed(reason: "Unreadable entry", raw: Clip("{\"type\":\"assistant\",\"mess", cap: 999)), .generic),
            ("capped", .assistant(Clip(String(repeating: "A long answer. ", count: 40), cap: 120)), .specific),
        ]
        var thread = TranscriptBlock(id: 99, body: .thread(agentId: "ag", title: "Audit the lexer"), tier: .specific,
                                     version: "2.1.318", source: nil)
        thread.children = [TranscriptBlock(id: 100, body: kinds[1].1, tier: .specific, version: "2.1.318", source: nil),
                           TranscriptBlock(id: 101, body: kinds[6].1, tier: .specific, version: "2.1.318", source: nil)]
        let blocks = kinds.enumerated().map { i, k in
            (k.0, TranscriptBlock(id: i, body: k.1, tier: k.2, version: "2.1.318", source: nil))
        } + [("subagent-thread", thread)]
        for scale: CGFloat in [0.85, 1.0] {
            ThemeRuntime.scale = scale
            for (name, b) in blocks {
                for expanded in [false, true] {
                    let ink = try inkPixels(TranscriptBlockView(block: b, expanded: expanded),
                                            write: "block-\(name)-\(expanded ? "open" : "folded")-\(scale)")
                    XCTAssertGreaterThan(ink, 30, "\(name) at \(scale)")
                }
            }
            XCTAssertGreaterThan(try inkPixels(TranscriptBanner(text: ClaudeCodeCompat.newerBanner), write: "banner-\(scale)"), 30)
            XCTAssertGreaterThan(try inkPixels(TranscriptHint(text: "Waiting for the next turn"), write: "waiting-\(scale)"), 30)
            XCTAssertGreaterThan(try inkPixels(TerminalFirstView(reason: "dch 1.29.2 cannot name the transcript (needs 1.30.0)"),
                                               write: "terminal-first-\(scale)"), 30)
        }
    }

    /// Whole-view evidence: a corpus conversation, a future-version one with the
    /// banner, and the terminal-first state, through `AgentTranscriptView` itself.
    @MainActor
    func testRendersTheWholeViewForAFixtureConversationOffscreen() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        // A newer version whose shapes are still known: banner over a live conversation.
        let newer = tempDir().appendingPathComponent("newer.jsonl")
        try write(newer, [entry("user", version: "2.1.400", ["message": ["role": "user", "content": "Run the checks again."]]),
                          assistant([["type": "text", "text": "Running them now."]], version: "2.1.400"),
                          toolUse("t1", "Bash", ["command": "swift test", "description": "Run the tests"]),
                          toolResult("t1", "Executed 12 tests", extra: ["stdout": "Executed 12 tests", "stderr": ""]),
                          entry("checkpoint", version: "2.1.400", ["label": "x"])])
        for (name, file, dch) in [("conversation-2.1.318", "2.1.318/b-compaction-agents-more-tools.jsonl", "1.30.0"),
                                  ("conversation-2.1.223", "2.1.223/a-tools-and-noise.jsonl", "1.30.0"),
                                  ("conversation-future", "2.4.0/future-renamed-and-unknown.jsonl", "1.30.0"),
                                  ("conversation-newer-known-shapes", newer.path, "1.30.0"),
                                  ("conversation-old-dch", "2.1.318/a-tools-and-noise.jsonl", "1.29.2")] {
            let m = model(file.hasPrefix("/") ? file : Self.corpus.appendingPathComponent(file).path, dch: dch)
            m.start()
            defer { m.stop() }
            for scale: CGFloat in [0.85, 1.0] {
                ThemeRuntime.scale = scale
                let ink = try inkPixels(AgentTranscriptView(model: m, scrolls: false), width: 560, write: "\(name)-\(scale)")
                XCTAssertGreaterThan(ink, 200, name)
            }
        }
    }
}

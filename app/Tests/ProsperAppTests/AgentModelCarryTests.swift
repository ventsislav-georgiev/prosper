import XCTest
@testable import ProsperApp

/// #1372: the model and effort of a session with a very large transcript. Every file here is a sparse fake through
/// the IO seam (a closure over a short tail, nothing on disk); no real transcript is read, no dch runs.
final class AgentModelCarryTests: XCTestCase {

    static let sid = "0b7c2f3e-aaaa-bbbb-cccc-0123456789ab"
    static let otherSID = "1b7c2f3e-aaaa-bbbb-cccc-0123456789ab"
    static let path = "/Users/example/.claude/projects/p/\(sid).jsonl"
    static let otherPath = "/Users/example/.claude/projects/p/\(otherSID).jsonl"
    static let dir = "/Users/example/dch"

    /// Files of any size: `tail` sits at the end, every byte before it repeats one short user line. Counts reads.
    final class Sparse: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: (size: UInt64, tail: Data)] = [:]
        private(set) var reads = 0, bytes = 0, longest = 0
        static let filler: Data = {
            let one = Data(#"{"type":"user","message":{"content":"\#(String(repeating: "x", count: 4000))"}}"#.utf8)
            return one + Data([0x0A])
        }()

        func set(_ path: String, size: UInt64, tail: Data) {
            precondition(UInt64(tail.count) <= size)
            lock.withLock { files[path] = (size, tail) }
        }
        func reset() { lock.withLock { reads = 0; bytes = 0; longest = 0 } }

        var io: AgentModelEffort.IO {
            AgentModelEffort.IO(
                size: { [self] path in lock.withLock { files[path]?.size } },
                read: { [self] path, off, len in
                    let f: (size: UInt64, tail: Data)? = lock.withLock {
                        reads += 1; bytes += len; longest = max(longest, len)
                        return files[path]
                    }
                    guard let f, len >= 0, off <= f.size, UInt64(len) <= f.size - off else { return nil }
                    return Self.bytes(size: f.size, tail: f.tail, off, len)
                })
        }

        private static func bytes(size: UInt64, tail: Data, _ off: UInt64, _ len: Int) -> Data {
            let tailStart = size - UInt64(tail.count), stop = off + UInt64(len)
            var out = Data(capacity: len), o = off
            while o < stop {
                if o >= tailStart {
                    out += tail.subdata(in: Int(o - tailStart)..<Int(stop - tailStart))
                    break
                }
                let k = Int(o % UInt64(filler.count))
                let n = Int(min(UInt64(filler.count - k), min(stop, tailStart) - o))
                out += filler.subdata(in: k..<(k + n))
                o += UInt64(n)
            }
            return out
        }
    }

    private func line(_ o: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: o) + Data("\n".utf8)
    }

    private func assistant(_ model: String, effort: String? = nil, side: Bool? = nil) -> Data {
        var o: [String: Any] = ["type": "assistant", "message": ["model": model, "role": "assistant"]]
        if let effort { o["effort"] = effort }
        if let side { o["isSidechain"] = side }
        return line(o)
    }

    /// One tool-result line of `count` bytes of content: the large line a long session writes.
    private func toolLine(_ count: Int) -> Data {
        Data(#"{"type":"user","message":{"content":[{"type":"tool_result","content":""#.utf8)
            + Data(repeating: 0x78, count: count) + Data(#""}]}}"#.utf8) + Data("\n".utf8)
    }

    private func read(_ path: String, _ f: Sparse) -> AgentModelEffort? {
        guard let size = f.io.size(path) else { return nil }
        return AgentModelEffort.read(size: size) { f.io.read(path, $0, $1) }
    }

    private func session(_ state: AgentState, sid: String = AgentModelCarryTests.sid,
                         path: String = AgentModelCarryTests.path) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: Self.dir, name: "api"), alias: "", activity: 1, state: state, agents: 0,
                     claudeSessionID: sid, transcriptPath: path)
    }

    /// One list answer for "api" in `state`, mapped to `path`.
    private func answer(_ state: String, sid: String = AgentModelCarryTests.sid,
                        path: String = AgentModelCarryTests.path) -> AgentIsland.Runner {
        let json = Data((#"[{"name":"api","alias":"","activity_epoch":1,"state":"\#(state)","version":"1.80.0","agents":0,"#
            + #""claude_session_id":"\#(sid)","transcript_path":"\#(path)"}]"#).utf8)
        return { _, _ in json }
    }

    private static let mb600: UInt64 = 600_000_000
    private static let mb800: UInt64 = 800_000_000

    /// The operator's case: a 600 MB transcript whose last 3 MiB are one tool-result line, an assistant line before it.
    func testTrailingLineLongerThanOneMiBIsSteppedOverAndTheModelFound() {
        let f = Sparse()
        f.set(Self.path, size: Self.mb600,
              tail: Data("\n".utf8) + assistant("claude-fixture-4-5", effort: "high") + toolLine(3 << 20))
        let got = read(Self.path, f)
        XCTAssertTrue(got?.model == "claude-fixture-4-5" && got?.effort == "high")
        XCTAssertLessThanOrEqual(f.bytes, 4 << 20)
        XCTAssertLessThanOrEqual(f.longest, 1 << 16)
    }

    /// Behind two long lines, the newest main-thread line still wins over a sidechain line after them.
    func testSidechainLineStillSkippedPastALongLine() {
        let f = Sparse()
        f.set(Self.path, size: Self.mb600,
              tail: Data("\n".utf8) + assistant("claude-fixture-4-5") + toolLine(3 << 20)
                + assistant("claude-side-9-9", side: true) + toolLine((1 << 20) + 5))
        XCTAssertTrue(read(Self.path, f)?.model == "claude-fixture-4-5")
    }

    /// The worst case of one read: no assistant line in 800 MB, so exactly the budget is read in 64 KiB steps.
    func testWorstCaseReadsExactlyTheBudget() {
        let f = Sparse()
        f.set(Self.path, size: Self.mb800, tail: toolLine(20 << 20))
        XCTAssertTrue(read(Self.path, f) == nil)
        XCTAssertEqual(f.bytes, 16 << 20)
        XCTAssertEqual(f.reads, 256)
        XCTAssertLessThanOrEqual(f.longest, 1 << 16)
    }

    /// Budget exhausted: nil with nothing known; the same id keeps its last known value through that nil.
    func testBudgetExhaustedIsNilAndTheSameIdKeepsTheLastKnownValue() {
        let f = Sparse()
        f.set(Self.path, size: 10_000_000, tail: Data("\n".utf8) + assistant("claude-fixture-4-5", effort: "high"))
        let known = AgentModelEffort.resolve(session(.working), previous: nil, io: f.io)
        XCTAssertTrue(known.model == "claude-fixture-4-5" && known.effort == "high")
        // The file grew by a line longer than the budget, the row went idle: read, nothing found, the value kept.
        f.set(Self.path, size: Self.mb600, tail: Data("\n".utf8) + assistant("claude-fixture-4-5", effort: "high")
              + toolLine(17 << 20))
        f.reset()
        let next = AgentModelEffort.resolve(session(.idle), previous: known, io: f.io)
        XCTAssertEqual(f.bytes, 16 << 20)
        XCTAssertTrue(next.model == "claude-fixture-4-5" && next.effort == "high" && next.modelReadSize == Self.mb600)
        // With nothing known, the same read is nil.
        let fresh = AgentModelEffort.resolve(session(.idle), previous: nil, io: f.io)
        XCTAssertTrue(fresh.model == nil && fresh.effort == nil && fresh.modelReadSize == Self.mb600)
    }

    /// "Gone after a card update": the row is rebuilt from each list answer; a state change re-reads a file that now
    /// ends in a line past the budget. Same Claude session id: the badge stays, through the next answers too.
    func testSameIdAfterARebuildIsKept() {
        let f = Sparse()
        f.set(Self.path, size: 10_000_000, tail: Data("\n".utf8) + assistant("claude-fixture-4-5", effort: "high"))
        let first = AgentIsland.list(dirs: [Self.dir], run: answer("working"), modelIO: f.io)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first.flatMap { AgentSidebar.row($0, details: .all, now: 1).model }, "Fixture 4.5")
        var rows = first, size = Self.mb800
        for state in ["idle", "working", "blocked", "idle"] {
            size += 1
            f.set(Self.path, size: size, tail: toolLine(17 << 20))
            rows = AgentIsland.list(dirs: [Self.dir], keeping: rows, run: answer(state), modelIO: f.io)
            let row = rows.first.map { AgentSidebar.row($0, details: .all, now: 1) }
            XCTAssertEqual(row?.model, "Fixture 4.5", state)
            XCTAssertEqual(row?.effort, "high", state)
        }
    }

    /// A new Claude session id (a new conversation) is read afresh and never shows the old id's value.
    func testNewIdIsReadAfresh() {
        let f = Sparse()
        f.set(Self.path, size: 10_000_000, tail: Data("\n".utf8) + assistant("claude-fixture-4-5", effort: "high"))
        f.set(Self.otherPath, size: Self.mb600, tail: toolLine(17 << 20))
        let first = AgentIsland.list(dirs: [Self.dir], run: answer("idle"), modelIO: f.io)
        XCTAssertTrue(first.first?.model == "claude-fixture-4-5")
        f.reset()
        let next = AgentIsland.list(dirs: [Self.dir], keeping: first,
                                    run: answer("idle", sid: Self.otherSID, path: Self.otherPath), modelIO: f.io)
        XCTAssertGreaterThan(f.reads, 0)
        XCTAssertTrue(next.first.map { $0.model == nil && $0.effort == nil && $0.claudeSessionID == Self.otherSID } == true)
        XCTAssertTrue(next.first.map { AgentSidebar.row($0, details: .all, now: 1).model == nil } == true)
    }
}

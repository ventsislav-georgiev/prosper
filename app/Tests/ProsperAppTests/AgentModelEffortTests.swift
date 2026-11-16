import XCTest
@testable import ProsperApp

/// #1198 (P1a of #1192): the model and effort of the last answer, read from a transcript tail. Fixtures
/// under Tests/Fixtures/claude-code and files written in tempDir(); every read goes through the counting
/// seam, nothing asserts time, no real dch runs, no real transcript is read.
final class AgentModelEffortTests: XCTestCase {

    static let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/claude-code", isDirectory: true)

    /// Counts what the reader asks for. Memory-backed when `files` holds the path, else the real file.
    final class Counting: @unchecked Sendable {
        private let lock = NSLock()
        private var files: [String: Data]
        private(set) var stats = 0, reads = 0, bytes = 0, longest = 0
        init(files: [String: Data] = [:]) { self.files = files }
        func set(_ path: String, _ data: Data) { lock.lock(); files[path] = data; lock.unlock() }
        func reset() { lock.lock(); stats = 0; reads = 0; bytes = 0; longest = 0; lock.unlock() }
        var io: AgentModelEffort.IO {
            AgentModelEffort.IO(
                size: { [self] path in
                    lock.lock(); defer { lock.unlock() }
                    stats += 1
                    if let d = files[path] { return UInt64(d.count) }
                    return AgentModelEffort.IO.live.size(path)
                },
                read: { [self] path, off, len in
                    lock.lock()
                    let mem = files[path]
                    reads += 1; bytes += len; longest = max(longest, len)
                    lock.unlock()
                    guard let d = mem else { return AgentModelEffort.IO.live.read(path, off, len) }
                    guard off <= UInt64(d.count), len <= d.count - Int(off) else { return nil }
                    return d.subdata(in: Int(off)..<(Int(off) + len))
                })
        }
    }

    private func readPath(_ path: String, _ c: Counting = Counting()) -> AgentModelEffort? {
        guard let size = c.io.size(path) else { return nil }
        return AgentModelEffort.read(size: size) { c.io.read(path, $0, $1) }
    }

    private func line(_ o: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: o) + Data("\n".utf8)
    }

    private func assistant(_ model: Any, side: Any? = nil, effort: Any? = nil) -> Data {
        var o: [String: Any] = ["type": "assistant", "message": ["model": model, "role": "assistant"]]
        if let side { o["isSidechain"] = side }
        if let effort { o["effort"] = effort }
        return line(o)
    }

    private func write(_ data: Data, _ name: String = "t.jsonl") -> String {
        let url = tempDir().appendingPathComponent(name)
        try! data.write(to: url)
        return url.path
    }

    // MARK: - Reader on the fixtures

    func testFixturesNewestMainThreadModelAndEffort() {
        // (fixture, model, effort): the 2.1.318 a and b files hold effort "high"; the rest hold none.
        let table: [(String, String?, String?)] = [
            ("2.1.223/a-tools-and-noise.jsonl", "claude-fixture-model", nil),
            ("2.1.223/b-compaction-agents-bad-lines.jsonl", "claude-fixture-model", nil),
            ("2.1.280/a-tools-and-noise.jsonl", "claude-fixture-model", nil),
            ("2.1.280/b-compaction-agents.jsonl", "claude-fixture-model", nil),
            ("2.1.318/a-tools-and-noise.jsonl", "claude-fixture-model", "high"),
            ("2.1.318/b-compaction-agents-more-tools.jsonl", "claude-fixture-model", "high"),
            ("2.1.318/c-tasks.jsonl", "claude-fixture-model", nil),
            ("2.1.318/d-todowrite.jsonl", "claude-fixture-model", nil),
            ("2.4.0/future-renamed-and-unknown.jsonl", nil, nil),
        ]
        for (file, model, effort) in table {
            let got = readPath(Self.corpus.appendingPathComponent(file).path)
            XCTAssertTrue(got?.model == model, file)
            XCTAssertTrue(got?.effort == effort, file)
        }
    }

    // MARK: - Reader rules

    func testSidechainNewestShowsTheMainThreadModel() {
        let data = assistant("claude-main-4-2") + assistant("claude-side-9-9", side: true)
            + assistant("claude-side-8-8", side: true)
        XCTAssertTrue(readPath(write(data))?.model == "claude-main-4-2")
        // A sidechain flag that is not a Bool is not a main-thread line either.
        let odd = assistant("claude-main-4-2") + assistant("claude-odd-1-1", side: "false")
        XCTAssertTrue(readPath(write(odd))?.model == "claude-main-4-2")
        // Absent and false both read as main.
        XCTAssertTrue(readPath(write(assistant("claude-a-1-1", side: false)))?.model == "claude-a-1-1")
    }

    func testEffortWordMustBeKnown() {
        let table: [(Any?, String?)] = [
            ("low", "low"), ("medium", "medium"), ("high", "high"), ("xhigh", "xhigh"), ("max", "max"),
            ("turbo", nil), ("HIGH", nil), ("", nil), (5, nil), (nil, nil),
        ]
        for (word, want) in table {
            let got = readPath(write(assistant("claude-a-1-1", effort: word)))
            XCTAssertTrue(got?.model == "claude-a-1-1")
            XCTAssertTrue(got?.effort == want, "\(String(describing: word))")
        }
    }

    func testNonStringModelAndOtherTypesReadAsNothing() {
        XCTAssertTrue(readPath(write(assistant(5))) == nil)
        XCTAssertTrue(readPath(write(assistant(""))) == nil)
        XCTAssertTrue(readPath(write(assistant(String(repeating: "m", count: 129)))) == nil)
        XCTAssertTrue(readPath(write(line(["type": "user", "message": ["model": "claude-a-1-1"]]))) == nil)
        XCTAssertTrue(readPath(write(Data())) == nil)
        XCTAssertTrue(readPath("/Users/example/none.jsonl") == nil)
    }

    func testModelIdAllowlistIsPerScalar() {
        let table: [(String, String?)] = [
            ("claude-a-1-1-20250101", "claude-a-1-1-20250101"),
            ("provider.model-v1:2", "provider.model-v1:2"),
            ("model@2025", "model@2025"),
            ("vendor/model_x", "vendor/model_x"),
            ("claude-a\u{202E}-1", nil),
            ("claude-a\u{0085}-1", nil),
            ("claude a-1", nil),
            ("claude-\u{00E9}-1", nil),
            ("claude-a\u{0301}-1", nil),
            ("", nil),
            (String(repeating: "m", count: 128), String(repeating: "m", count: 128)),
            (String(repeating: "m", count: 129), nil),
        ]
        for (id, want) in table {
            let got = AgentModelEffort.parse(assistant(id, effort: "high"))
            XCTAssertTrue(got?.model == want, id)
            // The effort is read from the same line only when the id is kept.
            XCTAssertTrue(got?.effort == (want == nil ? nil : "high"), id)
        }
    }

    func testRefusedIdLineLeavesTheOlderLineStanding() {
        let data = assistant("claude-old-2-0", effort: "low") + assistant("claude-a\u{202E}-1", effort: "max")
        let got = readPath(write(data))
        XCTAssertTrue(got?.model == "claude-old-2-0" && got?.effort == "low")
    }

    func testBadLinesReadAsNothingAndOlderLineStands() {
        var bad = Data("{\"type\":\"assistant\",\"message\":{\"model\":\"claude-nul-1-1\"}}".utf8)
        bad.insert(0, at: 5)
        let notUTF8 = Data([0x7B, 0xFF, 0xFE, 0x7D])
        let data = assistant("claude-old-2-0") + Data("{not json\n".utf8) + bad + Data("\n".utf8)
            + notUTF8 + Data("\n".utf8) + Data("[1,2]\n\n".utf8) + Data("{\"type\":\"assistant\"".utf8)
        XCTAssertTrue(readPath(write(data))?.model == "claude-old-2-0")
    }

    func testRenamedKeysReadAsUnknownNotWrong() {
        let renamed = line(["entry_type": "assistant", "message": ["model_id": "claude-alias-3-1"], "effort_level": "max"])
        let got = readPath(write(renamed))
        XCTAssertTrue(got?.model == "claude-alias-3-1")
        XCTAssertTrue(got?.effort == "max")
        XCTAssertTrue(readPath(write(line(["type": "assistant", "message": ["mdl": "claude-a-1-1"]]))) == nil)
    }

    // MARK: - Bounds

    func testFileWithNoAssistantInTheBudgetReadsAtMostTheBudget() {
        // #1372: an assistant line at the very start is outside the last 16 MiB (the budget) and must not be found.
        let filler = line(["type": "user", "message": ["content": String(repeating: "x", count: 1000)]])
        var data = assistant("claude-early-1-1")
        while data.count < 17 << 20 { data += filler }
        data = data.prefix(17 << 20) + Data()
        XCTAssertEqual(data.count, 17 << 20)
        let c = Counting(files: ["/Users/example/big.jsonl": data])
        XCTAssertTrue(readPath("/Users/example/big.jsonl", c) == nil)
        XCTAssertEqual(c.bytes, 16 << 20)
        XCTAssertLessThanOrEqual(c.longest, 1 << 16)
        XCTAssertGreaterThan(c.reads, 0)
    }

    func testOneLineLongerThanMaxLineReadsAsNothing() {
        let huge = Data("{\"type\":\"assistant\",\"pad\":\"".utf8) + Data(repeating: 0x78, count: 1_300_000)
            + Data("\",\"message\":{\"model\":\"claude-huge-1-1\"}}\n".utf8)
        let c = Counting(files: ["/Users/example/huge.jsonl": huge])
        XCTAssertTrue(readPath("/Users/example/huge.jsonl", c) == nil)
        // #1372: stepped over to the file start (under the budget), never parsed.
        XCTAssertEqual(c.bytes, huge.count)
        XCTAssertLessThanOrEqual(c.longest, 1 << 16)
    }

    func testLineSpanningSeveralStepsIsFoundWhole() {
        let pad = String(repeating: "y", count: 200_000)
        let data = line(["type": "assistant", "pad": pad, "message": ["model": "claude-wide-5-0"]])
            + line(["type": "user"])
        let c = Counting(files: ["/Users/example/wide.jsonl": data])
        XCTAssertTrue(readPath("/Users/example/wide.jsonl", c)?.model == "claude-wide-5-0")
        XCTAssertLessThanOrEqual(c.longest, 1 << 16)
    }

    func testShortFileAndShortReadAreSafe() {
        let data = assistant("claude-a-1-1")
        XCTAssertTrue(AgentModelEffort.read(size: UInt64(data.count)) { _, _ in nil } == nil)
        XCTAssertTrue(AgentModelEffort.read(size: UInt64(data.count)) { _, len in Data(repeating: 0x20, count: len - 1) } == nil)
        XCTAssertTrue(AgentModelEffort.read(size: 0) { _, _ in data } == nil)
    }

    func testAShortReadHoldingAWholeLineReadsAsNothing() {
        let data = assistant("claude-a-1-1")
        // Control: the same bytes read honestly give the model.
        let honest = AgentModelEffort.read(size: UInt64(data.count)) { off, len in
            data.subdata(in: Int(off)..<(Int(off) + len))
        }
        XCTAssertTrue(honest?.model == "claude-a-1-1")
        // Size larger than the bytes returned: the chunk is shorter than asked, so nothing.
        let short = AgentModelEffort.read(size: UInt64(data.count + 10)) { _, _ in data }
        XCTAssertTrue(short == nil)
    }

    // MARK: - Short name

    func testShortNames() {
        let table: [(String, String)] = [
            ("claude-opus-4-7", "Opus 4.7"),
            ("claude-sonnet-4-5-20250929", "Sonnet 4.5"),
            ("claude-sonnet-4", "Sonnet 4"),
            ("claude-sonnet-4-20250514", "Sonnet 4"),
            ("claude-haiku-5", "Haiku 5"),
            ("claude-haiku-5-20260101", "Haiku 5"),
            ("claude-fixture-model", "claude-fixture-model"),
            ("claude-3-5-sonnet-20241022", "claude-3-5-sonnet-20241022"),
            ("claude-opus-4-7-1-2", "claude-opus-4-7-1-2"),
            ("claude-opus-4-x", "claude-opus-4-x"),
            ("claude-Opus-4-7", "claude-Opus-4-7"),
            ("claude-opus", "claude-opus"),
            ("claude--4-7", "claude--4-7"),
            ("other-opus-4-7", "other-opus-4-7"),
            ("", ""),
            ("claude-opus-12345678-7", "claude-opus-12345678-7"),
        ]
        for (id, want) in table { XCTAssertEqual(AgentModelEffort.shortName(id), want, id) }
    }

    // MARK: - List path (cache by path and size)

    private let path = "/Users/example/.claude/projects/p/0b7c2f3e-aaaa-bbbb-cccc-0123456789ab.jsonl"

    private func session(_ state: AgentState, path: String?) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: "/Users/example/dch", name: "api"), alias: "", activity: 1,
                     state: state, agents: 0, transcriptPath: path)
    }

    func testResolveReadsOnlyWhenSizeChangedAndNewOrLeftWorking() {
        let a = assistant("claude-first-1-0", effort: "low")
        let b = a + assistant("claude-second-2-0", effort: "max")
        let c = Counting(files: [path: a])
        // New row: one read pass, values filled.
        var s = AgentModelEffort.resolve(session(.working, path: path), previous: nil, io: c.io)
        XCTAssertTrue(s.model == "claude-first-1-0" && s.effort == "low" && s.modelReadSize == UInt64(a.count))
        XCTAssertEqual(c.stats, 1)
        // Same size: no bytes read, one stat.
        c.reset()
        var next = AgentModelEffort.resolve(session(.working, path: path), previous: s, io: c.io)
        XCTAssertEqual(c.reads, 0); XCTAssertEqual(c.bytes, 0); XCTAssertEqual(c.stats, 1)
        XCTAssertTrue(next.model == "claude-first-1-0")
        s = next
        // Grew while still working: not read, old values and old size kept.
        c.set(path, b); c.reset()
        next = AgentModelEffort.resolve(session(.working, path: path), previous: s, io: c.io)
        XCTAssertEqual(c.reads, 0)
        XCTAssertTrue(next.model == "claude-first-1-0" && next.modelReadSize == UInt64(a.count))
        s = next
        // Grew, idle before and idle now (an answer between two ticks): exactly one read, new values.
        let idle = AgentSession(key: s.key, alias: "", activity: 1, state: .idle, agents: 0, transcriptPath: path,
                                           model: s.model, effort: s.effort, modelReadSize: s.modelReadSize)
        c.reset()
        next = AgentModelEffort.resolve(session(.idle, path: path), previous: idle, io: c.io)
        XCTAssertEqual(c.stats, 1)
        XCTAssertTrue(c.reads > 0 && c.bytes == b.count)
        XCTAssertTrue(next.model == "claude-second-2-0" && next.modelReadSize == UInt64(b.count))
        // Left working: read, new values.
        c.reset()
        next = AgentModelEffort.resolve(session(.done, path: path), previous: s, io: c.io)
        XCTAssertGreaterThan(c.reads, 0)
        XCTAssertTrue(next.model == "claude-second-2-0" && next.effort == "max" && next.modelReadSize == UInt64(b.count))
        // It is cached by the new size again.
        c.reset()
        _ = AgentModelEffort.resolve(session(.done, path: path), previous: next, io: c.io)
        XCTAssertEqual(c.reads, 0)
    }

    func testEveryStateOnGrowthAndUnchangedSize() {
        let a = assistant("claude-first-1-0"), b = a + assistant("claude-second-2-0")
        let c = Counting(files: [path: a])
        // (state now, read when the size grew): the literal table over every AgentState.
        let table: [(AgentState, Bool)] = [(.working, false), (.blocked, true), (.done, true), (.idle, true)]
        XCTAssertEqual(table.count, AgentState.allCases.count)
        XCTAssertEqual(Set(table.map { $0.0.rawValue }), Set(AgentState.allCases.map { $0.rawValue }))
        for (state, reads) in table {
            for before in AgentState.allCases {
                c.set(path, a)
                let seen = AgentModelEffort.resolve(session(before, path: path), previous: nil, io: c.io)
                // Size unchanged: never read.
                c.reset()
                _ = AgentModelEffort.resolve(session(state, path: path), previous: seen, io: c.io)
                XCTAssertEqual(c.reads, 0, "\(before) -> \(state) unchanged")
                // Size grew: read exactly when the row is not working now.
                c.set(path, b); c.reset()
                let got = AgentModelEffort.resolve(session(state, path: path), previous: seen, io: c.io)
                XCTAssertTrue((c.reads > 0) == reads, "\(before) -> \(state) grew")
                XCTAssertTrue(got.model == (reads ? "claude-second-2-0" : "claude-first-1-0"), "\(before) -> \(state)")
            }
        }
    }

    func testLiveStatRefusesAFolderAndAnswersForARegularFile() {
        let dir = tempDir()
        XCTAssertTrue(AgentModelEffort.IO.live.size(dir.path) == nil)
        let f = write(assistant("claude-a-1-1"), "live.jsonl")
        XCTAssertTrue(AgentModelEffort.IO.live.size(f) == UInt64(assistant("claude-a-1-1").count))
        // Through the seam: a folder reads as nothing and nothing is read.
        let c = Counting()
        let r = AgentModelEffort.resolve(session(.idle, path: dir.path), previous: nil, io: c.io)
        XCTAssertTrue(r.model == nil && r.modelReadSize == nil)
        XCTAssertEqual(c.reads, 0)
    }

    /// Descriptors open in this process (probing the low range), for the close-on-every-path row.
    private func openDescriptors() -> Int {
        (3..<1024).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    }

    func testLiveReadOfANonRegularFileIsNothingAndNeverBlocks() {
        let dir = tempDir()
        let live = AgentModelEffort.IO.live
        XCTAssertTrue(live.read(dir.path, 0, 16) == nil)
        // One FIFO, made after the non-blocking open is in the code under test; the read runs on its own
        // queue and the wait fails instead of hanging the suite.
        let fifo = dir.appendingPathComponent("pipe").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        let done = expectation(description: "read of a FIFO returns")
        let box = Box()
        DispatchQueue.global().async {   // runs off main, captures only Sendable values
            box.value = live.read(fifo, 0, 16)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(box.value == nil)
        XCTAssertTrue(live.size(fifo) == nil)
    }

    final class Box: @unchecked Sendable { var value: Data? = Data() }

    func testLiveReadOfARegularFileIsUnchangedAndASymlinkInsideTheFolderIsFollowed() {
        let body = assistant("claude-a-1-1")
        let f = write(body, "live.jsonl")
        let live = AgentModelEffort.IO.live
        XCTAssertTrue(live.read(f, 0, body.count) == body)
        XCTAssertTrue(live.read(f, 1, 3) == body.subdata(in: 1..<4))
        XCTAssertTrue(live.read(f, UInt64(body.count) + 1, 1) == nil)   // offset past the end
        XCTAssertTrue(live.read(f, UInt64.max, 1) == nil)
        XCTAssertTrue(live.read(f, 0, 0) == nil)
        let link = URL(fileURLWithPath: f).deletingLastPathComponent().appendingPathComponent("link.jsonl").path
        XCTAssertNoThrow(try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: f))
        XCTAssertTrue(live.read(link, 0, body.count) == body)
    }

    func testLiveReadsLeaveTheDescriptorCountUnchanged() {
        let dir = tempDir()
        let f = write(assistant("claude-a-1-1"), "live.jsonl")
        let missing = dir.appendingPathComponent("none").path
        let live = AgentModelEffort.IO.live
        _ = live.read(f, 0, 1)   // warm any lazy descriptor first
        let before = openDescriptors()
        for _ in 0..<200 {
            _ = live.read(f, 0, 8); _ = live.read(dir.path, 0, 8); _ = live.read(missing, 0, 8)
            _ = live.read(f, UInt64.max, 8)
        }
        // A leak on any one refused path adds at least 200; other threads may move the count by a few.
        XCTAssertLessThan(openDescriptors() - before, 100, "descriptors leaked by the live read")
    }

    func testShrunkOrReplacedFileIsReadAgain() {
        let big = assistant("claude-big-1-0") + assistant("claude-big-2-0")
        let small = assistant("claude-small-3-0")
        let c = Counting(files: [path: big])
        let s = AgentModelEffort.resolve(session(.idle, path: path), previous: nil, io: c.io)
        XCTAssertTrue(s.model == "claude-big-2-0")
        c.set(path, small); c.reset()
        let shrunk = AgentModelEffort.resolve(session(.idle, path: path), previous: s, io: c.io)
        XCTAssertGreaterThan(c.reads, 0)
        XCTAssertTrue(shrunk.model == "claude-small-3-0")
        // A different path under the same key (a new transcript) is read although the size grew.
        let other = "/Users/example/.claude/projects/p/1b7c2f3e-aaaa-bbbb-cccc-0123456789ab.jsonl"
        c.set(other, big + big); c.reset()
        let moved = AgentModelEffort.resolve(session(.idle, path: other), previous: shrunk, io: c.io)
        XCTAssertGreaterThan(c.reads, 0)
        XCTAssertTrue(moved.model == "claude-big-2-0")
    }

    func testNothingFoundIsCachedAndRowsWithoutAPathReadNothing() {
        let c = Counting(files: [path: line(["type": "user"])])
        let s = AgentModelEffort.resolve(session(.idle, path: path), previous: nil, io: c.io)
        XCTAssertTrue(s.model == nil && s.effort == nil && s.modelReadSize != nil)
        c.reset()
        _ = AgentModelEffort.resolve(session(.idle, path: path), previous: s, io: c.io)
        XCTAssertEqual(c.reads, 0)
        // Codex, shell and History rows have no transcript path: no stat, no read.
        c.reset()
        for p in [nil, ""] as [String?] {
            let r = AgentModelEffort.resolve(session(.idle, path: p), previous: nil, io: c.io)
            XCTAssertTrue(r.model == nil && r.modelReadSize == nil)
        }
        XCTAssertEqual(c.stats, 0); XCTAssertEqual(c.reads, 0)
        // A path that cannot be stat'd reads nothing.
        let gone = AgentModelEffort.resolve(session(.idle, path: "/Users/example/gone.jsonl"), previous: nil, io: c.io)
        XCTAssertTrue(gone.model == nil)
        XCTAssertEqual(c.reads, 0)
    }

    func testListFillsFieldsAndKeepsThemThroughTheNextList() {
        let sid = "0b7c2f3e-aaaa-bbbb-cccc-0123456789ab"
        let json = Data((#"[{"name":"api","alias":"","activity_epoch":1,"state":"working","version":"1.60.0","agents":0,"#
            + #""claude_session_id":"\#(sid)","transcript_path":"\#(path)"},"#
            + #"{"name":"sh","alias":"","activity_epoch":1,"state":"idle","version":"1.60.0","agents":0}]"#).utf8)
        let c = Counting(files: [path: assistant("claude-list-4-6", effort: "xhigh")])
        let run: AgentIsland.Runner = { _, _ in json }
        let first = AgentIsland.list(dirs: ["/Users/example/dch"], run: run, modelIO: c.io)
        XCTAssertEqual(first.count, 2)
        let api = first.first { $0.name == "api" }, sh = first.first { $0.name == "sh" }
        XCTAssertTrue(api?.model == "claude-list-4-6" && api?.effort == "xhigh")
        XCTAssertTrue(sh?.model == nil && sh?.effort == nil)
        XCTAssertEqual(c.stats, 1)
        c.reset()
        let second = AgentIsland.list(dirs: ["/Users/example/dch"], keeping: first, run: run, modelIO: c.io)
        XCTAssertEqual(c.reads, 0)
        XCTAssertTrue(second.first { $0.name == "api" }?.model == "claude-list-4-6")
    }
}

// MARK: - #1267: the label kept over list answers with no mapping, and a nil read again under a working row

extension AgentModelEffortTests {
    private static let carrySID = "0b7c2f3e-aaaa-bbbb-cccc-0123456789ab"   // the file name of `path`
    private static let carryDir = "/Users/example/dch"

    /// One list answer for "api" (working), mapped to `path` or with dch's nulls (no mapping), plus a shell row "sh".
    private func answer(_ mapped: String?, sid: String = AgentModelEffortTests.carrySID) -> AgentIsland.Runner {
        let map = mapped.map { #""claude_session_id":"\#(sid)","transcript_path":"\#($0)""# }
            ?? #""claude_session_id":null,"transcript_path":null"#
        let json = Data((#"[{"name":"api","alias":"","activity_epoch":1,"state":"working","version":"1.65.0","agents":0,"#
            + map + "},"
            + #"{"name":"sh","alias":"","activity_epoch":1,"state":"idle","version":"1.65.0","agents":0}]"#).utf8)
        return { _, _ in json }
    }

    private func list(_ run: @escaping AgentIsland.Runner, _ previous: [AgentSession], _ c: Counting) -> [AgentSession] {
        AgentIsland.list(dirs: [Self.carryDir], keeping: previous, run: run, modelIO: c.io)
    }

    private func sidebar(_ l: [AgentSession], _ name: String) -> AgentSidebar.Row? {
        l.first { $0.name == name }.map { AgentSidebar.row($0, details: .all, now: 1) }
    }

    func testCarryKeepsTheLabelForThreeAnswersWithoutAMappingThenDrops() {
        XCTAssertEqual(AgentModelEffort.carryAnswers, 3)
        let c = Counting(files: [path: assistant("claude-list-4-6", effort: "xhigh")])
        var l = list(answer(path), [], c)
        XCTAssertTrue(l.first { $0.name == "api" }?.model == "claude-list-4-6")
        for n in 1...3 {
            c.reset()
            l = list(answer(nil), l, c)
            let api = l.first { $0.name == "api" }
            XCTAssertTrue(api?.model == "claude-list-4-6" && api?.effort == "xhigh", "answer \(n) without a mapping keeps it")
            XCTAssertEqual(api?.modelCarried, n)
            // Display only: no path, no Claude id, no read size (the pane and auto-allow keep today's rule).
            XCTAssertTrue(api?.transcriptPath == nil && api?.claudeSessionID == nil && api?.modelReadSize == nil, "\(n)")
            XCTAssertEqual(c.stats, 0, "nothing stat'd without a path (\(n))"); XCTAssertEqual(c.reads, 0)
            let row = sidebar(l, "api")
            XCTAssertEqual(row?.modelSlot, true, "the slot stays (\(n))")
            XCTAssertEqual(row?.modelText, "List 4.6 · xhigh", "\(n)")
            XCTAssertEqual(sidebar(l, "sh")?.modelSlot, false, "a shell row never gets a slot (\(n))")
            // The transcript pane's input keeps today's nil.
            XCTAssertTrue(api.map { AgentSidebar.source($0).transcriptPath == nil && AgentSidebar.source($0).sessionId == nil } == true)
        }
        for n in 4...5 {
            l = list(answer(nil), l, c)
            let api = l.first { $0.name == "api" }
            XCTAssertTrue(api?.model == nil && api?.effort == nil && api?.modelCarried == 0, "answer \(n): dropped as before")
            XCTAssertEqual(sidebar(l, "api")?.modelSlot, false, "\(n)")
            XCTAssertEqual(sidebar(l, "api")?.modelText, "", "\(n)")
        }
    }

    func testCarryEndsWhenTheMappingReturnsAndIsCountedAfresh() {
        let c = Counting(files: [path: assistant("claude-list-4-6", effort: "high")])
        var l = list(answer(path), [], c)
        l = list(answer(nil), l, c)
        l = list(answer(nil), l, c)
        XCTAssertEqual(l.first { $0.name == "api" }?.modelCarried, 2)
        c.reset()
        l = list(answer(path), l, c)
        let api = l.first { $0.name == "api" }
        XCTAssertTrue(api?.modelCarried == 0 && api?.transcriptPath == path && api?.model == "claude-list-4-6")
        XCTAssertGreaterThan(c.reads, 0, "a returning mapping is read afresh (one bounded read)")
        for n in 1...3 { l = list(answer(nil), l, c); XCTAssertTrue(l.first { $0.name == "api" }?.model == "claude-list-4-6", "\(n)") }
        l = list(answer(nil), l, c)
        XCTAssertTrue(l.first { $0.name == "api" }?.model == nil)
    }

    func testCarryNeverShowsTheOldValueAfterANewPath() {
        let other = "/Users/example/.claude/projects/p/00000000-0000-4000-8000-000000000002.jsonl"
        let c = Counting(files: [path: assistant("claude-old-1-0", effort: "low"),
                                 other: assistant("claude-new-2-0", effort: "max")])
        var l = list(answer(path), [], c)
        l = list(answer(nil), l, c)
        XCTAssertTrue(l.first { $0.name == "api" }?.model == "claude-old-1-0")
        c.reset()
        let moved = list(answer(other, sid: "00000000-0000-4000-8000-000000000002"), l, c)
        XCTAssertTrue(moved.first { $0.name == "api" }?.model == "claude-new-2-0", "the new path's file")
        XCTAssertTrue(moved.first { $0.name == "api" }?.effort == "max")
        XCTAssertGreaterThan(c.reads, 0)
        // A new path whose file holds no answer yet shows nothing, never the old value.
        c.set(other, line(["type": "user"]))
        let empty = list(answer(other, sid: "00000000-0000-4000-8000-000000000002"), l, c)
        let api = empty.first { $0.name == "api" }
        XCTAssertTrue(api?.model == nil && api?.effort == nil && api?.modelCarried == 0)
        // And a carry after it carries nothing.
        let after = list(answer(nil), empty, c)
        XCTAssertTrue(after.first { $0.name == "api" }?.model == nil)
    }

    func testCarryNeverCrossesToAnotherKeyAndNeedsAnEarlierClaudeRow() {
        let c = Counting(files: [path: assistant("claude-list-4-6", effort: "high")])
        let l = list(answer(path), [], c)
        guard let api = l.first(where: { $0.name == "api" }) else { return XCTFail("api listed") }
        // Same name in another dir, and another name: nothing inherited.
        for key in [AgentSessionKey(dir: "/Users/example/other", name: "api"), AgentSessionKey(dir: Self.carryDir, name: "web")] {
            let fresh = AgentSession(key: key, alias: "", activity: 1, state: .working, agents: 0)
            let got = AgentModelEffort.carry(fresh, previous: api)
            XCTAssertTrue(got.model == nil && got.effort == nil && got.modelCarried == 0, "\(key)")
        }
        // A list whose earlier answer had "api" mapped: the shell row "sh" (never mapped) gets nothing.
        let next = list(answer(nil), l, c)
        XCTAssertTrue(next.first { $0.name == "sh" }.map { $0.model == nil && $0.modelCarried == 0 } == true)
        // An earlier Claude row with no model (nothing found yet): the slot is kept, the text is empty.
        let none = Counting(files: [path: line(["type": "user"])])
        var e = list(answer(path), [], none)
        e = list(answer(nil), e, none)
        XCTAssertTrue(e.first { $0.name == "api" }?.model == nil)
        XCTAssertEqual(sidebar(e, "api")?.modelText, "")
        // No earlier list at all (the first answer has no mapping): nothing.
        let first = list(answer(nil), [], none)
        XCTAssertTrue(first.first { $0.name == "api" }.map { $0.model == nil && $0.modelCarried == 0 } == true)
        XCTAssertEqual(sidebar(first, "api")?.modelSlot, false)
    }

    /// 3a: a nil cached under a working row (read before the stretch's first answer) is read again on the next answer
    /// that grew, once per answer; once found, the working carry holds it as before.
    func testWorkingRowWithNothingCachedIsReadAgainOncePerAnswer() {
        let user = line(["type": "user"])
        let c = Counting(files: [path: user])
        var s = AgentModelEffort.resolve(session(.working, path: path), previous: nil, io: c.io)
        XCTAssertTrue(s.model == nil && s.modelReadSize == UInt64(user.count))
        // Same size: no read (the empty result stays cached).
        c.reset()
        s = AgentModelEffort.resolve(session(.working, path: path), previous: s, io: c.io)
        XCTAssertEqual(c.reads, 0)
        // Grew, still nothing: one bounded pass, still nil, the new size kept.
        let more = user + user
        c.set(path, more); c.reset()
        s = AgentModelEffort.resolve(session(.working, path: path), previous: s, io: c.io)
        XCTAssertTrue(c.reads > 0 && c.bytes == more.count)
        XCTAssertTrue(s.model == nil && s.modelReadSize == UInt64(more.count))
        // Grew with an answer: read, found.
        let answered = more + assistant("claude-work-3-1", effort: "high")
        c.set(path, answered); c.reset()
        s = AgentModelEffort.resolve(session(.working, path: path), previous: s, io: c.io)
        XCTAssertGreaterThan(c.reads, 0)
        XCTAssertTrue(s.model == "claude-work-3-1" && s.effort == "high")
        // Found: growth under working is carried again, no read.
        c.set(path, answered + assistant("claude-work-3-2")); c.reset()
        let held = AgentModelEffort.resolve(session(.working, path: path), previous: s, io: c.io)
        XCTAssertEqual(c.reads, 0)
        XCTAssertTrue(held.model == "claude-work-3-1")
    }
}

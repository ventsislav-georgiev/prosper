import XCTest
@testable import ProsperApp

/// #1355 (#1346 P7): X-ray's Search tab runs `dch --xray <n> --search <text> --json` on Return through the
/// XrayPanels.run seam, for a local name or a remote "host:name"; never on a timer. A fake runner answers by form; the
/// clock is injected and the ticks are called by hand. No dch, no process, no window shown, no key posted.
@MainActor
final class XraySearchTabTests: XCTestCase {

    typealias Answer = (status: Int32, out: Data)
    nonisolated static let base = XrayPanelTasksTests.now
    nonisolated static let ok: Answer = (0, XrayPanelTasksTests.tasksOut)
    nonisolated static let mem: Answer = (0, XrayPanelTasksTests.ndjson(XrayPanelTasksTests.memory))

    /// dch's one object with `n` hits, newest first (README "Search" JSON shape).
    nonisolated static func hits(_ n: Int, more: Bool = false, partial: Bool = false, why: String? = nil,
                                 snippet: String = "fix the login test") -> Answer {
        let rows: [[String: Any]] = (0..<n).map { i in
            ["chapter": "f3a41c:\(i)", "offset": i, "at": 1_794_304_860 - i, "who": i % 2 == 0 ? "user" : "assistant",
             "tool": NSNull(), "snippet": "\(snippet) \(i)"]
        }
        let o: [String: Any] = ["schema": 1, "session": "api", "session_id": "0b1f6a52-4c1e-4d7a-9a51-2f6d8c3e7a10",
                                "corpus": "claude", "text": "login", "hits": rows, "more": more, "partial": partial,
                                "why": why ?? NSNull(), "bytes": 1024]
        return (0, (try? JSONSerialization.data(withJSONObject: o)) ?? Data())
    }

    /// The fake dch: records each argv; Tasks and Memory answer at once, a search by its text (default: 3 hits). The
    /// text "slow" waits until its read is cancelled (at most 10 s), counts that, then answers 7 hits.
    final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        private var _answers: [String: Answer] = [:]
        private var _cancelled = 0
        var calls: [[String]] { lock.withLock { _calls } }
        var searches: [[String]] { calls.filter { $0.contains("--search") } }
        var cancelled: Int { lock.withLock { _cancelled } }
        func answer(_ text: String, _ a: Answer) { lock.withLock { _answers[text] = a } }
        var run: XrayPanels.Run {
            { [self] _, args, _ in
                lock.withLock { _calls.append(args) }
                if args.contains("--tasks") { return XraySearchTabTests.ok }
                if args.contains("--memory") { return XraySearchTabTests.mem }
                let text = args.firstIndex(of: "--search").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? ""
                if text == "slow" {
                    let end = Date().addingTimeInterval(10)
                    while !Task.isCancelled, Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
                    if Task.isCancelled { lock.withLock { _cancelled += 1 } }
                    return XraySearchTabTests.hits(7)
                }
                return lock.withLock { _answers[text] } ?? XraySearchTabTests.hits(3)
            }
        }
    }

    final class Clock { var t = XraySearchTabTests.base }

    static let local = XrayTarget(name: "api", dir: "/tmp/dch-test")
    static let remote = XrayTarget(name: "example-host:api", dir: nil)

    /// An opened panel on the Search tab, shown and live, its clock at `base`.
    func opened(_ target: XrayTarget, _ clock: Clock, _ run: Run) async -> XrayPanelModel {
        let p = XrayPanelModel(target: target, tab: .search)
        p.now = { clock.t }
        p.paneState = { (true, true) }
        p.mtime = { _ in Self.base }
        p.searchable = true
        p.read(dch: "/fake/dch", run: run.run)
        await p.reading?.value
        return p
    }

    func search(_ p: XrayPanelModel, _ text: String) async {
        p.query = text
        p.runSearch()
        await p.reading?.value
    }

    /// Red at TIP: no Search tab, no searchArgs, no runSearch (XrayPanel.swift:15 has four tabs).
    func testArgvForALocalSessionAndARemoteOne() async {
        for (target, argv) in [(Self.local, ["--xray", "api", "--search", "login test", "--json"]),
                               (Self.remote, ["--xray", "example-host:api", "--search", "login test", "--json"])] {
            let run = Run(), p = await opened(target, Clock(), run)
            XCTAssertEqual(p.tabs, [.search, .tasks, .memory], "\(target.name)")
            XCTAssertEqual(p.title(.search), "Search", "no count before a search")
            await search(p, "login test")
            XCTAssertEqual(run.searches, [argv], "\(target.name): one read")
            XCTAssertEqual(p.search?.hits.count, 3)
            XCTAssertEqual(p.title(.search), "Search 3")
        }
    }

    /// DchCtl.searchOK: under 2 bytes, over 200, or a control character runs nothing and says why; 2 and 200 bytes run.
    func testABadQueryRunsNothingAndSaysWhy() async {
        let run = Run(), p = await opened(Self.local, Clock(), run)
        for bad in ["", "a", String(repeating: "a", count: 201), "ab\u{0007}", "a\u{202E}b"] {
            await search(p, bad)
            XCTAssertEqual(run.searches.count, 0, "\(bad.utf8.count) bytes ran")
            XCTAssertEqual(p.searchNote, XraySearch.badQuery)
        }
        await search(p, "ab")
        await search(p, String(repeating: "a", count: 200))
        XCTAssertEqual(run.searches.count, 2)
        XCTAssertTrue(p.searchNote == nil, "a good query clears the reason")
    }

    /// 60 hits from a host (more than dch's 50) with more and partial: 50 rows, "Search 50+", the footer lines; every
    /// string capped. Red at TIP: no XraySearch.
    func testFiftyHitsAndMoreSayItInTheFooter() async throws {
        let run = Run(), p = await opened(Self.local, Clock(), run)
        run.answer("login", Self.hits(60, more: true, partial: true, why: "time", snippet: String(repeating: "x", count: 1000)))
        await search(p, "login")
        let s = try XCTUnwrap(p.search)
        XCTAssertEqual(s.hits.count, 50, "dch's cap")
        XCTAssertEqual(s.hits.first?.snippet.unicodeScalars.count, XraySearch.snippetCap)
        XCTAssertEqual(p.title(.search), "Search 50+")
        XCTAssertEqual(p.searchFooter, ["the 50 newest are shown", "the search stopped early: too long"])
        let row = try XCTUnwrap(s.hits.first.map { XraySearchRow($0, now: Self.base) })
        XCTAssertEqual(row.who, "You")
        XCTAssertLessThanOrEqual(row.snippet.count, 240, "drawn through OutsideText")

        run.answer("more", Self.hits(51))
        await search(p, "more")
        XCTAssertEqual(p.search?.hits.count, 50)
        XCTAssertEqual(p.searchFooter, ["the 50 newest are shown"], "a 51st hit is more even without the key")
        run.answer("few", Self.hits(2))
        await search(p, "few")
        XCTAssertEqual(p.searchFooter, [])
        XCTAssertEqual(p.search?.hits.last.map { XraySearchRow($0, now: Self.base).who }, "Reply")
    }

    /// Exit 1 (the host's dch does not know --search) and 6 (refused): no Search tab, the strip moves to Tasks.
    func testExitOneAndSixGiveNoSearchTab() async {
        for status: Int32 in [1, 6] {
            let run = Run(), p = await opened(Self.remote, Clock(), run)
            run.answer("login", (status, Data("dch: example-host: the host's dch does not know --search\n".utf8)))
            await search(p, "login")
            XCTAssertEqual(p.tabs, [.tasks, .memory], "exit \(status)")
            XCTAssertEqual(p.tab, .tasks)
            XCTAssertTrue(p.search == nil)
            XCTAssertEqual(p.searchFooter, [])
        }
    }

    /// Exit 4, 7 or a remote -1 keeps the last hits and says "host unreachable"; the next answer clears the line. A
    /// local -1 is a failed search, not an unreachable host.
    func testAnUnreachableHostKeepsTheHits() async {
        let run = Run(), p = await opened(Self.remote, Clock(), run)
        await search(p, "login")
        for status: Int32 in [4, 7, -1] {
            run.answer("again", (status, Data()))
            await search(p, "again")
            XCTAssertEqual(p.search?.hits.count, 3, "exit \(status) keeps the hits")
            XCTAssertEqual(p.searchFooter, ["host unreachable"])
            XCTAssertTrue(p.tabs.contains(.search))
        }
        await search(p, "login")
        XCTAssertEqual(p.searchFooter, [])

        let lrun = Run(), lp = await opened(Self.local, Clock(), lrun)
        lrun.answer("login", (-1, Data()))
        await search(lp, "login")
        XCTAssertTrue(lp.search == nil)
        XCTAssertEqual(lp.searchNote, "The search failed")
        XCTAssertEqual(lp.searchFooter, [])
    }

    /// A new query cancels the read in flight (the product runner SIGTERMs its dch); only the new answer lands.
    func testANewQueryCancelsTheOneInFlight() async {
        let run = Run(), p = await opened(Self.local, Clock(), run)
        p.query = "slow"
        p.runSearch()
        let first = p.reading
        p.query = "login"
        p.runSearch()
        await first?.value
        XCTAssertEqual(run.cancelled, 1, "the first read was cancelled")
        await p.reading?.value
        XCTAssertEqual(p.search?.hits.count, 3, "the new query's hits, not the cancelled one's 7")
        XCTAssertEqual(run.searches.count, 2)
    }

    /// The poller never runs a search: ticks on the Search tab past every cadence read nothing.
    func testNoSearchReadOnATimer() async {
        for target in [Self.local, Self.remote] {
            let clock = Clock(), run = Run(), p = await opened(target, clock, run)
            await search(p, "login")
            let n = run.calls.count
            for s: TimeInterval in [5, 15, 30, 60, 300] {
                clock.t = Self.base + s
                p.tick()
                await p.reading?.value
            }
            XCTAssertEqual(run.searches.count, 1, "\(target.name)")
            XCTAssertEqual(run.calls.count, n)
        }
    }
}

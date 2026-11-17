import XCTest
@testable import ProsperApp

// #1483 (#1183 R2): the usage record's reader and the five aggregations. Literal rows in files under the row's tempDir()
// (fake accounts "acct-a", sessions "s-0001"), literal expected series. Nothing here touches the real folder.

private let rdNow = 1_800_000_000.25          // 2027-01-15 08:00:00 UTC
private let rdDay = "usage-2027-01-15.jsonl"

/// One good row as JSON text: the keys in the writer's order; `over` replaces a value (raw JSON) or, with nil, removes the key.
private func rdLine(_ over: [String: String?] = [:]) -> String {
    var pairs: [(String, String)] = [
        ("v", "1"), ("t", "1799999000.5"), ("acct", "\"acct-a\""), ("model", "\"claude-opus-5\""), ("sess", "\"s-0001\""),
        ("agent", "\"\""), ("path", "\"messages\""), ("st", "200"), ("ms", "1500"), ("done", "true"), ("qc", "false"),
        ("att", "1"), ("thr", "0"), ("mv", "false"), ("routed", "\"pin\""), ("in", "1000"), ("out", "500"), ("cr", "2000"),
        ("cw5", "400"), ("cw1", "0"), ("lim", #"{"five_hour":{"u":0.5,"r":1800003600,"s":"a"}}"#),
    ]
    for (k, v) in over {
        if let i = pairs.firstIndex(where: { $0.0 == k }) {
            if let v { pairs[i].1 = v } else { pairs.remove(at: i) }
        } else if let v { pairs.append((k, v)) }
    }
    return "{" + pairs.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
}

private func rdEntry(_ t: Double, acct: String = "acct-a", model: String = "claude-opus-5", sess: String? = "s-0001", agent: String? = "",
                     st: Int = 200, ms: Int = 1000, done: Bool = true, qc: Bool = false,
                     tokens: CCPoolUsageEntry.Tokens? = nil, lim: [String: CCPoolUsageEntry.Claim] = [:]) -> CCPoolUsageEntry {
    CCPoolUsageEntry(t: t, acct: acct, model: model, sess: sess, agent: sess == nil ? nil : agent, path: "messages", st: st, ms: ms, done: done,
                     qc: qc, att: 1, thr: 0, mv: false, routed: "pin", tokens: tokens, lim: lim)
}

private func rdTok(_ i: Int, _ o: Int, _ cr: Int, _ cw5: Int, _ cw1: Int = 0) -> CCPoolUsageEntry.Tokens {
    .init(input: i, output: o, cacheRead: cr, cacheWrite5m: cw5, cacheWrite1h: cw1)
}

private func rdClaim(_ u: Double, _ r: Double) -> [String: CCPoolUsageEntry.Claim] { ["five_hour": .init(u: u, r: r, s: "a")] }

/// Written once by the background read, read after the semaphore: no overlap.
private final class RdBox: @unchecked Sendable { var v: CCPoolUsageReadResult? }

final class CCPoolUsageReaderTests: XCTestCase {
    private func dir(_ files: [String: String] = [:]) throws -> URL {
        let d = tempDir().appendingPathComponent("usage")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for (n, text) in files { try Data(text.utf8).write(to: d.appendingPathComponent(n)) }
        return d
    }

    // MARK: the reader

    func testGoodRowDecodesToTheLiteralEntry() throws {
        let got = CCPoolUsageReader.readNow(directory: try dir([rdDay: rdLine() + "\n"]), range: .day, now: rdNow)
        XCTAssertEqual(got.skippedTotal, 0)
        XCTAssertEqual(got.rows, [CCPoolUsageEntry(
            t: 1_799_999_000.5, acct: "acct-a", model: "claude-opus-5", sess: "s-0001", agent: "", path: "messages", st: 200, ms: 1500,
            done: true, qc: false, att: 1, thr: 0, mv: false, routed: "pin", tokens: rdTok(1000, 500, 2000, 400),
            lim: ["five_hour": .init(u: 0.5, r: 1_800_003_600, s: "a")])])
    }

    func testRowWithoutSessionOrUsageOrLimDecodes() throws {
        let bare = rdLine(["sess": nil, "agent": nil, "in": nil, "out": nil, "cr": nil, "cw5": nil, "cw1": nil, "lim": nil])
        let got = CCPoolUsageReader.readNow(directory: try dir([rdDay: bare + "\n"]), range: .day, now: rdNow)
        XCTAssertEqual(got.rows.count, 1)
        XCTAssertTrue(got.rows.first?.sess == nil && got.rows.first?.tokens == nil && got.rows.first?.lim.isEmpty == true)
    }

    /// One literal row per bad kind and the reason it is counted under.
    func testEachBadRowKindIsCountedUnderItsReason() {
        let cases: [(String, String, CCPoolUsageSkip)] = [
            ("not JSON", "this is not json", .notJSON),
            ("a JSON array", "[1,2,3]", .notJSON),
            ("a cut row", String(rdLine().dropLast(20)), .notJSON),
            ("unknown v", rdLine(["v": "2"]), .version),
            ("v zero", rdLine(["v": "0"]), .version),
            ("v missing", rdLine(["v": nil]), .missing),
            ("v a string", rdLine(["v": "\"1\""]), .type),
            ("t missing", rdLine(["t": nil]), .missing),
            ("acct missing", rdLine(["acct": nil]), .missing),
            ("model missing", rdLine(["model": nil]), .missing),
            ("st missing", rdLine(["st": nil]), .missing),
            ("done missing", rdLine(["done": nil]), .missing),
            ("sess without agent", rdLine(["agent": nil]), .missing),
            ("agent without sess", rdLine(["sess": nil]), .missing),
            ("some counts only", rdLine(["cw1": nil]), .missing),
            ("acct a number", rdLine(["acct": "7"]), .type),
            ("acct empty", rdLine(["acct": "\"\""]), .type),
            ("acct over 256 bytes", rdLine(["acct": "\"" + String(repeating: "a", count: 257) + "\""]), .type),
            ("ms a string", rdLine(["ms": "\"1500\""]), .type),
            ("ms a fraction", rdLine(["ms": "1.5"]), .type),
            ("done a number", rdLine(["done": "1"]), .type),
            ("qc null", rdLine(["qc": "null"]), .type),
            ("lim an array", rdLine(["lim": "[]"]), .type),
            ("claim a number", rdLine(["lim": #"{"five_hour":3}"#]), .type),
            ("status word unknown", rdLine(["lim": #"{"five_hour":{"u":0.5,"r":1800003600,"s":"x"}}"#]), .type),
            ("negative tokens", rdLine(["in": "-1"]), .number),
            ("negative ms", rdLine(["ms": "-5"]), .number),
            ("tokens over 1e12", rdLine(["out": "1000000000001"]), .number),
            ("utilization 10.5", rdLine(["lim": #"{"five_hour":{"u":10.5,"r":1800003600,"s":"a"}}"#]), .utilization),
            ("utilization negative", rdLine(["lim": #"{"seven_day":{"u":-0.1,"r":1800003600}}"#]), .utilization),
            ("t negative", rdLine(["t": "-1"]), .epoch),
            ("t at 253402300800", rdLine(["t": "253402300800"]), .epoch),
            ("reset at 1e12", rdLine(["lim": #"{"five_hour":{"u":0.5,"r":1000000000000}}"#]), .epoch),
        ]
        for (name, text, reason) in cases {
            guard case .failure(let bad) = CCPoolUsageReader.decode(Data(text.utf8)) else { XCTFail("\(name) decoded"); continue }
            XCTAssertEqual(bad.reason, reason, name)
        }
        // JSONSerialization may refuse 1e999 or read it as infinity: either way the row is not decoded.
        if case .success = CCPoolUsageReader.decode(Data(rdLine(["ms": "1e999"]).utf8)) { XCTFail("1e999 decoded") }
        // The edges that stay good.
        for (name, text) in [("utilization 10", rdLine(["lim": #"{"five_hour":{"u":10,"r":1800003600}}"#])),
                             ("utilization 0", rdLine(["lim": #"{"five_hour":{"u":0}}"#])),
                             ("t last second", rdLine(["t": "253402300799"])),
                             ("unknown key ignored", rdLine(["extra": "[1]"]))] {
            guard case .success = CCPoolUsageReader.decode(Data(text.utf8)) else { XCTFail("\(name) refused"); continue }
        }
    }

    /// A bad row skips only itself: the good rows before and after it in the same file are read, and the skip is counted.
    func testABadRowSkipsOnlyItself() throws {
        let text = [rdLine(["t": "1799999001"]), "garbage", rdLine(["t": "1799999002"]), rdLine(["v": "9"]), rdLine(["t": "1799999003"]), ""]
            .joined(separator: "\n")
        let got = CCPoolUsageReader.readNow(directory: try dir([rdDay: text]), range: .day, now: rdNow)
        XCTAssertEqual(got.rows.map(\.t), [1_799_999_001, 1_799_999_002, 1_799_999_003])
        XCTAssertEqual(got.skipped, [.notJSON: 1, .version: 1])
        XCTAssertEqual(got.skippedTotal, 2)
    }

    func testTheLineCapIs4KiB() throws {
        func padded(to n: Int) -> String {
            let base = rdLine(["pad": "\"\""]).utf8.count
            return rdLine(["pad": "\"" + String(repeating: "x", count: n - base) + "\""])
        }
        XCTAssertEqual(padded(to: 4096).utf8.count, 4096)
        XCTAssertEqual(padded(to: 4097).utf8.count, 4097)
        // 4096 bytes is read, 4097 is not, and a megabyte without a newline is one skipped line, not the end of the file.
        let text = [padded(to: 4096), padded(to: 4097), String(repeating: "y", count: 1 << 20), rdLine(["t": "1799999002"])].joined(separator: "\n")
        let got = CCPoolUsageReader.readNow(directory: try dir([rdDay: text]), range: .day, now: rdNow)
        XCTAssertEqual(got.rows.map(\.t), [1_799_999_000.5, 1_799_999_002])
        XCTAssertEqual(got.skipped, [.tooLong: 2])
    }

    func testTheRowCapStopsTheReadAndSaysSo() throws {
        let text = (1...5).map { rdLine(["t": "\(1_799_999_000 + $0)"]) }.joined(separator: "\n") + "\n"
        let d = try dir([rdDay: text])
        let capped = CCPoolUsageReader.readNow(directory: d, range: .day, now: rdNow, maxRows: 3)
        XCTAssertEqual(capped.rows.map(\.t), [1_799_999_001, 1_799_999_002, 1_799_999_003])
        XCTAssertTrue(capped.truncated)
        let exact = CCPoolUsageReader.readNow(directory: d, range: .day, now: rdNow, maxRows: 5)
        XCTAssertEqual(exact.rows.count, 5)
        XCTAssertFalse(exact.truncated)
        XCTAssertEqual(CCPoolUsageReader.rowsMax, 500_000)
    }

    func testRowCapCountsBadLinesToo() throws {
        let text = ["bad", "bad", rdLine(), rdLine()].joined(separator: "\n")
        let got = CCPoolUsageReader.readNow(directory: try dir([rdDay: text]), range: .day, now: rdNow, maxRows: 3)
        XCTAssertEqual(got.rows.count, 1)
        XCTAssertEqual(got.skipped, [.notJSON: 2])
        XCTAssertTrue(got.truncated)
    }

    func testASymlinkedDayFileIsNotRead() throws {
        let d = try dir(["usage-2027-01-14.jsonl": rdLine(["t": "1799990000"]) + "\n"])
        let outside = tempDir().appendingPathComponent("elsewhere.jsonl")
        try Data((rdLine() + "\n").utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: d.appendingPathComponent(rdDay), withDestinationURL: outside)
        let got = CCPoolUsageReader.readNow(directory: d, range: .day, now: rdNow)
        XCTAssertEqual(got.rows.map(\.t), [1_799_990_000], "only the regular file")
        XCTAssertEqual(got.filesNotRead, 1)
    }

    func testAPipeWithAnOwnNameDoesNotBlockTheRead() throws {
        let d = try dir()
        let path = d.appendingPathComponent(rdDay).path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        let box = RdBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.v = CCPoolUsageReader.readNow(directory: d, range: .day, now: rdNow)
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 2) == .success
        // A writer at the end, so a reader stuck in open() is released and nothing stays blocked.
        let w = open(path, O_WRONLY | O_NONBLOCK)
        if w >= 0 { close(w) }
        if !finished { _ = done.wait(timeout: .now() + 5) }
        XCTAssertTrue(finished, "readNow returns within 2 s")
        XCTAssertEqual(box.v?.filesNotRead, 1)
        XCTAssertTrue(box.v?.rows.isEmpty ?? false)
    }

    func testOnlyOwnFileNamesAreRead() throws {
        let row = rdLine() + "\n"
        let d = try dir([rdDay + ".bak": row, "usage-2027-01-15.json": row, "._usage-2027-01-15.jsonl": row, "other.jsonl": row,
                         "usage-2027-1-15.jsonl": row])
        try FileManager.default.createDirectory(at: d.appendingPathComponent("usage-2027-01-14.jsonl"), withIntermediateDirectories: false)
        let got = CCPoolUsageReader.readNow(directory: d, range: .day, now: rdNow)
        XCTAssertTrue(got.rows.isEmpty)
        XCTAssertEqual(got.filesNotRead, 1, "the folder with an own name is counted, not read")
    }

    func testOnlyTheDaysTheRangeNeedsAreRead() throws {
        func f(_ day: String, _ t: Int) -> (String, String) { ("usage-\(day).jsonl", rdLine(["t": "\(t)"]) + "\n") }
        // The 13th's file holds a row that would be in range if it were read; the 1st's holds one inside 14 days only by name.
        let d = try dir(Dictionary(uniqueKeysWithValues: [f("2027-01-13", 1_799_999_001), f("2027-01-14", 1_799_913_601),
                                                          f("2027-01-15", 1_799_999_000), f("2027-01-01", 1_798_800_000)]))
        XCTAssertEqual(CCPoolUsageReader.readNow(directory: d, range: .day, now: rdNow).rows.map(\.t), [1_799_913_601, 1_799_999_000],
                       "24 h: the 14th and 15th; the 14th's row older than 24 h is also dropped by time")
        XCTAssertEqual(CCPoolUsageReader.readNow(directory: d, range: .week, now: rdNow).rows.map(\.t),
                       [1_799_913_601, 1_799_999_000, 1_799_999_001])
        XCTAssertEqual(CCPoolUsageReader.readNow(directory: d, range: .fortnight, now: rdNow).rows.map(\.t),
                       [1_798_800_000, 1_799_913_601, 1_799_999_000, 1_799_999_001])
    }

    func testRowsComeBackOldestFirstAndOutOfRangeRowsAreNotSkips() throws {
        let text = [rdLine(["t": "1799999500"]), rdLine(["t": "1799999100"]), rdLine(["t": "1700000000"]), rdLine(["t": "1800000100"])]
            .joined(separator: "\n")
        let got = CCPoolUsageReader.readNow(directory: try dir([rdDay: text]), range: .day, now: rdNow)
        XCTAssertEqual(got.rows.map(\.t), [1_799_999_100, 1_799_999_500])
        XCTAssertEqual(got.skippedTotal, 0)
    }

    func testAMissingFolderReadsAsEmpty() async {
        let got = await CCPoolUsageReader.read(directory: tempDir().appendingPathComponent("nope"), range: .week, now: rdNow)
        XCTAssertEqual(got, CCPoolUsageReadResult())
    }

    func testAsyncReadMatchesTheSyncRead() async throws {
        let d = try dir([rdDay: rdLine() + "\nbad\n"])
        let a = await CCPoolUsageReader.read(directory: d, range: .day, now: rdNow)
        XCTAssertEqual(a, CCPoolUsageReader.readNow(directory: d, range: .day, now: rdNow))
        XCTAssertEqual(a.rows.count, 1)
    }

    // MARK: 1. utilization with the running max

    func testTheWobbleIsPlottedAsItsRunningMax() {
        let r = 1_800_003_600.0
        let rows = [(1.0, 0.34), (2.0, 0.35), (3.0, 0.34), (4.0, 0.35)].map { rdEntry(1_799_999_000 + $0.0, lim: rdClaim($0.1, r)) }
        let s = CCPoolUsageStats.utilization(rows)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.points.map(\.value), [0.34, 0.35, 0.35, 0.35])
        XCTAssertEqual(s.first?.points.map(\.t), [1_799_999_001, 1_799_999_002, 1_799_999_003, 1_799_999_004])
        XCTAssertEqual(s.first?.resets, [])
    }

    func testANewResetStartsTheMaxOverAndGetsAMarker() {
        let rows = [(1.0, 0.8, 1_800_003_600.0), (2.0, 0.9, 1_800_003_600), (3.0, 0.1, 1_800_021_600), (4.0, 0.05, 1_800_021_600),
                    (5.0, 0.2, 1_800_021_600)].map { rdEntry(1_799_999_000 + $0.0, lim: rdClaim($0.1, $0.2)) }
        let s = CCPoolUsageStats.utilization(rows)
        XCTAssertEqual(s.first?.points.map(\.value), [0.8, 0.9, 0.1, 0.1, 0.2])
        XCTAssertEqual(s.first?.resets, [.init(t: 1_799_999_003, reset: 1_800_021_600)])
    }

    func testFiveHourAndSevenDayAndAccountsAreSeparateSeriesQuotaChecksCountAndAnUnplottableRowIsLeftOut() {
        let rows = [
            rdEntry(1_799_999_001, acct: "acct-b", lim: rdClaim(0.4, 1_800_003_600)),
            rdEntry(1_799_999_002, acct: "acct-a", lim: ["five_hour": .init(u: 0.2, r: 1_800_003_600, s: "a"),
                                                         "seven_day": .init(u: 0.6, r: 1_800_500_000, s: "a")]),
            rdEntry(1_799_999_003, acct: "acct-a", qc: true, lim: ["five_hour": .init(u: 0.1, r: 1_800_003_600, s: "a")]),
            rdEntry(1_799_999_004, acct: "acct-a", lim: ["five_hour": .init(u: 0.9, r: nil, s: "w"), "seven_day_opus": .init(u: 0.9, r: 1, s: "a")]),
        ]
        let s = CCPoolUsageStats.utilization(rows)
        XCTAssertEqual(s.map { "\($0.acct)/\($0.window)" }, ["acct-a/five_hour", "acct-a/seven_day", "acct-b/five_hour"])
        XCTAssertEqual(s.first?.points.map(\.value), [0.2, 0.2], "the quota check counts, and its lower 0.1 does not lower the line")
        XCTAssertEqual(s.dropFirst().first?.points.map(\.value), [0.6])
        XCTAssertEqual(s.last?.points.map(\.value), [0.4])
    }

    // MARK: 2. tokens by kind

    func testTokensByAccountModelAndSessionLeaveQuotaChecksOut() {
        let rows = [
            rdEntry(1, acct: "acct-a", model: "m-one", sess: "s-0001", tokens: rdTok(10, 1, 100, 20, 5)),
            rdEntry(2, acct: "acct-a", model: "m-two", sess: "s-0002", tokens: rdTok(1, 2, 3, 4, 5)),
            rdEntry(3, acct: "acct-b", model: "m-one", sess: nil, tokens: rdTok(7, 7, 7, 7, 7)),
            rdEntry(4, acct: "acct-a", model: "m-one", sess: "s-0001", qc: true, tokens: rdTok(99, 99, 99, 99, 99)),
            rdEntry(5, acct: "acct-a", model: "m-one", sess: "s-0001", tokens: nil),
        ]
        func t(_ i: Int, _ cw5: Int, _ cw1: Int, _ cr: Int, _ o: Int, _ n: Int) -> CCPoolUsageTotals {
            CCPoolUsageTotals(input: i, cacheWrite5m: cw5, cacheWrite1h: cw1, cacheRead: cr, output: o, requests: n)
        }
        let a = CCPoolUsageStats.tokens(rows, by: .account)
        XCTAssertEqual(a.map { $0.key }, ["acct-a", "acct-b"])
        XCTAssertEqual(a.map { $0.totals }, [t(11, 24, 10, 103, 3, 2), t(7, 7, 7, 7, 7, 1)])
        let m = CCPoolUsageStats.tokens(rows, by: .model)
        XCTAssertEqual(m.map { $0.key }, ["m-one", "m-two"])
        XCTAssertEqual(m.map { $0.totals }, [t(17, 27, 12, 107, 8, 2), t(1, 4, 5, 3, 2, 1)])
        let s = CCPoolUsageStats.tokens(rows, by: .session)
        XCTAssertEqual(s.map { $0.key }, ["s-0001", "s-0002"], "a row without a session has no bar")
        XCTAssertEqual(s.map { $0.totals }, [t(10, 20, 5, 100, 1, 1), t(1, 4, 5, 3, 2, 1)])
        XCTAssertEqual(a.first?.totals.total, 151)
    }

    // MARK: 3. cache hit rate

    func testCacheHitRatePerSessionWithAMoveMarker() {
        let rows = [
            rdEntry(1, acct: "acct-a", sess: "s-0001", tokens: rdTok(100, 5, 700, 200)),   // 700 / 1000
            rdEntry(2, acct: "acct-a", sess: "s-0001", tokens: rdTok(0, 5, 900, 100)),     // 900 / 1000
            rdEntry(2.5, acct: "acct-b", sess: "s-0001", qc: true, tokens: rdTok(1, 0, 0, 0)),  // quota check on another account: left out
            rdEntry(3, acct: "acct-b", sess: "s-0001", tokens: rdTok(100, 5, 0, 300)),     // moved: 0 / 400
            rdEntry(4, acct: "acct-b", sess: "s-0001", tokens: rdTok(0, 0, 0, 0)),         // empty denominator: no point
            rdEntry(5, acct: "acct-b", sess: "s-0001", tokens: rdTok(50, 5, 150, 0, 0)),   // 150 / 200, same account as before
            rdEntry(6, acct: "acct-a", sess: "s-0002", tokens: rdTok(0, 0, 1, 0, 3)),      // 1 / 4
            rdEntry(7, acct: "acct-a", sess: nil, tokens: rdTok(1, 1, 1, 1)),
            rdEntry(8, acct: "acct-a", sess: "s-0002", tokens: nil),
        ]
        let got = CCPoolUsageStats.cacheHitRate(rows)
        XCTAssertEqual(got.map { $0.sess }, ["s-0001", "s-0002"])
        XCTAssertEqual(got.first?.points.map(\.rate), [0.7, 0.9, 0.0, 0.75])
        XCTAssertEqual(got.first?.points.map(\.moved), [false, false, true, false])
        XCTAssertEqual(got.first?.points.map(\.acct), ["acct-a", "acct-a", "acct-b", "acct-b"])
        XCTAssertEqual(got.last?.points.map(\.rate), [0.25])
        XCTAssertEqual(got.last?.points.map(\.moved), [false])
    }

    // MARK: 4. top sessions

    func testTopSessionsAndTheirAgentsByTotalTokens() {
        let rows = [
            rdEntry(1, acct: "acct-a", sess: "s-0001", agent: "", tokens: rdTok(10, 10, 10, 10, 10)),        // 50
            rdEntry(2, acct: "acct-b", sess: "s-0001", agent: "ag-one", tokens: rdTok(100, 0, 0, 0, 0)),     // 100
            rdEntry(3, acct: "acct-a", sess: "s-0001", agent: "ag-one", tokens: rdTok(0, 5, 0, 0, 0)),       // 5
            rdEntry(4, acct: "acct-a", sess: "s-0002", agent: "", tokens: rdTok(500, 0, 0, 0, 0)),           // 500
            rdEntry(5, acct: "acct-a", sess: "s-0003", agent: "", tokens: rdTok(155, 0, 0, 0, 0)),           // 155 = s-0001
            rdEntry(6, acct: "acct-a", sess: "s-0003", agent: "", qc: true, tokens: rdTok(9999, 0, 0, 0, 0)),
            rdEntry(7, acct: "acct-a", sess: nil, tokens: rdTok(9999, 0, 0, 0, 0)),
        ]
        let top = CCPoolUsageStats.topSessions(rows)
        XCTAssertEqual(top.map(\.sess), ["s-0002", "s-0001", "s-0003"], "500, then 155 and 155 by id")
        XCTAssertEqual(top.map(\.totals.total), [500, 155, 155])
        XCTAssertEqual(top.map(\.totals.requests), [1, 3, 1])
        let first = top.dropFirst().first
        XCTAssertEqual(first?.accounts, ["acct-a", "acct-b"])
        XCTAssertEqual(first?.agents.map { $0.agent }, ["ag-one", ""], "agent ag-one 105 before the main conversation's 50")
        XCTAssertEqual(first?.agents.map { $0.totals.total }, [105, 50])
        XCTAssertEqual(first?.agents.map { $0.totals.requests }, [2, 1])
        XCTAssertEqual(CCPoolUsageStats.topSessions(rows, limit: 2).map(\.sess), ["s-0002", "s-0001"])
        XCTAssertEqual(CCPoolUsageStats.topSessions(rows, limit: 0).count, 0)
    }

    // MARK: 5. time to finish

    func testFinishTimesMedianAndP90PerModelPerDay() {
        let d1 = 1_799_884_800.0 + 100   // 2027-01-14
        let d2 = 1_799_971_200.0 + 100   // 2027-01-15
        var rows = (1...10).map { rdEntry(d1 + Double($0), ms: $0 * 100) }                          // 100...1000
        rows += [100, 200, 300, 400].map { rdEntry(d2, ms: $0) }                                   // even count
        rows += [rdEntry(d2, model: "m-two", ms: 7000)]
        rows += [rdEntry(d1, ms: 99999, qc: true), rdEntry(d1, st: 429, ms: 99999), rdEntry(d1, ms: 99999, done: false)]
        let got = CCPoolUsageStats.finishTimes(rows.shuffled())
        XCTAssertEqual(got, [
            .init(model: "claude-opus-5", day: "2027-01-14", median: 550, p90: 900, count: 10),
            .init(model: "claude-opus-5", day: "2027-01-15", median: 250, p90: 400, count: 4),
            .init(model: "m-two", day: "2027-01-15", median: 7000, p90: 7000, count: 1),
        ])
    }
}

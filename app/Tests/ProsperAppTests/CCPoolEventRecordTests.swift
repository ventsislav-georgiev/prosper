import XCTest
@testable import ProsperApp

// #1666 (#1664 F4a): the event record writer alone (no proxy, no emit sites: those are #1667). Fake labels and tokens.

private let evNow = 1_800_000_000.25
/// evNow's UTC day.
private let evDay = "2027-01-15"

final class CCPoolEventRecordTests: XCTestCase {
    private func row(_ ev: CCPoolEventRow.Kind = .bench, acct: String? = nil, from: String? = nil, to: String? = nil,
                     claim: String? = nil, reset: Int? = nil, sess: String? = nil, t: Double = evNow) -> CCPoolEventRow {
        CCPoolEventRow(t: t, ev: ev, acct: acct, from: from, to: to, claim: claim, reset: reset, sess: sess)
    }

    private func text(_ row: CCPoolEventRow) throws -> String { String(decoding: try XCTUnwrap(row.line()), as: UTF8.self) }

    private func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func sparse(_ url: URL, size: Int) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(size))
        try h.close()
    }

    // MARK: line()

    func testLineKeyOrderAndOmission() throws {
        XCTAssertEqual(try text(row(.bench, acct: "Example Org A", claim: "five_hour", reset: 1_900_000_000, sess: "s-0001")),
                       #"{"v":1,"t":1800000000.250,"ev":"bench","acct":"Example Org A","claim":"five_hour","reset":1900000000,"sess":"s-0001"}"#)
        XCTAssertEqual(try text(row(.rotate, from: "Example Org A", to: "Example Org B")),
                       #"{"v":1,"t":1800000000.250,"ev":"rotate","from":"Example Org A","to":"Example Org B"}"#)
        XCTAssertEqual(try text(row(.allBenched)), #"{"v":1,"t":1800000000.250,"ev":"all-benched"}"#)
        // Every key, in the schema's order.
        XCTAssertEqual(try text(row(.pinBack, acct: "a", from: "b", to: "c", claim: "seven_day", reset: 5, sess: "s")),
                       #"{"v":1,"t":1800000000.250,"ev":"pin-back","acct":"a","from":"b","to":"c","claim":"seven_day","reset":5,"sess":"s"}"#)
    }

    func testEveryEventWordIsFixed() {
        XCTAssertEqual(CCPoolEventRow.Kind.allCases.map(\.rawValue).sorted(),
                       ["all-benched", "bench", "pin-back", "retire", "rotate", "throttle-move"])
    }

    func testClaimAndSessionAreWrittenOnlyWhenValid() throws {
        let line = try text(row(.bench, acct: "a", claim: "Bearer tok-example-1", sess: "s 0001"))
        XCTAssertEqual(line, #"{"v":1,"t":1800000000.250,"ev":"bench","acct":"a"}"#)
        let long = String(repeating: "k", count: CCPoolState.pinKeyMax + 1)
        XCTAssertFalse(try text(row(sess: long)).contains("sess"))
    }

    func testRowTimeIsBelowYear9999() {
        XCTAssertNotNil(row(t: 253402300799).line())
        XCTAssertTrue(row(t: 253402300800).line() == nil)
        XCTAssertTrue(row(t: -1).line() == nil)
        XCTAssertTrue(row(t: .nan).line() == nil)
    }

    func testNoTokenShapedStringOrBodyByteReachesTheLine() throws {
        // The row type has no field for a token, header or body: what a caller puts in a fixed-word slot is dropped.
        let line = try text(row(.rotate, acct: "Example Org A", from: "Example Org A", to: "Example Org B",
                                claim: "tok-example-1 body-byte-example", reset: 1, sess: "client-secret-example\n"))
        for never in ["tok-example", "body-byte-example", "client-secret-example", "Bearer", "sk-"] {
            XCTAssertFalse(line.contains(never), never)
        }
        XCTAssertFalse(line.contains("\n"))
    }

    // MARK: Name rule

    func testNameRuleMatchesOnlyEventsDayFiles() {
        XCTAssertTrue(CCPoolEventRecord.isOwnName("events-2027-01-15.jsonl"))
        for n in ["events-2027-01-15.jsonl.bak", "events-2027-01-15.json", "Events-2027-01-15.jsonl", "events-2027-1-15.jsonl",
                  "xevents-2027-01-15.jsonl", "usage-2027-01-15.jsonl", "events-2027-01-1a.jsonl", "events-2027_01-15.jsonl",
                  "events-2027-01-15.jsonl\n", "events-.jsonl", ""] {
            XCTAssertFalse(CCPoolEventRecord.isOwnName(n), n)
        }
    }

    // MARK: Files

    func testFileModeIs0600AndFolderIs0700() throws {
        let dir = tempDir().appendingPathComponent("events")
        let w = CCPoolEventRecord(directory: dir, logger: ThrottleLog())
        w.add(row(.rotate, from: "a", to: "b"))
        w.flush()
        let file = dir.appendingPathComponent("events-\(evDay).jsonl")
        let d = try FileManager.default.attributesOfItem(atPath: dir.path)
        let f = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((d[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((f[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), try text(row(.rotate, from: "a", to: "b")) + "\n")
    }

    func testSymlinkedNameIsNeverWritten() throws {
        let dir = tempDir().appendingPathComponent("events")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.deletingLastPathComponent().appendingPathComponent("elsewhere.txt")
        try Data("keep\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("events-\(evDay).jsonl"), withDestinationURL: target)
        let log = ThrottleLog()
        let w = CCPoolEventRecord(directory: dir, logger: log)
        w.add(row(.bench, acct: "a", claim: "five_hour"))
        w.stop()
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep\n")
        XCTAssertEqual(log.lines.filter { $0.contains("event record") }, ["-: event record could not be opened; 1 row(s) dropped"])
    }

    func testSixtyFourthRowFlushesWithoutTheTimer() throws {
        let dir = tempDir().appendingPathComponent("events")
        let w = CCPoolEventRecord(directory: dir, logger: ThrottleLog())
        let file = dir.appendingPathComponent("events-\(evDay).jsonl")
        for _ in 0..<(CCPoolEventRecord.flushRows - 1) { w.add(row()) }
        w.settle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "63 rows are still held")
        w.add(row())
        w.settle()
        let n = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").count
        XCTAssertEqual(n, CCPoolEventRecord.flushRows)
    }

    // MARK: Retention and caps

    func testFourteenDayRemovalTouchesOnlyOwnNames() throws {
        let dir = tempDir().appendingPathComponent("events")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let foreign = ["events-2020-01-01.jsonl.bak", "Events-2020-01-01.jsonl", "events-2020-1-1.jsonl", "usage-2020-01-01.jsonl", "notes.txt"]
        for n in foreign + ["events-2026-12-20.jsonl", "events-2027-01-01.jsonl", "events-2027-01-02.jsonl"] {
            try Data("x\n".utf8).write(to: dir.appendingPathComponent(n))
        }
        // A folder that carries an own name is never removed.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("events-2020-01-03.jsonl"), withIntermediateDirectories: false)
        let w = CCPoolEventRecord(directory: dir, logger: ThrottleLog())
        w.add(row())
        w.stop()
        XCTAssertEqual(names(dir), (foreign + ["events-2020-01-03.jsonl", "events-2027-01-02.jsonl", "events-\(evDay).jsonl"]).sorted())
    }

    func testKeepDaysIsTheUsageConstant() {
        XCTAssertEqual(CCPoolEventRecord.keepDays, CCPoolUsageRecord.keepDays)
    }

    func testFolderCapRemovesTheOldestDayFirst() throws {
        let dir = tempDir().appendingPathComponent("events")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Eight days inside the 14 kept, 16 MiB each: the folder is at its cap.
        for d in 7...14 { try sparse(dir.appendingPathComponent(String(format: "events-2027-01-%02d.jsonl", d)), size: 16 << 20) }
        let w = CCPoolEventRecord(directory: dir, logger: ThrottleLog())
        w.add(row())
        w.stop()
        XCTAssertEqual(names(dir), (8...15).map { String(format: "events-2027-01-%02d.jsonl", $0) })
    }

    func testDayCapDropsAndCountsInOneLogLine() throws {
        let dir = tempDir().appendingPathComponent("events")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let line = try XCTUnwrap(row().line())
        let file = dir.appendingPathComponent("events-\(evDay).jsonl")
        // Room for exactly one more row and its newline.
        try sparse(file, size: CCPoolEventRecord.dayMax - line.count - 1)
        let log = ThrottleLog()
        let w = CCPoolEventRecord(directory: dir, logger: log)
        for _ in 0..<3 { w.add(row()) }
        w.stop()
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        XCTAssertEqual(size?.intValue, CCPoolEventRecord.dayMax)
        XCTAssertEqual(log.lines.filter { $0.contains("event record") }, ["-: event record for \(evDay) reached 16 MiB; 2 row(s) dropped"])
    }

    func testRowOverTwoKiBIsNotWritten() throws {
        let dir = tempDir().appendingPathComponent("events")
        let base = try XCTUnwrap(row(acct: "").line()).count
        let fits = row(acct: String(repeating: "a", count: CCPoolEventRecord.rowMax - base))
        let over = row(acct: String(repeating: "b", count: CCPoolEventRecord.rowMax - base + 1))
        XCTAssertEqual(fits.line()?.count, CCPoolEventRecord.rowMax)
        let w = CCPoolEventRecord(directory: dir, logger: ThrottleLog())
        w.add(over)
        w.add(fits)
        w.stop()
        let t = try String(contentsOf: dir.appendingPathComponent("events-\(evDay).jsonl"), encoding: .utf8)
        XCTAssertEqual(t, try text(fits) + "\n")
    }
}

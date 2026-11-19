import AppKit
import XCTest
@testable import ProsperApp

extension XrayGridMarksTests {
    /// #1655: a hop that runs the compute and its apply at once, on main (the rigs' rows read the marks right after).
    nonisolated static func inline(_ work: @escaping @Sendable () -> XrayGridMarksView.Placed,
                                   _ apply: @escaping @MainActor @Sendable (XrayGridMarksView.Placed) -> Void) {
        MainActor.assumeIsolated { apply(work()) }
    }
}

/// #1655: the grid marks' compute off main. The refs are prepared once per refs change, each line's spans are memoized,
/// an ASCII line skips the refs it cannot hold, the compute runs on XrayGridMarksView.queue and a stale result is
/// dropped; every mark stays what the #1559 algorithm (kept below as a reference copy) gave. Counts work, never time.
/// Offscreen: no window, no event, no dch (XrayGridMarksTests' rig and seams).
@MainActor
final class XrayGridMarksMemoTests: XCTestCase {
    typealias Mark = XrayGridMarksView.Mark

    // MARK: - The reference copy (base b6b4399b XrayRefSpans.find and XrayGridMarksView.marks, test-only)

    static func oldFind(_ text: String, _ refs: [XrayRefs.Entry]) -> [XrayRefSpans.Span] {
        let code = XrayRefSpans.codeSpans(text)
        var out: [XrayRefSpans.Span] = []
        for e in refs.filter(\.underline).sorted(by: { $0.text.count > $1.text.count }) where !e.text.isEmpty {
            var from = text.startIndex
            while from < text.endIndex, let r = text.range(of: e.text, range: from..<text.endIndex), !r.isEmpty {
                from = r.upperBound
                guard !XrayRefSpans.word(text[..<r.lowerBound].last), !XrayRefSpans.word(text[r.upperBound...].first),
                      !code.contains(where: { $0.overlaps(r) }), !out.contains(where: { $0.range.overlaps(r) }) else { continue }
                out.append(XrayRefSpans.Span(range: r, key: e.key))
            }
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    static func oldMarks(_ lines: [String], _ refs: [XrayRefs.Entry], rows: Int) -> [Mark] {
        let linked = refs.filter { $0.underline && $0.shape != .url && $0.shape != .file }
        guard !linked.isEmpty, rows > 0 else { return [] }
        return lines.prefix(rows).enumerated().flatMap { row, line in
            oldFind(line, linked).map {
                Mark(row: row, col: XrayRefSpans.cells(line[..<$0.range.lowerBound]), cells: XrayRefSpans.cells(line[$0.range]), key: $0.key)
            }
        }
    }

    // MARK: - The fixture: 2000 fake refs, 60 lines

    static func entry(_ i: Int, _ shape: XrayRefs.Shape?, _ text: String, underline: Bool = true) -> XrayRefs.Entry {
        XrayRefs.Entry(key: "\(shape?.rawValue ?? "x"):\(text)#\(i)", shape: shape, text: text, full: nil, count: 1, lastOffset: nil,
                       defined: false, definitions: 0, title: "", underline: underline, index: i)
    }

    /// Issues #1-#1199 (overlapping prefixes), tickets, wide and accented texts, a Kelvin sign (NFD "K"), a backtick-ish
    /// term, url and file shapes, underline:false and empty texts; 2000 in all.
    static let refs: [XrayRefs.Entry] = {
        var out: [XrayRefs.Entry] = []
        for i in 1..<1200 { out.append(entry(out.count, .issue, "#\(i)", underline: i % 7 != 0)) }
        for i in 1..<400 { out.append(entry(out.count, .ticket, "API-\(i)")) }
        for i in 1..<100 { out.append(entry(out.count, .term, "\u{65E5}\u{672C}-\(i)")) }
        for i in 1..<100 { out.append(entry(out.count, .term, "caf\u{E9}-\(i)")) }
        out.append(entry(out.count, .term, "\u{212A}-7"))   // canonically "K-7"
        out.append(entry(out.count, .term, "KEY_NAME"))
        out.append(entry(out.count, .term, "API-1-2"))
        out.append(entry(out.count, .term, ""))
        out.append(entry(out.count, .url, "https://example.org/acme/7"))
        out.append(entry(out.count, .file, "README.md"))
        while out.count < 2000 { out.append(entry(out.count, .commit, "abc\(out.count)def")) }
        return out
    }()

    /// 60 lines (some repeated) of word edges, code spans, overlaps, wide and decomposed characters.
    static let lines: [String] = {
        let parts = ["fix #12 now, API-7 too", "see #1 and #123.", "`#12` in code, #13 out", "#1234x no, x#5 no, _#6 no",
                     "(#99). [#100]", "\u{65E5}\u{672C}-3 wide \u{4E2D} #44", "cafe\u{301}-5 and caf\u{E9}-6", "K-7 kelvin, K-77",
                     "", "API-1-2 API-1 API-12", "KEY_NAME and KEY_NAMES", "abc1700def abc1701defx", "README.md https://example.org/acme/7",
                     "$ git log --oneline", "#7 #14 #21 underline:false", "e\u{301}#8 mark, \u{212A}-7 sign"]
        var (out, x) = ([String](), 7)
        for i in 0..<60 {
            x = (x * 1_103_515_245 + 12_345) & 0x7FFF_FFFF
            out.append(i % 5 == 4 ? parts[i % parts.count] : parts[x % parts.count] + " #\(x % 1300) API-\(x % 450)")
        }
        return out
    }()

    /// Red if any mark (row, column, cells, key) of the new path differs from the reference copy over the fixture, if one
    /// line's spans differ, or if the fixture is vacuous.
    func testMarksMatchTheReferenceOnTwoThousandRefs() {
        let (refs, lines) = (Self.refs, Self.lines)
        XCTAssertEqual(refs.count, 2000)
        let old = Self.oldMarks(lines, refs, rows: 60)
        XCTAssertGreaterThan(old.count, 60, "the fixture marks many spans")
        XCTAssertTrue(old.contains { $0.key.hasPrefix("term:caf") }, "an accented ref marks")
        XCTAssertEqual(XrayGridMarksView.marks(lines, refs, rows: 60), old)
        XCTAssertEqual(XrayGridMarksView.marks(lines, refs, rows: 17), Self.oldMarks(lines, refs, rows: 17))
        let memo = XrayMarksMemo()
        XCTAssertEqual(memo.marks(lines, refs, version: 1, rows: 60), old, "a cold memo")
        XCTAssertEqual(memo.marks(lines, refs, version: 1, rows: 60), old, "a warm memo")
        let prepared = XrayRefSpans.prepare(refs)
        for line in lines {
            XCTAssertEqual(XrayRefSpans.find(line, prepared), Self.oldFind(line, refs), line)
            XCTAssertEqual(XrayRefSpans.find(line, refs), Self.oldFind(line, refs), line)
        }
    }

    /// Red if the refs are prepared (filtered and sorted) per line or per place instead of once per refs change, or a
    /// refs change keeps the old preparation (the memo keyed on the text alone).
    func testRefsArePreparedOncePerRefsChange() {
        let memo = XrayMarksMemo()
        for _ in 0..<3 { _ = memo.marks(Self.lines, Self.refs, version: 1, rows: 60) }
        XCTAssertEqual(memo.prepares, 1, "60 lines, three places, one preparation")
        var fewer = Self.refs
        fewer[11].underline = false   // "#12"
        let after = memo.marks(Self.lines, fewer, version: 2, rows: 60)
        XCTAssertEqual(memo.prepares, 2)
        XCTAssertEqual(after, Self.oldMarks(Self.lines, fewer, rows: 60), "the new refs, not the memo's old spans")
        XCTAssertFalse(after.contains { $0.key == fewer[11].key })
    }

    /// Red if a second place over unchanged lines scans them again, if a changed line is served from the memo, or if the
    /// memo grows past twice the rows.
    func testUnchangedLinesHitTheMemoAndAChangedOneMisses() throws {
        let g = XrayGridMarksTests()
        try g.withSeams { fake in
            let r = g.rig(g.local)
            r.v.marks.follow = try g.follow(fake, 1, XrayTarget(name: "api", dir: g.local.dir))
            let memo = r.v.marks.memo
            let lines = XrayGridMarksTests.viewport.components(separatedBy: "\n").count   // 4
            XCTAssertEqual(XrayGridMarksTests.keys(r.v), ["issue:#12", "issue:#1"])
            let (m0, h0, p0) = (memo.misses, memo.hits, memo.prepares)
            r.v.marks.place()
            XCTAssertEqual(memo.misses, m0, "unchanged lines are not scanned again")
            XCTAssertEqual(memo.hits, h0 + lines)
            r.v.viewportText = { "$ git log\nfix #12 now, API-7 too\nsee #1 again\n" }
            r.v.marks.place()
            XCTAssertEqual(memo.misses, m0 + 1, "the changed line only")
            XCTAssertEqual(memo.hits, h0 + 2 * lines - 1)
            XCTAssertEqual(XrayGridMarksTests.keys(r.v), ["issue:#12", "issue:#1"])
            XCTAssertEqual(memo.prepares, p0, "the refs did not change")
        }
        let memo = XrayMarksMemo()
        for i in 0..<50 { _ = memo.marks(["line \(i) #12"], Self.refs, version: 1, rows: 3) }
        XCTAssertEqual(memo.misses, 50)
        XCTAssertEqual(memo.hits, 0)
        _ = memo.marks(["line 49 #12"], Self.refs, version: 1, rows: 3)
        XCTAssertEqual(memo.hits, 1, "the newest line is still kept")
        _ = memo.marks(["line 0 #12"], Self.refs, version: 1, rows: 3)
        XCTAssertEqual(memo.hits, 1, "an old line went: the memo holds at most 2 x rows")
    }

    /// Red if the pre-check is gone (every ref scanned on every ASCII line: scans = lines x refs) or skips a ref that
    /// marks (equality with the reference copy here and above).
    func testTheAsciiPreCheckSkipsMostScans() {
        let memo = XrayMarksMemo()
        let ascii = Self.lines.filter { $0.utf8.allSatisfy { $0 < 0x80 } }
        XCTAssertGreaterThan(ascii.count, 20)
        XCTAssertEqual(memo.marks(ascii, Self.refs, version: 1, rows: 60), Self.oldMarks(ascii, Self.refs, rows: 60))
        let prepared = XrayRefSpans.prepare(Self.refs.filter { $0.shape != .url && $0.shape != .file }).refs.count
        XCTAssertGreaterThan(prepared, 1500)
        XCTAssertLessThan(memo.scans, memo.misses * prepared * 3 / 4, "\(memo.scans) scans for \(memo.misses) lines x \(prepared) refs")
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(main: Bool, queue: Bool)] = []
        func note(_ main: Bool, _ queue: Bool) {
            lock.lock()
            seen.append((main, queue))
            lock.unlock()
        }
        var all: [(main: Bool, queue: Bool)] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
    }

    /// Red if the compute runs on main (or off the marks queue), or its result is not applied on main once it is back.
    nonisolated(unsafe) static let key = DispatchSpecificKey<Int>()

    func testTheComputeRunsOnTheMarksQueue() throws {
        let g = XrayGridMarksTests()
        XrayGridMarksView.queue.setSpecific(key: Self.key, value: 1655)
        defer { XrayGridMarksView.queue.setSpecific(key: Self.key, value: nil) }
        try g.withSeams { fake in
            let r = g.rig(g.local)
            r.v.marks.follow = try g.follow(fake, 1, XrayTarget(name: "api", dir: g.local.dir))
            let base = XrayGridMarksView(frame: .zero).hop   // the production hop
            let rec = Recorder()
            let done = expectation(description: "applied")
            r.v.marks.hop = { work, apply in
                base({ rec.note(Thread.isMainThread, DispatchQueue.getSpecific(key: XrayGridMarksMemoTests.key) == 1655); return work() },
                     { p in apply(p); done.fulfill() })
            }
            r.v.viewportText = { "see #1\n" }
            r.v.marks.place()
            XCTAssertEqual(XrayGridMarksTests.keys(r.v), ["issue:#12", "issue:#1"], "nothing applied on main before the hop")
            wait(for: [done], timeout: 10)
            XCTAssertEqual(rec.all.count, 1)
            XCTAssertTrue(rec.all.first.map { !$0.main && $0.queue } == true, "computed on the marks queue: \(rec.all)")
            XCTAssertEqual(r.v.marks.marks, [Mark(row: 0, col: 4, cells: 2, key: "issue:#1")], "applied on main")
        }
    }

    /// Red if a result computed before a newer place, an output or a refs change is applied (it would draw marks for
    /// text or refs the grid no longer has).
    func testAStaleResultIsDropped() throws {
        let g = XrayGridMarksTests()
        try g.withSeams { fake in
            let r = g.rig(g.local)
            r.v.marks.follow = try g.follow(fake, 1, XrayTarget(name: "api", dir: g.local.dir))
            XCTAssertEqual(XrayGridMarksTests.keys(r.v), ["issue:#12", "issue:#1"])
            var kept: [() -> Void] = []
            r.v.marks.hop = { work, apply in kept.append { MainActor.assumeIsolated { apply(work()) } } }
            r.v.viewportText = { "see #1\n" }
            r.v.marks.place()                     // kept[0], older
            r.v.marks.place()                     // kept[1], the newest
            kept.first?()
            XCTAssertEqual(XrayGridMarksTests.keys(r.v), ["issue:#12", "issue:#1"], "an older place's result is dropped")
            kept.last?()
            XCTAssertEqual(r.v.marks.marks, [Mark(row: 0, col: 4, cells: 2, key: "issue:#1")])
            r.v.viewportText = { "  #12 here\n" }
            r.v.marks.place()                     // kept[2]: #12 at column 2
            r.v.marks.output()                    // the text moved on: kept[2] is stale
            XCTAssertTrue(r.v.marks.marks.isEmpty, "output took the moved mark off")
            kept.last?()
            XCTAssertTrue(r.v.marks.marks.isEmpty, "a result from before the output is dropped")
            r.items.last?.perform()               // the settle places: kept[3], #12 at column 2
            fake.send(1, XrayGridMarksTests.refDelta("issue:#12", text: "#12", underline: false))   // places: kept[4]
            XCTAssertEqual(kept.count, 5)
            kept.dropLast().last?()
            XCTAssertTrue(r.v.marks.marks.isEmpty, "a result from before the refs change is dropped")
            kept.last?()
            XCTAssertTrue(r.v.marks.marks.isEmpty, "#12 is no longer underlined")
        }
    }
}

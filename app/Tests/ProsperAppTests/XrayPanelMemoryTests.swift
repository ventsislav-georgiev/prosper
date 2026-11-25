import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1352 (#1346 P4): the X-ray panel's Memory tab and its card. Offscreen only: the card goes through a recorder of the
/// panel's present seam (no popover), the reads through a fake runner (literal NDJSON); no window is shown, no real dch.
@MainActor
final class XrayPanelMemoryTests: XCTestCase {

    nonisolated static let header = #"{"schema":1,"source":"claude","title":null,"partial":false}"#
    nonisolated static let rows = [
        #"{"memory":{"id":"m2","title":"Uses the staging API","note":"from the README","kind":"project","scope":"project","updated":"2026-11-16T09:00:00Z","path":"/Users/example/mem/m2.md","session":"loaded","chapter":null,"body":null}}"#,
        #"{"memory":{"id":"m1","title":"Prefers short replies","note":"said twice","kind":"feedback","scope":"user","updated":"2026-11-16T11:00:00Z","path":"/Users/example/mem/m1.md","session":"wrote","chapter":"f5:100","body":"Keep replies short."}}"#,
        #"{"memory":{"id":"m3","title":"Runs zsh","note":"shell","kind":"user","scope":"user","updated":"2026-11-14T12:00:00Z","path":"/Users/example/mem/m3.md","session":null,"chapter":"f5:200","body":"The user runs zsh.\nSecond line","cut":true}}"#,
        #"{"memory":{"id":"i1","title":"AGENTS.md","note":"load order 1","kind":"instructions","scope":"project","updated":null,"path":"/Users/example/acme/api/AGENTS.md","session":null,"chapter":null,"body":"Run the tests first."}}"#,
        #"{"memory":{"id":"i2","title":"CLAUDE.md","note":"load order 2","kind":"instructions","scope":"user","updated":null,"path":"/Users/example/notes/CLAUDE.md","session":null,"chapter":null,"body":"Be brief."}}"#,
    ]
    nonisolated static let done = #"{"done":true,"count":5,"dropped":0}"#
    nonisolated static var memoryOut: Data { XrayPanelTasksTests.ndjson([header] + rows + [done]) }
    static let now = XrayPanelTasksTests.now
    static let home = "/Users/example", cwd = "/Users/example/acme/api"

    final class Shown { var cards: [CGSize] = []; var views: [AnyView] = [] }

    func panel(memory: Data = XrayPanelMemoryTests.memoryOut, shown: Shown = Shown()) -> XrayPanelModel {
        let p = XrayPanelModel(target: XrayTarget(name: "api", dir: "/tmp/dch-test"), tab: .memory)
        p.now = { Self.now }
        p.home = Self.home
        p.cwd = { Self.cwd }
        p.present = { v, s in shown.views.append(v); shown.cards.append(s) }
        p.apply(tasks: (0, XrayPanelTasksTests.tasksOut), memory: (0, memory))
        return p
    }

    func rows(_ p: XrayPanelModel) -> [XrayMemoryRow] {
        p.shownMemory.flatMap(\.items).map { XrayMemoryRow($0, now: Self.now, home: Self.home, cwd: Self.cwd) }
    }

    func item(_ p: XrayPanelModel, _ id: String) -> XrayMemory.Item? { p.memory?.items.first { $0.id == id } }

    /// Red at TIP: no shownMemory / XrayMemoryRow (the tab drew one faint count line).
    func testGroupsOrderAndCounts() {
        let p = panel()
        XCTAssertEqual(p.tabs, [.tasks, .memory])
        XCTAssertEqual(p.title(.memory), "Memory 5", "every row")
        XCTAssertEqual(p.shownMemory.map { "\($0.title) \($0.items.count)" }, ["This session 2", "Memories 1", "Instructions 2"])
        XCTAssertEqual(p.shownMemory.map { $0.items.map(\.id) }, [["m1", "m2"], ["m3"], ["i1", "i2"]], "this session newest first")
        let none = panel(memory: XrayPanelTasksTests.ndjson([Self.header, Self.rows[2], Self.done]))
        XCTAssertEqual(none.shownMemory.map(\.title), ["Memories"], "empty groups omitted")
    }

    func testRowTexts() {
        let r = rows(panel())
        XCTAssertEqual(r.map(\.title), ["Prefers short replies", "Uses the staging API", "Runs zsh", "AGENTS.md", "CLAUDE.md"])
        XCTAssertEqual(r.map(\.detail), ["feedback \u{00B7} said twice", "project \u{00B7} from the README", "user \u{00B7} shell",
                                         "instructions \u{00B7} AGENTS.md", "instructions \u{00B7} ~/notes/CLAUDE.md"],
                       "an instruction file shows its path: relative to the cwd, else ~")
        XCTAssertEqual(r.map(\.session), ["wrote", "loaded", nil, nil, nil])
        XCTAssertEqual(r.map(\.age), ["1h", "3h", "2d", nil, nil])
        XCTAssertEqual(XrayMemoryRow.shortPath("/opt/example/AGENTS.md", home: Self.home, cwd: Self.cwd), "/opt/example/AGENTS.md")
        XCTAssertEqual(XrayMemoryRow.shortPath("/Users/examples/x.md", home: Self.home, cwd: nil), "/Users/examples/x.md",
                       "a sibling dir is not home")
    }

    /// Red at TIP: no memory card (XrayMemoryCard, openMemoryCard).
    func testCardFieldsNotesAndReadThePrompt() throws {
        let shown = Shown()
        let p = panel(shown: shown)
        let m1 = try XCTUnwrap(item(p, "m1")), m2 = try XCTUnwrap(item(p, "m2")), m3 = try XCTUnwrap(item(p, "m3"))
        XCTAssertEqual(XrayMemoryCard.fields(m3, now: Self.now).map { "\($0.label): \($0.value)" },
                       ["Path: /Users/example/mem/m3.md", "Kind: user", "Scope: user", "Updated: 2 days ago"])
        XCTAssertEqual(XrayMemoryCard.notes(m3), ["cut at 16 KB: see /Users/example/mem/m3.md"])
        XCTAssertEqual(XrayMemoryCard.bodyText(m3), "The user runs zsh.\nSecond line", "plain text, the line break kept")
        XCTAssertEqual(XrayMemoryCard.notes(m2), ["not readable"])
        XCTAssertTrue(XrayMemoryCard.bodyText(m2) == nil)
        XCTAssertEqual(XrayMemoryCard.notes(m1), [])
        XCTAssertTrue(XrayMemoryCard.canRead(m1), "session and chapter")
        XCTAssertFalse(XrayMemoryCard.canRead(m2), "no chapter")
        XCTAssertFalse(XrayMemoryCard.canRead(m3), "no session (a chapter alone is not enough)")
        p.openMemoryCard(m1)
        XCTAssertEqual(shown.cards, [XrayMemoryCard.size], "through the presenter seam")
        XCTAssertEqual(p.memoryCard, m1)
        // The card draws offscreen (a hosting view never put in a shown window).
        for m in [m1, m2, m3] {
            let host = NSHostingView(rootView: XrayMemoryCard(item: m, now: Self.now, readPrompt: nil)
                .frame(width: XrayMemoryCard.size.width, height: XrayMemoryCard.size.height))
            host.frame = CGRect(origin: .zero, size: XrayMemoryCard.size)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
        // "Read the prompt" with no transcript (Terminal mode, remote) and no chapters read: the memory card again with
        // the note (#1472: never nothing), never a jump.
        p.readPrompt(m1)
        XCTAssertEqual(shown.cards, [XrayMemoryCard.size, XrayMemoryCard.size], "the memory card again")
        XCTAssertEqual(p.memoryCard, m1)
        XCTAssertTrue(p.chapterCard == nil, "no chapter to show")
    }

    /// Red at TIP: matches had no memory form; with memory-filter-ignores-body "Second line" finds nothing.
    func testFilterCoversIdTitleNoteKindPathAndBody() {
        let p = panel()
        func ids(_ q: String) -> [String] { p.filter = q; return p.shownMemory.flatMap(\.items).map(\.id) }
        XCTAssertEqual(ids("SECOND LINE"), ["m3"], "the body")
        XCTAssertEqual(ids("staging"), ["m2"], "the title")
        XCTAssertEqual(ids("twice"), ["m1"], "the note")
        XCTAssertEqual(ids("instructions"), ["i1", "i2"], "the kind")
        XCTAssertEqual(ids("acme/api"), ["i1"], "the path")
        XCTAssertEqual(ids("i2"), ["i2"], "the id")
        XCTAssertEqual(ids("nothing like it"), [])
        p.filter = "brief"
        XCTAssertEqual(p.shownMemory.map(\.title), ["Instructions"], "an emptied group goes")
        XCTAssertEqual(ids(""), ["m1", "m2", "m3", "i1", "i2"])
    }

    func testAccessibilityLabels() {
        let p = panel()
        XCTAssertEqual(p.spoken(.memory), "Memory, 5")
        XCTAssertEqual(rows(p).map(\.spoken), [
            "Prefers short replies, feedback, said twice, wrote, 1 hour ago",
            "Uses the staging API, project, from the README, loaded, 3 hours ago",
            "Runs zsh, user, shell, 2 days ago",
            "AGENTS.md, instructions, AGENTS.md",
            "CLAUDE.md, instructions, ~/notes/CLAUDE.md",
        ])
        let host = NSHostingView(rootView: XrayPanelView(panel: p).frame(width: 340, height: 400))
        host.frame = CGRect(x: 0, y: 0, width: 340, height: 400)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    /// The QA r1297 rider: 40 combining marks on one letter are capped at three in the shown body, whether the item came
    /// through the parse or not. Red with marks-uncapped (the card's own cap removed).
    func testFortyCombiningMarksStayInsideTheLine() throws {
        let stack = "a" + String(repeating: "\u{0301}", count: 40) + "b"
        func longestRun(_ s: String) -> Int {
            var run = 0, best = 0
            for u in s.unicodeScalars {
                run = u.properties.generalCategory == .nonspacingMark ? run + 1 : 0
                best = max(best, run)
            }
            return best
        }
        let p = panel()
        var raw = try XCTUnwrap(item(p, "m1"))
        raw.body = "x\n" + stack + "\ny"
        let shown = try XCTUnwrap(XrayMemoryCard.bodyText(raw))
        XCTAssertEqual(longestRun(shown), OutsideText.maxMarks, "capped at three in the display")
        XCTAssertEqual(shown.split(separator: "\n").count, 3, "the lines stay")
        let parsed = XrayMemory.parse(XrayPanelTasksTests.ndjson([Self.header,
            #"{"memory":{"id":"z","title":"t","kind":"user","path":"/Users/example/z.md","body":"a"# + String(repeating: #"\u0301"#, count: 40) + #"b"}}"#,
            Self.done])).items.first?.body
        XCTAssertEqual(parsed.map(longestRun), OutsideText.maxMarks, "and in the parse")
    }

    /// Design 3.4: Memory is read on open, again on a switch to its tab and (#1381) every 30 s while it shows; the fake's
    /// answer never changes, so (#1636) the spacing doubles after one identical answer, 30 then 60 s (XrayQuiet).
    func testMemoryIsReadOnOpenOnTabSwitchAndEveryThirtySeconds() async throws {
        let fake = XrayPanelTasksTests.FakeRun(memory: (0, Self.memoryOut))
        let p = XrayPanelModel(target: XrayTarget(name: "api", dir: "/tmp/dch-test"), tab: .tasks)
        var t = Self.now
        p.now = { t }
        p.paneState = { (true, true) }
        p.read(dch: "/fake/dch", run: fake.run)
        await p.reading?.value
        func memoryReads() -> Int { fake.calls.filter { $0.contains("--memory") }.count }
        XCTAssertEqual(memoryReads(), 1, "the open read")
        p.select(.memory)
        await p.reading?.value
        XCTAssertEqual(memoryReads(), 2, "the switch to Memory")
        XCTAssertEqual(fake.calls.last, ["/fake/dch", "--xray", "api", "--memory", "--json"])
        for s in [30.0, 90, 600] { t = Self.now + s; p.tick(); await p.reading?.value }
        XCTAssertEqual(memoryReads(), 5, "polled at +30, +90 (60 s: identical) and +600 while Memory is shown")
        XCTAssertEqual(fake.calls.count, 6, "and no Tasks read")
        p.select(.tasks)
        await p.reading?.value
        XCTAssertEqual(memoryReads(), 5, "a switch to Tasks reads no memory")
        p.stop()
    }

    /// #1381 (R1352-i1): a switch to Memory while a Tasks read is held gives exactly one Memory read, after it. Red at
    /// TIP: select skipped the read while one was in flight and nothing ran it later.
    func testSwitchDuringAHeldTasksReadReadsMemoryOnceAfterIt() async {
        let clock = XrayPollTests.Clock(), run = XrayPollTests.PollRun()
        let p = XrayPanelModel(target: XrayTarget(name: "api", dir: "/tmp/dch-test"), tab: .tasks)
        p.now = { clock.t }
        p.paneState = { (true, true) }
        p.mtime = { _ in XrayPollTests.base }
        p.read(dch: "/fake/dch", run: run.run)
        await p.reading?.value
        XCTAssertEqual(run.memoryReads, 1, "the open read")
        run.hold = true
        clock.t = XrayPollTests.base + 5
        p.tick()
        for _ in 0..<10_000 where run.held < 1 { await Task.yield() }
        XCTAssertEqual(run.held, 1, "the Tasks poll is held")
        p.select(.memory)
        p.select(.tasks)
        p.select(.memory)
        XCTAssertEqual(run.memoryReads, 1, "nothing while the Tasks read runs")
        run.hold = false
        let r = p.reading
        run.answer()
        await r?.value
        await p.reading?.value
        XCTAssertEqual(run.memoryReads, 2, "one Memory read after it, never two")
        XCTAssertTrue(p.reading == nil)
        XCTAssertEqual(p.tab, .memory)
        XCTAssertEqual(run.calls.last, ["--xray", "api", "--memory", "--json"])
        p.stop()
    }

    /// #1381 (QA r1297): the 16 KB cut is on a Character: a flag (two scalars) or a letter with three marks is kept
    /// whole or dropped whole, and the text stays within 16 KB of UTF-8. Red at TIP (cut on a scalar): half a flag, or
    /// the letter with one of its marks, was kept.
    func testCutKeepsAGraphemeWholeAtTheSixteenKBEdge() {
        let flag = "\u{1F1FA}\u{1F1F8}", marked = "e\u{0301}\u{0302}\u{0303}"
        for g in [flag, marked] {
            let pad = String(repeating: "a", count: XrayMemory.maxBody - 4)   // the edge falls inside g
            let r = XrayMemory.cleanBody(pad + g + "z")
            XCTAssertTrue(r.cut)
            XCTAssertEqual(r.text.utf8.count, pad.utf8.count, "\(g.unicodeScalars.count) scalars: dropped whole")
            XCTAssertTrue(r.text == pad, "no part of the grapheme is kept")
            let fits = String(repeating: "a", count: XrayMemory.maxBody - g.utf8.count)
            let whole = XrayMemory.cleanBody(fits + g + "z")
            XCTAssertTrue(whole.cut)
            XCTAssertEqual(whole.text.utf8.count, XrayMemory.maxBody, "at the edge exactly")
            XCTAssertTrue(whole.text.hasSuffix(g), "kept whole")
            XCTAssertEqual(whole.text.unicodeScalars.count, fits.unicodeScalars.count + g.unicodeScalars.count)
        }
    }

    /// #1945. Red at 5c214a39: the session and age cells fit their own text, so "wrote" and "loaded" started at different x.
    func testSessionAndAgeColumnsLineUp() throws {
        let r = rows(panel())
        let a = try XCTUnwrap(r.first), b = try XCTUnwrap(r.dropFirst().first), c = try XCTUnwrap(r.dropFirst(2).first)
        XCTAssertEqual([a.session, b.session, c.session], ["wrote", "loaded", nil])
        let (sw, aw) = (XrayCol.widest(r.map(\.session)), XrayCol.widest(r.map(\.age)))
        XCTAssertEqual(sw, "loaded")
        func f(_ row: XrayMemoryRow, _ fit: Bool) -> [String: CGRect] {
            let v = XrayMemoryRowView(row: row, sessionWidest: fit ? sw : nil, ageWidest: fit ? aw : nil, open: {})
            return XrayPanelTasksTests().frames(v.padding(sz(10)).frame(width: 420), size: CGSize(width: 420, height: 80),
                                                kinds: ["xrayStatus", "xrayAge"])
        }
        let (fa, fb) = (f(a, true), f(b, true))
        XCTAssertTrue(fa["xrayStatus"] != nil && fb["xrayStatus"] != nil && fa["xrayAge"] != nil, "drawn")
        XCTAssertEqual(fa["xrayStatus"]?.minX ?? -1, fb["xrayStatus"]?.minX ?? -2, accuracy: 0.5, "session starts at one x")
        XCTAssertEqual(f(c, true)["xrayAge"]?.maxX ?? -1, fa["xrayAge"]?.maxX ?? -2, accuracy: 0.5, "age ends at one x")
        XCTAssertGreaterThan(abs((f(a, false)["xrayStatus"]?.minX ?? 0) - (f(b, false)["xrayStatus"]?.minX ?? 0)), 1, "control: drifts")
    }
}

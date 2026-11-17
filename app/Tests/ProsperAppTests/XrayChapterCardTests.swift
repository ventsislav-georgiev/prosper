import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1472: X-ray in Terminal mode (no transcript to jump in): a Prompts or Responses row (a click, or Return: the row's
/// Button action, XrayPromptRowView) and the memory card's "Read the prompt" open the chapter card through the window's
/// presenter (FakeCardPresenter: hosts offscreen, never shown); a ref link in that card opens the ref card; the panel's
/// cwd is dch's. Literal JSON, fake runners, no dch, no window shown, no key posted.
@MainActor
final class XrayChapterCardTests: XCTestCase {
    static let cwd = "/Users/example/acme/api"

    /// A memory written at chapter 3 (anchor f3a41c:200 in XrayChaptersTests.json) and one at an anchor dch did not list.
    nonisolated static let memory: Data = XrayPanelTasksTests.ndjson([XrayPanelMemoryTests.header,
        #"{"memory":{"id":"m1","title":"Rerun after a fix","kind":"feedback","path":"/Users/example/mem/m1.md","session":"wrote","chapter":"f3a41c:200","body":"b"}}"#,
        #"{"memory":{"id":"m2","title":"Older one","kind":"feedback","path":"/Users/example/mem/m2.md","session":"wrote","chapter":"f3a41c:900","body":"b"}}"#,
        #"{"done":true,"count":2,"dropped":0}"#])

    /// A Terminal-mode pane on a local session whose dch row says `cwd`, its X-ray panel opened through the window
    /// (wired: presenter, transcript, cwd), then dch's chapters applied; `body` runs with the panel and the presenter.
    func withTerminalPanel(_ body: (XrayPanelModel, FakeCardPresenter) async throws -> Void) async throws {
        let saved = Preferences.agentWindowTranscriptSessions
        defer { Preferences.agentWindowTranscriptSessions = saved }
        let key = AgentSessionKey(dir: "/tmp/dch-test", name: "api")
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        var s = AgentSession(key: key, alias: "", activity: AgentWindowD1Tests.now - 60, state: .idle, agents: 0, version: "1.78.0")
        s.cwd = Self.cwd
        store.sessions = [s]
        let m = AgentWindowModel(lastLive: AgentLastLiveHome(), layouts: nil)
        m.now = { AgentWindowD1Tests.now }
        m.openSession = { _ in }
        m.resume = { _ in }
        m.onVisible = { _ in }
        m.ageInterval = 3600
        m.onNewRuntime = { r in
            r.transcript.offMain = { $0() }
            r.transcript.makeWatch = { _, _ in NSObject() }
            r.transcript.tickInterval = 3600
        }
        m.runtimes.values.forEach(m.onNewRuntime)
        final class Spawns { var count = 0 }
        let spawns = Spawns()
        m.terminal.request = { AgentTerminalSpawn.local($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { _, _ in spawns.count += 1; return AgentTerminalTests.FakeChild() }
        m.bind(store)
        m.setVisible(true)
        m.select(.live(key))
        defer { m.close() }
        let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        win.model = m
        let cards = FakeCardPresenter()
        win.cards = cards
        let (dch, run, model, window) = (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.window)
        defer { (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.window) = (dch, run, model, window); XrayPanels.shared.open = [:] }
        XrayPanels.dch = XrayPanelTasksTests.gate([1, 78, 0])
        XrayPanels.run = XrayPanelTasksTests.FakeRun().run
        XrayPanels.model = { [weak m] _ in m }
        XrayPanels.window = { [weak win] _ in win }
        XCTAssertEqual(m.paneMode, .terminal)
        XCTAssertTrue(win.toggleXray())
        let p = try XCTUnwrap(XrayPanels.shared.open[m.layout.focused])
        await p.reading?.value
        XCTAssertTrue(p.transcript() == nil, "Terminal mode: no transcript")
        p.apply(tasks: XrayChaptersTests.ok, memory: (0, Self.memory), chapters: XrayChaptersTests.chapters)
        XCTAssertEqual(p.tabs, [.prompts, .responses, .tasks, .memory], "dch's chapters")
        try await body(p, cards)
        XCTAssertEqual(spawns.count, 0, "no terminal spawned")
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// Red at base: activate(chapter) returned at `guard let tm = transcript() else { return }` (XrayPanel.swift:515):
    /// no card. Red with click-noop and card-no-response.
    func testTerminalModeRowClickPresentsThePromptAndItsResponse() async throws {
        try await withTerminalPanel { p, cards in
            let c = try XCTUnwrap(p.shownPrompts.first { $0.ordinal == 1 })
            p.activate(c)   // a click, and Return: XrayPromptRowView's Button runs this same action
            XCTAssertEqual(cards.presents, 1, "the card through the window's presenter")
            XCTAssertEqual(cards.size, XrayChapterCard.size)
            XCTAssertEqual(p.chapterCard, c)
            let text = XrayChapterCard.text(c)
            XCTAssertTrue(text.contains("Fix the login test"), text)
            XCTAssertTrue(text.contains("Done: login fixed"), text)
            XCTAssertTrue(text.contains("Tools: Bash 1"), text)
            // A Responses row: the same card for its chapter.
            let r = try XCTUnwrap(p.shownResponses.first { $0.ordinal == 3 })
            p.activate(r)
            XCTAssertEqual(cards.presents, 2)
            XCTAssertEqual(p.chapterCard, r)
            XCTAssertEqual(XrayChapterCard.response(r), "Rerunning")
            XCTAssertTrue(XrayChapterCard.text(r).contains("Please rerun the api suite"))
            XCTAssertTrue(XrayChapterCard.heading(r).hasSuffix("Prompt 3"), "after the peer's mark")
            // A prompt with no response yet says so.
            let none = try XCTUnwrap(p.chapters.first { $0.ordinal == 5 })
            p.activate(none)
            XCTAssertEqual(cards.presents, 3)
            XCTAssertTrue(XrayChapterCard.response(none) == nil)
            XCTAssertTrue(XrayChapterCard.text(none).hasSuffix("Response\n" + XrayChapterCard.noResponse))
        }
    }

    /// Red at base: readPrompt went through go(), whose card(false) its closure ignored: nothing at all. Red with
    /// click-noop (the card is not the chapter's) only through chapterCard.
    func testTerminalModeReadThePromptPresentsTheCard() async throws {
        try await withTerminalPanel { p, cards in
            let m1 = try XCTUnwrap(p.memory?.items.first { $0.id == "m1" })
            let m2 = try XCTUnwrap(p.memory?.items.first { $0.id == "m2" })
            p.openMemoryCard(m1)
            XCTAssertEqual(cards.presents, 1)
            p.readPrompt(m1)
            XCTAssertEqual(cards.presents, 2, "the chapter card replaces the memory card")
            XCTAssertEqual(p.chapterCard?.ordinal, 3, "the chapter the anchor names")
            XCTAssertTrue(XrayChapterCard.text(try XCTUnwrap(p.chapterCard)).contains("Rerunning"))
            p.readPrompt(m2)
            XCTAssertEqual(cards.presents, 3, "a prompt dch did not list: the memory card again, never nothing")
            XCTAssertEqual(cards.size, XrayMemoryCard.size)
            XCTAssertEqual(p.memoryCard, m2)
            XCTAssertEqual(p.chapterCard?.ordinal, 3, "no new chapter card")
        }
    }

    /// Red at base: m.cwd was the transcript model's alone (XrayPanel.swift:114), nil in Terminal mode. Red with
    /// cwd-nil-terminal.
    func testTerminalModeCwdIsDchs() async throws {
        try await withTerminalPanel { p, _ in
            XCTAssertEqual(p.cwd(), Self.cwd, "the session's cwd from dch's list")
            XCTAssertTrue(XrayPanels.cwd(UUID(), XrayTarget(name: "web", dir: "/tmp/dch-test")) == nil,
                          "never the cwd of a row other than the panel's")
        }
    }

    func testAnchorsFollowTheParse() {
        XCTAssertEqual(XrayPanelModel.anchors(XrayChaptersTests.chapters.out)["f3a41c:200"], 3)
        XCTAssertEqual(XrayPanelModel.anchors(XrayChaptersTests.chapters.out).count, 6)
        XCTAssertEqual(XrayPanelModel.anchors(Data(#"{"schema":2,"chapters":[{"anchor":"f1:0","i":1}]}"#.utf8)), [:], "schema 1 only")
        XCTAssertEqual(XrayPanelModel.anchors(Data(#"{"schema":1,"chapters":[{"anchor":"f1:0","i":-4},{"anchor":"f1:9"}]}"#.utf8)),
                       ["f1:0": 1, "f1:9": 2], "a bad or missing i: the place in the list, as XrayChapters.parse")
        XCTAssertEqual(XrayPanelModel.anchors(Data("not json".utf8)), [:])
    }

    /// A ref in the card's response (gate B on) is a prosper-xray link; following it through the card's handler opens
    /// the ref card once. A Terminal-mode panel: no transcript. Red at base: no chapter card, no openLink.
    func testARefLinkInTheCardOpensTheRefCard() async throws {
        let refs = try XrayRefLinkFixture.parsed()
        let run = XrayRefRunTests.Run()
        let cards = XrayRefPopoverTests.Cards()
        let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .prompts)
        (p.dch, p.run, p.refs, p.panels) = ("/fake/dch", run.run, refs, XrayPanels())
        p.presentRef = { cards.present($0, $1, $2) }
        p.dismiss = { cards.close() }
        XCTAssertTrue(p.transcript() == nil)
        var c = TranscriptOutline.Chapter(id: 0, ordinal: 1, title: "Look at the login bug", kind: .prompt, hasError: false)
        c.response = "Fixed in #12, see the notes"
        let answer = try XCTUnwrap(XrayChapterCard.response(c))
        let a = try XCTUnwrap(XrayRefLinkFixture.gateOn {
            XrayRefSpans.attributed(answer, markdown: false, refs: refs.entries, color: .blue)
        })
        let url = try XCTUnwrap(XrayRefLinkFixture.links(a).first)
        XCTAssertEqual(p.openLink(url), .handled)
        XCTAssertEqual(cards.views.count, 1)
        XCTAssertEqual(cards.sizes.first, XrayRefPopover.size)
        XCTAssertEqual(p.refCard?.key, "issue:#12")
        XCTAssertEqual(p.openLink(try XCTUnwrap(URL(string: "file:///Users/example/notes.md"))), .discarded)
        XCTAssertEqual(cards.views.count, 1, "no second card")
        cards.close()
        await p.panels?.refReading?.value
        // The card itself draws offscreen, with the gate on and off (a hosting view never put in a window).
        for on in [true, false] {
            let old = XrayRefLink.decorate
            XrayRefLink.decorate = { on }
            defer { XrayRefLink.decorate = old }
            let host = NSHostingView(rootView: XrayChapterCard(chapter: c, refs: refs.entries, link: { p.openLink($0) })
                .frame(width: XrayChapterCard.size.width, height: XrayChapterCard.size.height))
            host.frame = CGRect(origin: .zero, size: XrayChapterCard.size)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
        }
    }

    // MARK: #1472 b, the --chapter read

    /// A fake dch for the --chapter read: records argv; an anchor "f9:1" holds until cancelled (bounded 5 s) and then
    /// records the SIGTERM the product runner would send. Never a real dch.
    final class ChapterRun: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        private var _sigterms = 0
        var answer: (status: Int32, out: Data) = (0, Data())
        var calls: [[String]] { lock.withLock { _calls } }
        var sigterms: Int { lock.withLock { _sigterms } }
        var run: XrayPanels.Run {
            { [self] _, args, _ in
                lock.withLock { _calls.append(args) }
                if args.contains("f9:1") {
                    let end = Date().addingTimeInterval(5)
                    while !Task.isCancelled, Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
                    if Task.isCancelled { lock.withLock { _sigterms += 1 } }
                }
                return lock.withLock { answer }
            }
        }
    }

    static let anchor = "f3a41c:200"

    /// dch's --chapter object: the user entry, tool and output entries, an interim and a final assistant entry.
    static func object(user: String = "Please rerun the api suite\nand then the web one", tool: String = "npm test",
                       output: String = "ran 42 tests", interim: String = "Running now", answer: String = "All green") -> Data {
        let o: [String: Any] = ["schema": 1, "session": "api", "anchor": anchor, "title": "Please rerun", "kind": "prompt",
                                "truncated": false, "entries": [
                                    ["role": "user", "text": user, "offset": 200],
                                    ["role": "assistant", "text": interim, "offset": 300],
                                    ["role": "tool", "tool": "Bash", "text": tool, "offset": 400],
                                    ["role": "output", "text": output, "error": false, "offset": 500],
                                    ["role": "assistant", "text": answer, "offset": 600]] as [[String: Any]]]
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }

    /// The chapter as dch's chapters gave it (title and capped response).
    static var rerun: TranscriptOutline.Chapter {
        var c = TranscriptOutline.Chapter(id: 0, ordinal: 3, title: "Please rerun", kind: .prompt, hasError: false)
        c.response = "Rerunning"
        return c
    }

    /// A bare Terminal-mode panel (no transcript) with the fake runner and a presenter that captures the card.
    func panel(_ run: ChapterRun, anchors: [String: Int] = [XrayChapterCardTests.anchor: 3]) -> (XrayPanelModel, XrayRefPopoverTests.Cards) {
        let cards = XrayRefPopoverTests.Cards()
        let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .prompts)
        (p.dch, p.run, p.chapterAnchors) = ("/fake/dch", run.run, anchors)
        p.presentRef = { cards.present($0, $1, $2) }
        p.dismiss = { cards.close() }
        XCTAssertTrue(p.transcript() == nil)
        return (p, cards)
    }

    /// Red at base: openChapterCard ran no read (XrayPanel.swift:609 `present(...)` alone): no call, no full text.
    /// Red with shows-tool-entries.
    func testTheReadShowsTheWholePromptAndTheLastAnswer() async throws {
        let run = ChapterRun()
        run.answer = (0, Self.object())
        let (p, cards) = panel(run)
        let c = Self.rerun
        p.openChapterCard(c)
        XCTAssertEqual(cards.views.count, 1, "the card at once, through the presenter")
        XCTAssertEqual(cards.sizes.first, XrayChapterCard.size)
        let read = try XCTUnwrap(p.chapterRead)
        await read.reading?.value
        XCTAssertEqual(run.calls, [["--xray", "api", "--chapter", Self.anchor, "--json"]], "one read, for the chapter's anchor")
        let full = try XCTUnwrap(read.full)
        XCTAssertEqual(full.prompt, "Please rerun the api suite\nand then the web one", "the whole prompt, its line kept")
        XCTAssertEqual(full.response, "All green", "the last assistant entry")
        XCTAssertFalse(full.promptCut || full.responseCut)
        XCTAssertTrue(read.note == nil)
        let text = XrayChapterCard.text(c, full: full, note: read.note)
        XCTAssertTrue(text.contains("and then the web one"), text)
        XCTAssertTrue(text.contains("All green"), text)
        for hidden in ["Running now", "npm test", "ran 42 tests", "Rerunning", XrayChapterRead.cutNote] {
            XCTAssertFalse(text.contains(hidden), "not shown: " + hidden)
        }
        // The card draws offscreen with the read in hand (a hosting view never put in a window).
        let host = NSHostingView(rootView: XrayChapterCard(chapter: c, read: read)
            .frame(width: XrayChapterCard.size.width, height: XrayChapterCard.size.height))
        host.frame = CGRect(origin: .zero, size: XrayChapterCard.size)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        cards.close()
    }

    /// Red at base: no read to cancel (no call at all). Red with no-cancel-on-close: the read runs its 5 s, no SIGTERM.
    func testClosingTheCardCancelsTheRead() async throws {
        let run = ChapterRun()
        run.answer = (0, Self.object())
        let (p, cards) = panel(run, anchors: ["f9:1": 3])
        p.openChapterCard(Self.rerun)
        let read = try XCTUnwrap(p.chapterRead)
        let task = try XCTUnwrap(read.reading)
        let end = Date().addingTimeInterval(5)
        while run.calls.isEmpty, Date() < end { try await Task.sleep(nanoseconds: 1_000_000) }   // the read started
        cards.close()
        await task.value
        XCTAssertEqual(run.sigterms, 1, "the close cancelled the read (the product runner SIGTERMs dch)")
        XCTAssertTrue(read.full == nil && read.note == nil, "a cancelled answer is not news")
    }

    /// Red at base: no read, so no note. Each exit's note; the capped text stays.
    func testEachExitSaysWhyAndKeepsTheCappedText() async throws {
        let toolsOnly = Data(#"{"schema":1,"entries":[{"role":"tool","text":"ls"},{"role":"output","text":"a"}]}"#.utf8)
        let cases: [(Int32, Data, String)] = [(1, Data(), XrayChapterRead.gone), (2, Data(), XrayChapterRead.badAnchor),
                                              (0, Data("not json".utf8), XrayChapterRead.nothing),
                                              (0, Data(#"{"schema":2,"entries":[{"role":"user","text":"x"}]}"#.utf8), XrayChapterRead.nothing),
                                              (0, toolsOnly, XrayChapterRead.nothing), (5, Data(), XrayChapterRead.failed)]
        for (status, out, note) in cases {
            let run = ChapterRun()
            run.answer = (status, out)
            let (p, cards) = panel(run)
            let c = Self.rerun
            p.openChapterCard(c)
            let read = try XCTUnwrap(p.chapterRead)
            await read.reading?.value
            XCTAssertEqual(read.note, note, "exit \(status)")
            XCTAssertTrue(read.full == nil)
            let text = XrayChapterCard.text(c, full: read.full, note: read.note)
            XCTAssertTrue(text.contains("Please rerun") && text.contains("Rerunning") && text.hasSuffix(note), text)
            cards.close()
        }
        XCTAssertTrue(XrayChapterRead.parse(Data(count: XrayChapterRead.maxBytes + 1)) == nil, "over the cap: nothing to read")
    }

    /// Red with read-without-anchor. No anchor for the chapter, or one that is not dch's shape: the card, no read.
    func testNoReadWithoutAnAnchor() async throws {
        for anchors in [[:], ["f1:0": 1], ["-f3:200": 3], ["f3 200": 3]] as [[String: Int]] {
            let run = ChapterRun()
            run.answer = (0, Self.object())
            let (p, cards) = panel(run, anchors: anchors)
            p.openChapterCard(Self.rerun)
            XCTAssertEqual(cards.views.count, 1, "the card still opens")
            XCTAssertTrue(p.chapterRead?.reading == nil, "\(anchors)")
            XCTAssertEqual(run.calls.count, 0)
            cards.close()
        }
    }

    /// A text at dch's 6000-scalar cap says so; one under it does not; a longer one is cut here too.
    func testACutTextSaysSo() throws {
        let long = String(repeating: "a", count: XrayChapterRead.entryCap + 10)
        let full = try XCTUnwrap(XrayChapterRead.parse(Self.object(user: long)))
        XCTAssertEqual(full.prompt?.unicodeScalars.count, XrayChapterRead.entryCap)
        XCTAssertTrue(full.promptCut)
        XCTAssertFalse(full.responseCut)
        let text = XrayChapterCard.text(Self.rerun, full: full)
        XCTAssertTrue(text.contains(XrayChapterRead.cutNote))
        XCTAssertEqual(text.components(separatedBy: XrayChapterRead.cutNote).count, 2, "once, after the prompt")
    }

    /// QA r1433 s1: U+202E, U+0007 and 40 combining marks in the title, peer, tools and response, and in the read's
    /// user and assistant text: the card's text holds no unseen scalar (its line breaks aside) and no base carries more
    /// than OutsideText.maxMarks marks. Red with card-response-raw.
    func testOutsideTextIsCleanedEverywhereInTheCard() throws {
        let bad = "x\u{202E}y\u{0007}z w" + String(repeating: "\u{0301}", count: 40) + "v"
        var c = TranscriptOutline.Chapter(id: 0, ordinal: 3, title: "Rerun " + bad, kind: .prompt, hasError: false)
        c.peer = "peer" + bad
        c.tools = "Bash 1 " + bad
        c.response = "Done " + bad + "\nline two " + bad
        let full = try XCTUnwrap(XrayChapterRead.parse(Self.object(user: "Prompt " + bad + "\nmore " + bad, answer: "Answer " + bad)))
        for text in [XrayChapterCard.text(c), XrayChapterCard.text(c, full: full)] {
            XCTAssertFalse(text.unicodeScalars.contains { $0 != "\n" && OutsideText.isUnseen($0) }, text)
            var marks = 0, most = 0
            for u in text.unicodeScalars {
                marks = u.properties.generalCategory == .nonspacingMark ? marks + 1 : 0
                most = max(most, marks)
            }
            XCTAssertLessThanOrEqual(most, OutsideText.maxMarks, "marks capped")
            XCTAssertTrue(text.contains("xyz"), "the visible text stays")
        }
        XCTAssertTrue(XrayChapterCard.text(c, full: full).contains("Answer xyz"))
        XCTAssertTrue(XrayChapterCard.text(c, full: full).contains("Prompt xyz"))
    }

    // MARK: #1487 dch #451 (1.93.0): head + tail, keyed on `cut` / `response_cut_chars`

    static let ellipsis = "\u{2026}"
    static func marker(_ n: Int) -> String { "\n\(ellipsis) \(n) characters cut \(ellipsis)\n" }
    static func cutLine(_ n: Int) -> String { "\(ellipsis) \(n) characters cut \(ellipsis)" }

    /// A --chapter object whose user entry is `user` with `cut` (any JSON value; nil: no key), a final answer likewise.
    static func cutObject(user: String, cut: Any? = nil, answer: String = "All green", answerCut: Any? = nil) -> Data {
        var u: [String: Any] = ["role": "user", "text": user], a: [String: Any] = ["role": "assistant", "text": answer]
        if let cut { u["cut"] = cut }
        if let answerCut { a["cut"] = answerCut }
        let o: [String: Any] = ["schema": 1, "entries": [u, a] as [[String: Any]]]
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }

    /// Red at base: no `cut` read; the 6000+ scalars say "cut at 6000 characters" and the marker line shows as text.
    /// Red with marker-drawn-literally.
    func testACutEntryDrawsHeadNoteTailAndNoLiteralMarker() throws {
        let head = String(repeating: "h", count: 3000), tail = String(repeating: "t", count: 3000)
        for who in ["user", "assistant"] {
            let text = head + Self.marker(1234) + tail
            let data = who == "user" ? Self.cutObject(user: text, cut: 1234) : Self.cutObject(user: "q", answer: text, answerCut: 1234)
            let full = try XCTUnwrap(XrayChapterRead.parse(data, cutFields: true))
            let lines = XrayChapterCard.text(Self.rerun, full: full).components(separatedBy: "\n")
            let h = lines.firstIndex(of: head), n = lines.firstIndex(of: Self.cutLine(1234)), t = lines.firstIndex(of: tail)
            XCTAssertTrue(h != nil && n != nil && t != nil, who)
            XCTAssertTrue((h ?? 9) + 1 == (n ?? 0) && (n ?? 0) + 1 == (t ?? 0), "head, note, tail in a row: " + who)
            XCTAssertFalse(lines.contains(XrayChapterRead.cutNote), "no 6000 note")
            XCTAssertEqual(lines.filter { $0.contains("characters cut") }.count, 1, "the marker line is the note, not drawn twice")
        }
    }

    /// Red with length-rule-on-new-dch: 7000 scalars and no `cut` on 1.93.0: no note, whatever the length.
    func testAnUncutLongEntryOnNewDchHasNoNote() throws {
        let long = String(repeating: "a", count: 7000)
        let full = try XCTUnwrap(XrayChapterRead.parse(Self.cutObject(user: long), cutFields: true))
        XCTAssertFalse(full.promptCut)
        XCTAssertTrue(full.promptCutChars == nil && full.promptTail == nil)
        let text = XrayChapterCard.text(Self.rerun, full: full)
        XCTAssertFalse(text.contains("characters cut") || text.contains(XrayChapterRead.cutNote), "no note")
    }

    /// The same on 1.92.0 keeps today's note.
    func testTheSameOnOldDchKeepsTheLengthRule() throws {
        let long = String(repeating: "a", count: 7000)
        let full = try XCTUnwrap(XrayChapterRead.parse(Self.cutObject(user: long), cutFields: false))
        XCTAssertTrue(full.promptCut)
        XCTAssertTrue(XrayChapterCard.text(Self.rerun, full: full).contains(XrayChapterRead.cutNote))
        let withCut = try XCTUnwrap(XrayChapterRead.parse(Self.cutObject(user: "x", cut: 5), cutFields: false))
        XCTAssertTrue(withCut.promptCutChars == nil, "the old host's rule ignores a `cut` key")
    }

    /// `cut` present, no marker line in the text: the text as is, the note at its end.
    func testCutWithoutAMarkerShowsTheTextAndTheNoteAtItsEnd() throws {
        let full = try XCTUnwrap(XrayChapterRead.parse(Self.cutObject(user: "a plain text", cut: 77), cutFields: true))
        XCTAssertEqual(full.prompt, "a plain text")
        XCTAssertTrue(full.promptTail == nil)
        XCTAssertEqual(full.promptCutChars, 77)
        let text = XrayChapterCard.text(Self.rerun, full: full)
        XCTAssertTrue(text.contains("a plain text\n" + Self.cutLine(77) + "\n"), text)
        // a marker for another count is not this entry's marker
        let other = try XCTUnwrap(XrayChapterRead.parse(Self.cutObject(user: "a" + Self.marker(5) + "b", cut: 77), cutFields: true))
        XCTAssertTrue(other.promptTail == nil)
    }

    static let chaptersJSON = #"{"schema":1,"chapters":[{"anchor":"f3a41c:200","i":3,"title":"Please rerun","kind":"prompt","response":"Head 999 part\n\#(ellipsis)\ntail part","response_cut":true__EXTRA__}]}"#

    func chapter(_ extra: String) throws -> TranscriptOutline.Chapter {
        let json = Self.chaptersJSON.replacingOccurrences(of: "__EXTRA__", with: extra)
        return try XCTUnwrap(XrayChapters.parse(Data(json.utf8))?.first)
    }

    /// Red at base: nothing reads response_cut_chars; the "..." line is plain text. Red with count-from-text.
    func testTheResponseCutLineShowsTheCountFromTheField() throws {
        let c = try chapter(#","response_cut_chars":4096"#)
        XCTAssertEqual(c.responseCutChars, 4096)
        let lines = XrayChapterCard.text(c).components(separatedBy: "\n")
        let i = lines.firstIndex(of: "Head 999 part")
        XCTAssertTrue(i != nil && lines.count > (i ?? 0) + 2)
        XCTAssertEqual(lines.dropFirst((i ?? 0) + 1).prefix(2).map { $0 }, [Self.cutLine(4096), "tail part"])
        XCTAssertFalse(lines.contains(Self.ellipsis), "the bare joiner line is not drawn")
        // a count in the text is never read
        var t = c
        t.responseCutChars = nil
        t.response = "Head 999 characters cut\n\(Self.ellipsis)\ntail"
        XCTAssertFalse(XrayChapterCard.text(t).contains("999 characters cut \(Self.ellipsis)"))
    }

    /// An older host: `response_cut` true without the count: today's text.
    func testResponseCutWithoutTheCountIsTodaysText() throws {
        let c = try chapter("")
        XCTAssertTrue(c.responseCutChars == nil)
        XCTAssertEqual(XrayChapterCard.response(c), "Head 999 part\n\(Self.ellipsis)\ntail part")
        XCTAssertFalse(XrayChapterCard.text(c).contains("characters cut"))
    }

    /// Red with outside-count-unchecked: 0, -1, 1e12, "12", true (and 10_000_001, 1.5) are ignored: no note.
    func testABadCountIsIgnored() throws {
        let bads: [Any] = [0, -1, 1e12, "12", true, false, 10_000_001, 1.5, [1], ["n": 1]]
        for bad in bads {
            let full = try XCTUnwrap(XrayChapterRead.parse(Self.cutObject(user: "a" + Self.marker(12) + "b", cut: bad, answerCut: bad), cutFields: true))
            XCTAssertTrue(full.promptCutChars == nil && full.responseCutChars == nil && full.promptTail == nil, "\(bad)")
            XCTAssertEqual(XrayChapterCard.text(Self.rerun, full: full).components(separatedBy: "characters cut").count, 2, "only the text's own line, no note: \(bad)")
            let raw = String(data: (try? JSONSerialization.data(withJSONObject: [bad])) ?? Data(), encoding: .utf8) ?? "[0]"
            let json = Self.chaptersJSON.replacingOccurrences(of: "__EXTRA__", with: ",\"response_cut_chars\":" + raw.dropFirst().dropLast())
            XCTAssertTrue(XrayChapters.parse(Data(json.utf8))?.first?.responseCutChars == nil, "response \(bad)")
        }
        let top = try XCTUnwrap(XrayChapterRead.parse(Self.cutObject(user: "a" + Self.marker(10_000_000) + "b", cut: 10_000_000), cutFields: true))
        XCTAssertEqual(top.promptCutChars, 10_000_000, "the top of the range is taken")
    }

    /// The read's gate: the probed dch version picks the rule (take); unknown reads as old.
    func testTheProbedVersionPicksTheRule() throws {
        let saved = XrayPanels.probed
        defer { XrayPanels.probed = saved }
        let long = Self.cutObject(user: String(repeating: "a", count: 7000))
        for (version, old) in [([1, 92, 0], true), ([1, 93, 0], false), ([2, 0, 0], false)] as [([Int], Bool)] {
            XrayPanels.probed = DchCommand.Binary(path: "/Users/example/bin/dch", version: version)
            let read = XrayChapterRead()
            read.take((0, long))
            XCTAssertEqual(read.full?.promptCut, old, "\(version)")
        }
        XrayPanels.probed = nil
        let read = XrayChapterRead()
        read.take((0, long))
        XCTAssertEqual(read.full?.promptCut, true, "no probe: the old rule")
    }
}

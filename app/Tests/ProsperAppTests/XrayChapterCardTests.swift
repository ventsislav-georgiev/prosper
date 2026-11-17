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
}

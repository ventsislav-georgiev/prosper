import AppKit
import XCTest
@testable import ProsperApp

/// #1471: Terminal is the only pane mode. No mode toggle (Command-T, the Go menu), a stored Transcript choice changes
/// nothing, and X-ray reads every tab from dch with the session's own cwd. Fakes only: a fake dch gate and runner, a fake
/// terminal child, the XCTest scratch defaults; the window is never shown and no event is posted.
@MainActor
final class AgentWindowNoModeToggleTests: XCTestCase {
    static let cwd = "/Users/example/acme/api"
    static let oldKey = "agentWindowTranscriptSessions"
    static let chaptersArgv = ["/fake/dch", "--xray", "api", "--json"]

    func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    /// Two live local sessions ("api" with a dch cwd, "web"), "api" selected in a window model on an offscreen
    /// AgentsNSWindow; X-ray's seams on fakes that record each dch argv. `stored` goes into the old mode key first.
    func withPane(stored: [String]? = nil,
                  _ body: (AgentWindowModel, AgentsNSWindow, XrayPanelTasksTests.FakeRun) async throws -> Void) async throws {
        let saved = Preferences.defaults.object(forKey: Self.oldKey)
        defer { Preferences.defaults.set(saved, forKey: Self.oldKey) }
        Preferences.defaults.set(stored, forKey: Self.oldKey)
        let api = AgentSessionKey(dir: "/tmp/dch-test", name: "api"), web = AgentSessionKey(dir: "/tmp/dch-test", name: "web")
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        var a = AgentSession(key: api, alias: "", activity: AgentWindowD1Tests.now - 60, state: .idle, agents: 0, version: "1.78.0")
        a.cwd = Self.cwd
        let w = AgentSession(key: web, alias: "", activity: AgentWindowD1Tests.now - 90, state: .idle, agents: 0, version: "1.78.0")
        store.sessions = [a, w]
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
        m.terminal.request = { AgentTerminalSpawn.local($0, cols: $1, rows: $2, dch: "/opt/example/bin/dch", env: [:]) }
        m.terminal.spawn = { _, _ in AgentTerminalTests.FakeChild() }
        m.bind(store)
        m.setVisible(true)
        m.select(.live(api))
        defer { m.close() }
        let win = AgentsNSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        win.model = m
        win.cards = FakeCardPresenter()
        let fake = XrayPanelTasksTests.FakeRun()
        let (dch, run, model, window, read) = (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.window, XrayPanels.chaptersRead)
        defer {
            (XrayPanels.dch, XrayPanels.run, XrayPanels.model, XrayPanels.window, XrayPanels.chaptersRead) = (dch, run, model, window, read)
            XrayPanels.shared.open = [:]
        }
        XrayPanels.dch = XrayPanelTasksTests.gate([1, 78, 0])
        XrayPanels.run = fake.run
        XrayPanels.model = { [weak m] _ in m }
        XrayPanels.window = { [weak win] _ in win }
        XrayPanels.chaptersRead = XrayPanels.fromDch   // off under XCTest by default: the row turns the real answer on
        try await body(m, win, fake)
        XCTAssertFalse(win.isVisible, "never shown")
    }

    /// Red at base: paneRoute's `case "t": return .toggleMode` (AgentsWindow.swift:384), the Go menu's
    /// "Terminal or Transcript" entry (AgentGoMenu.swift:40).
    func testCommandTIsNoPaneKeyAndNoToggleIsDrawn() {
        let cmdT = key(17, "t", .command)
        for r in [AgentsNSWindow.ResponderKind.text, .terminal, .other] {
            for terminal in [true, false] {
                for form in [false, true] {
                    XCTAssertEqual(AgentsNSWindow.route(cmdT, responder: r, sidebarFocused: !terminal, terminalMode: terminal, form: form),
                                   terminal ? .swallow : .pass, "R1471a-s1: Command-T is swallowed in a terminal pane, else passes (\(r), terminal \(terminal), form \(form))")
                }
            }
        }
        for splits in [false, true] {
            let entries = AgentGoMenu.entries(splits: splits).compactMap { $0 }
            XCTAssertFalse(entries.isEmpty, "control: the menu has entries")
            XCTAssertFalse(entries.contains { $0.title.contains("Transcript") }, "no Terminal or Transcript item (splits \(splits))")
            XCTAssertFalse(entries.contains { $0.key == "t" && $0.mods == .command }, "no Command-T item (splits \(splits))")
        }
    }

    /// Red at base: XrayPanels.fromDch answered false for a local pane in Transcript mode and the stored choice put it
    /// there (AgentWindowModel.swift:1835 mode(_:) read Preferences.agentWindowTranscriptSessions).
    func testStoredTranscriptChoiceIsIgnoredNewAndRestoredPanesAreTerminal() async throws {
        try await withPane(stored: ["/tmp/dch-test\tapi", "/tmp/dch-test\tweb"]) { m, win, _ in
            XCTAssertTrue(m.paneHasTerminal, "api: the stored Transcript choice is ignored")
            XCTAssertNil(m.interaction.session, "no input box")
            m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "web")))
            XCTAssertTrue(m.paneHasTerminal, "a newly shown pane: Terminal too")
            XCTAssertTrue(win.performKeyEquivalent(with: key(17, "t", .command)), "R1471a-s1: Command-T is the window's in a terminal pane (swallowed)")
            XCTAssertTrue(m.paneHasTerminal, "Command-T changes nothing")
            XCTAssertEqual(Preferences.defaults.stringArray(forKey: Self.oldKey), ["/tmp/dch-test\tapi", "/tmp/dch-test\tweb"],
                           "the old value is left alone (ignored, never rewritten)")
        }
    }

    /// Red at base: a local Transcript-mode pane took XrayPanels.transcript (XrayPanel.swift:73) and never ran the
    /// chapters read (fromDch :98). Now the local row's panel runs dch's --xray read and its Prompts and Responses come
    /// from dch's chapters.
    func testXrayLocalRowReadsPromptsAndResponsesFromDch() async throws {
        try await withPane(stored: ["/tmp/dch-test\tapi"]) { m, win, fake in
            let pane = m.layout.focused
            XCTAssertTrue(XrayPanels.fromDch(pane, XrayTarget(name: "api", dir: "/tmp/dch-test")), "a local row reads dch")
            XCTAssertTrue(win.toggleXray())
            let p = try XCTUnwrap(XrayPanels.shared.open[pane])
            await p.reading?.value
            XCTAssertEqual(fake.calls.filter { $0 == Self.chaptersArgv }.count, 1, "the chapters read ran: \(fake.calls)")
            XCTAssertTrue(p.fromDch())
            p.apply(tasks: XrayChaptersTests.ok, memory: (0, XrayChapterCardTests.memory), chapters: XrayChaptersTests.chapters)
            XCTAssertTrue(p.tabs.contains(.prompts) && p.tabs.contains(.responses), "dch's chapters: \(p.tabs)")
            XCTAssertEqual(p.chapters.count, p.dchChapters?.count, "the rows are dch's")
        }
    }

    /// Red with the cwd-lost mutant: X-ray's cwd is the session's own (dch's list), not only the transcript's.
    func testXrayCwdIsTheSessionsCwd() async throws {
        try await withPane { m, _, _ in
            let pane = m.layout.focused
            XCTAssertEqual(XrayPanels.cwd(pane, XrayTarget(name: "api", dir: "/tmp/dch-test")), Self.cwd)
        }
    }
}

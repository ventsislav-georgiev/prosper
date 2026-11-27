import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #2058: the form's Start shows the new session's terminal at once, typeable, before dch answers; the client starts
/// on the answer and gets the keys typed meanwhile, in order. Offscreen only: an AgentsNSWindow that is never shown,
/// ordered or made key. No dch runs: the spawn is `spawnSession`'s recorder, which holds its answer until the row
/// releases it, and the terminal is the fake one. No menu, panel, pasteboard or defaults write.
extension AgentWindowD1Tests {

    /// A window on `a` with the form open for `web`, the keys in the sidebar.
    @MainActor
    func launchRig(_ spawns: SpawnCalls) -> (m: AgentWindowModel, st: AgentIslandStore, win: AgentsNSWindow,
                                              host: NSHostingView<AgentWindowRootView>,
                                              t: (spawned: () -> [AgentTerminalSpawn], children: () -> [AgentTerminalTests.FakeChild])) {
        let a = mapped("a"), st = store([a]), m = wiringModel(st, spawns)
        let t = fakeTerminal(m)
        let (win, host) = focusWindow(m)
        m.select(.live(a.key))
        settle(host)
        sidebarKeys(win)
        m.openNewSessionNamed(folder: "/Users/example/web")
        settle(host)
        return (m, st, win, host, t)
    }

    /// Keys as libghostty hands them over: the shown screen's write event.
    @MainActor
    func typeKeys(_ m: AgentWindowModel, _ s: String) {
        (m.terminal.screen as? AgentTerminalTests.FakeScreen)?.events.write(Data(s.utf8))
    }

    /// #2058 rows 1 and 5: Start shows web's terminal, blank (not the hidden cover) and with the keys, while dch's
    /// answer is still held; no client runs until it answers. The click to the visible, focused pane is under 80 ms.
    @MainActor
    func testAgentWindowNewSessionLaunchShowsItsTerminalBeforeDchAnswers() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), r = launchRig(spawns)
            defer { r.m.close(); r.win.close() }
            let (m, win, host, t) = (r.m, r.win, r.host, r.t)
            XCTAssertEqual(formFields(host).count, 3, "the form is up")
            let clients = t.spawned().count
            let start = Date()
            XCTAssertTrue(m.startNewSession())
            @MainActor func shown() -> Bool {
                m.terminal.key?.name == "web" && m.terminal.revealed && m.terminal.screen != nil
                    && m.terminal.view.map { $0.window === win && win.firstResponder === $0 } == true
            }
            let deadline = Date().addingTimeInterval(2)
            while !shown(), Date() < deadline {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
            let took = Date().timeIntervalSince(start)
            print("#2058 new session -> pane visible and focused: \(Int(took * 1000)) ms")
            XCTAssertTrue(shown(), "web's terminal shown, revealed and first responder")
            XCTAssertLessThan(took, 0.08, "click to a visible, typeable pane under 80 ms")
            XCTAssertEqual(spawns.done.count, 1, "dch's answer is still held")
            XCTAssertTrue(formFields(host).isEmpty, "the form left the pane at the click")
            XCTAssertEqual(m.newSessionStatus, "Starting web…", "the model still waits for the answer")
            XCTAssertEqual(m.terminal.launching?.name, "web")
            XCTAssertEqual(t.spawned().count, clients, "no client before dch answers")
            XCTAssertEqual(m.terminal.phase, .attaching)
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// #2058 row 2: keys typed before the answer reach the new client in order once it starts, then later keys after them.
    @MainActor
    func testAgentWindowNewSessionLaunchKeysTypedBeforeTheAnswerReachTheClientInOrder() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), r = launchRig(spawns)
            defer { r.m.close(); r.win.close() }
            let (m, st, host, t) = (r.m, r.st, r.host, r.t)
            let clients = t.spawned().count
            XCTAssertTrue(m.startNewSession())
            settle(host)
            typeKeys(m, "ab")
            m.terminal.input(Array("c".utf8))   // a paste's path
            typeKeys(m, "d")
            m.terminal.writer.flush()
            XCTAssertEqual(t.spawned().count, clients, "still no client")
            spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: "web"), nil)
            settle(host)
            XCTAssertEqual(t.spawned().count, clients + 1, "web's client once dch answered, before its row lists")
            XCTAssertTrue(t.spawned().last?.args.contains("web") == true, "web's attach")
            XCTAssertEqual(m.terminal.phase, .live)
            typeKeys(m, "e")
            m.terminal.writer.flush()
            let child = try XCTUnwrap(t.children().last)
            XCTAssertEqual(String(decoding: child.written, as: UTF8.self), "abcde", "every key, in order")
            st.sessions = [mapped("a"), mapped("web")]
            settle(host)
            XCTAssertEqual(m.selection, live("web"), "its row lands")
            XCTAssertNil(m.newSession)
            XCTAssertEqual(t.spawned().count, clients + 1, "the landing keeps the running client")
            XCTAssertTrue(r.win.firstResponder === m.terminal.view, "the keys stay in it")
        }
    }

    /// #2058 row 3: a failed start leaves no started pane: the form again with dch's line, no client, nothing pending,
    /// and the held keys go nowhere.
    @MainActor
    func testAgentWindowNewSessionLaunchFailureBringsTheFormBackWithTheLine() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), r = launchRig(spawns)
            defer { r.m.close(); r.win.close() }
            let (m, host, t) = (r.m, r.host, r.t)
            let clients = t.spawned().count
            XCTAssertTrue(m.startNewSession())
            settle(host)
            XCTAssertEqual(m.terminal.key?.name, "web")
            typeKeys(m, "lost")
            let why = "dch: web: nope: No such file or directory"
            spawns.done.last?(nil, why)
            settle(host)
            XCTAssertTrue(m.launchKey == nil, "no started pane")
            XCTAssertTrue(m.newSession?.starting == nil, "the form is enabled again")
            XCTAssertEqual(m.newSessionStatus, why, "with dch's line")
            XCTAssertEqual(formFields(host).count, 3, "the form shows")
            XCTAssertTrue(m.terminal.key?.name != "web", "web's terminal is gone")
            XCTAssertTrue(m.terminal.launching == nil)
            XCTAssertTrue(m.pendingSpawn == nil, "nothing waits for a row")
            XCTAssertEqual(t.spawned().count, clients, "no client ran")
            XCTAssertFalse(t.children().contains { String(decoding: $0.written, as: UTF8.self).contains("lost") }, "the keys went nowhere")
        }
    }

    /// #2058 row 4: a switch to an existing session still covers its screen until its first bytes (no stale frame), while
    /// a started session's pane shows at once.
    @MainActor
    func testAgentWindowNewSessionLaunchExistingSwitchStillCoversUntilItsFirstBytes() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), r = launchRig(spawns)
            defer { r.m.close(); r.win.close() }
            let (m, st, host) = (r.m, r.st, r.host)
            st.sessions = [mapped("a"), mapped("b")]
            m.cancelNewSession()
            m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "b")))
            settle(host)
            XCTAssertEqual(m.terminal.key?.name, "b")
            XCTAssertFalse(m.terminal.revealed, "an existing session's screen stays covered until its first bytes")
            m.openNewSessionNamed(folder: "/Users/example/web")
            XCTAssertTrue(m.startNewSession())
            settle(host)
            XCTAssertTrue(m.terminal.revealed, "a started session has no stale screen to hide")
            m.select(.live(AgentSessionKey(dir: "/tmp/dch-test", name: "a")))
            settle(host)
            XCTAssertEqual(m.terminal.key?.name, "a")
            XCTAssertFalse(m.terminal.revealed, "a manual pick away: covered again until its first bytes")
            XCTAssertTrue(m.terminal.launching == nil, "the pick drops the hold")
        }
    }
}

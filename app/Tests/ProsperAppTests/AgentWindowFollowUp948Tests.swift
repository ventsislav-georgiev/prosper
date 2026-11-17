import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #948 F1: Option-Command on "Dvorak - QWERTY Command"'s W key (key 43) against the same fields on the Finnish and
/// Norwegian Extended W key (key 13). Events are built with NSEvent.keyEvent and handed to the pure `route` or a
/// never-shown window; nothing is posted. The input source is the `inputSourceID` seam, faked per row: no input source
/// is read, selected or changed.
final class AgentWindowFollowUp948Tests: XCTestCase {
    typealias R = AgentsNSWindow.KeyRoute

    @MainActor
    func ev(_ code: UInt16, _ chars: String, _ ignoring: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: ignoring, isARepeat: false,
                         keyCode: code)!
    }

    @MainActor
    func route(_ e: NSEvent, _ r: AgentsNSWindow.ResponderKind = .terminal) -> R {
        AgentsNSWindow.route(e, responder: r, sidebarFocused: false, terminalMode: true)
    }

    /// The seam returns `id` for the body; the reads are counted.
    @MainActor
    func on(_ id: String, _ body: () -> Void) -> Int {
        final class Reads { var n = 0 }
        let saved = AgentsNSWindow.inputSourceID, reads = Reads()
        AgentsNSWindow.inputSourceID = { reads.n += 1; return id }
        defer { AgentsNSWindow.inputSourceID = saved }
        body()
        return reads.n
    }

    @MainActor
    func testAgentWindow948DvorakQwertyCommandOptionCommandOnItsWKeyIsNoChord() {
        _ = on(AgentsNSWindow.dvorakQwertyCommandID) {
            for r: AgentsNSWindow.ResponderKind in [.text, .terminal, .other] {
                XCTAssertEqual(route(ev(43, ",", "w", [.command, .option]), r), .pass, "Option-Command on key 43 \(r)")
                XCTAssertEqual(route(ev(13, "w", ",", [.command, .option]), r), .close, "on the QWERTY W key it closes")
                XCTAssertEqual(route(ev(43, ",", "w", .command), r), .pass, "Command alone, as before")
                XCTAssertEqual(route(ev(13, "w", ",", .command), r), .close)
            }
            let win = AgentsNSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: true)
            win.isReleasedWhenClosed = false
            XCTAssertFalse(win.performKeyEquivalent(with: ev(43, ",", "w", [.command, .option])), "no model: passes on")
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// Every other input source id (and none): the fields decide as before, the letter rules; Finnish and Norwegian
    /// Extended's Option-Command-W types "," and closes. The seam is read only with Option and Command held.
    @MainActor
    func testAgentWindow948LetterStillDecidesOnEveryOtherLayout() {
        for id in ["com.apple.keylayout.FinnishExtended", "com.apple.keylayout.NorwegianExtended",
                   "com.apple.keylayout.Dvorak", "com.apple.keylayout.US", ""] {
            let reads = on(id) {
                XCTAssertEqual(route(ev(13, ",", "w", [.command, .option])), .close, "Option-Command-W on \(id)")
                XCTAssertEqual(route(ev(43, ",", "w", [.command, .option])), .close, "the same fields on key 43, \(id)")
                XCTAssertEqual(route(ev(45, "n", "b", [.command, .option])), .pass, "Option-Command-N is no chord")
            }
            XCTAssertEqual(reads, 3, "one read per Option-Command key on \(id)")
        }
        let reads = on(AgentsNSWindow.dvorakQwertyCommandID) {
            XCTAssertEqual(route(ev(13, "w", ",", .command)), .close)
            XCTAssertEqual(route(ev(45, "n", "n", .command)), .newSession)
            XCTAssertEqual(route(ev(13, "w", "w", [])), .pass)
        }
        XCTAssertEqual(reads, 0, "no Option: the input source is not read")
    }
}

/// #948 F2 and F3: the window's own line in the dir-wide slot, and the end in the not-listed sentence. Models on fake
/// stores, no window shown; no dch runs (the spawn is `spawnSession`'s recorder, the History read the island's
/// controlDch and readHistory seams returning fakes).
extension AgentWindowD1Tests {

    /// F2: a gate refusal written by Shift-Command-N (and Command-N) stays while the gate is shut, through any publish,
    /// and goes when it opens (the probe, then the records, as setHistory); the form opening takes it too. A line the
    /// island wrote over it is the island's and stays. The strip keeps its fixed height either way.
    @MainActor
    func testAgentWindow948DirLineGoesWhenTheGateOpensOrTheFormOpens() throws {
        try withNewSessionPrefs {
            let st = store([mapped("a")]), spawns = SpawnCalls(), m = newSessionModel(st, spawns)
            defer { m.close() }
            let key = AgentSessionKey(dir: "/tmp/dch-test", name: ""), open = st.controlDch
            st.controlDch = nil
            let why = "Controls " + (try XCTUnwrap(st.resumeGate.refusal))
            XCTAssertFalse(m.startShell())
            XCTAssertEqual(st.actions[key], why)
            st.history = []
            st.sessions = [mapped("a"), mapped("b")]
            XCTAssertEqual(st.actions[key], why, "the gate still shut: the line stays")
            st.controlDch = open
            st.history = []
            XCTAssertTrue(st.actions[key] == nil, "the gate open: the line is gone")
            XCTAssertEqual(st.dirStatus, "")
            XCTAssertTrue(m.dirLine == nil)

            // Command-N's refusal, then the form opening (the gate opened without a publish).
            st.controlDch = nil
            m.openNewSession()
            XCTAssertEqual(st.actions[key], why, "Command-N says why")
            st.controlDch = open
            m.openNewSession()
            XCTAssertNotNil(m.newSession)
            XCTAssertTrue(st.actions[key] == nil, "the form opened: the line is gone")
            m.cancelNewSession()

            // The island's line over the window's: not the window's to clear.
            st.controlDch = nil
            XCTAssertFalse(m.startShell())
            st.actions[key] = "End all: 1 ended"
            st.controlDch = open
            st.history = []
            m.openNewSession()
            XCTAssertEqual(st.actions[key], "End all: 1 ended", "the island's line stays")
            XCTAssertEqual(NSHostingView(rootView: AgentDirStatusStrip(store: st).frame(width: 290)).fittingSize.height,
                           AgentWindowControls.stripHeight, accuracy: 1, "the same fixed slot")
        }
    }

    /// F2 + F3: a quick shell answered but never listed. Past the deadline the dir line says so and the window reads
    /// History once; that read's record of the name, started since the request, puts its end in the sentence. The line
    /// stays through publishes and goes when a session of that name lists. A form start whose only record of the name
    /// is older keeps the plain sentence.
    @MainActor
    func testAgentWindow948UnlistedStartSaysItsEndAndGoesWhenTheNameLists() throws {
        try withNewSessionPrefs {
            final class Clock { var t = AgentWindowD1Tests.now }
            final class Reads: @unchecked Sendable {
                let lock = NSLock()
                var n = 0
                var records: [DchHistoryRecord] = []
            }
            let other = mapped("other"), clock = Clock(), st = store([other]), spawns = SpawnCalls(), reads = Reads()
            let m = newSessionModel(st, spawns)
            defer { m.close() }
            m.now = { clock.t }
            let island = m.island()
            island.store = st
            island.showsPanel = false
            island.controlDch = { DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1]) }
            island.listSessions = { _ in [] }
            island.readHistory = { _, _ in reads.lock.withLock { reads.n += 1; return reads.records } }
            @MainActor func drain(until done: () -> Bool) {
                let end = Date().addingTimeInterval(5)
                repeat {
                    island.queue.sync {}
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                } while !done() && Date() < end
            }
            let key = AgentSessionKey(dir: "/tmp/dch-test", name: "")
            m.select(.live(other.key))

            XCTAssertTrue(m.startShell())
            let shell = try XCTUnwrap(spawns.calls.last?.name)
            var r = DchHistoryRecord(key: AgentSessionKey(dir: "/tmp/dch-test", name: shell))
            r.started = clock.t
            r.ended = clock.t
            r.end = "exit 127"
            reads.lock.withLock { reads.records = [r] }
            spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: shell), nil)
            XCTAssertEqual(reads.lock.withLock { reads.n }, 0, "no read before the deadline")
            clock.t += AgentWindowModel.spawnSlack + 1
            try XCTUnwrap(m.spawnDeadline).fire()
            let said = AgentWindowModel.notListedText(shell, end: "exit 127", command: false)
            XCTAssertEqual(said, "\(shell) ended at once or never started (exit 127)", "#1096 4: a quick shell: no command")
            drain { st.actions[key] == said }
            XCTAssertEqual(st.actions[key], said, "the record's end in the sentence")
            XCTAssertEqual(reads.lock.withLock { reads.n }, 1, "one History read")
            XCTAssertTrue(m.unlisted == nil)
            st.sessions = [other]
            XCTAssertEqual(st.actions[key], said, "another publish: it stays")
            st.sessions = [other, mapped(shell)]
            XCTAssertTrue(st.actions[key] == nil, "a session of that name lists: the line is gone")

            // The form: a record of the name from before the request is not this start's.
            m.openNewSession(folder: "/Users/example/web")
            XCTAssertTrue(m.startNewSession())
            var old = DchHistoryRecord(key: AgentSessionKey(dir: "/tmp/dch-test", name: "web"))
            old.started = clock.t - 3600
            old.ended = clock.t - 3500
            old.end = "exit 1"
            reads.lock.withLock { reads.records = [old] }
            spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: "web"), nil)
            clock.t += AgentWindowModel.spawnSlack + 1
            try XCTUnwrap(m.spawnDeadline).fire()
            XCTAssertEqual(m.newSessionStatus, AgentWindowModel.notListedText("web"))
            drain { reads.lock.withLock { reads.n } == 2 }
            drain { st.history == [old] }
            XCTAssertEqual(reads.lock.withLock { reads.n }, 2, "one read for this start too")
            XCTAssertEqual(m.newSessionStatus, AgentWindowModel.notListedText("web"), "an older record: no end")
        }
    }

    /// QA R948-q1: a signal end carries the sender's pid and argv; the sentence shows it as the island does (#839 no
    /// pid, #937 no hidden characters), on the form's status and on the dir line.
    @MainActor
    func testAgentWindow948UnlistedSignalEndHidesPidAndHiddenCharacters() throws {
        try withNewSessionPrefs {
            let st = store([mapped("other")]), spawns = SpawnCalls()
            let m = newSessionModel(st, spawns)
            defer { m.close() }
            var clock = Self.now
            m.now = { clock }
            let island = m.island()
            island.store = st
            island.showsPanel = false
            island.controlDch = { DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1]) }
            island.listSessions = { _ in [] }
            final class Box: @unchecked Sendable {
                let lock = NSLock()
                var records: [DchHistoryRecord] = []
            }
            let box = Box()
            island.readHistory = { _, _ in box.lock.withLock { box.records } }
            let key = AgentSessionKey(dir: "/tmp/dch-test", name: "")
            let raw = "signal 9 from 4242 /bin/kill\u{202E}x -9"

            m.openNewSession(folder: "/Users/example/web")
            XCTAssertTrue(m.startNewSession())
            var r = DchHistoryRecord(key: AgentSessionKey(dir: "/tmp/dch-test", name: "web"))
            r.started = clock
            r.ended = clock
            r.end = raw
            box.lock.withLock { box.records = [r] }
            spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: "web"), nil)
            clock += AgentWindowModel.spawnSlack + 1
            try XCTUnwrap(m.spawnDeadline).fire()
            let end = Date().addingTimeInterval(5)
            while m.newSessionStatus == AgentWindowModel.notListedText("web"), Date() < end {
                island.queue.sync {}
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            let status = try XCTUnwrap(m.newSessionStatus)
            XCTAssertEqual(status, AgentWindowModel.notListedText("web", end: "crashed (signal 9) from /bin/killx -9"))
            XCTAssertTrue(status.contains("kill"))
            XCTAssertFalse(status.contains("4242"))
            XCTAssertFalse(status.contains("\u{202E}"))

            // The quick shell's dir line.
            m.cancelNewSession()
            m.select(.live(mapped("other").key))
            XCTAssertTrue(m.startShell())
            let shell = try XCTUnwrap(spawns.calls.last?.name)
            var q = DchHistoryRecord(key: AgentSessionKey(dir: "/tmp/dch-test", name: shell))
            q.started = clock
            q.ended = clock
            q.end = raw
            box.lock.withLock { box.records = [q] }
            spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: shell), nil)
            clock += AgentWindowModel.spawnSlack + 1
            try XCTUnwrap(m.spawnDeadline).fire()
            let want = AgentWindowModel.notListedText(shell, end: "crashed (signal 9) from /bin/killx -9", command: false)
            let until = Date().addingTimeInterval(5)
            while st.actions[key] != want, Date() < until {
                island.queue.sync {}
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            let line = try XCTUnwrap(st.actions[key])
            XCTAssertEqual(line, want)
            XCTAssertFalse(line.contains("4242"))
            XCTAssertFalse(line.contains("\u{202E}"))
        }
    }

    /// #1313: a quick shell dch refuses (no form open) leaves its failure on the dir line as the window's own: it goes
    /// when a session of that name lists or the form opens; another name listing leaves it.
    @MainActor
    func testAgentWindow1313RefusedQuickShellLineGoesWhenItsCauseGoes() throws {
        try withNewSessionPrefs {
            let other = mapped("other"), st = store([other]), spawns = SpawnCalls(), m = newSessionModel(st, spawns)
            defer { m.close() }
            let key = AgentSessionKey(dir: "/tmp/dch-test", name: "")
            XCTAssertTrue(m.startShell())
            let shell = try XCTUnwrap(spawns.calls.last?.name)
            let failed = "New session failed: dch: \(shell): nope"
            spawns.done.last?(nil, failed)
            XCTAssertEqual(st.actions[key], failed, "the refusal shows")
            XCTAssertEqual(m.dirLine?.cause, .listed(shell))
            st.sessions = [other, mapped("unrelated")]
            XCTAssertEqual(st.actions[key], failed, "an unrelated name lists: it stays")
            st.sessions = [other, mapped("unrelated"), mapped(shell)]
            XCTAssertTrue(st.actions[key] == nil, "a session of that name lists: gone")
            XCTAssertTrue(m.dirLine == nil)

            XCTAssertTrue(m.startShell())
            let again = try XCTUnwrap(spawns.calls.last?.name)
            spawns.done.last?(nil, "New session failed: dch: \(again): nope")
            XCTAssertEqual(st.actions[key], "New session failed: dch: \(again): nope")
            m.openNewSession()
            XCTAssertNotNil(m.newSession)
            XCTAssertTrue(st.actions[key] == nil, "the form opens: gone")

            // A form's own failure stays the form's: no dir line.
            m.setNewSessionName("web")
            XCTAssertTrue(m.startNewSession())
            spawns.done.last?(nil, "New session failed: dch: web: nope")
            XCTAssertTrue(st.actions[key] == nil)
            XCTAssertTrue(m.dirLine == nil)
        }
    }

    /// R948-n2: the not-listed sentence shows dch's "exit N" raw only when N is a number; any other "exit ..." reads
    /// through endLabel, as every other end does.
    @MainActor
    func testAgentWindow1313UnlistedExitEndIsRawOnlyForANumber() throws {
        try withNewSessionPrefs {
            let st = store([mapped("other")]), spawns = SpawnCalls()
            let m = newSessionModel(st, spawns)
            defer { m.close() }
            var clock = Self.now
            m.now = { clock }
            let island = m.island()
            island.store = st
            island.showsPanel = false
            island.controlDch = { DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1]) }
            island.listSessions = { _ in [] }
            final class Box: @unchecked Sendable {
                let lock = NSLock()
                var records: [DchHistoryRecord] = []
            }
            let box = Box()
            island.readHistory = { _, _ in box.lock.withLock { box.records } }
            let key = AgentSessionKey(dir: "/tmp/dch-test", name: "")
            for (end, shown) in [("exit 1", "exit 1"), ("exit 1x\u{202E}", AgentIsland.endLabel("exit 1x\u{202E}"))] {
                m.select(.live(mapped("other").key))
                XCTAssertTrue(m.startShell())
                let shell = try XCTUnwrap(spawns.calls.last?.name)
                var r = DchHistoryRecord(key: AgentSessionKey(dir: "/tmp/dch-test", name: shell))
                r.started = clock
                r.ended = clock
                r.end = end
                box.lock.withLock { box.records = [r] }
                spawns.done.last?(AgentSessionKey(dir: "/tmp/dch-test", name: shell), nil)
                clock += AgentWindowModel.spawnSlack + 1
                try XCTUnwrap(m.spawnDeadline).fire()
                let want = AgentWindowModel.notListedText(shell, end: shown, command: false)
                let until = Date().addingTimeInterval(5)
                while st.actions[key] != want, Date() < until {
                    island.queue.sync {}
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                }
                XCTAssertEqual(st.actions[key], want, "end \(end.debugDescription)")
            }
            XCTAssertEqual(AgentIsland.endLabel("exit 1x\u{202E}"), "exited (1x\u{202E})", "the exact endLabel reading")
            XCTAssertNotEqual(AgentIsland.endLabel("exit 1x\u{202E}"), "exit 1x\u{202E}", "not the raw text")
        }
    }
}

import AppKit
import XCTest
@testable import ProsperApp

/// #1566 (X-ray phase F): Cmd-K's `dch --xray <n> --clear --json` beside the local clear, and the panel header's corpus
/// label as dch's view words it. Fakes only: the XrayPanels.run recorder, XrayFollowTests.Fake through the follow seam,
/// XrayRequestsTests' fake `--requests` child, a recorder for libghostty's clear_screen. The view gets a built NSEvent
/// through its own performKeyEquivalent; its window is never ordered in or made key. No dch, no pty, no event posted.
@MainActor
final class XrayClearTests: XCTestCase {
    static let dir = "/Users/example/dch"
    static let local = AgentSessionKey(dir: dir, name: "api")
    static let sid = "0b1f6a52-4c1e-4d7a-9a51-2f6d8c3e7a10"   // XrayChaptersTests.json's session_id

    /// Each argv the cold run got (the path first).
    final class Runs: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] { lock.withLock { _calls } }
        var run: XrayPanels.Run {
            { [self] path, args, _ in
                lock.withLock { _calls.append([path] + args) }
                return (0, Data(#"{"schema":1,"session":"api","corpus":"shell","ring_cleared":true}"#.utf8))
            }
        }
    }

    @MainActor final class Rig {
        let t = AgentTerminalController()
        let v = AgentTerminalHostView(frame: NSRect(x: 0, y: 0, width: 648, height: 410))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 648, height: 410), styleMask: [.titled], backing: .buffered, defer: true)
        var child: AgentTerminalTests.FakeChild?
        var io: AgentTerminalIO?
        var clears = 0
    }

    /// The seams set for the body and put back after it (the dch gate, the cold run, the follow and its gate).
    func withSeams(_ runs: Runs, _ body: (XrayFollowTests.Fake) async throws -> Void) async rethrows {
        let (ok, follow, dch, run) = (XrayPanels.followOK, XrayPanels.follow, XrayPanels.dch, XrayPanels.run)
        defer { (XrayPanels.followOK, XrayPanels.follow, XrayPanels.dch, XrayPanels.run) = (ok, follow, dch, run) }
        let fake = XrayFollowTests.Fake()
        XrayPanels.followOK = { true }
        XrayPanels.follow = fake.follow
        XrayPanels.dch = XrayPanelTasksTests.gate([1, 99, 0])
        XrayPanels.run = runs.run
        try await body(fake)
    }

    /// A live terminal on `key`, its view the first responder of a window that is never shown; `follow` is the focused
    /// pane's follow it holds (as XrayFollows.focus hands it).
    func rig(_ key: AgentSessionKey = XrayClearTests.local, follow: XrayFollow? = nil) -> Rig {
        let r = Rig()
        r.t.spawn = { [weak r] _, io in let c = AgentTerminalTests.FakeChild(); r?.child = c; r?.io = io; return c }
        r.t.makeScreen = { AgentTerminalTests.FakeScreen($0) }
        r.t.clearAction = { [weak r] _ in r?.clears += 1 }
        r.t.focusFollow = { _, _ in follow }
        r.v.owner = r.t
        r.t.view = r.v
        r.v.marks.windowShown = { _ in false }
        r.v.marks.after = { _, _ in }
        r.w.isReleasedWhenClosed = false
        if AgentTerminalSpawn.remoteHost(key) != nil { r.t.arm(key) }
        r.t.attach(key)
        r.t.gridChanged(cols: 80, rows: 24)
        r.t.gridChanged(cols: 80, rows: 24, generation: r.t.generation)
        r.w.contentView = r.v
        XCTAssertTrue(r.w.makeFirstResponder(r.v))
        XCTAssertEqual(r.t.phase, .live)
        return r
    }

    func tearDown(_ r: Rig) {
        r.t.detach()
        r.w.contentView = nil
    }

    static func cmd(_ chars: String, _ mods: NSEvent.ModifierFlags = .command, keyCode: UInt16 = 40) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    }

    func until(_ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    /// A follow of the local session with XrayChaptersTests.json's snapshot in (fake start `n`).
    func follow(_ fake: XrayFollowTests.Fake, _ n: Int = 1, _ json: String = XrayChaptersTests.json) throws -> XrayFollow {
        let f = try XCTUnwrap(XrayFollows().attach(XrayTarget(name: "api", dir: Self.dir), dch: "/fake/dch"))
        fake.send(n, XrayFollowTests.snapshot(json))
        return f
    }

    // MARK: Cmd-K

    /// Cmd-K in the focused live pane: libghostty's clear once, and exactly one run with argv [--xray, <session_id>,
    /// --clear, --json] (the session_id of the pane's follow snapshot); not one byte to the pty from this path (red with
    /// the clear action dropped, the spawn dropped, the name sent while the snapshot names an id, or a write added).
    func testCommandKClearsLocallyAndRunsOneClearBySessionID() async throws {
        let runs = Runs()
        try await withSeams(runs) { fake in
            let f = try follow(fake)
            XCTAssertEqual(f.state?.corpus?.sessionID, Self.sid)
            let r = rig(follow: f)
            defer { tearDown(r) }
            XCTAssertTrue(r.v.marks.follow === f)
            let before = r.child?.written.count ?? -1
            XCTAssertTrue(r.v.performKeyEquivalent(with: Self.cmd("k")))
            XCTAssertEqual(r.clears, 1, "libghostty's local clear still runs")
            await until { runs.calls.count >= 1 }
            try? await Task.sleep(nanoseconds: 50_000_000)   // a second run would land here
            XCTAssertEqual(runs.calls, [["/fake/dch", "--xray", Self.sid, "--clear", "--json"]])
            r.t.writer.flush()
            XCTAssertEqual(r.child?.written.count ?? -1, before, "0 bytes to the pty from the Cmd-K path")
            XCTAssertEqual(before, 0)
        }
    }

    /// No follow snapshot (or one of another session): the name, which dch matches after a live ring's id (red with
    /// the id taken from any follow, or with nothing run without one).
    func testCommandKWithoutASnapshotClearsByName() async throws {
        let runs = Runs()
        await withSeams(runs) { _ in
            let r = rig()
            defer { tearDown(r) }
            XCTAssertTrue(r.v.performKeyEquivalent(with: Self.cmd("k")))
            await until { runs.calls.count >= 1 }
            XCTAssertEqual(runs.calls, [["/fake/dch", "--xray", "api", "--clear", "--json"]])
            r.t.writer.flush()
            XCTAssertEqual(r.child?.written.count, 0)
        }
    }

    /// #1881: the pane holds a follow of ANOTHER session whose snapshot carries a session_id: the name, never that id
    /// (red with the follow's target unchecked, mutant sid-any-follow).
    func testCommandKWithAnotherSessionsFollowClearsByName() async throws {
        let runs = Runs()
        try await withSeams(runs) { fake in
            let f = try XCTUnwrap(XrayFollows().attach(XrayTarget(name: "api-qa", dir: Self.dir), dch: "/fake/dch"))
            fake.send(1, XrayFollowTests.snapshot(XrayChaptersTests.json))
            XCTAssertEqual(f.state?.corpus?.sessionID, Self.sid)
            let r = rig(follow: f)
            defer { tearDown(r) }
            XCTAssertTrue(r.v.marks.follow === f)
            XCTAssertTrue(r.v.performKeyEquivalent(with: Self.cmd("k")))
            await until { runs.calls.count >= 1 }
            XCTAssertEqual(runs.calls, [["/fake/dch", "--xray", "api", "--clear", "--json"]])
        }
    }

    /// An ended pane: the local clear, 0 runs (red with the live check gone).
    func testCommandKInAnEndedPaneRunsNothing() async throws {
        let runs = Runs()
        await withSeams(runs) { _ in
            let r = rig()
            defer { tearDown(r) }
            r.t.isLive = { _ in false }
            r.t.socketExists = { _ in false }
            r.io?.exit(0)
            await until { r.t.phase == .ended }
            XCTAssertEqual(r.t.phase, .ended)
            XCTAssertTrue(r.v.performKeyEquivalent(with: Self.cmd("k")))
            XCTAssertEqual(r.clears, 1)
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(runs.calls.count, 0)
        }
    }

    /// The X-ray gate shut (an older dch): the local clear alone (red with the gate check gone: a run with no path).
    func testCommandKWithTheGateShutRunsNothing() async throws {
        let runs = Runs()
        await withSeams(runs) { _ in
            XrayPanels.dch = { nil }
            let r = rig()
            defer { tearDown(r) }
            XCTAssertTrue(r.v.performKeyEquivalent(with: Self.cmd("k")))
            XCTAssertEqual(r.clears, 1)
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(runs.calls.count, 0)
        }
    }

    /// Only Cmd-K, and only in the first responder: Shift-Cmd-K and Cmd-J go on; a view that is not the first
    /// responder (another pane: a key equivalent visits every view) neither clears nor runs (red with either check gone).
    func testOnlyCommandKInTheFocusedPaneClears() async throws {
        let runs = Runs()
        await withSeams(runs) { _ in
            let r = rig()
            defer { tearDown(r) }
            _ = r.v.performKeyEquivalent(with: Self.cmd("K", [.command, .shift]))
            _ = r.v.performKeyEquivalent(with: Self.cmd("j", keyCode: 38))
            XCTAssertEqual(r.clears, 0)
            XCTAssertTrue(r.w.makeFirstResponder(nil))
            XCTAssertFalse(r.v.performKeyEquivalent(with: Self.cmd("k")))
            XCTAssertEqual(r.clears, 0)
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(runs.calls.count, 0)
        }
    }

    /// A remote pane: the clear is a request on the warm host:name connection, argv the flags after the name; no cold
    /// run (red with the remote branch gone: a cold `--xray api` on this machine, or a name without its host).
    func testCommandKInARemotePaneSendsAWarmClearRequest() async throws {
        let runs = Runs(), panels = XrayPanels.shared
        let spawns = XrayRequestsTests.Spawns { XrayRequestsTests.Child(reply: XrayRequestsTests.echo) }
        let old = panels.requests.spawn
        defer { panels.requests.spawn = old; panels.requests.windowClosed() }
        panels.requests.spawn = spawns.spawn
        await withSeams(runs) { _ in
            let r = rig(AgentSessionKey(dir: "@box", name: "api"))
            defer { tearDown(r) }
            XCTAssertTrue(r.v.performKeyEquivalent(with: Self.cmd("k")))
            XCTAssertEqual(r.clears, 1)
            await until { spawns.children.last?.writes.isEmpty == false }
            XCTAssertEqual(spawns.calls, [["--xray", "box:api", "--requests", "--json"]])
            XCTAssertEqual(spawns.children.last?.writes.last?["argv"] as? [String], ["--clear", "--json"])
            XCTAssertEqual(runs.calls.count, 0, "never cold while the connection answers")
            r.t.writer.flush()
            XCTAssertEqual(r.child?.written.count, 0)
        }
    }

    // MARK: The corpus label

    static func object(_ fields: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(#"{"schema":1,"chapters":[],\#(fields)}"#.utf8))) as? [String: Any] ?? [:]
    }

    /// Each label as dch's view words it (xview.c xv_label, v1.100.0:2430-2481), from fixture snapshots (red with any
    /// branch or word changed).
    func testEachLabelFromFixtureSnapshots() {
        let note = " \u{00B7} a terminal's own clear-screen key may not clear X-ray; run `clear`"
        let rows: [(String, String?)] = [
            (#""corpus":"claude","reason":null,"available":true,"mentions_only":false"#, nil),
            (#""corpus":"claude","reason":null,"available":true,"claudes":1"#, nil),
            (#""corpus":"claude","reason":null,"available":true,"claudes":2"#, "2 Claude sessions run here; X-ray reads one"),
            (#""corpus":"codex","reason":null,"available":true,"mentions_only":true"#, "Codex \u{00B7} mentions only"),
            (#""corpus":"codex","reason":null,"available":true,"mentions_only":false"#, "Codex"),
            (#""corpus":"shell","available":true,"mentions_only":false,"lines":500,"complete":true"#, "Shell \u{00B7} last 500 rows" + note),
            (#""corpus":"shell","available":true,"mentions_only":true,"lines":40"#, "Shell \u{00B7} no shell integration \u{00B7} mentions only" + note),
            (#""corpus":"shell","available":true,"lines":12,"complete":true,"why":"alt""#,
             "Shell \u{00B7} last 12 rows \u{00B7} waiting for the shell prompt" + note),
            (#""corpus":"shell","available":true,"lines":-3"#, "Shell \u{00B7} last 0 rows" + note),
            (#""corpus":"screen","available":true,"mentions_only":true,"lines":24"#, "Screen \u{00B7} last 24 lines \u{00B7} mentions only"),
            (#""corpus":"none","reason":"ended","available":false"#, "Shell \u{00B7} ended \u{00B7} not kept"),
            (#""corpus":"none","reason":"lite","available":false"#, "X-ray needs the full dch build"),
            (#""corpus":"none","reason":"off","available":false"#, "X-ray is off for shells (xray_ring = 0)"),
            (#""corpus":"none","reason":null,"available":false,"claudes":0"#, "No Claude session found here"),
            (#""corpus":"none","reason":null,"available":false"#, "No X-ray corpus for this session"),
            (#""corpus":"none","reason":"off","available":false,"claudes":3"#, "3 Claude sessions run here; X-ray reads one"),
            (#""corpus":"tape","available":true"#, "X-ray corpus not supported by this dch"),
        ]
        for (fields, want) in rows {
            XCTAssertEqual(XrayChapters.corpus(Self.object(fields))?.label, want, fields)
        }
        XCTAssertTrue(XrayChapters.corpus(Self.object(#""reason":null"#)) == nil, "no corpus: an older dch, no line")
        XCTAssertTrue(XrayChapters.corpus(["corpus": "shell"]) == nil, "no schema 1")
    }

    /// why "range" on a shell: "counts in the last N rows" after the label; complete, another why or not a shell: none
    /// (red with the range note dropped or shown for a complete answer).
    func testRangeGivesInTheLastNRows() {
        let range = XrayChapters.corpus(Self.object(#""corpus":"shell","lines":500,"complete":false,"why":"range""#))
        XCTAssertEqual(range?.rangeNote, "counts in the last 500 rows")
        for fields in [#""corpus":"shell","lines":500,"complete":true"#, #""corpus":"shell","lines":500,"complete":false,"why":"budget""#,
                       #""corpus":"claude","lines":500,"complete":false,"why":"range""#] {
            XCTAssertTrue(XrayChapters.corpus(Self.object(fields))?.rangeNote == nil, fields)
        }
    }

    /// #1991 (dch 1.174.0 README "Ended Codex", "Codex", "None"): an ended Codex is corpus "codex" with live false, its
    /// label "Codex" as a live one's and its session_id the thread id; no rollout is none with reason null; the reasons
    /// "compressed" and "corrupt" have their own words; why "corrupt" (a partial decode) gives its note, and only on a
    /// Codex. Red with the reason words gone (they read "No X-ray corpus for this session") or the note dropped.
    func testEndedCodexCorpusAndItsRolloutReasons() {
        let tid = "019a2b3c-4d5e-7f60-8a9b-0c1d2e3f4a5b"
        let ended = XrayChapters.corpus(Self.object(#""corpus":"codex","live":false,"available":true,"mentions_only":false,"session_id":"\#(tid)""#))
        XCTAssertEqual(ended?.label, "Codex")
        XCTAssertEqual(ended?.sessionID, tid, "the thread id, never a record file")
        XCTAssertTrue(ended?.rangeNote == nil && ended?.rolloutWhy == nil)
        let rows: [(String, String?, String?)] = [
            (#""corpus":"none","reason":null,"available":false,"session_id":"\#(tid)""#, "No X-ray corpus for this session", nil),
            (#""corpus":"none","reason":"compressed","available":false,"session_id":"\#(tid)""#,
             "Codex rollout is compressed: X-ray needs a dch built with libzstd", "the Codex rollout is compressed"),
            (#""corpus":"none","reason":"corrupt","available":false,"session_id":"\#(tid)""#,
             "Codex rollout is corrupt: nothing could be read", "the Codex rollout is corrupt"),
            (#""corpus":"none","reason":"ended","available":false"#, "Shell \u{00B7} ended \u{00B7} not kept", nil),
        ]
        for (fields, label, why) in rows {
            let c = XrayChapters.corpus(Self.object(fields))
            XCTAssertEqual(c?.label, label, fields)
            XCTAssertEqual(c?.rolloutWhy, why, fields)
        }
        let partial = XrayChapters.corpus(Self.object(#""corpus":"codex","available":true,"complete":false,"why":"corrupt""#))
        XCTAssertEqual(partial?.rangeNote, "rollout corrupt: read up to the damage")
        for fields in [#""corpus":"codex","complete":true,"why":"corrupt""#, #""corpus":"codex","complete":false,"why":"range""#,
                       #""corpus":"shell","lines":5,"complete":false,"why":"corrupt""#] {
            XCTAssertTrue(XrayChapters.corpus(Self.object(fields))?.rangeNote == nil, fields)
        }
    }

    /// #1991: an Ended pane's X-ray of a Codex opens: its read's chapters land, the header says "Codex" and the corrupt
    /// note, and the corpus keeps the thread id (red with an ended Codex answer dropped or mislabelled).
    func testAnEndedCodexReadOpensWithItsChapters() {
        let p = XrayPanelModel(target: XrayTarget(name: "api", dir: Self.dir), tab: .prompts)
        p.fromDch = { true }
        let tid = "019a2b3c-4d5e-7f60-8a9b-0c1d2e3f4a5b"
        let json = #"{"schema":1,"session":"api","session_id":"\#(tid)","corpus":"codex","live":false,"available":true,"#
            + #""mentions_only":false,"complete":false,"why":"corrupt","chapters":[{"i":1,"title":"Fix the login form"}]}"#
        p.takeChapters((0, Data(json.utf8)))
        XCTAssertEqual(p.dchChapters?.count, 1)
        XCTAssertEqual(p.dchChapters?.first?.title, "Fix the login form")
        XCTAssertEqual(p.corpusLine, "Codex \u{00B7} rollout corrupt: read up to the damage")
        XCTAssertEqual(p.corpus?.sessionID, tid)
        p.stop()
    }

    /// The panel header's second line from a `--json` read and from a follow snapshot, through OutsideText.shown; a
    /// lone Claude's has none (red with the line not set from either source).
    func testThePanelHeaderLineComesFromTheReadAndTheSnapshot() throws {
        let p = XrayPanelModel(target: XrayTarget(name: "api", dir: Self.dir), tab: .prompts)
        p.fromDch = { true }
        let shell = #"{"schema":1,"session":"sh","corpus":"shell","lines":500,"complete":false,"why":"range","chapters":[]}"#
        p.takeChapters((0, Data(shell.utf8)))
        let want = "Shell \u{00B7} last 500 rows \u{00B7} a terminal's own clear-screen key may not clear X-ray; run `clear`"
            + " \u{00B7} counts in the last 500 rows"
        XCTAssertEqual(p.corpusLine, want)
        p.takeChapters((1, Data()))
        XCTAssertTrue(p.corpusLine == nil, "a failed read keeps no label")
        let fake = XrayFollowTests.Fake(), follow = XrayPanels.follow, ok = XrayPanels.followOK
        defer { (XrayPanels.follow, XrayPanels.followOK) = (follow, ok) }
        (XrayPanels.follow, XrayPanels.followOK) = (fake.follow, { true })
        let f = try XCTUnwrap(XrayFollows().attach(XrayTarget(name: "api", dir: Self.dir), dch: "/fake/dch"))
        fake.send(1, XrayFollowTests.snapshot(#"{"schema":1,"corpus":"codex","mentions_only":true,"chapters":[]}"#))
        p.takeFollow(f.state)
        XCTAssertEqual(p.corpusLine, "Codex \u{00B7} mentions only")
        fake.send(1, XrayFollowTests.snapshot(XrayChaptersTests.json))
        p.takeFollow(f.state)
        XCTAssertTrue(p.corpusLine == nil, "a lone Claude: no label (dch shows none)")
        p.stop()
    }

    /// A session_id goes to argv only when it is a plain id (red with the check gone: a flag or a host:name form).
    func testOnlyAPlainSessionIDIsKept() {
        for (sid, want) in [(Self.sid, Self.sid), ("-rf", nil), ("box:api", nil), ("", nil), ("a b", nil), ("caf\u{00E9}", nil),
                            (String(repeating: "a", count: 129), nil)] as [(String, String?)] {
            XCTAssertEqual(XrayChapters.corpus(["schema": 1, "corpus": "shell", "session_id": sid])?.sessionID, want, sid)
        }
    }
}

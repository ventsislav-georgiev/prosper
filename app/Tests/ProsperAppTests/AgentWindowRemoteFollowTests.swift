import XCTest
@testable import ProsperApp

/// #1555: with a client dch >= 1.62.0 the remote list comes from one `dch --ls-json --remote --follow` child while the
/// window shows. Fakes only: the version, the child and the restart delay are seams; no dch, no process, no window shown.
final class AgentWindowRemoteFollowTests: XCTestCase {

    static func line(_ host: String, _ name: String) -> String {
        #"[{"name":"\#(name)","alias":"","host":"\#(host)","state":"idle","stale":false,"cwd":"/Users/example/\#(name)"}]"#
            + "\n"
    }

    final class FakeFollow: AgentRemoteFollowHandle {
        let args: [String]
        let data: @MainActor @Sendable (Data) -> Void
        let exit: @MainActor @Sendable (Int32) -> Void
        var stops = 0
        init(_ args: [String], _ data: @escaping @MainActor @Sendable (Data) -> Void,
             _ exit: @escaping @MainActor @Sendable (Int32) -> Void) { self.args = args; self.data = data; self.exit = exit }
        func stop() { stops += 1 }
        @MainActor func send(_ s: String) { data(Data(s.utf8)) }
    }

    final class Rig {
        var follows: [FakeFollow] = []
        var delays: [TimeInterval] = []
        var pending: [@MainActor () -> Void] = []
        var clock: TimeInterval = 100
    }

    /// A visible window model on the island's store, the client at `version`, the remote list call on `lister`.
    @MainActor
    func model(_ version: [Int]?, lister: AgentWindowRemoteRowsTests.Lister = .init(nil))
        -> (AgentWindowModel, AgentIslandStore, Rig) {
        let rig = Rig()
        let store = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        let m = AgentWindowModel()
        m.now = { AgentWindowD1Tests.now }
        m.openSession = { _ in }
        m.resume = { _ in }
        m.onVisible = { _ in }
        m.ageInterval = 3600
        m.remoteRun = { args, _ in lister.run(args) }
        m.remoteClock = { rig.clock }
        m.remoteFollowVersion = { version }
        m.remoteFollowStart = { args, _, data, exit in
            let f = FakeFollow(args, data, exit)
            rig.follows.append(f)
            return f
        }
        m.remoteAfter = { delay, work in rig.delays.append(delay); rig.pending.append(work) }
        m.bind(store)
        m.setVisible(true)
        return (m, store, rig)
    }

    // MARK: version gate

    @MainActor
    func testANewEnoughClientListsThroughOneFollowChildAndNoCall() throws {
        for version in [[1, 62, 0], [1, 99, 0], [2, 0]] {
            let lister = AgentWindowRemoteRowsTests.Lister(Self.line("host-a", "api"))
            let (m, _, rig) = model(version, lister: lister)
            defer { m.close() }
            XCTAssertEqual(rig.follows.count, 1, "one child on show, client \(version)")
            XCTAssertEqual(rig.follows.last?.args, ["--ls-json", "--remote", "--follow"])
            m.refresh()
            m.pollRemote()
            XCTAssertEqual(m.remoteFollowStarts, 1, "a refresh never starts a second child")
            XCTAssertEqual(lister.calls, [], "no per-refresh list call while following")
            XCTAssertEqual(m.remoteCalls, 0)
            try XCTUnwrap(rig.follows.last).send(Self.line("host-a", "api"))
            XCTAssertEqual(m.remoteSessions.map(\.name), ["api"], "a line is the new remote rows")
            XCTAssertEqual(m.sections.last?.title, AgentSidebar.otherMachinesTitle)
        }
    }

    @MainActor
    func testAnOlderOrUnknownClientKeepsThePerRefreshCall() {
        for version in [[1, 61, 9], [1, 40, 0], nil] as [[Int]?] {
            let lister = AgentWindowRemoteRowsTests.Lister(Self.line("host-a", "api"))
            let (m, _, rig) = model(version, lister: lister)
            defer { m.close() }
            XCTAssertEqual(rig.follows.count, 0, "no child, client \(String(describing: version))")
            XCTAssertEqual(lister.calls, [["--ls-json", "--remote"]], "today's call on show")
            XCTAssertEqual(m.remoteSessions.map(\.name), ["api"])
        }
    }

    // MARK: lines

    @MainActor
    func testALineSplitAcrossReadsIsTakenOnlyWhole() throws {
        let (m, _, rig) = model([1, 62, 0])
        defer { m.close() }
        let f = try XCTUnwrap(rig.follows.last)
        let whole = Self.line("host-a", "api")
        let cut = whole.index(whole.startIndex, offsetBy: 30)
        f.send(String(whole[..<cut]))
        XCTAssertEqual(m.remoteSessions, [], "half a line is not a list yet")
        f.send(String(whole[cut...]))
        XCTAssertEqual(m.remoteSessions.map(\.name), ["api"], "the rest of it completes the line")
        f.send(Self.line("host-a", "web") + Self.line("host-b", "build"))
        XCTAssertEqual(m.remoteSessions.map(\.name), ["build"], "two lines in one read: the last is the list")

        var lines = AgentRemoteFollowLines()
        XCTAssertEqual(lines.append(Data("a\nb".utf8)), [Data("a".utf8)])
        XCTAssertEqual(lines.append(Data("c\n\n".utf8)), [Data("bc".utf8)], "the kept tail joins; an empty line is none")
        XCTAssertEqual(lines.append(Data()), [])
    }

    /// #1486 B4: the cut tail never grows past the cap; an over-long line is dropped through its newline.
    func testAnOverlongFollowLineIsDroppedAndTheNextGoodLineStillComes() {
        let max = AgentRemoteFollowLines.maxPending
        let good = Data("good\n".utf8)
        var lines = AgentRemoteFollowLines()
        XCTAssertEqual(lines.append(Data(repeating: UInt8(ascii: "x"), count: max + 1)), [])
        XCTAssertTrue(lines.pending.count <= max, "pending never above the cap")
        XCTAssertEqual(lines.append(Data(repeating: UInt8(ascii: "x"), count: 100)), [], "still dropping")
        XCTAssertTrue(lines.pending.count <= max)
        XCTAssertEqual(lines.append(Data("tail\n".utf8) + good), [Data("good".utf8)], "the newline ends the drop")

        var one = AgentRemoteFollowLines()
        XCTAssertEqual(one.append(Data(repeating: UInt8(ascii: "x"), count: max + 1) + Data("\n".utf8) + good),
                       [Data("good".utf8)], "over-long line and good line in one read")
        XCTAssertTrue(one.pending.isEmpty)

        // Exactly max bytes then a newline: not over the cap, so it is emitted like any line.
        var exact = AgentRemoteFollowLines()
        let full = Data(repeating: UInt8(ascii: "y"), count: max)
        XCTAssertEqual(exact.append(full), [])
        XCTAssertEqual(exact.pending.count, max)
        XCTAssertEqual(exact.append(Data("\n".utf8)), [full])

        var split = AgentRemoteFollowLines()
        XCTAssertEqual(split.append(Data("go".utf8)), [])
        XCTAssertEqual(split.append(Data("od\n".utf8)), [Data("good".utf8)], "a good line split across reads joins")
    }

    @MainActor
    func testABadLineKeepsTheLastGoodRows() throws {
        let (m, _, rig) = model([1, 62, 0])
        defer { m.close() }
        let f = try XCTUnwrap(rig.follows.last)
        f.send(Self.line("host-a", "api"))
        for bad in ["not json\n", "{}\n", "[{\"name\":\n"] {
            f.send(bad)
            XCTAssertEqual(m.remoteSessions.map(\.name), ["api"], "a bad line keeps the rows: \(bad)")
        }
        f.send("[]\n")
        XCTAssertEqual(m.remoteSessions, [], "an empty array is a good answer: no remote rows")
    }

    // MARK: exit and restart

    @MainActor
    func testAnExitRestartsTheChildAfterTheBackoff() throws {
        let (m, _, rig) = model([1, 62, 0])
        defer { m.close() }
        try XCTUnwrap(rig.follows.last).send(Self.line("host-a", "api"))
        try XCTUnwrap(rig.follows.last).exit(0)
        XCTAssertEqual(rig.delays, [1], "the first restart waits the backoff's first step")
        m.pollRemote()
        XCTAssertEqual(rig.follows.count, 1, "no child while the backoff runs")
        XCTAssertEqual(m.remoteSessions.map(\.name), ["api"], "an exit keeps the rows")
        try XCTUnwrap(rig.pending.last)()
        XCTAssertEqual(rig.follows.count, 2, "restarted")
        try XCTUnwrap(rig.follows.last).exit(1)
        XCTAssertEqual(rig.delays, [1, 2], "a quick second exit doubles")
        try XCTUnwrap(rig.pending.last)()
        rig.clock += AgentTerminalController.reconnectSettled
        try XCTUnwrap(rig.follows.last).exit(0)
        XCTAssertEqual(rig.delays, [1, 2, 1], "a child that lived reconnectSettled starts the backoff over")
        XCTAssertEqual(rig.follows.count, 3)
    }

    @MainActor
    func testBadUsageHandsTheListBackToTheCall() throws {
        let lister = AgentWindowRemoteRowsTests.Lister(Self.line("host-a", "api"))
        let (m, _, rig) = model([1, 62, 0], lister: lister)
        defer { m.close() }
        try XCTUnwrap(rig.follows.last).exit(2)
        XCTAssertEqual(rig.delays, [], "exit 2 (bad usage) is not restarted")
        XCTAssertEqual(lister.calls, [["--ls-json", "--remote"]], "the per-refresh call takes over")
        XCTAssertEqual(m.remoteSessions.map(\.name), ["api"])
    }

    // MARK: hide, close, island off

    @MainActor
    func testHideStopsTheChildAndDropsItsLateAnswers() throws {
        let (m, store, rig) = model([1, 62, 0])
        defer { m.close() }
        let first = try XCTUnwrap(rig.follows.last)
        first.send(Self.line("host-a", "api"))
        first.exit(0)   // a restart waits
        m.setVisible(false)
        XCTAssertEqual(first.stops, 0, "an exited child is not signalled")
        try XCTUnwrap(rig.pending.last)()
        XCTAssertEqual(rig.follows.count, 1, "the restart after a hide starts nothing")

        m.setVisible(true)
        XCTAssertEqual(rig.follows.count, 2, "showing again starts one child")
        let second = try XCTUnwrap(rig.follows.last)
        m.setVisible(false)
        XCTAssertEqual(second.stops, 1, "hide stops the running child")
        second.send(Self.line("host-b", "build"))
        second.exit(15)
        XCTAssertEqual(m.remoteSessions.map(\.name), ["api"], "its late line is dropped")
        XCTAssertEqual(rig.delays, [1], "its late exit restarts nothing")

        m.setVisible(true)
        let third = try XCTUnwrap(rig.follows.last)
        m.bind(nil)
        XCTAssertEqual(third.stops, 1, "the island off stops it")
        m.bind(store)
        m.pollRemote()
        let fourth = try XCTUnwrap(rig.follows.last)
        XCTAssertEqual(rig.follows.count, 4)
        m.close()
        XCTAssertEqual(fourth.stops, 1, "close stops it")
        m.pollRemote()
        XCTAssertEqual(rig.follows.count, 4, "closed: none")
    }

    /// #1881: a restart queued before a hide, run after the show again while the new child's own restart waits, starts
    /// nothing (red with the generation check gone, mutant late-restart-runs: it would start a child before the backoff).
    @MainActor
    func testARestartQueuedBeforeAHideStartsNothingAfterTheShowAgain() throws {
        let (m, _, rig) = model([1, 62, 0])
        defer { m.close() }
        try XCTUnwrap(rig.follows.last).exit(0)   // its restart waits
        let stale = try XCTUnwrap(rig.pending.last)
        m.setVisible(false)
        m.setVisible(true)
        XCTAssertEqual(rig.follows.count, 2, "showing again starts one child")
        try XCTUnwrap(rig.follows.last).exit(0)   // the new child's restart waits its backoff
        XCTAssertEqual(rig.pending.count, 2)
        stale()
        XCTAssertEqual(rig.follows.count, 2, "the restart queued before the hide starts nothing")
        try XCTUnwrap(rig.pending.last)()
        XCTAssertEqual(rig.follows.count, 3, "the current restart does")
    }

    // MARK: #896 ask 2: remote scrollback (no code change)

    /// dch >= 1.40.0's client forwards `--scrollback` as the remote frame's "scrollback" key: the remote attach carries it.
    @MainActor
    func testARemoteAttachCarriesScrollback() {
        let key = AgentTerminalSpawn.remoteKey(host: "host-a", name: "api")
        let s = AgentTerminalSpawn.attach(key, cols: 80, rows: 24, dch: "/opt/example/bin/dch", env: [:])
            .scrollback(2000)
        XCTAssertEqual(s.args, ["-E", "--host", "host-a", "-a", "api", "--scrollback", "2000"])
    }
}

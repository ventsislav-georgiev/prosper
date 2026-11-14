import XCTest
@testable import ProsperApp

/// #900 (#831 B2, N900-d and N900-e; spec 4.1a, 4.4, 11.2): with the split gate on, a publish stamps every pane of the
/// active layout of a visible window (a zoomed-away or too-small hidden pane too), and a suspended pane whose session
/// ends is Ended with its blocks kept and nothing read. Model only: no window shown, nothing posted. Sessions and
/// records are fakes (/tmp/dch-test, literal ids); transcripts are files under tempDir(); reads are counted on each
/// pane's offMain seam; time is the model's injected clock. Every row saves, sets and restores the gate (withTreeGate).
extension AgentWindowD1Tests {
    static let stampA = "0b7c2f3e-aaaa-2222-3333-444455556666"
    static let stampB = "0b7c2f3e-bbbb-2222-3333-444455556666"

    /// Panes "web" (focused) and "api" in columns in the wide area, both live; "api" is instance A. Not yet visible.
    @MainActor
    func stampFixture() throws -> (m: AgentWindowModel, st: AgentIslandStore, log: ZoomModelLog) {
        let web = session("web", .idle, path: try transcriptFile("web").path)
        var api = session("api", .idle, path: try transcriptFile("api").path)
        api.claudeSessionID = Self.stampA
        let st = store([web, api])
        let m = windowModel(st)
        m.paneArea = Self.wideArea
        m.adopt(paneLayout([paneTarget("web"), paneTarget("api")]))
        let log = ZoomModelLog()
        for n in ["web", "api"] {
            let t = try runtime(m, n).transcript
            t.offMain = { job in log.polls[n, default: 0] += 1; job() }   // on main, where poll() calls it
            t.taskStoreDirectory = { _ in nil }
        }
        return (m, st, log)
    }

    @MainActor
    func stampEntry(_ m: AgentWindowModel, _ name: String) throws -> LastLive? {
        m.lastLive[AgentPaneLayout.PaneSlot(layout: m.layout.id, pane: try paneID(m, name))]
    }

    /// The instance B of "api" (a new Claude session id; no transcript mapped).
    func instanceB() -> AgentSession {
        var b = session("api", .idle)
        b.claudeSessionID = Self.stampB
        return b
    }

    func stampRecord(_ id: String, file: String? = nil) -> DchHistoryRecord {
        var r = record("api", ago: 0)
        if let file { r.file = file }
        r.agent = DchHistoryRecord.Agent(kind: "claude", sessionID: id)
        return r
    }

    /// QA 996 (N900-d): stamped for A while shown, zoomed away, A ends, B live under the same name, B ends, unzoom: the
    /// pane resolves to B's record (the parent's stale stamp, A's id, bound it to A's record).
    @MainActor
    func testZoomStampAZoomedAwayPaneResolvesToTheLastInstancesRecord() throws {
        try withTreeGate(true) {
            let (m, st, _) = try stampFixture()
            defer { m.close() }
            m.setVisible(true)
            let web = try XCTUnwrap(st.sessions.first { $0.key.name == "web" })
            st.sessions = st.sessions   // a publish while api shows: stamped for A
            XCTAssertEqual(try stampEntry(m, "api")?.claudeSessionID, Self.stampA)
            XCTAssertTrue(m.perform(.zoom))   // web zoomed, api zoomed away
            XCTAssertEqual(m.shownPanes, [try paneID(m, "web")])
            let recA = stampRecord(Self.stampA, file: "api.1700000000")
            st.history = [recA]
            st.sessions = [web]                // A ended
            st.sessions = [web, instanceB()]      // B live under the same name
            let recB = stampRecord(Self.stampB)
            XCTAssertNotEqual(recA.id, recB.id)
            st.history = [recA, recB]
            st.sessions = [web]                // B ended
            XCTAssertTrue(m.perform(.zoom))
            XCTAssertTrue(m.layout.zoomed == nil)
            let api = try runtime(m, "api")
            XCTAssertEqual(AgentWindowModel.resolvedRow(api.content), .history(recB.id), "B's own record, never A's")
        }
    }

    /// N900-d: a zoomed-away pane is stamped by a publish that lists it live: the entry carries that publish's time
    /// (the injected clock) and B's Claude session id.
    @MainActor
    func testZoomStampAZoomedAwayPaneIsStampedByAPublish() throws {
        try withTreeGate(true) {
            let (m, st, _) = try stampFixture()
            defer { m.close() }
            m.setVisible(true)
            let web = try XCTUnwrap(st.sessions.first { $0.key.name == "web" })
            XCTAssertTrue(m.perform(.zoom))
            m.now = { Self.now + 30 }
            st.sessions = [web, instanceB()]
            XCTAssertEqual(try stampEntry(m, "api"), LastLive(at: Self.now + 30, claudeSessionID: Self.stampB))
            XCTAssertEqual(try stampEntry(m, "web"), LastLive(at: Self.now + 30, claudeSessionID: web.claudeSessionID ?? ""))
        }
    }

    /// 4.1a: a hidden window stamps nothing (gate on), never shown or hidden after a sight.
    @MainActor
    func testZoomStampAHiddenWindowStampsNothing() throws {
        try withTreeGate(true) {
            let (m, st, _) = try stampFixture()
            defer { m.close() }
            st.sessions = st.sessions   // never shown
            XCTAssertTrue(m.lastLive.isEmpty, "never shown: no sight")
            m.setVisible(true)
            st.sessions = st.sessions
            let before = m.lastLive
            XCTAssertEqual(before.count, 2)
            m.setVisible(false)
            m.now = { Self.now + 30 }
            st.sessions = st.sessions.map { $0.key.name == "api" ? instanceB() : $0 }
            XCTAssertEqual(m.lastLive, before, "hidden: the map unchanged")
        }
    }

    /// 4.1a: an inactive layout's panes keep their last stamp; the active layout's panes take the publish's time.
    @MainActor
    func testZoomStampAnInactiveLayoutIsNotStamped() throws {
        try withTreeGate(true) {
            let (m, st, _) = try stampFixture()
            defer { m.close() }
            m.setVisible(true)
            st.sessions = st.sessions
            let first = m.layout
            let old = m.lastLive
            XCTAssertEqual(old.count, 2)
            m.adopt(paneLayout([paneTarget("api"), paneTarget("web")]))   // another layout id
            XCTAssertNotEqual(m.layout.id, first.id)
            m.now = { Self.now + 30 }
            st.sessions = st.sessions
            for p in first.order {
                let slot = AgentPaneLayout.PaneSlot(layout: first.id, pane: p)
                XCTAssertEqual(m.lastLive[slot], old[slot], "the inactive layout keeps its stamp")
            }
            for p in m.layout.order {
                XCTAssertEqual(m.lastLive[AgentPaneLayout.PaneSlot(layout: m.layout.id, pane: p)]?.at, Self.now + 30)
            }
        }
    }

    /// 15.0: with the gate off the stamped set is the focused pane alone, as before (a zoomed blob changes nothing).
    @MainActor
    func testZoomStampGateOffStampsTheFocusedPaneAlone() throws {
        try withTreeGate(false) {
            let (m, st, _) = try stampFixture()
            defer { m.close() }
            m.setVisible(true)
            st.sessions = st.sessions
            let web = AgentPaneLayout.PaneSlot(layout: m.layout.id, pane: try paneID(m, "web"))
            XCTAssertEqual(Set(m.lastLive.keys), [web])
            m.adopt(m.layout.toggleZoom())
            st.sessions = st.sessions
            XCTAssertEqual(Set(m.lastLive.keys), [web])
        }
    }

    /// N900-e (4.4, 4.4 (c)): a session that ends while its pane is zoomed away: the pane is Ended with its blocks
    /// kept; unzoomed it stays Ended, suspended, and reads NOTHING (counted on the fake).
    @MainActor
    func testZoomStampASessionEndedWhileZoomedAwayIsEndedWithNoRead() throws {
        try withTreeGate(true) {
            let (m, st, log) = try stampFixture()
            defer { m.close() }
            m.setVisible(true)
            st.sessions = st.sessions
            let web = try XCTUnwrap(st.sessions.first { $0.key.name == "web" })
            XCTAssertTrue(m.perform(.zoom))
            let api = try runtime(m, "api")
            XCTAssertTrue(api.transcript.suspended)
            XCTAssertEqual(api.transcript.blocks.count, 1)
            let reads = log.polls["api"] ?? 0
            st.sessions = [web]   // api ended while zoomed away
            XCTAssertTrue(api.ended != nil, "Ended while zoomed away")
            XCTAssertTrue(m.perform(.zoom))
            XCTAssertTrue(m.layout.zoomed == nil)
            XCTAssertTrue(api.ended != nil, "unzoomed: Ended")
            XCTAssertTrue(!api.transcript.running && api.transcript.suspended)
            XCTAssertEqual(api.transcript.blocks.count, 1, "its blocks kept")
            XCTAssertEqual(log.polls["api"] ?? 0, reads, "zero reads")
        }
    }

    /// 3.4: the too-small fallback's hidden pane follows both rules: a publish stamps it, and a session that ends while
    /// it is hidden is Ended with its blocks kept and no read when the area grows back.
    @MainActor
    func testZoomStampTheTooSmallHiddenPaneIsStampedAndEnded() throws {
        try withTreeGate(true) {
            let (m, st, log) = try stampFixture()
            defer { m.close() }
            m.setVisible(true)   // wide: both run, api holds its one block
            m.paneArea = CGRect(x: 0, y: 0, width: 300, height: 300)
            XCTAssertEqual(m.shownPanes, [try paneID(m, "web")])
            let api = try runtime(m, "api")
            XCTAssertTrue(api.transcript.suspended)
            let web = try XCTUnwrap(st.sessions.first { $0.key.name == "web" })
            m.now = { Self.now + 30 }
            st.sessions = st.sessions   // a publish while api is hidden by the small area
            XCTAssertEqual(try stampEntry(m, "api"), LastLive(at: Self.now + 30, claudeSessionID: Self.stampA))
            let blocks = api.transcript.blocks.count
            XCTAssertEqual(blocks, 1)
            let reads = log.polls["api"] ?? 0
            st.sessions = [web]   // ended while too-small hidden
            XCTAssertTrue(api.ended != nil, "Ended while hidden by the small area")
            m.paneArea = Self.wideArea
            XCTAssertTrue(api.ended != nil)
            XCTAssertTrue(!api.transcript.running && api.transcript.suspended)
            XCTAssertEqual(api.transcript.blocks.count, blocks, "its blocks kept")
            XCTAssertEqual(log.polls["api"] ?? 0, reads, "zero reads")
        }
    }
}

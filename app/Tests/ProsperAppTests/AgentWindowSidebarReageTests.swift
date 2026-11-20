import Combine
import XCTest
@testable import ProsperApp

/// #1634: a list where only activity (or the clock) moved re-ages the sidebar's rows instead of building
/// `AgentSidebar.sections` again, and publishes nothing when no age changed; and the remote list call of a client dch
/// older than 1.62 backs off while its answers change nothing. Rows count builds, publishes and calls, never time.
/// Fakes only: the store, the list call and the clock are seams; no dch, no window shown.
final class AgentWindowSidebarReageTests: XCTestCase {

    static let dir = AgentWindowRemoteRowsTests.dir
    static let now = AgentWindowD1Tests.now

    static func session(_ name: String, _ state: AgentState, ago: TimeInterval, alias: String = "") -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: dir, name: name), alias: alias, activity: now - ago, state: state, agents: 0,
                     meta: nil, version: "1.80.0")
    }

    static func key(_ name: String) -> AgentSidebar.RowID { .live(AgentSessionKey(dir: dir, name: name)) }

    /// api idle (Sessions), web done (Needs you), build working, and one History record.
    static func list(_ shift: TimeInterval = 0) -> [AgentSession] {
        [session("api", .idle, ago: 70 + shift), session("web", .done, ago: 75 + shift), session("build", .working, ago: shift)]
    }

    static let record = DchHistoryRecord(key: AgentSessionKey(dir: dir, name: "old"), ended: now - 300, end: "exit 0")

    @MainActor
    func model() -> (AgentWindowModel, AgentIslandStore) {
        let (m, store, _) = AgentWindowRemoteRowsTests().model(AgentWindowRemoteRowsTests.Lister(nil), sessions: Self.list())
        store.history = [Self.record]
        return (m, store)
    }

    @MainActor
    func testActivityOnlyUpdatesBuildNoSectionsAndPublishOnlyAnAgeThatChanged() {
        let (m, store) = model()
        defer { m.close() }
        var publishes = 0
        let sub = m.$sections.dropFirst().sink { _ in publishes += 1 }
        defer { sub.cancel() }
        let builds = m.sectionBuilds
        XCTAssertEqual(m.row(Self.key("api"))?.age, "1m")
        // 20 activity-only lists (the same sessions, states, titles and order), every age the same: no build, no publish.
        for i in 1...20 { store.sessions = Self.list(TimeInterval(i)) }
        XCTAssertEqual(m.sectionBuilds, builds, "activity-only lists build no sections")
        XCTAssertEqual(publishes, 0, "no age changed: nothing publishes")
        // One more where api's age moves to 2m: still no build, one publish, the rows as a full build gives them.
        let aged = Self.list(60)
        store.sessions = aged
        XCTAssertEqual(m.sectionBuilds, builds)
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(m.row(Self.key("api"))?.age, "2m")
        XCTAssertTrue(m.row(Self.key("api"))?.session == aged.first, "a publish carries the sessions of the list")
        let full = AgentSidebar.sections(sessions: aged, history: [Self.record], sort: store.sort,
                                         sidekickPattern: store.sidekickPattern, details: store.details, now: Self.now)
        XCTAssertTrue(m.sections == full, "re-aged rows equal a full build's")
        // The age clock with the same lists: History's age moves with the clock, no build.
        m.now = { Self.now + 3600 }
        m.refresh()
        XCTAssertEqual(m.sectionBuilds, builds, "the age tick builds nothing")
        XCTAssertEqual(publishes, 2)
        XCTAssertEqual(m.row(.history(Self.record.id))?.age, "1h")
        XCTAssertEqual(m.row(Self.key("api"))?.age, "1h")
    }

    @MainActor
    func testATitleOrderAddOrRemoveBuildsOnce() {
        let (m, store) = model()
        defer { m.close() }
        var builds = m.sectionBuilds
        func step(_ list: [AgentSession], _ why: String) {
            store.sessions = list
            XCTAssertEqual(m.sectionBuilds, builds + 1, why)
            builds = m.sectionBuilds
            let full = AgentSidebar.sections(sessions: list, history: [Self.record], sort: store.sort,
                                             sidekickPattern: store.sidekickPattern, details: store.details, now: Self.now)
            XCTAssertTrue(m.sections == full, "a full build's rows: \(why)")
        }
        var l = Self.list()
        l[0] = Self.session("api", .idle, ago: 70, alias: "Example task")
        step(l, "a title")
        XCTAssertEqual(m.row(Self.key("api"))?.title, "Example task")
        l.append(Self.session("docs", .idle, ago: 80))
        step(l, "an added session")
        // build (working) sorts ahead of the idle api and docs (state first, then activity).
        XCTAssertEqual(m.sections.first { $0.title == "Sessions" }?.rows.map(\.id),
                       [Self.key("build"), Self.key("api"), Self.key("docs")])
        // docs' activity now newer than api's: under the activity sort the two swap places.
        l[3] = Self.session("docs", .idle, ago: 10)
        step(l, "an order")
        XCTAssertEqual(m.sections.first { $0.title == "Sessions" }?.rows.map(\.id),
                       [Self.key("build"), Self.key("docs"), Self.key("api")])
        l.removeLast()
        step(l, "a removed session")
        store.history = []
        XCTAssertEqual(m.sectionBuilds, builds + 1, "History changed")
    }

    /// Island off then on with the same lists: bind(nil) emptied the sections, so the rebind builds them again.
    @MainActor
    func testTheIslandBackRebuildsTheSectionsItsOffEmptied() {
        let (m, store) = model()
        defer { m.close() }
        let builds = m.sectionBuilds
        m.bind(nil)
        XCTAssertTrue(m.sections.isEmpty)
        m.bind(store)
        XCTAssertEqual(m.sectionBuilds, builds + 1)
        XCTAssertEqual(m.row(Self.key("api"))?.age, "1m")
    }

    @MainActor
    func testReagedRefusesAMissingSessionOrAnOrderTheActivityTurned() throws {
        let a = Self.session("a", .done, ago: 10), b = Self.session("b", .done, ago: 20)
        let built = AgentSidebar.sections(sessions: [a, b], history: [], sort: .activity, sidekickPattern: "",
                                          details: .all, now: Self.now)
        XCTAssertEqual(built.first?.title, AgentSidebar.needsYouTitle)
        XCTAssertTrue(AgentSidebar.reaged(built, sessions: [a, b], sort: .activity, now: Self.now) == built)
        XCTAssertTrue(AgentSidebar.reaged(built, sessions: [a], sort: .activity, now: Self.now) == nil, "a gone session")
        let turned = [Self.session("a", .done, ago: 30), b]
        XCTAssertTrue(AgentSidebar.reaged(built, sessions: turned, sort: .activity, now: Self.now) == nil, "Needs you turned")
        let x = Self.session("x", .idle, ago: 10), y = Self.session("y", .idle, ago: 20)
        for sort in [AgentIslandSort.activity, .name] {
            let idle = AgentSidebar.sections(sessions: [x, y], history: [], sort: sort, sidekickPattern: "",
                                             details: .all, now: Self.now)
            let swapped = [Self.session("x", .idle, ago: 30), y]
            let r = AgentSidebar.reaged(idle, sessions: swapped, sort: sort, now: Self.now)
            XCTAssertEqual(r == nil, sort == .activity, "only the activity sort reads activity (\(sort))")
        }
    }

    // MARK: pollRemote's idle backoff (dch < 1.62)

    @MainActor
    func testAQuietRemoteListBacksOffToTenSecondsAndAChangeStartsItOver() {
        let lister = AgentWindowRemoteRowsTests.Lister(AgentWindowRemoteRowsTests.fixture)
        let (m, _, log) = AgentWindowRemoteRowsTests().model(lister, sessions: [])
        defer { m.close() }
        XCTAssertEqual(lister.calls.count, 1, "one call on show")
        // A refresh every second for a minute, the answer never changing: 2, 4, 8, then every 10 s (31 calls before).
        for _ in 1...60 {
            log.clock += 1
            m.refresh()
        }
        XCTAssertEqual(lister.calls.count, 8, "calls at 102, 106, 114, 124, 134, 144, 154")
        XCTAssertEqual(m.remoteGap, AgentWindowModel.remoteIdleMax)
        // A change in the answer: the next call takes it, and the spacing is back to dch's 2 s.
        lister.answer(#"[{"name":"api","alias":"","host":"host-a","state":"idle","stale":false,"cwd":null}]"#)
        log.clock += 4   // 164: ten seconds after the last call
        m.refresh()
        XCTAssertEqual(lister.calls.count, 9)
        XCTAssertEqual(m.remoteGap, AgentWindowModel.remoteEvery, "a change starts the spacing over")
        log.clock += AgentWindowModel.remoteEvery
        m.refresh()
        XCTAssertEqual(lister.calls.count, 10)
        XCTAssertEqual(m.remoteGap, 2 * AgentWindowModel.remoteEvery, "the same answer again: doubled")
    }

    @MainActor
    func testAFollowingClientNeverRunsTheListCallOverAQuietStretch() {
        let lister = AgentWindowRemoteRowsTests.Lister(AgentWindowRemoteRowsTests.fixture)
        let (m, _, rig) = AgentWindowRemoteFollowTests().model([1, 62, 0], lister: lister)
        defer { m.close() }
        for _ in 1...60 {
            rig.clock += 1
            m.refresh()
        }
        XCTAssertEqual(m.remoteCalls, 0)
        XCTAssertEqual(lister.calls, [], "dch >= 1.62 follows: no list call, as before")
        XCTAssertEqual(m.remoteFollowStarts, 1)
        XCTAssertEqual(m.remoteGap, AgentWindowModel.remoteEvery, "untouched while following")
    }

    /// A remote Start waiting for its row: the list at once, then every 2 s while it is awaited however often the answer
    /// is the same (the person is waiting for it); once the row lands and is selected, a quiet answer doubles again.
    @MainActor
    func testARemoteStartWaitingForItsRowListsAtDchsPaceUntilItLands() throws {
        let spawn = AgentWindowRemoteSpawnTests()
        try spawn.withPrefs {
            let lister = AgentWindowRemoteRowsTests.Lister(AgentWindowRemoteRowsTests.fixture)
            let (m, log, calls) = spawn.model(lister)
            defer { m.close() }
            m.setNewSessionHost("host-a")
            m.setNewSessionFolder("/Users/example/site")
            m.setNewSessionName("site")   // #1731: the name is typed, not derived from the folder
            XCTAssertTrue(m.startNewSession())
            let before = m.remoteCalls
            calls.done?(DchActionResult(status: 0))
            spawn.rows.spin { m.pendingSpawn != nil }
            XCTAssertEqual(m.remoteCalls, before + 1, "the list at once")
            XCTAssertEqual(m.remoteGap, AgentWindowModel.remoteEvery)
            for i in 1...3 {
                log.clock += AgentWindowModel.remoteEvery
                m.refresh()
                XCTAssertEqual(m.remoteCalls, before + 1 + i, "awaited: listed at dch's 2 s (\(i))")
                XCTAssertEqual(m.remoteGap, AgentWindowModel.remoteEvery, "awaited: the spacing never grows (\(i))")
            }
            let site = #"{"name":"site","alias":"","host":"host-a","state":"idle","stale":false,"cwd":"/Users/example/site"}"#
            lister.answer("[" + site + "," + AgentWindowRemoteRowsTests.fixture.dropFirst())
            log.clock += AgentWindowModel.remoteEvery
            m.refresh()
            XCTAssertEqual(m.selection, .remote(host: "host-a", name: "site"))
            XCTAssertTrue(m.pendingSpawn == nil, "landed")
            log.clock += AgentWindowModel.remoteEvery
            m.refresh()
            XCTAssertEqual(m.remoteCalls, before + 6)
            XCTAssertEqual(m.remoteGap, 2 * AgentWindowModel.remoteEvery, "landed: a quiet answer doubles again")
        }
    }

    /// A remote Resume's answer: the list at once, and that call, the same answer as before, does not double the
    /// spacing, so the resumed session is looked for again 2 s later.
    @MainActor
    func testAListRunAtOnceAfterARemoteResumeKeepsDchsPace() throws {
        let history = AgentWindowRemoteHistoryTests()
        let verbs = AgentWindowRemoteHistoryTests.Verbs()
        let (m, _, log) = history.model(AgentWindowRemoteRowsTests.Lister(AgentWindowRemoteHistoryTests.fixture), verbs: verbs)
        defer { m.close() }
        let docs = try XCTUnwrap(m.row(.history(AgentWindowRemoteHistoryTests.key("host-a", "docs")))?.record)
        m.resumeRemote(docs)
        XCTAssertEqual(verbs.calls.count, 1)
        let before = m.remoteCalls
        verbs.done?(DchActionResult(status: 0))
        history.spin { m.remoteCalls > before }
        XCTAssertEqual(m.remoteCalls, before + 1, "the list at once")
        XCTAssertEqual(m.remoteGap, AgentWindowModel.remoteEvery, "the list at once never doubles")
        log.clock += AgentWindowModel.remoteEvery
        m.refresh()
        XCTAssertEqual(m.remoteCalls, before + 2, "looked for again at dch's 2 s")
    }
}

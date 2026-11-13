import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1114: a session row's age (the Agents window's sidebar, the island's rows, History). No seconds ("now" under a
/// minute), nothing on a working row, and the window's label never more than one age-clock tick behind. Offscreen
/// only: the accessibility test builds its tree in a never-shown window, as AgentWindowNewSessionFollowUpTests does.
final class AgentRowAgeTests: XCTestCase {

    static let now: TimeInterval = 1_800_000_000
    static let dir = "/tmp/dch-test"

    func session(_ name: String, _ state: AgentState, ago: TimeInterval) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: Self.dir, name: name), alias: "", activity: Self.now - ago, state: state,
                     agents: 0)
    }

    func record(_ name: String, ago: TimeInterval) -> DchHistoryRecord {
        var r = DchHistoryRecord(key: AgentSessionKey(dir: Self.dir, name: name))
        r.cwd = "/Users/example/\(name)"
        r.ended = Self.now - ago
        r.updated = Self.now - ago
        r.end = "exit 0"
        return r
    }

    // MARK: The formatter

    func testAgeFormatterHasNoSeconds() {
        let m = 60.0, h = 3600.0, d = 86400.0, y = 365 * d
        let cases: [(TimeInterval, String)] = [
            (0, "now"), (59, "now"), (59.9, "now"), (m, "1m"), (m + 1, "1m"), (59 * m + 59, "59m"), (h, "1h"),
            (23 * h + 59 * m, "23h"), (d, "1d"), (364 * d, "364d"), (y, "1y"),
            (-5, "now"),            // the clock moved back a little
            (1e12, "99y"),          // a very large difference
        ]
        for (s, want) in cases { XCTAssertEqual(AgentIsland.age(s), want, "\(s)") }
        XCTAssertEqual(AgentIsland.ago(""), nil, "no age, nothing to read")
        XCTAssertEqual(AgentIsland.ago("now"), "just now")
        XCTAssertEqual(AgentIsland.ago("4m"), "4m ago")
        XCTAssertEqual(AgentIsland.ageWidest, "000d", "364d stays the widest text; the slot test measures \"now\" too")
    }

    /// The age is now minus a file's mtime (or a History record's dch timestamp): a far-future, zero-like or broken
    /// value never reaches Int( out of range. Its own test, so a trap names it.
    func testAgeFormatterSurvivesOutsideValues() {
        let cases: [(TimeInterval, String)] = [
            (-1e300, "now"), (-.infinity, "now"), (.nan, "now"), (-Double.greatestFiniteMagnitude, "now"),
            (1e300, "99y"), (.infinity, "99y"), (Self.now, "57y"),   // activity 0 seen raw: 1970
        ]
        for (s, want) in cases { XCTAssertEqual(AgentIsland.age(s), want, "\(s)") }
        // A far-future mtime and a far-future History stamp, through the row builders.
        var s = session("api", .idle, ago: 0)
        s.activity = 1e300
        XCTAssertEqual(AgentIsland.age(of: s, now: Self.now), "now")
        XCTAssertEqual(AgentSidebar.row(record("old", ago: -1e300), now: Self.now).age, "now")
    }

    // MARK: Which rows show an age

    func testOnlyAWorkingRowShowsNoAge() {
        let table: [(AgentState, String, String)] = [
            (.working, "", "api, Working"),
            (.blocked, "4m", "api, Needs input, 4m ago"),
            (.done, "4m", "api, Done, 4m ago"),
            (.idle, "4m", "api, Idle, 4m ago"),
        ]
        XCTAssertEqual(Set(table.map { $0.0 }), Set(AgentState.allCases), "every state has a row")
        for (state, age, label) in table {
            let s = session("api", state, ago: 240)
            XCTAssertEqual(AgentIsland.age(of: s, now: Self.now), age, "\(state): the island's row")
            XCTAssertEqual(AgentSidebar.row(s, details: .all, now: Self.now).age, age, "\(state): the window's row")
            XCTAssertEqual(AgentIsland.rowAccessibilityLabel(s, now: Self.now), label, "\(state): the island's label")
        }
        // Under a minute: "now", read as "just now"; a working row still nothing.
        XCTAssertEqual(AgentIsland.rowAccessibilityLabel(session("api", .done, ago: 12), now: Self.now), "api, Done, just now")
        XCTAssertEqual(AgentIsland.rowAccessibilityLabel(session("api", .working, ago: 600), now: Self.now), "api, Working")
        // History keeps its age, by the same formatter.
        XCTAssertEqual(AgentSidebar.row(record("old", ago: 7200), now: Self.now).age, "2h")
        XCTAssertEqual(AgentSidebar.row(record("old", ago: 30), now: Self.now).age, "now")
        let r = record("old", ago: 30)
        XCTAssertEqual(AgentIsland.historyRowAccessibilityLabel(r, status: nil, end: "exit 0",
                                                               age: AgentIsland.age(Self.now - r.lastSeen), cwd: "~/old"),
                       "old, exit 0, just now, ~/old")
        XCTAssertEqual(AgentSidebar.row(session("unknown", .done, ago: Self.now), details: .all, now: Self.now).age, "",
                       "no activity stamp, no age")
    }

    // MARK: The window's bound

    static let geometry = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    /// The bound: while the window is visible its clock rebuilds the rows every `ageInterval` (30 s), so a label is
    /// never more than 30 s behind the real age: with whole minutes, at most one minute low, for at most 30 s past
    /// the minute. Pinned on the model's clock seam (`now`, the clock's own tick), no wait.
    @MainActor
    func testWindowAgeIsNeverMoreThanOneTickBehind() throws {
        var t = Self.now
        let st = AgentIslandStore(geometry: Self.geometry)
        st.sessions = [session("api", .idle, ago: 59)]
        let m = AgentWindowModel()
        defer { m.close() }
        m.now = { t }
        m.openSession = { _ in }
        m.resume = { _ in }
        m.onVisible = { _ in }
        m.transcript.offMain = { $0() }
        m.transcript.makeWatch = { _, _ in NSObject() }
        m.transcript.tickInterval = 3600
        XCTAssertEqual(m.ageInterval, 30, "the window's age clock")
        m.bind(st)
        m.setVisible(true)
        let clock = try XCTUnwrap(m.clock)
        XCTAssertEqual(clock.timeInterval, m.ageInterval, "the clock ticks at ageInterval")
        func shown() -> String? { m.sections.flatMap(\.rows).first?.age }
        XCTAssertEqual(shown(), "now", "59 s")

        t += m.ageInterval   // 89 s: the label is a tick old, one minute low
        XCTAssertEqual(shown(), "now")
        clock.fire()
        XCTAssertEqual(shown(), "1m", "the tick catches up")

        // Every tick over ten minutes: the label is the real age at the tick, and until the next tick the real age
        // is at most one minute more.
        let act = Self.now - 59
        for _ in 0..<20 {
            t += m.ageInterval
            clock.fire()
            XCTAssertEqual(shown(), AgentIsland.age(t - act), "at \(t - act) s")
            let lowest = Int((t - act) / 60), highest = Int((t + m.ageInterval - 0.001 - act) / 60)
            XCTAssertLessThanOrEqual(highest - lowest, 1, "at most one minute low before the next tick")
        }
    }

    // MARK: VoiceOver, from the real accessibility tree

    /// Every element under `e` in an AX client's walk (accessibilityChildren), depth first: its label.
    @MainActor
    func axLabels(_ e: Any, _ out: inout [String], depth: Int = 0) {
        guard depth < 40, let o = e as? NSObject else { return }
        let v = o.value(forKey: "accessibilityLabel")
        out.append((v as? String) ?? (v as? NSAttributedString)?.string ?? "")
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { axLabels(k, &out, depth: depth + 1) }
    }

    /// The sidebar row's label as VoiceOver reads it: "<age> ago", "just now" under a minute, nothing on a working
    /// row. SwiftUI builds the tree in a never-shown window once this process (only) is asked to, as an AX client's
    /// attribute write would; both attributes are put back after.
    @MainActor
    func testSidebarRowAccessibilityLabelReadsTheAge() {
        let set = Selector(("accessibilitySetValue:forAttribute:")), attrs = ["AXEnhancedUserInterface", "AXManualAccessibility"]
        let app = NSApplication.shared
        XCTAssertTrue(app.responds(to: set))
        defer { for a in attrs { app.perform(set, with: NSNumber(value: false), with: a) } }
        let rows = [AgentSidebar.row(session("api", .working, ago: 600), details: .all, now: Self.now),
                    AgentSidebar.row(session("api-qa", .done, ago: 12), details: .all, now: Self.now),
                    AgentSidebar.row(session("api-dev", .idle, ago: 240), details: .all, now: Self.now),
                    AgentSidebar.row(record("api-old", ago: 7200), now: Self.now)]
        let size = CGSize(width: 300, height: 300)
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            ForEach(rows) { AgentSidebarRowView(row: $0, selected: false) }
        })
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        for a in attrs { app.perform(set, with: NSNumber(value: true), with: a) }
        var labels: [String] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            var all: [String] = []
            axLabels(host, &all)
            labels = all.filter { $0.hasPrefix("api") }
        } while labels.count < rows.count && Date() < deadline
        XCTAssertEqual(labels, ["api, Working",
                                "api-qa, Done, just now",
                                "api-dev, Idle, 4m ago",
                                "api-old, Ended · exited, 2h ago"])
        XCTAssertFalse(win.isVisible, "never shown")
    }
}

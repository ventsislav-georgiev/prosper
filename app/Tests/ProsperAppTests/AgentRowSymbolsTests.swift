import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1115: a session row's agents and pull request counts as an SF Symbol plus a number (the Agent Sessions sidebar
/// row and the session header), their words for VoiceOver, the fit at every UI scale and the ViewThatFits order; the
/// age clock in the common run-loop mode (R1115-1) and the live row's fixed age slot (R1115-2). Offscreen only: views
/// are rendered or hosted in windows that are never shown, and no event is posted.
extension AgentWindowD1Tests {

    func symbolsSession(_ name: String, _ state: AgentState, agents: Int, merged: Int?, open: Int,
                        ago: TimeInterval = 240) -> AgentSession {
        let prs = (0..<open).map {
            DchSessionMeta.PR(url: "https://github.com/acme/api/pull/\($0 + 1)", repo: "acme/api", num: $0 + 1, title: "t")
        }
        return session(name, state, ago: ago, agents: agents, meta: DchSessionMeta(openPRs: prs, merged: merged))
    }

    // MARK: The symbols and their words

    /// The git set, written out: one symbol per count, merged and open never swapped, each present on this OS.
    func testRowSymbolsAreTheGitSetAndExist() {
        XCTAssertEqual(AgentSidebar.Count.allCases.map(\.symbol), ["person.2", "arrow.triangle.merge", "arrow.triangle.pull"])
        XCTAssertTrue(NSImage(systemSymbolName: "person.2", accessibilityDescription: nil) != nil, "person.2")
        XCTAssertTrue(NSImage(systemSymbolName: "arrow.triangle.merge", accessibilityDescription: nil) != nil, "arrow.triangle.merge")
        XCTAssertTrue(NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil) != nil, "arrow.triangle.pull")
        XCTAssertEqual(AgentSidebar.Count.allCases.map { $0.words(1) }, ["1 agent", "1 merged pull request", "1 open pull request"])
        XCTAssertEqual(AgentSidebar.Count.allCases.map { $0.words(192) },
                       ["192 agents", "192 merged pull requests", "192 open pull requests"])
        XCTAssertEqual(AgentSidebar.Count.merged.words(100_000), "99999+ merged pull requests", "the drawn cap")
    }

    /// The Row carries the numbers as fields, per Row details switch; the detail is the state text alone.
    func testRowSymbolsFieldsFollowEachRowDetailsSwitch() {
        let s = symbolsSession("api", .working, agents: 3, merged: 192, open: 8)
        typealias D = AgentIslandRowDetails
        let table: [(String, D, [Int], [String])] = [
            ("all", .all, [3, 192, 8], ["3 agents", "192 merged pull requests", "8 open pull requests"]),
            ("agents off", D(agents: false, openPRs: true, merged: true), [0, 192, 8],
             ["192 merged pull requests", "8 open pull requests"]),
            ("open off", D(agents: true, openPRs: false, merged: true), [3, 192, 0], ["3 agents", "192 merged pull requests"]),
            ("merged off", D(agents: true, openPRs: true, merged: false), [3, 0, 8], ["3 agents", "8 open pull requests"]),
            ("all off", D(agents: false, openPRs: false, merged: false), [0, 0, 0], []),
        ]
        for (tag, d, want, words) in table {
            let r = AgentSidebar.row(s, details: d, now: Self.now)
            XCTAssertEqual(r.detail, "Working", tag)
            XCTAssertEqual([r.agents, r.merged, r.prCount], want, tag)
            XCTAssertEqual(r.counts.map { $0.1 }, want.prefix(2).filter { $0 > 0 }, tag)
            XCTAssertEqual(r.countWords, words, tag)
        }
        // A count of 0, none at all, or a negative from dch's unclamped agents: no group, no words.
        for (agents, merged) in [(0, 0), (-3, nil), (0, nil)] as [(Int, Int?)] {
            let r = AgentSidebar.row(symbolsSession("api", .idle, agents: agents, merged: merged, open: 0), details: .all, now: Self.now)
            XCTAssertTrue(r.counts.isEmpty, "\(agents) \(String(describing: merged))")
            XCTAssertEqual(r.countWords, [], "\(agents) \(String(describing: merged))")
            XCTAssertEqual([r.agents, r.merged, r.prCount], [0, 0, 0])
            XCTAssertEqual(r.detail, "Idle")
        }
        let one = AgentSidebar.row(symbolsSession("api", .idle, agents: 1, merged: 1, open: 1), details: .all, now: Self.now)
        XCTAssertEqual(one.counts.map { "\($0.0)" }, ["agents", "merged"], "agents then merged; the open PRs are chips")
        XCTAssertEqual(one.countWords, ["1 agent", "1 merged pull request", "1 open pull request"])
        XCTAssertEqual(one.prs, ["api#1"])
    }

    // MARK: VoiceOver, from the real accessibility tree

    struct SymbolsAX { let label: String, value: String, help: String }

    /// Every element under `e` in an AX client's walk, depth first: label, value and help.
    @MainActor
    func symbolsAX(_ e: Any, _ out: inout [SymbolsAX], depth: Int = 0) {
        guard depth < 40, let o = e as? NSObject else { return }
        func text(_ key: String) -> String {
            guard o.responds(to: Selector(key)) else { return "" }
            let v = o.value(forKey: key)
            return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
        }
        out.append(SymbolsAX(label: text("accessibilityLabel"), value: text("accessibilityValue"), help: text("accessibilityHelp")))
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { symbolsAX(k, &out, depth: depth + 1) }
    }

    /// Hosts `view` in a never-shown window and walks its AX tree (built once this process asks, as an AX client's
    /// attribute write would; both attributes are put back after) until `done` holds, with a ceiling.
    @MainActor
    func symbolsTree<V: View>(_ view: V, _ size: CGSize,
                              until done: ([SymbolsAX]) -> Bool) -> [SymbolsAX] {
        let set = Selector(("accessibilitySetValue:forAttribute:")), attrs = ["AXEnhancedUserInterface", "AXManualAccessibility"]
        let app = NSApplication.shared
        XCTAssertTrue(app.responds(to: set))
        defer { for a in attrs { app.perform(set, with: NSNumber(value: false), with: a) } }
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        for a in attrs { app.perform(set, with: NSNumber(value: true), with: a) }
        var tree: [SymbolsAX] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            tree = []
            symbolsAX(host, &tree)
        } while !done(tree) && Date() < deadline
        XCTAssertFalse(win.isVisible, "never shown")
        return tree
    }

    /// The sidebar row reads the counts as words ("3 agents", "192 merged pull requests", "8 open pull requests"),
    /// none for a count of 0 or a detail switched off; History keeps its text.
    @MainActor
    func testRowSymbolsSidebarAccessibilityReadsTheWords() {
        let off = AgentIslandRowDetails(agents: false, openPRs: false, merged: false)
        let rows = [AgentSidebar.row(symbolsSession("api", .working, agents: 3, merged: 192, open: 8), details: .all, now: Self.now),
                    AgentSidebar.row(symbolsSession("api-qa", .done, agents: 1, merged: 0, open: 0, ago: 12), details: .all, now: Self.now),
                    AgentSidebar.row(symbolsSession("api-dev", .idle, agents: 3, merged: 192, open: 8), details: off, now: Self.now),
                    AgentSidebar.row(record("api-old", ago: 7200), now: Self.now)]
        let tree = symbolsTree(VStack(spacing: 0) { ForEach(rows) { AgentSidebarRowView(row: $0, selected: false) } },
                               CGSize(width: 300, height: 300)) { t in t.filter { $0.label.hasPrefix("api") }.count >= rows.count }
        XCTAssertEqual(tree.map(\.label).filter { $0.hasPrefix("api") },
                       ["api, Working, 3 agents, 192 merged pull requests, 8 open pull requests",
                        "api-qa, Done, 1 agent, just now",
                        "api-dev, Idle, 4m ago",
                        "api-old, Ended · exited, 2h ago"])
    }

    /// The header draws the groups from the row's fields (no split of the detail text): each group reads its words
    /// and has them as help; the dots are not read; the age follows.
    @MainActor
    func testRowSymbolsHeaderReadsTheGroupsFromTheFields() throws {
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        let a = symbolsSession("api", .done, agents: 3, merged: 192, open: 8)
        let st = store([a])
        st.controlDch = bin([1, 38, 0])
        let row = AgentSidebar.row(a, details: .all, now: Self.now)
        let header = AgentSessionHeader(row: row, session: a, cwd: "/Users/example/api", open: {}, store: st,
                                        mode: .transcript, setMode: { _ in })
        func groupsOf(_ t: [SymbolsAX]) -> [SymbolsAX] { t.filter { $0.label.hasSuffix(" agents") || $0.label.hasSuffix(" pull requests") } }
        // The help attributes can arrive a pass after the labels: the poll waits for them, with the ceiling.
        let tree = symbolsTree(header.frame(width: 900, height: 80, alignment: .top), CGSize(width: 900, height: 80)) { t in
            t.contains { $0.value == "4m ago" || $0.label == "4m ago" } && groupsOf(t).filter { !$0.help.isEmpty }.count >= 2
        }
        let groups = groupsOf(tree)
        XCTAssertEqual(groups.map(\.label), ["3 agents", "192 merged pull requests"], "agents then merged; the open PRs are not in the header")
        XCTAssertEqual(groups.map(\.help), ["3 agents", "192 merged pull requests"], "each group's help says the words")
        XCTAssertTrue(tree.contains { $0.value == "4m ago" || $0.label == "4m ago" }, "the age after the groups")
        XCTAssertFalse(tree.contains { $0.label.contains("·") || $0.value.contains("·") },
                       "no dot is read, no joined detail text: \(tree.filter { $0.label.contains("·") || $0.value.contains("·") })")
    }

    // MARK: The fit

    /// Five-digit counts (99999 agents and merged, and dch's cap of 50 open PRs as the chips' fallback) beside every
    /// state text fit the sidebar's text column whole at UI scale 0.7, 0.85 and 1.0; with the drawn cap ("99999+") the
    /// state and both groups still fit whole (the open count may give way to none: the ViewThatFits order). The row
    /// never grows a line. Measured ideal widths include the line's trailing spacing before its Spacer (conservative).
    @MainActor
    func testRowSymbolsFitEveryScaleWithFiveDigitCounts() {
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let states = AgentState.allCases.map(\.label) + AgentIsland.runningTexts.sorted()
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            // The 290 pt sidebar less its 8 pt list inset each side; in a row: padding 10 each side, the glyph slot 14, its gap 8.
            let width = sz(290) - sz(16), column = width - 2 * sz(10) - sz(14) - sz(8)
            for state in states {
                func big(_ n: Int) -> AgentSidebar.Row {
                    AgentSidebar.Row(id: live("x"), title: "api", state: .working, detail: state, age: "",
                                     prs: ["api#1", "api#2", "+48"], prCount: DchSessionMeta.maxOpenPRs, agents: n, merged: n)
                }
                let plain = AgentSidebar.Row(id: live("x"), title: "api", state: .working, detail: state, age: "", prs: [])
                func ideal(_ r: AgentSidebar.Row, open: Int) -> CGFloat {
                    NSHostingView(rootView: AgentSidebarRowView(row: r, selected: false).detailLine([], open: open).fixedSize())
                        .fittingSize.width
                }
                XCTAssertLessThanOrEqual(ideal(big(99_999), open: DchSessionMeta.maxOpenPRs), column,
                                         "\"\(state)\", both five-digit groups and the open count fit uncut at \(scale)")
                XCTAssertLessThanOrEqual(ideal(big(100_000), open: 0), column, "\"\(state)\" and both 99999+ groups fit uncut at \(scale)")
                func height(_ r: AgentSidebar.Row) -> CGFloat {
                    NSHostingView(rootView: AgentSidebarRowView(row: r, selected: false).frame(width: width)).fittingSize.height
                }
                XCTAssertEqual(height(big(99_999)), height(plain), accuracy: 0.5, "one detail line (\(state) \(scale))")
                XCTAssertEqual(height(big(100_000)), height(plain), accuracy: 0.5, "one detail line, 99999+ (\(state) \(scale))")
            }
        }
    }

    /// The ViewThatFits order stays chips, then the open count, then none: at the sidebar's width the detail line's
    /// rightmost ink ends where the first option that fits ends (each option measured on its own).
    @MainActor
    func testRowSymbolsKeepTheChipsThenCountThenNoneOrder() throws {
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        for scale: CGFloat in [0.7, 1.0] {
            ThemeRuntime.scale = scale
            let width = sz(290) - sz(16), left = sz(10) + sz(14) + sz(8)
            let long = String(repeating: "w", count: 40)
            let cases: [(String, AgentSidebar.Row, Int)] = [   // the option that shows: 0 chips, 1 the count, 2 none
                ("chips", AgentSidebar.Row(id: live("x"), title: "api", state: .working, detail: "Working", age: "",
                                           prs: ["api#1", "api#2"], prCount: 2, agents: 3, merged: 192), 0),
                ("count", AgentSidebar.Row(id: live("x"), title: "api", state: .working, detail: "Working", age: "",
                                           prs: [long + "#1", long + "#2"], prCount: 2, agents: 3, merged: 192), 1),
            ]
            for (tag, row, want) in cases {
                let v = AgentSidebarRowView(row: row, selected: false)
                let ideal = [v.detailLine(row.prs), v.detailLine([], open: row.prCount), v.detailLine([])]
                    .map { NSHostingView(rootView: $0.fixedSize()).fittingSize.width }
                XCTAssertLessThanOrEqual(ideal[want], width - left, "\(tag): the wanted option fits (\(scale))")
                if want == 1 { XCTAssertGreaterThan(ideal[0], width - left, "count: the chips do not fit (\(scale))") }
                let other = want == 0 ? ideal[1] : ideal[2]
                XCTAssertGreaterThan(abs(ideal[want] - other), 2 * (sz(3) + 1) + sz(4), "\(tag): the options tell apart (\(scale))")
                let size = CGSize(width: width, height: NSHostingView(rootView: v.frame(width: width)).fittingSize.height)
                let rep = try render(v, size: size, dark: true)
                try save(rep, "1115-order-\(tag)-\(scale)")
                let k = CGFloat(rep.pixelsWide) / (size.width + 24)
                guard let bg = rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB) else { return XCTFail("no canvas") }
                // The detail line is the row's lower part: the title line (and its age slot) are above it.
                var last = 0
                for y in Int(size.height * 0.55 * k)..<Int((size.height - sz(3)) * k) {
                    for x in 0..<Int(size.width * k) {
                        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        if abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent)
                            + abs(c.blueComponent - bg.blueComponent) > 0.3 { last = max(last, x) }
                    }
                }
                // Where each option's ink ends: its ideal width less the line's spacing before its Spacer, and for
                // chips the chip's inner padding.
                let edge = CGFloat(last) / k
                let ends = ideal.indices.map { left + ideal[$0] - sz(5) - ($0 == 0 ? sz(4) : 0) }
                let shown = ends.indices.min { abs(ends[$0] - edge) < abs(ends[$1] - edge) }
                XCTAssertEqual(shown, want, "\(tag): option \(want) shows (\(scale)); option ends \(ends), ink to \(edge)")
                XCTAssertEqual(edge, ends[want], accuracy: sz(3) + 1, "\(tag): ink to \(edge), option ends \(ends) (\(scale))")
            }
        }
    }

    // MARK: R1115-2: a live row keeps its age slot

    /// A working row has no age (#1114) but keeps the hidden widest-age slot, so the title does not move when the
    /// session goes working to idle and back: same ideal width, title ink ends at the same pixel. A History row with
    /// no age (no dch timestamp) keeps no slot, as before.
    @MainActor
    func testRowSymbolsLiveRowKeepsTheAgeSlotWithNoAge() throws {
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let title = "a long session title that truncates in the sidebar"
        let rows = [AgentSidebar.Row(id: live("x"), title: title, state: .working, detail: "Working", age: "", prs: []),
                    AgentSidebar.Row(id: live("x"), title: title, state: .idle, detail: "Idle", age: "4m", prs: [])]
        for scale: CGFloat in [1.0, 0.85, 0.7] {
            ThemeRuntime.scale = scale
            var ideal: [Int] = [], edges: [Int] = []
            for row in rows {
                let v = AgentSidebarRowView(row: row, selected: false)
                ideal.append(Int((NSHostingView(rootView: v.fixedSize()).fittingSize.width * 2).rounded()))
                let size = CGSize(width: sz(290) - sz(16), height: sz(50))
                let rep = try render(v, size: size, dark: true)
                try save(rep, "1115-slot-\(row.detail)-\(scale)")
                let k = CGFloat(rep.pixelsWide) / (size.width + 24)
                let slot = NSHostingView(rootView: Text("00m").font(Neon.font(10).monospacedDigit()).fixedSize()).fittingSize.width
                let limit = Int((size.width - sz(10) - slot - sz(2)) * k)
                var last = 0
                for y in Int(sz(8) * k)..<Int(sz(24) * k) {
                    for x in 0..<limit {
                        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        if c.redComponent + c.greenComponent + c.blueComponent > 1.2 { last = max(last, x) }
                    }
                }
                XCTAssertGreaterThan(last, 0, "found the title (\(row.detail) \(scale))")
                edges.append(last)
            }
            XCTAssertEqual(ideal.first, ideal.last, "working and idle rows are as wide at \(scale): \(ideal)")
            XCTAssertEqual(edges.first, edges.last, "the title ends at the same pixel, working or idle, at \(scale): \(edges)")
        }
        ThemeRuntime.scale = 1.0
        func wide(_ age: String) -> CGFloat {
            let r = AgentSidebar.Row(id: .history(AgentSessionKey(dir: "/tmp/dch-test", name: "old")), title: title, state: nil,
                                     detail: "Ended · exited", age: age, prs: [])
            return NSHostingView(rootView: AgentSidebarRowView(row: r, selected: false).fixedSize()).fittingSize.width
        }
        XCTAssertLessThan(wide(""), wide("2h"), "a History row with no age keeps no slot (unchanged)")
    }

    // MARK: R1115-1: the age clock in the common modes

    /// The clock is added in the common run-loop modes, so it fires while a scroll or a drag tracks: here only the
    /// event-tracking mode runs, and the row's age catches up. Polls end on the tick, with a ceiling.
    @MainActor
    func testRowSymbolsAgeClockTicksWhileTracking() throws {
        // The main run loop's common modes include event tracking in the app (NSApplication adds it at launch); this
        // process may not have set one up yet when this test runs first, so add it as AppKit does.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        var t = Self.now
        let m = windowModel(store([session("api", .idle, ago: 59)]))
        m.now = { t }
        m.ageInterval = 0.05
        m.setVisible(true)
        defer { m.close() }
        XCTAssertEqual(m.clock?.timeInterval, 0.05, "the model's clock")
        func shown() -> String? { m.sections.flatMap(\.rows).first?.age }
        XCTAssertEqual(shown(), "now", "59 s")
        t += 60
        let deadline = Date().addingTimeInterval(5)
        while shown() != "1m" && Date() < deadline {
            _ = RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(shown(), "1m", "the clock fired in the event-tracking mode")
    }

    // MARK: Review pictures (opt-in)

    /// The row before and after (#1115) at 0.7 and 1.0, light and dark. Uses only API the base has, so the same body
    /// renders the base's row. PROSPER_SYMBOLS_PNG_DIR enables it, PROSPER_SYMBOLS_PHASE prefixes the names.
    @MainActor
    func testRowSymbolsReviewPictures() throws {
        guard let dir = ProcessInfo.processInfo.environment["PROSPER_SYMBOLS_PNG_DIR"].map({ URL(fileURLWithPath: $0) }) else {
            throw XCTSkip("#1115 review pictures: set PROSPER_SYMBOLS_PNG_DIR")
        }
        let phase = ProcessInfo.processInfo.environment["PROSPER_SYMBOLS_PHASE"] ?? "run"
        _ = ThemeStore.shared
        let saved = (ThemeRuntime.scale, ThemeRuntime.palette)
        defer { (ThemeRuntime.scale, ThemeRuntime.palette) = saved }
        let pr = { (n: Int) in DchSessionMeta.PR(url: "https://github.com/acme/api/pull/\(n)", repo: "acme/api", num: n, title: "t") }
        let sessions = [session("api", .working, ago: 60, agents: 2, meta: DchSessionMeta(merged: 1)),
                        session("api-qa", .working, ago: 60, agents: 3,
                                meta: DchSessionMeta(openPRs: (1...8).map { pr($0 * 1111) }, merged: 192)),
                        session("api-dev", .done, ago: 240, agents: 1, meta: DchSessionMeta(openPRs: [pr(12)], merged: 18))]
        for dark in [true, false] {
            ThemeRuntime.palette = dark ? saved.1 : Self.lightPalette
            for scale: CGFloat in [0.7, 1.0] {
                ThemeRuntime.scale = scale
                let width = sz(290) - sz(16)
                let view = VStack(spacing: 0) {
                    ForEach(sessions.map { AgentSidebar.row($0, details: .all, now: Self.now) }) {
                        AgentSidebarRowView(row: $0, selected: false)
                    }
                }
                let size = CGSize(width: width, height: NSHostingView(rootView: view.frame(width: width)).fittingSize.height)
                let rep = try render(view, size: size, dark: dark)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: dir.appendingPathComponent("\(phase)-row-\(dark ? "dark" : "light")-\(scale).png"))
            }
        }
    }
}

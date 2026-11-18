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
        XCTAssertEqual(AgentSidebar.Count.allCases.map(\.symbol), ["person.2", "arrow.triangle.merge", "arrow.triangle.pull", "terminal"])
        XCTAssertTrue(NSImage(systemSymbolName: "person.2", accessibilityDescription: nil) != nil, "person.2")
        XCTAssertTrue(NSImage(systemSymbolName: "arrow.triangle.merge", accessibilityDescription: nil) != nil, "arrow.triangle.merge")
        XCTAssertTrue(NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil) != nil, "arrow.triangle.pull")
        XCTAssertTrue(NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) != nil, "terminal")   // #1558
        XCTAssertEqual(AgentSidebar.Count.allCases.map { $0.words(1) }, ["1 agent", "1 merged pull request", "1 open pull request", "1 running shell"])
        XCTAssertEqual(AgentSidebar.Count.allCases.map { $0.words(192) },
                       ["192 agents", "192 merged pull requests", "192 open pull requests", "192 running shells"])
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

    typealias SymbolsAX = AXTreeNode

    /// The real accessibility tree of `view` in a never-shown window, walked until `done` holds, with a ceiling
    /// (AXTreeSupport: both attributes are put back as found).
    @MainActor
    func symbolsTree<V: View>(_ view: V, _ size: CGSize, until done: ([SymbolsAX]) -> Bool) -> [SymbolsAX] {
        AXTreeSupport.tree(view, size, until: done)
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
        let header = AgentSessionHeader(row: row, session: a, cwd: "/Users/example/api", open: {}, store: st)
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

    /// #1268 (R5): which step of line two's ladder shows, from a literal table (state text, group digits, UI scale):
    /// the open PRs' count (`count`) or the line without it (`none`); the chips never fit (long names). #1345 round 2:
    /// measured at the row's real line two (`rowColumn`, 134.8 / 164.4 / 195.0 at 0.7 / 0.85 / 1.0: the chip's column
    /// and its gap are beside it now; was TIP's 162.4 / 197.2 / 232.0). At 999 the quiet states keep the count at every
    /// scale (Done and Idle at 0.7; also Ending, Exiting and Working at 0.85; seven states at 1.0); from 9999 almost every
    /// state drops it; 99999 drops it everywhere but Idle at 0.85 and 1.0. A `cut` cell's last step is drawn in less than
    /// it needs (its unrounded ideal over rowColumn, as ViewThatFits compares). What shows is read by pixels (the ladder
    /// renders exactly as the wanted step, not as the other); every other cell fits uncut; the row's height is the same in
    /// every cell. Widths print as BADGE1268C-FIT (fittingSizes, then the unrounded ideals).
    @MainActor
    func testRowSymbolsLadderStepByStateDigitsAndScaleFromALiteralTable() throws {
        let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let states = AgentState.allCases.map(\.label) + AgentIsland.runningTexts.sorted()
        let relaunching = "Relaunching\u{2026}", all = Set(states)
        let first = AgentIsland.firstSendingText   // #1369: longer than "Relaunching\u{2026}", so cut wherever it is
        let calm: Set<String> = ["Done", "Idle"]
        // The state texts that DROP the open count, per (digits, scale); every other state keeps it.
        // #1360: every cell's agents group is a filled pill, its capsule's padding (sz(4) each side) in the line's width, so
        // the count gives way sooner: from TIP's prints plus 2 * sz(4) (BADGE1268C-FIT reads the new widths).
        let drops: [Int: [CGFloat: Set<String>]] = [
            999: [0.7: all.subtracting(calm), 0.85: all.subtracting(calm), 1.0: all.subtracting(calm).subtracting(["Working", "Exiting\u{2026}"])],   // #1453: the robot group is narrower than the people symbol was, so two more states keep the count at 1.0
            9_999: [0.7: all.subtracting(["Idle"]), 0.85: all.subtracting(["Idle"]), 1.0: all.subtracting(calm)],
            99_999: [0.7: all, 0.85: all, 1.0: all],
        ]
        // The cells drawn cut, per (digits as printed, scale).
        let cuts: [String: [CGFloat: Set<String>]] = [
            "999": [0.7: [relaunching, first], 0.85: [relaunching, first], 1.0: [first]],   // #1453: "Relaunching" now fits at 1.0
            "9999": [0.7: ["Needs input", relaunching, "Restarting\u{2026}", "Resuming\u{2026}", "Stopping\u{2026}", first],   // #1453: "Sending" and "Starting" now fit
                     0.85: ["Needs input", relaunching, "Restarting\u{2026}", "Resuming\u{2026}", "Stopping\u{2026}", first],
                     1.0: ["Needs input", relaunching, "Restarting\u{2026}", first]],
            "99999": [0.7: all.subtracting(calm), 0.85: all.subtracting(calm).subtracting(["Working"]),   // #1453: "Working" now fits at 0.85
                      1.0: ["Needs input", "Pausing\u{2026}", relaunching, "Restarting\u{2026}", "Resuming\u{2026}", "Sending\u{2026}",
                            "Starting\u{2026}", "Stopping\u{2026}", first]],
            "99999+": [0.7: all.subtracting(["Idle"]), 0.85: all.subtracting(calm), 1.0: all.subtracting(calm)],
        ]
        let cut = Set(cuts.flatMap { digits, byScale in byScale.flatMap { scale, s in s.map { "\($0) \(digits) \(scale)" } } })
        let named = (drops.values.flatMap { $0.values } + cuts.values.flatMap { $0.values }).reduce(Set<String>()) { $0.union($1) }
        XCTAssertTrue(named.isSubset(of: Set(states)), "the table names the app's state texts: \(named.subtracting(states))")
        // #1448: two w x h pixel regions of one sheet (was two whole renders of one size); a region past the sheet is -1.
        func differ(_ rep: NSBitmapImageRep, _ a: (x: Int, y: Int), _ b: (x: Int, y: Int), _ w: Int, _ h: Int) -> Int {
            guard max(a.x, b.x) + w <= rep.pixelsWide, max(a.y, b.y) + h <= rep.pixelsHigh else { return -1 }
            var n = 0
            for y in 0..<h {
                for x in 0..<w {
                    guard let p = rep.colorAt(x: a.x + x, y: a.y + y)?.usingColorSpace(.sRGB),
                          let q = rep.colorAt(x: b.x + x, y: b.y + y)?.usingColorSpace(.sRGB) else { continue }
                    if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent)
                        + abs(p.blueComponent - q.blueComponent) > 0.02 { n += 1 }
                }
            }
            return n
        }
        func ideal<V: View>(_ v: V) -> CGFloat { NSHostingView(rootView: v.fixedSize()).fittingSize.width }
        // #1345 round 2: the ideal ViewThatFits compares, unrounded (a fittingSize is whole points rounded up: "Idle 99999
        // 0.85" read 165 for a count the ladder keeps at 164.4).
        func exact<V: View>(_ v: V) -> CGFloat {
            let box = ExactIdeal1345.Box()
            _ = NSHostingView(rootView: ExactIdeal1345(box: box) { v }).fittingSize
            return box.width
        }
        var cells = 0
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            // The 290 pt sidebar less its 8 pt list inset each side; in a row: padding 10 each side, the glyph slot 14, its gap 8.
            let width = AgentWindowModel.fullSidebarWidth - sz(16), column = width - 2 * sz(10) - sz(14) - sz(8)
            // #1345 round 2: the table is measured at the row's real line two, less the chip's column and its gap (was
            // `column`, TIP's, when line two ran under the chip); both print.
            let rowColumn = column - sz(8) - NSHostingView(rootView: AgentSidebarRowView.digitColumn.fixedSize()).fittingSize.width
            let long = String(repeating: "w", count: 40)
            // #1448: one render per (state, scale) holds its four cells' three pictures (shown, wanted, other), each in its
            // own slot at whole-point offsets on render's own black canvas and margin (was one render, with its 0.15 s
            // settle, per picture); every picture is compared over its own slot's pixels as before.
            let margin: CGFloat = 24, slotWidth = (rowColumn + margin).rounded(.up)
            var slots: [(tag: String, keeps: Bool, capped: Bool, size: CGSize, pictures: [AnyView])] = []
            for state in states {
                func height(_ r: AgentSidebar.Row) -> CGFloat {
                    NSHostingView(rootView: AgentSidebarRowView(row: r, selected: false).frame(width: width)).fittingSize.height
                }
                let plainHeight = height(AgentSidebar.Row(id: live("x"), title: "api", state: .working, detail: state, age: "", prs: []))
                slots = []
                for digits in [999, 9_999, 99_999, 100_000] {
                    let capped = digits > 99_999
                    let r = AgentSidebar.Row(id: live("x"), title: "api", state: .working, detail: state, age: "",
                                             prs: capped ? [] : [long + "#1", long + "#2", "+48"],
                                             prCount: capped ? 0 : DchSessionMeta.maxOpenPRs, agents: digits, merged: digits)
                    let tag = "\(state) \(capped ? "99999+" : String(digits)) \(scale)"
                    XCTAssertTrue(capped || drops[digits]?[scale] != nil, "\(tag): in the table")
                    let keeps = !capped && !(drops[digits]?[scale]?.contains(state) ?? false)
                    let v = AgentSidebarRowView(row: r, selected: false)
                    let count = v.detailLine([], open: r.prCount), none = v.detailLine([])
                    // #1448: each ideal measured once (was twice or three times per cell, the same value each time).
                    let idealCount = ideal(count), idealNone = ideal(none), exactCount = exact(count), exactNone = exact(none)
                    let shownIdeal = keeps ? exactCount : exactNone
                    XCTAssertEqual(shownIdeal, keeps ? idealCount : idealNone, accuracy: 1, "\(tag): the unrounded ideal read")
                    print("BADGE1268C-FIT \(tag) column \(column) rowColumn \(rowColumn) count \(idealCount) none \(idealNone) exact \(exactCount) \(exactNone) shows \(keeps ? "count" : "none")")
                    if cut.contains(tag) {
                        XCTAssertGreaterThan(shownIdeal, rowColumn, "\(tag): the last step, drawn in less than it needs")
                    } else {
                        XCTAssertLessThanOrEqual(shownIdeal, rowColumn, "\(tag): \(keeps ? "count" : "none") fits uncut")
                    }
                    let size = CGSize(width: rowColumn, height: NSHostingView(rootView: v.detailVariants.frame(width: rowColumn)).fittingSize.height)
                    slots.append((tag, keeps, capped, size, [AnyView(v.detailVariants.frame(width: rowColumn)),
                                                             AnyView((keeps ? count : none).frame(width: rowColumn)),
                                                             AnyView((keeps ? none : count).frame(width: rowColumn))]))
                    XCTAssertEqual(height(r), plainHeight, accuracy: pixel, "\(tag): the row's height")
                    cells += 1
                }
                // Each slot is render's root for one picture (black canvas, picture at the top left, the margin past it),
                // in a box of whole points so every slot starts on a whole pixel at 1x and 2x.
                let drawn = slots, heights = slots.map { ($0.size.height + margin).rounded(.up) }
                let canvas = CGSize(width: 3 * slotWidth, height: heights.reduce(0, +))
                let sheet = VStack(alignment: .leading, spacing: 0) {
                    ForEach(drawn.indices, id: \.self) { i in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<3, id: \.self) { j in
                                ZStack(alignment: .topLeading) {
                                    Color.black
                                    drawn[i].pictures[j].frame(width: drawn[i].size.width, height: drawn[i].size.height, alignment: .topLeading)
                                }
                                .frame(width: drawn[i].size.width + margin, height: drawn[i].size.height + margin, alignment: .topLeading)
                                .frame(width: slotWidth, height: heights[i], alignment: .topLeading)
                            }
                        }
                    }
                }
                let rep = try render(sheet, size: canvas, dark: true, margin: 0)
                let k = CGFloat(rep.pixelsWide) / canvas.width
                var top: CGFloat = 0
                for (i, s) in slots.enumerated() {
                    // A picture's pixels as render drew them alone: its canvas, size plus margin, rounded up to whole pixels.
                    let w = Int(((s.size.width + margin) * k).rounded(.up)), h = Int(((s.size.height + margin) * k).rounded(.up))
                    let y = Int((top * k).rounded()), x = { (j: Int) in Int((CGFloat(j) * slotWidth * k).rounded()) }
                    XCTAssertEqual(differ(rep, (x(0), y), (x(1), y), w, h), 0, "\(s.tag): \(s.keeps ? "the open count" : "the line without it") shows")
                    if !s.capped {
                        XCTAssertGreaterThan(differ(rep, (x(0), y), (x(2), y), w, h), 0, "\(s.tag): and not the other step")
                    }
                    top += heights[i]
                }
            }
        }
        XCTAssertEqual(cells, 3 * 4 * states.count)
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
            let width = AgentWindowModel.fullSidebarWidth - sz(16), left = sz(10) + sz(14) + sz(8)
            let long = String(repeating: "w", count: 40)
            // #1268: the text column (was width - left: the row's right padding was left out). #1345: less the chip's
            // column and its gap (line two no longer runs under the chip); the chips row drops its 3 agents and 192
            // merged (about 70 pt at 1.0) so its two chips still fit the narrower line at both scales (was: 0.7 showed
            // the count, ideal 165 vs 162.4).
            let column = width - left - sz(10) - sz(8)
                - NSHostingView(rootView: AgentSidebarRowView.digitColumn.fixedSize()).fittingSize.width
            let cases: [(String, AgentSidebar.Row, Int)] = [   // the option that shows: 0 chips, 1 the count, 2 none
                ("chips", AgentSidebar.Row(id: live("x"), title: "api", state: .working, detail: "Working", age: "",
                                           prs: ["api#1", "api#2"], prCount: 2, agents: 0, merged: 0), 0),
                ("count", AgentSidebar.Row(id: live("x"), title: "api", state: .working, detail: "Working", age: "",
                                           prs: [long + "#1", long + "#2"], prCount: 2, agents: 3, merged: 192), 1),
            ]
            for (tag, row, want) in cases {
                let v = AgentSidebarRowView(row: row, selected: false)
                let ideal = [v.detailLine(row.prs), v.detailLine([], open: row.prCount), v.detailLine([])]
                    .map { NSHostingView(rootView: $0.fixedSize()).fittingSize.width }
                XCTAssertLessThanOrEqual(ideal[want], column, "\(tag): the wanted option fits (\(scale))")
                if want == 1 { XCTAssertGreaterThan(ideal[0], column, "\(tag): the chips do not fit (\(scale))") }
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
                // chips the chip's inner padding. #1268: every option now ends with the age slot (empty here: a working
                // row), after the Spacer's second spacing, so the ink ends that much before the option's end.
                let edge = CGFloat(last) / k
                let age = NSHostingView(rootView: v.ageSlot.fixedSize()).fittingSize.width
                let ends = ideal.indices.map { left + ideal[$0] - sz(5) - sz(5) - age - ($0 == 0 ? sz(4) : 0) }
                let shown = ends.indices.min { abs(ends[$0] - edge) < abs(ends[$1] - edge) }
                XCTAssertEqual(shown, want, "\(tag): option \(want) shows (\(scale)); option ends \(ends), ink to \(edge)")
                XCTAssertEqual(edge, ends[want], accuracy: sz(3) + 1, "\(tag): ink to \(edge), option ends \(ends) (\(scale))")
            }
        }
    }

    // MARK: R1115-2: a live row keeps its age slot

    /// A working row has no age (#1114) but keeps the hidden widest-age slot, so the title does not move when the
    /// session goes working to idle and back: same ideal width, title ink ends at the same pixel. A History row with
    /// no age (no dch timestamp) keeps no slot, as before. #1268 (R2): the slot is the last thing on line two; line one
    /// ends with the chip's room on every row, so the title never depends on the age.
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
                let size = CGSize(width: AgentWindowModel.fullSidebarWidth - sz(16), height: sz(50))
                let rep = try render(v, size: size, dark: true)
                try save(rep, "1115-slot-\(row.detail)-\(scale)")
                let k = CGFloat(rep.pixelsWide) / (size.width + 24)
                // #1268 (R2): line one carries no age, so its whole width is read (was: left of a "00m" slot there).
                let limit = Int(size.width * k)
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
            // #1268 (R2): the slot is on line two: the working row's line two (no age) is as wide as with an age.
            func line(_ age: String) -> CGFloat {
                let r = AgentSidebar.Row(id: live("x"), title: title, state: .working, detail: "Working", age: age, prs: [])
                return NSHostingView(rootView: AgentSidebarRowView(row: r, selected: false).detailLine([]).fixedSize()).fittingSize.width
            }
            XCTAssertEqual(line(""), line("4m"), accuracy: 0.01, "a live row keeps the age slot on line two with no age (\(scale))")
        }
        ThemeRuntime.scale = 1.0
        // #1268 (R2): line two is where the age is (was: the whole row's width, now the title line's whatever the age).
        func wide(_ age: String) -> CGFloat {
            let r = AgentSidebar.Row(id: .history(AgentSessionKey(dir: "/tmp/dch-test", name: "old")), title: title, state: nil,
                                     detail: "Ended · exited", age: age, prs: [])
            return NSHostingView(rootView: AgentSidebarRowView(row: r, selected: false).detailLine([]).fixedSize()).fittingSize.width
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
                let width = AgentWindowModel.fullSidebarWidth - sz(16)
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

    /// #1268d: a row WITH a model and an effort, the PRs never fitting, at scale 1.0: the ladder's `count` step (open count,
    /// no badges) shows where count+badges overflows the column and count alone fits, and not `none` (the mutant that puts
    /// none before count passes the table above: its rows have no model, so count+badges draws as count). In the wider
    /// column count+badges fits and shows, so the row cannot pass with the badges always off. Columns are literals, measured
    /// (BADGE1268D-FIT): at 1.0 count 174, count+badges 275, none 145, chips+badges 797; narrow 232 (the sidebar's own text column: 290 - 16 - 20 - 14 - 8) leaves 58 over count and 43 under count+badges; wide 300 leaves 25 over count+badges.
    @MainActor
    func testRowSymbolsLadderWithBadgesKeepsTheCountBeforeNone() throws {
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        func differ(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
            guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return -1 }
            var n = 0
            for y in 0..<a.pixelsHigh {
                for x in 0..<a.pixelsWide {
                    guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent)
                        + abs(p.blueComponent - q.blueComponent) > 0.02 { n += 1 }
                }
            }
            return n
        }
        func ideal<V: View>(_ v: V) -> CGFloat { NSHostingView(rootView: v.fixedSize()).fittingSize.width }
        let long = String(repeating: "w", count: 40)
        var r = AgentSidebar.Row(id: live("x"), title: "api", state: .working, detail: "Working", age: "",
                                 prs: [long + "#1", long + "#2", "+48"], prCount: DchSessionMeta.maxOpenPRs, agents: 3, merged: 192)
        r.modelSlot = true
        r.model = "Fable 9"
        r.effort = "high"
        let v = AgentSidebarRowView(row: r, selected: false)
        // #1345: line two has no badge step any more (the badges are on line one): count, then none, at literal columns
        // between the measured widths (BADGE1268D-FIT at 1.0: count 174, none 145), and with the badges' room (wide)
        // the line is the count line exactly (was: count+badges there).
        let count = v.detailLine([], open: r.prCount), none = v.detailLine([])
        print("BADGE1268D-FIT count \(ideal(count)) none \(ideal(none)) chips \(ideal(v.detailLine(r.prs)))")
        let narrow: CGFloat = 232, between: CGFloat = 160, wide: CGFloat = 300
        XCTAssertLessThanOrEqual(ideal(count), narrow, "premise: count fits the narrow column")
        XCTAssertGreaterThan(ideal(count), between, "premise: count overflows the between column")
        XCTAssertLessThanOrEqual(ideal(none), between, "premise: none fits the between column")
        XCTAssertGreaterThan(ideal(v.detailLine(r.prs)), wide, "premise: the chips still never fit")
        func shows(_ column: CGFloat, _ want: some View, _ other: some View, _ tag: String) throws {
            let size = CGSize(width: column, height: NSHostingView(rootView: v.detailVariants.frame(width: column)).fittingSize.height)
            let shown = try render(v.detailVariants.frame(width: column), size: size, dark: true)
            XCTAssertEqual(differ(shown, try render(want.frame(width: column), size: size, dark: true)), 0, "\(tag): the step shows")
            XCTAssertGreaterThan(differ(shown, try render(other.frame(width: column), size: size, dark: true)), 0, "\(tag): and not the other")
        }
        try shows(narrow, count, none, "narrow: the open count, not none")
        try shows(between, none, count, "between: none, not the count")
        try shows(wide, count, none, "wide: the count line, no badges on it")
    }
}

/// Tests (#1345 round 2): records its child's ideal size unrounded, as ViewThatFits reads it.
struct ExactIdeal1345: Layout {
    final class Box: @unchecked Sendable { var width: CGFloat = 0 }
    let box: Box
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let s = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        box.width = s.width
        return s
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: .unspecified)
    }
}

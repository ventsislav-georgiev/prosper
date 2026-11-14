import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1137: the Agent island draws its agents capsule and merged count as the Agent Sessions window does (#1115):
/// AgentSidebar.Count's symbol plus the capped number, its words for VoiceOver and the help; the PR line's chip budget
/// measures what is drawn. Offscreen only: views are rendered with ImageRenderer or hosted in windows that are never
/// shown; the island panel is never created; no event is posted; every session is a model value made in the row.
final class AgentIslandCountSymbolsTests: XCTestCase {
    static let now: TimeInterval = 1_800_000_000

    func session(_ name: String, _ state: AgentState, ago: TimeInterval = 240, agents: Int,
                 meta: DchSessionMeta? = nil) -> AgentSession {
        var s = AgentSession(key: AgentSessionKey(dir: "/tmp/dch-test", name: name), alias: "", activity: Self.now - ago,
                             state: state, agents: agents)
        s.meta = meta
        return s
    }

    /// A PR in a repo whose label ("web#12345") never starts with a session name used here.
    func pr(_ n: Int) -> DchSessionMeta.PR {
        DchSessionMeta.PR(url: "https://github.com/acme/web/pull/\(n)", repo: "acme/web", num: n, title: "t")
    }

    @MainActor
    func ideal<V: View>(_ v: V) -> CGFloat { NSHostingView(rootView: v.fixedSize()).fittingSize.width }

    // MARK: The window's symbols and words, capped

    /// The island draws the window's symbol and the capped number, pixel for pixel the same as a view built from the
    /// literal symbol name and text; its drawn width is the measured width (order checked first).
    @MainActor
    func testIslandCountDrawsTheWindowsSymbolAndTheCappedNumber() throws {
        // Order first: the symbol has a width, more digits measure wider, the cap stops the growth.
        let w1 = AgentIsland.countWidth(.merged, 1), w5 = AgentIsland.countWidth(.merged, 99_999)
        let capped = AgentIsland.countWidth(.merged, 100_000)
        XCTAssertGreaterThan(AgentIsland.symbolWidth(.merged), 0, "the symbol has a width")
        XCTAssertGreaterThan(AgentIsland.symbolWidth(.agents), 0, "the symbol has a width")
        XCTAssertLessThan(w1, w5, "1 < 99999")
        XCTAssertLessThan(w5, capped, "99999 < 99999+")
        XCTAssertEqual(AgentIsland.countWidth(.merged, Int.max), capped, "Int.max draws 99999+, as wide as 100000")
        XCTAssertEqual(AgentIsland.countWidth(.agents, Int.max), AgentIsland.countWidth(.agents, 100_000), "the agents cap")
        XCTAssertLessThan(capped, AgentIslandGeometry.rowTextWidth / 4, "a capped count leaves the chips the line")

        // (kind, count, the symbol drawn, the text drawn)
        let table: [(AgentSidebar.Count, Int, String, String)] = [
            (.agents, 3, "person.2", "3"),
            (.agents, 99_999, "person.2", "99999"),
            (.agents, 100_000, "person.2", "99999+"),
            (.agents, Int.max, "person.2", "99999+"),
            (.merged, 1, "arrow.triangle.merge", "1"),
            (.merged, 99_999, "arrow.triangle.merge", "99999"),
            (.merged, Int.max, "arrow.triangle.merge", "99999+"),
        ]
        func pixels<V: View>(_ v: V) throws -> (Int, Int, Data) {
            let r = ImageRenderer(content: v.foregroundStyle(Color.white).background(Color.black))
            r.scale = 2
            let cg = try XCTUnwrap(r.cgImage)
            return (cg.width, cg.height, try XCTUnwrap(cg.dataProvider?.data as Data?))
        }
        for (kind, n, symbol, text) in table {
            let drawn = ideal(AgentIslandCount(kind: kind, n: n)), measured = AgentIsland.countWidth(kind, n)
            XCTAssertLessThanOrEqual(drawn, measured + 0.01, "\(kind) \(n): never drawn wider than measured")
            XCTAssertLessThanOrEqual(measured - drawn, 2, "\(kind) \(n): the measure is the drawn width, rounded up")
            let want = HStack(spacing: 2) {
                Image(systemName: symbol).frame(width: AgentIsland.symbolWidth(kind))
                Text(verbatim: text)
            }.font(Font(AgentIslandGeometry.chipFont)).fixedSize()
            let got = try pixels(AgentIslandCount(kind: kind, n: n)), ref = try pixels(want)
            XCTAssertEqual(got.0, ref.0, "\(kind) \(n): width")
            XCTAssertEqual(got.1, ref.1, "\(kind) \(n): height")
            XCTAssertTrue(got.2 == ref.2, "\(kind) \(n): draws \(symbol) and \"\(text)\"")
        }
    }

    /// The row's VoiceOver text carries the window's words; a count of 0, a negative from dch's unclamped agents or
    /// a detail switched off is not read.
    func testIslandRowLabelReadsTheWindowsWords() {
        typealias D = AgentIslandRowDetails
        // (agents, merged, details, label)
        let table: [(Int, Int?, D, String)] = [
            (3, 192, .all, "api, Idle, 4m ago, 3 agents, 192 merged pull requests"),
            (1, 1, .all, "api, Idle, 4m ago, 1 agent, 1 merged pull request"),
            (100_000, Int.max, .all, "api, Idle, 4m ago, 99999+ agents, 99999+ merged pull requests"),
            (Int.max, 99_999, .all, "api, Idle, 4m ago, 99999+ agents, 99999 merged pull requests"),
            (0, 0, .all, "api, Idle, 4m ago"),
            (-3, nil, .all, "api, Idle, 4m ago"),
            (Int.min, 5, .all, "api, Idle, 4m ago, 5 merged pull requests"),
            (3, 192, D(agents: false), "api, Idle, 4m ago, 192 merged pull requests"),
            (3, 192, D(merged: false), "api, Idle, 4m ago, 3 agents"),
        ]
        for (agents, merged, d, label) in table {
            let s = session("api", .idle, agents: agents, meta: DchSessionMeta(merged: merged))
            XCTAssertEqual(AgentIsland.rowAccessibilityLabel(s, now: Self.now, show: d), label, "\(agents) \(String(describing: merged))")
        }
        XCTAssertTrue(AgentIsland.agentsCount(session("api", .idle, agents: -3)) == nil, "a negative draws no capsule")
        XCTAssertTrue(AgentIsland.agentsCount(session("api", .idle, agents: Int.min)) == nil, "Int.min draws no capsule")
        XCTAssertEqual(AgentIsland.agentsCount(session("api", .idle, agents: Int.max)), Int.max, "drawn capped by the view")
    }

    // MARK: The fit

    /// Five-digit and capped counts beside the PR chips fit the text column whole at UI scale 0.7, 0.85 and 1.0. The
    /// island does not follow the UI scale, so each line measures the same at every scale. "Not cut": every chip and
    /// the count are fixedSize (they never compress), and the line's ideal width fits the column, so the line is laid
    /// out at that ideal width and every part is drawn whole.
    @MainActor
    func testPRLineWithFiveDigitCountsFitsWholeAtEveryScale() {
        _ = ThemeStore.shared   // its first use seeds ThemeRuntime.scale from the prefs: before the scale is set here
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        XCTAssertEqual(AgentIslandGeometry.rowTextWidth, 392, "the column the budget is")
        let five = (0..<5).map { pr(12_345 + $0) }
        // (tag, meta, the chips drawn, the "+M")
        let cases: [(String, DchSessionMeta, [String], Int)] = [
            ("three PRs, 99999 merged", DchSessionMeta(openPRs: Array(five.prefix(3)), merged: 99_999),
             ["web#12345", "web#12346", "web#12347"], 0),
            ("five PRs, 99999+ merged", DchSessionMeta(openPRs: five, merged: 100_000),
             ["web#12345", "web#12346", "web#12347"], 2),
            ("merged alone, Int.max", DchSessionMeta(merged: Int.max), [], 0),
        ]
        var widths: [String: [CGFloat]] = [:]
        for scale: CGFloat in [0.7, 0.85, 1.0] {
            ThemeRuntime.scale = scale
            for (tag, meta, chips, more) in cases {
                let prs = AgentIsland.prChips(meta)
                XCTAssertEqual(prs.chips.map(\.label), chips, "\(tag) at \(scale)")
                XCTAssertEqual(prs.more, more, "\(tag) at \(scale)")
                let s = session("api", .idle, agents: 99_999, meta: meta)
                let row = AgentIslandRow(session: s, now: Self.now, notice: nil, show: .all) {}
                let line = ideal(row.prLineView(prs))
                XCTAssertLessThanOrEqual(line, AgentIslandGeometry.rowTextWidth, "\(tag): the PR line fits whole at \(scale)")
                widths[tag, default: []].append(line)
            }
            // Line 1 with a short title: glyph, title, the capped agents capsule, the age: the whole row at its ideal
            // width fits the row (480 less the list insets), so nothing is cut; a longer title truncates first.
            let big = session("api", .idle, agents: Int.max, meta: DchSessionMeta(openPRs: five, merged: Int.max))
            let whole = ideal(AgentIslandRow(session: big, now: Self.now, notice: nil, show: .all) {})
            XCTAssertLessThanOrEqual(whole, AgentIslandGeometry.expandedWidth - 2 * AgentIslandGeometry.listInset,
                                     "the row at its ideal width fits at \(scale)")
        }
        for (tag, _, _, _) in cases {
            XCTAssertEqual(Set(widths[tag] ?? []).count, 1, "\(tag): the same width at 0.7, 0.85 and 1.0: \(widths[tag] ?? [])")
        }
    }

    /// The budget reserves the merged count as drawn (symbol plus number), not the old words: with room for exactly
    /// one chip, the "+M" and the drawn 99999+ count, one chip shows; half a point less, none.
    func testBudgetReservesTheDrawnMergedCount() {
        let many = DchSessionMeta(openPRs: (1...10).map { pr($0) }, merged: 100_000)
        let one = AgentIsland.chipWidth("web#1") + AgentIsland.chipSpacing + AgentIsland.chipWidth(AgentIsland.moreLabel(9))
        let reserve = AgentIsland.countWidth(.merged, 100_000) + AgentIsland.mergedGap
        XCTAssertLessThan(reserve, AgentIsland.chipWidth("99999+ merged") - 2 * AgentIsland.chipInset + AgentIsland.mergedGap,
                          "symbol plus number is narrower than the old words")
        XCTAssertEqual(AgentIsland.prChips(many, budget: one + reserve).chips.map(\.label), ["web#1"], "one chip fits")
        XCTAssertEqual(AgentIsland.prChips(many, budget: one + reserve - 0.5).chips.map(\.label), [], "half a point less: none")
    }

    /// The panel widths the island supports, passed as numbers: each screen's expanded panel is 480 pt, so the text
    /// column is 392 pt, the chip budget; the row with capped counts renders at that width in its 64 pt (no new line).
    @MainActor
    func testRowAtTheNotchWidthsTheIslandSupports() throws {
        func notched(_ w: CGFloat, notch: CGFloat, bar: CGFloat) -> AgentIslandGeometry {
            let side = (w - notch) / 2
            return AgentIslandGeometry.make(frame: CGRect(x: 0, y: 0, width: w, height: 900),
                                            visibleFrame: CGRect(x: 0, y: 0, width: w, height: 900 - bar),
                                            topLeft: CGRect(x: 0, y: 900 - bar, width: side, height: bar),
                                            topRight: CGRect(x: w - side, y: 900 - bar, width: side, height: bar), safeTop: bar)
        }
        func plain(_ w: CGFloat, bar: CGFloat) -> AgentIslandGeometry {
            AgentIslandGeometry.make(frame: CGRect(x: 0, y: 0, width: w, height: 900),
                                     visibleFrame: CGRect(x: 0, y: 0, width: w, height: 900 - bar), topLeft: nil, topRight: nil,
                                     safeTop: 0)
        }
        // (tag, geometry, notch width, panel width)
        let screens: [(String, AgentIslandGeometry, CGFloat, CGFloat)] = [
            ("14-inch, notch 185", notched(1512, notch: 185, bar: 32), 185, 480),
            ("16-inch, notch 200", notched(1728, notch: 200, bar: 38), 200, 480),
            ("no notch, 2560", plain(2560, bar: 25), 0, 480),
            ("no notch, 800, hidden bar", plain(800, bar: 0), 0, 480),
        ]
        let s = session("api", .idle, agents: Int.max,
                        meta: DchSessionMeta(openPRs: (0..<5).map { pr(12_345 + $0) }, merged: Int.max))
        for (tag, g, notch, panel) in screens {
            XCTAssertEqual(g.notchWidth, notch, tag)
            let size = g.expandedSize(rows: [AgentIslandGeometry.prRowHeight])
            XCTAssertEqual(size.width, panel, tag)
            let rowWidth = size.width - 2 * AgentIslandGeometry.listInset
            XCTAssertEqual(rowWidth - AgentIslandGeometry.rowLead - AgentIslandGeometry.glyphWidth - AgentIslandGeometry.glyphGap
                           - AgentIslandGeometry.rowTrail, 392, "\(tag): the text column is the chip budget")
            let r = ImageRenderer(content: AgentIslandRow(session: s, now: Self.now, notice: nil, show: .all) {}.frame(width: rowWidth))
            r.scale = 1
            let cg = try XCTUnwrap(r.cgImage, tag)
            XCTAssertEqual(CGFloat(cg.width), rowWidth, tag)
            XCTAssertEqual(CGFloat(cg.height), AgentIslandGeometry.prRowHeight, "\(tag): the row keeps its 64 pt")
        }
    }

    // MARK: VoiceOver, from the real accessibility tree

    struct AX { let label: String, help: String }

    @MainActor
    func axWalk(_ e: Any, _ out: inout [AX], depth: Int = 0) {
        guard depth < 40, let o = e as? NSObject else { return }
        func text(_ key: String) -> String {
            guard o.responds(to: Selector(key)) else { return "" }
            let v = o.value(forKey: key)
            return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
        }
        out.append(AX(label: text("accessibilityLabel"), help: text("accessibilityHelp")))
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { axWalk(k, &out, depth: depth + 1) }
    }

    static let axAttrs = ["AXEnhancedUserInterface", "AXManualAccessibility"]

    /// The two flags as NSApplication reports them (nil where it reports nothing).
    @MainActor
    func axFlags() -> [Bool?] {
        let get = Selector(("accessibilityAttributeValue:")), app = NSApplication.shared
        guard app.responds(to: get) else { return Self.axAttrs.map { _ in nil } }
        return Self.axAttrs.map { (app.perform(get, with: $0)?.takeUnretainedValue() as? NSNumber)?.boolValue }
    }

    @MainActor
    func setAXFlags(_ v: [Bool?]) {
        let set = Selector(("accessibilitySetValue:forAttribute:")), app = NSApplication.shared
        for (a, f) in zip(Self.axAttrs, v) { app.perform(set, with: NSNumber(value: f ?? false), with: a) }
    }

    /// Hosts `view` in a never-shown window and walks its AX tree (built once this process asks, as an AX client's
    /// attribute write would) until `done` holds, with a ceiling. R1137-1: both attributes are put back to the values
    /// read before (false only where NSApplication reports none), not to false.
    @MainActor
    func axTree<V: View>(_ view: V, _ size: CGSize, until done: ([AX]) -> Bool) -> [AX] {
        XCTAssertTrue(NSApplication.shared.responds(to: Selector(("accessibilitySetValue:forAttribute:"))))
        let prior = axFlags()
        defer { setAXFlags(prior) }
        let win = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        win.isReleasedWhenClosed = false
        defer { win.close() }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        win.contentView = host
        setAXFlags([true, true])
        print("#1137 R1137-1: flags before \(prior), while walking \(axFlags())")
        var tree: [AX] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            tree = []
            axWalk(host, &tree)
        } while !done(tree) && Date() < deadline
        XCTAssertFalse(win.isVisible, "never shown")
        return tree
    }

    /// The rendered island rows read the window's words in their label; each count group, hosted on its own, reads
    /// its words as label and help (inside the row's button the row label is what VoiceOver reads).
    @MainActor
    func testIslandRowAccessibilityTreeReadsTheWords() {
        let off = AgentIslandRowDetails(agents: false, merged: false)
        // (session, details, the row's label)
        let rows: [(AgentSession, AgentIslandRowDetails, String)] = [
            (session("api", .idle, agents: 3, meta: DchSessionMeta(openPRs: [pr(1)], merged: 192)), .all,
             "api, Idle, 4m ago, 3 agents, 192 merged pull requests, open pull requests acme/web#1"),
            (session("api-qa", .done, ago: 12, agents: 1, meta: DchSessionMeta(merged: 1)), .all,
             "api-qa, Done, just now, 1 agent, 1 merged pull request"),
            (session("api-big", .idle, agents: Int.max, meta: DchSessionMeta(merged: 100_000)), .all,
             "api-big, Idle, 4m ago, 99999+ agents, 99999+ merged pull requests"),
            (session("api-dev", .idle, agents: 3, meta: DchSessionMeta(merged: 192)), off, "api-dev, Idle, 4m ago"),
        ]
        let width = AgentIslandGeometry.expandedWidth - 2 * AgentIslandGeometry.listInset
        let list = VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                AgentIslandRow(session: r.0, now: Self.now, notice: nil, show: r.1) {}
            }
        }.frame(width: width)
        let tree = axTree(list, CGSize(width: width, height: 4 * AgentIslandGeometry.prRowHeight)) { t in
            t.filter { $0.label.hasPrefix("api") }.count >= rows.count
        }
        // Each row's label once, in drawn order (a wrapper repeating its button's label is not a second row).
        let read = tree.map(\.label).filter { $0.hasPrefix("api") }.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        XCTAssertEqual(read, rows.map(\.2))
        XCTAssertFalse(tree.contains { $0.label.contains(" merged,") || $0.label.hasSuffix(" merged") || $0.label.hasPrefix("+") },
                       "no old words are read: \(tree.map(\.label))")

        let groups = HStack(spacing: 8) { AgentIslandCount(kind: .agents, n: 3); AgentIslandCount(kind: .merged, n: 100_000) }
        func words(_ t: [AX]) -> [AX] { t.filter { $0.label.hasSuffix(" agents") || $0.label.hasSuffix(" pull requests") } }
        // The help attributes can arrive a pass after the labels: the poll waits for them, with the ceiling.
        let g = words(axTree(groups, CGSize(width: 200, height: 30)) { t in words(t).filter { !$0.help.isEmpty }.count >= 2 })
        XCTAssertEqual(g.map(\.label), ["3 agents", "99999+ merged pull requests"], "each group reads its words")
        XCTAssertEqual(g.map(\.help), ["3 agents", "99999+ merged pull requests"], "and has them as help")
    }

    /// R1137-1: the helper puts the flags back as it found them. NSApplication reads AXEnhancedUserInterface back and
    /// reports nothing for AXManualAccessibility (run of 2026-11-14: before [false, nil], while walking [true, nil]),
    /// so the readable one is checked: on before the helper runs (as an AX client would have left it), still on after;
    /// off before, off after. AXManualAccessibility is restored to false, its only knowable value.
    @MainActor
    func testAXHelperRestoresThePriorFlags() throws {
        let original = axFlags()
        defer { setAXFlags(original) }
        func enhanced() -> Bool? { axFlags().first ?? nil }
        setAXFlags([true, true])
        guard enhanced() == true else {
            throw XCTSkip("NSApplication does not read AXEnhancedUserInterface back (\(axFlags()))")
        }
        _ = axTree(Text(verbatim: "x"), CGSize(width: 40, height: 20)) { $0.count > 1 }
        XCTAssertEqual(enhanced(), true, "put back as found, not false")
        setAXFlags([false, false])
        _ = axTree(Text(verbatim: "x"), CGSize(width: 40, height: 20)) { $0.count > 1 }
        XCTAssertEqual(enhanced(), false, "and off when it was off")
    }
}

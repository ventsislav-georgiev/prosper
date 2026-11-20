import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1342 (#847 P1e Step C2): in the Agent Sessions sidebar a group is ONE row of its live members in group order; a session
/// in no group is its own row; with no groups the sidebar is unchanged. Offscreen only: every window is built and never
/// shown, ordered in or made key; a line is pressed through this process's own accessibility tree (no event is posted).
/// Every row saves the sidebar mode, the split gate and the UI scale, and puts them back in a defer.
@MainActor
final class AgentSidebarGroupRowTests: XCTestCase {
    private let d1 = AgentWindowD1Tests()
    static let scales: [CGFloat] = [0.7, 0.85, 1.0]

    func withRow(_ body: () throws -> Void) rethrows {
        let d = Preferences.defaults
        let mode = d.object(forKey: AgentSidebarModeTests.modeKey), hidden = d.object(forKey: AgentWindowD1Tests.sidebarKey)
        let gate = AgentPaneLayout.splitsEnabled, scale = ThemeRuntime.scale
        defer {
            if let mode { d.set(mode, forKey: AgentSidebarModeTests.modeKey) } else { d.removeObject(forKey: AgentSidebarModeTests.modeKey) }
            if let hidden { d.set(hidden, forKey: AgentWindowD1Tests.sidebarKey) } else { d.removeObject(forKey: AgentWindowD1Tests.sidebarKey) }
            AgentPaneLayout.splitsEnabled = gate
            ThemeRuntime.scale = scale
        }
        XCTAssertFalse(d === UserDefaults.standard, "a private defaults store")
        d.removeObject(forKey: AgentSidebarModeTests.modeKey)
        d.removeObject(forKey: AgentWindowD1Tests.sidebarKey)
        AgentPaneLayout.splitsEnabled = false
        ThemeRuntime.scale = 1
        try body()
    }

    /// A shown model over `sessions` and `history` with the pair suffix "-qa" (or `suffix`).
    func model(_ sessions: [AgentSession], history: [DchHistoryRecord] = [], suffix: String = "-qa") -> (AgentWindowModel, AgentIslandStore) {
        let st = d1.store(sessions, history: history)
        st.pairSuffix = suffix
        let m = d1.windowModel(st)
        m.setVisible(true)
        return (m, st)
    }

    /// The group fixture: api (working), api-2 (idle), web (idle) and api-qa blocked, so the group starts in Needs you.
    var grouped: [AgentSession] {
        [d1.session("api", .working), d1.session("api-qa", .blocked), d1.session("api-2", .idle), d1.session("web", .idle)]
    }

    func key(_ name: String) -> AgentSidebar.RowID { .live(AgentSessionKey(dir: "/tmp/dch-test", name: name)) }

    /// What VoiceOver reads for `name`'s row in the sidebar, as at TIP: the row's words, then its chip's ("Command-<n>"),
    /// which the row's button reads together.
    func words(_ m: AgentWindowModel, _ name: String) -> String {
        guard let row = m.rows.first(where: { $0.id == key(name) }) else { return "no row \(name)" }
        return label(m, row)
    }

    func label(_ m: AgentWindowModel, _ row: AgentSidebar.Row) -> String {
        AgentSidebarRowView(row: row, selected: false).accessibilityWords + (m.number(row.id).map { ", Command-\($0)" } ?? "")
    }

    // MARK: The rows

    /// No group (no sidekick live or in History; the suffix off too): every section's items are its rows, one each, the
    /// same rows byte for byte; the sidebar draws each row at its own row's height, sz(2) apart, and no group element.
    func testNoGroupKeepsTheRowListAndTheFrames() throws {
        try withRow {
            for suffix in ["-qa", ""] {
                let (m, st) = model([d1.session("api", .idle), d1.session("web", .idle), d1.session("docs", .idle)],
                                    history: [d1.record("old")], suffix: suffix)
                defer { m.close() }
                XCTAssertTrue(st.groups.isEmpty, "no group with suffix \(suffix)")
                let drawn = AgentSidebar.items(m.sections) { st.groups }
                XCTAssertEqual(drawn.count, m.sections.count)
                for s in m.sections {
                    let items = drawn[s.id] ?? []
                    XCTAssertEqual(items.map(\.rows), s.rows.map { [$0] }, "\(s.title): the rows, one per item")
                    XCTAssertEqual(items.map(\.id), s.rows.map(\.id))
                    XCTAssertTrue(items.allSatisfy { $0.stem == nil })
                }
            }
            let (m, _) = model([d1.session("api", .idle), d1.session("web", .idle), d1.session("docs", .idle)])
            defer { m.close() }
            let width = AgentWindowModel.fullSidebarWidth, pixel = AXTreeSupport.devicePixel
            let rows = m.sections.first { $0.title == "Sessions" }?.rows ?? []
            XCTAssertEqual(rows.count, 3)
            let all = rows.map { label(m, $0) }
            let tree = AXTreeSupport.tree(AgentSidebarView(model: m).frame(width: width, height: 900), CGSize(width: width, height: 900)) { t in
                all.allSatisfy { w in t.contains { $0.label == w } }
            }
            XCTAssertFalse(tree.contains { $0.label.hasPrefix("Group ") }, "no group element")
            let frames = all.compactMap { w in tree.first { $0.label == w && !$0.ignored }?.frame }
            XCTAssertEqual(frames.count, 3, "\(tree.map(\.label))")
            for (row, f) in zip(rows, frames) {
                let alone = NSHostingView(rootView: AgentSidebarRowView(row: row, selected: m.selection == row.id, number: m.number(row.id))
                    .frame(width: width - 2 * sz(8))).fittingSize
                XCTAssertEqual(f.height, alone.height, accuracy: pixel, "\(row.title): today's row height")
                XCTAssertEqual(f.width, width - 2 * sz(8), accuracy: pixel, "\(row.title): today's row width")
            }
            for (a, b) in zip(frames, frames.dropFirst()) {
                XCTAssertEqual(a.minY - b.maxY, sz(2), accuracy: pixel, "sz(2) apart, top to bottom (AX y grows upward)")
            }
        }
    }

    /// api, api-2 and api-qa (main, second main, sidekick) are one row at api-qa's place (Needs you: it is blocked), in group
    /// order: api, api-2, then api-qa; Sessions keeps web alone and draws none of the members.
    func testGroupIsOneRowInGroupOrderAndASoloSessionIsItsOwnRow() throws {
        try withRow {
            let (m, st) = model(grouped)
            defer { m.close() }
            let drawn = AgentSidebar.items(m.sections) { st.groups }
            let needs = drawn[AgentSidebar.needsYouTitle] ?? []
            XCTAssertEqual(needs.count, 1, "one row")
            XCTAssertEqual(needs.first?.stem, "api")
            XCTAssertEqual(needs.first?.rows.map(\.id), [key("api"), key("api-2"), key("api-qa")], "group order: mains, then the sidekick")
            XCTAssertEqual(needs.first?.id, key("api"))
            let sessions = drawn["Sessions"] ?? []
            XCTAssertEqual(sessions.map(\.id), [key("web")], "web alone, as today")
            XCTAssertEqual(sessions.first?.rows.count, 1)
            XCTAssertTrue(sessions.first?.stem == nil)
            XCTAssertEqual(drawn.values.flatMap { $0 }.flatMap(\.rows).count, m.rows.count, "every row drawn once")
        }
    }

    /// api live, api-qa ended (its record in History): the group has one live member, so api is its plain row and the
    /// record stays its own History row.
    func testGroupWithOneLiveMemberIsAPlainRow() throws {
        try withRow {
            let (m, st) = model([d1.session("api", .idle), d1.session("web", .idle)], history: [d1.record("api-qa")])
            defer { m.close() }
            XCTAssertEqual(st.groups.count, 1, "the group is there (live + History keys)")
            let drawn = AgentSidebar.items(m.sections) { st.groups }
            let all = drawn.values.flatMap { $0 }
            XCTAssertTrue(all.allSatisfy { $0.stem == nil && $0.rows.count == 1 }, "\(all.map { ($0.stem, $0.rows.map(\.title)) })")
            XCTAssertEqual(all.count, m.rows.count, "every row its own item")
            XCTAssertEqual((drawn["History"] ?? []).map(\.rows), (m.sections.first { $0.title == "History" }?.rows ?? []).map { [$0] })
        }
    }

    /// R909-1: the groups are computed once for the whole list, never per row.
    func testGroupsAreComputedOncePerDraw() throws {
        try withRow {
            let (m, st) = model(grouped + [d1.session("ios", .idle), d1.session("ios-qa", .idle)])
            defer { m.close() }
            var calls = 0
            let drawn = AgentSidebar.items(m.sections) { calls += 1; return st.groups }
            XCTAssertEqual(calls, 1, "once for \(m.rows.count) rows")
            XCTAssertEqual(drawn.values.flatMap { $0 }.compactMap(\.stem).sorted(), ["api", "ios"])
        }
    }

    // MARK: Drawn: the accessibility tree, a click and the frames

    /// VoiceOver: the group reads "Group api, 3 sessions" and holds each member's line, named as today's row, top to bottom
    /// in group order; web's row is outside it.
    func testGroupAndLinesAreNamedForVoiceOver() throws {
        try withRow {
            let (m, _) = model(grouped)
            defer { m.close() }
            let names = ["api", "api-2", "api-qa"].map { words(m, $0) }
            let group = AgentSidebarGroupRow<EmptyView>.words(stem: "api", count: 3)
            XCTAssertEqual(group, "Group api, 3 sessions")
            let tree = AXTreeSupport.tree(AgentSidebarView(model: m).frame(width: AgentWindowModel.fullSidebarWidth, height: 900), CGSize(width: AgentWindowModel.fullSidebarWidth, height: 900)) { t in
                t.contains { $0.label == group } && names.allSatisfy { w in t.contains { $0.label == w } }
            }
            let g = try XCTUnwrap(tree.first { $0.label == group && !$0.ignored }, "\(tree.map(\.label))")
            let lines = names.compactMap { w in tree.first { $0.label == w && !$0.ignored } }
            XCTAssertEqual(lines.count, 3, "each line its own element: \(tree.map(\.label))")
            XCTAssertEqual(lines.map(\.frame.minY), lines.map(\.frame.minY).sorted(by: >), "group order, top to bottom")
            for l in lines { XCTAssertTrue(g.frame.contains(CGPoint(x: l.frame.midX, y: l.frame.midY)), "\(l.label) in the group") }
            let web = try XCTUnwrap(tree.first { $0.label == words(m, "web") && !$0.ignored })
            XCTAssertFalse(g.frame.contains(CGPoint(x: web.frame.midX, y: web.frame.midY)), "web is its own row")
        }
    }

    /// A press on api-qa's line selects api-qa, then one on api-2's selects api-2: the selection is on that line (its
    /// element reads selected, the others not). Each line is its own button with its own frame (TIP draws no hover on a
    /// row: the pointer's target is the line's button).
    func testMemberLineClickSelectsThatSession() throws {
        try withRow {
            let (m, _) = model(grouped)
            defer { m.close() }
            let restore = AXTreeSupport.axOn()
            defer { restore() }
            let width = AgentWindowModel.fullSidebarWidth
            let (win, host) = AXTreeSupport.hosted(AgentSidebarView(model: m).frame(width: width, height: 900), CGSize(width: width, height: 900))
            defer { win.close() }
            let names = ["api", "api-2", "api-qa"].map { words(m, $0) }
            _ = AXTreeSupport.poll(host) { t in names.allSatisfy { w in t.contains { $0.label == w } } }
            for name in ["api-qa", "api-2"] {
                let w = words(m, name)
                let line = try XCTUnwrap(pressable(host, label: w), "no button for \(name)")
                XCTAssertTrue(press(line), "\(name) pressed")
                XCTAssertEqual(m.selection, key(name), "the line's own session")
                let tree = AXTreeSupport.poll(host) { t in t.contains { $0.label == w && $0.selected } }
                for n in names { XCTAssertEqual(tree.contains { $0.label == n && $0.selected }, n == w, "\(n) selected only on \(name)'s line") }
            }
            let after = AXTreeSupport.poll(host) { _ in true }
            let frames = names.compactMap { n in after.first { $0.label == n && !$0.ignored }?.frame }
            XCTAssertEqual(frames.count, 3, "each line its own element")
            let pixel = AXTreeSupport.devicePixel(of: win)
            for (i, a) in frames.enumerated() {
                for b in frames.dropFirst(i + 1) {
                    XCTAssertFalse(a.insetBy(dx: 0, dy: pixel).intersects(b), "one target per line: \(a) \(b)")
                }
            }
            XCTAssertFalse(win.isVisible, "never shown")
        }
    }

    /// At 0.7, 0.85 and 1.0: the lines do not overlap, the group's height is its lines' plus its own padding, and nothing is
    /// drawn past the sidebar's width.
    func testGroupRowAtEveryScale() throws {
        try withRow {
            let (m, _) = model(grouped)
            defer { m.close() }
            let pixel = AXTreeSupport.devicePixel
            for scale in Self.scales {
                ThemeRuntime.scale = scale
                let width = AgentWindowModel.fullSidebarWidth, group = AgentSidebarGroupRow<EmptyView>.words(stem: "api", count: 3)
                let names = ["api", "api-2", "api-qa"].map { words(m, $0) }
                let tree = AXTreeSupport.tree(AgentSidebarView(model: m).frame(width: width, height: 900), CGSize(width: width, height: 900)) { t in
                    t.contains { $0.label == group } && names.allSatisfy { w in t.contains { $0.label == w } }
                }
                let g = try XCTUnwrap(tree.first { $0.label == group && !$0.ignored }, "the group at \(scale)")
                let lines = names.compactMap { w in tree.first { $0.label == w && !$0.ignored }?.frame }
                XCTAssertEqual(lines.count, 3, "at \(scale)")
                for (a, b) in zip(lines, lines.dropFirst()) {
                    XCTAssertLessThanOrEqual(b.maxY, a.minY + pixel, "no overlap at \(scale): \(a) \(b)")
                }
                XCTAssertEqual(g.frame.height, lines.map(\.height).reduce(0, +) + 2 * AgentSidebarGroupRow<EmptyView>.padding,
                               accuracy: pixel, "the lines plus the padding at \(scale)")
                for f in [g.frame] + lines {
                    XCTAssertGreaterThanOrEqual(f.minX, -pixel, "inside the sidebar at \(scale)")
                    XCTAssertLessThanOrEqual(f.maxX, width + pixel, "inside sz(290) at \(scale): \(f)")
                }
            }
        }
    }

    // MARK: AX press (no event; the offscreen window's own tree)

    /// The first element under `e` named `label` that takes a press.
    private func pressable(_ e: Any, label: String, depth: Int = 0) -> NSObject? {
        guard depth < 60, let o = e as? NSObject else { return nil }
        let sel = NSSelectorFromString("accessibilityPerformPress")
        if o.responds(to: Selector(("accessibilityLabel"))), (o.value(forKey: "accessibilityLabel") as? String) == label,
           o.responds(to: sel) { return o }
        for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
            if let found = pressable(k, label: label, depth: depth + 1) { return found }
        }
        return nil
    }

    private func press(_ o: NSObject) -> Bool {
        let sel = NSSelectorFromString("accessibilityPerformPress")
        guard o.responds(to: sel) else { return false }
        if let p = o as? NSAccessibilityProtocol { return p.accessibilityPerformPress() }
        _ = o.perform(sel)
        return true
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1342, #1820: the pair groups are gone, so in the Agent Sessions sidebar every session is its own row (the group row
/// and its rows went with them); the helpers stay for the sidebar rows of other classes. Offscreen only: every window is built and never
/// shown, ordered in or made key; a line is pressed through this process's own accessibility tree (no event is posted).
/// Every row saves the sidebar mode, the split gate and the UI scale, and puts them back in a defer.
@MainActor
final class AgentSidebarGroupRowTests: XCTestCase {
    private let d1 = AgentWindowD1Tests()

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

    /// A shown model over `sessions` and `history`.
    func model(_ sessions: [AgentSession], history: [DchHistoryRecord] = []) -> (AgentWindowModel, AgentIslandStore) {
        let st = d1.store(sessions, history: history)
        let m = d1.windowModel(st)
        m.setVisible(true)
        return (m, st)
    }

    /// api (working), api-2 (idle), web (idle) and api-qa blocked (Needs you).
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

    /// #1820: api, api-qa and api-2 (once one pair group) and a History record: every section's items are its rows, one
    /// each, the same rows byte for byte; the sidebar draws each row at its own row's height, sz(2) apart, and no group
    /// element. Red at base with the suffix "-qa": api, api-2 and api-qa were one item of three rows.
    func testEveryRowIsItsOwnItemAndFrame() throws {
        try withRow {
            let (gm, _) = model(grouped, history: [d1.record("web-qa")])
            defer { gm.close() }
            let drawn = AgentSidebar.items(gm.sections)
            XCTAssertEqual(drawn.count, gm.sections.count)
            for s in gm.sections {
                let items = drawn[s.id] ?? []
                XCTAssertEqual(items.map(\.rows), s.rows.map { [$0] }, "\(s.title): the rows, one per item")
                XCTAssertEqual(items.map(\.id), s.rows.map(\.id))
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

    /// A press on api-qa's row selects api-qa, then one on api-2's selects api-2: the selection is on that row (its
    /// element reads selected, the others not). Each row is its own button with its own frame.
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

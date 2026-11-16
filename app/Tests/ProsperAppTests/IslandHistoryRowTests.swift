import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #994 (QA #569 INFO-2, INFO-3; QA #570 INFO-4): the History row's play icons and context menu reach the right
/// resume action, a refused row's tooltip is empty by value, and equal-lastSeen records of one name order stably.
/// Offscreen only: a row is hosted in a window that is never shown and pressed through its accessibility action
/// (no event is posted, no menu is opened, no hover). No dch runs.
final class IslandHistoryRowTests: XCTestCase {
    private let notched = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)
    private static let v127 = DchCommand.Binary(path: "/fake/dch", version: [1, 27, 0])

    private func record(_ name: String = "api", ended: TimeInterval = 100) -> DchHistoryRecord {
        DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: name), cwd: "/src", updated: ended, ended: ended, end: "signal 9")
    }

    private final class Log { var calls: [String] = [] }

    /// The drawn row's context menu items by title: Resume (with message), Resume (no message), Pin, Remove; each
    /// item runs the view's own callback for its record (the wrong resume action reads as the wrong call here).
    @MainActor
    func testHistoryContextMenuItemsReachTheirActions() throws {
        let store = AgentIslandStore(geometry: notched)
        store.controlDch = Self.v127
        store.history = [record("api")]
        store.historyTab = true
        let log = Log()
        let view = AgentIslandView(store: store, onResume: { log.calls.append("msg:\($0.name)") },
                                   onResumeNoMessage: { log.calls.append("quiet:\($0.name)") },
                                   onPin: { log.calls.append("pin:\($0.name)") }, onRemove: { log.calls.append("remove:\($0.name)") })
        let row = try XCTUnwrap(view.historyDrawn.first)
        XCTAssertEqual(row.menu.map(\.title), [AgentIsland.resumeLabel, AgentIsland.resumeNoMessageLabel,
                                               AgentIsland.pinLabel, AgentIsland.removeLabel])
        for item in row.menu { item.action() }
        XCTAssertEqual(log.calls, ["msg:api", "quiet:api", "pin:api", "remove:api"])
    }

    /// The `.contextMenu` itself cannot be opened here, so the line that attaches `r.menu` to each History row is
    /// pinned in the source (as are the play icons' wiring): dropping the modifier reads as red.
    func testHistoryRowsAttachTheContextMenu() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/AgentIsland/AgentIslandView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let attach = ".contextMenu { ForEach(r.menu, id: \\.title) { Button($0.title, action: $0.action) } }"
        let at = try XCTUnwrap(src.range(of: "ForEach(historyDrawn) { r in"), "the History rows loop")
        let tail = String(src[at.upperBound...])
        let end = try XCTUnwrap(tail.range(of: "ForEach(drawn) { r in"), "the Sessions rows loop follows")
        XCTAssertTrue(tail[..<end.lowerBound].contains(attach), "each drawn History row carries its context menu")
        // QA #569 INFO-3: the two play icons (an inner button is not its own AX element, so pinned here): the filled
        // one runs the row's `action` (Resume with the message), the outline one `resumeNoMessage`.
        // #1069 (QA #742 INFO-1): each by its own symbol constant (AgentIslandWordingTests pins the two shapes).
        XCTAssertTrue(src.contains("iconButton(AgentIsland.resumeWithMessageSymbol, ink: quiet, label: AgentIsland.resumeWithMessageHelp, action: action)"),
                      "the filled play runs Resume with the message")
        XCTAssertTrue(src.contains("iconButton(AgentIsland.resumeNoMessageSymbol, ink: quiet, label: AgentIsland.resumeNoMessageLabel, action: resumeNoMessage)"),
                      "the skip icon runs Resume (no message)")
    }

    /// The row's click (its filled play icon's action, drawn from the same closure) and the row's "Resume (no message)"
    /// action reach their own resume, pressed through the accessibility actions of the hosted, never-shown row (a nested
    /// icon button is not its own AX element). The icon's wiring itself is pinned in the source row below.
    @MainActor
    func testRowClickAndNoMessageActionRunTheirOwnResume() throws {
        let log = Log()
        let row = AgentIslandHistoryRow(record: record(), now: 0, status: nil, enabled: true,
                                        action: { log.calls.append("msg") }, pin: { log.calls.append("pin") },
                                        remove: { log.calls.append("remove") },
                                        resumeNoMessage: { log.calls.append("quiet") })
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let (window, host) = AXTreeSupport.hosted(row, CGSize(width: 420, height: AgentIslandGeometry.rowHeight))
        defer { window.close() }
        let dump = { (host: NSView) in self.items(host).map { "\($0.role)|\($0.label)|\($0.customs.map(\.name))" }.joined(separator: "; ") }
        let button = try XCTUnwrap(wait(host) { $0.first { $0.label.hasPrefix("api") && $0.object.responds(to: NSSelectorFromString("accessibilityPerformPress")) } },
                                   "no row button: \(dump(host))")
        XCTAssertTrue(press(button.object), "row pressed")
        XCTAssertEqual(log.calls, ["msg"], "the row click runs Resume with the message")
        let quiet = try XCTUnwrap(items(host).lazy.flatMap(\.customs).first { $0.name == AgentIsland.resumeNoMessageLabel },
                                  "no no-message action: \(dump(host))")
        XCTAssertTrue(quiet.handler?() ?? false, "action ran")
        XCTAssertEqual(log.calls, ["msg", "quiet"], "Resume (no message) runs its own resume")
        XCTAssertFalse(window.isVisible, "never shown")
    }

    /// A refused row (enabled false) has an empty tooltip and hint by value, and no filled play button; the enabled
    /// row's is the Resume text. (That AppKit hides an empty tooltip is not checked: it takes a hover.)
    @MainActor
    func testRefusedRowHasAnEmptyHelpByValue() throws {
        func row(_ enabled: Bool) -> AgentIslandHistoryRow {
            AgentIslandHistoryRow(record: record(), now: 0, status: nil, enabled: enabled, action: {})
        }
        XCTAssertEqual(row(false).helpText, "")
        XCTAssertEqual(row(true).helpText, AgentIsland.resumeWithMessageHelp)
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let (window, host) = AXTreeSupport.hosted(row(false), CGSize(width: 420, height: AgentIslandGeometry.rowHeight))
        defer { window.close() }
        let tree = wait(host) { items in items.contains { $0.label.hasPrefix("api") } ? items : nil }
        XCTAssertNotNil(tree, "the row was drawn")
        XCTAssertFalse((tree ?? []).contains { $0.role == "AXButton" && $0.label == AgentIsland.resumeWithMessageHelp },
                       "no filled play on a refused row")
    }

    /// QA #570 INFO-4: two records of one (dir, name) with the same lastSeen order the same whatever order dch
    /// listed them in; the unaside record (file "") is the first, which is the one the row keeps.
    func testEqualLastSeenRecordsOrderStably() {
        let live = #"{"name":"work","ended":500,"updated":500,"end":"stopped"}"#
        let aside = #"{"name":"work","ended":500,"updated":500,"end":"stopped","file":"work.500"}"#
        for listing in [[live, aside], [aside, live]] {
            let out = AgentIsland.history(dirs: ["/d"]) { _, _ in Data("[\(listing.joined(separator: ","))]".utf8) }
            XCTAssertEqual(out.map(\.id.name), ["work", "work.500"], "listed \(listing.first == live ? "unaside" : "aside") first")
            XCTAssertEqual(AgentIsland.newestPerName(out).map(\.id.name), ["work"], "the row keeps the unaside record")
        }
    }

    // MARK: - AX press (no event; the offscreen window's own tree)

    private struct Item { let object: NSObject; let role: String; let label: String; let customs: [NSAccessibilityCustomAction] }

    private func press(_ o: NSObject) -> Bool {
        let sel = NSSelectorFromString("accessibilityPerformPress")
        guard o.responds(to: sel) else { return false }
        if let p = o as? NSAccessibilityProtocol { return p.accessibilityPerformPress() }
        _ = o.perform(sel)
        return true
    }

    @MainActor
    private func items(_ host: NSView) -> [Item] {
        var out: [Item] = []
        func walk(_ e: Any, depth: Int) {
            guard depth < 60, let o = e as? NSObject else { return }
            func text(_ key: String) -> String {
                guard o.responds(to: Selector(key)) else { return "" }
                let v = o.value(forKey: key)
                return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
            }
            out.append(Item(object: o, role: text("accessibilityRole"), label: text("accessibilityLabel"),
                            customs: o.responds(to: Selector(("accessibilityCustomActions")))
                                ? o.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? [] : []))
            for k in o.value(forKey: "accessibilityChildren") as? [Any] ?? [] { walk(k, depth: depth + 1) }
        }
        walk(host, depth: 0)
        return out
    }

    /// Lays out and reads the tree until `found` returns a value, or nil after 5 s (a ceiling, not a wait).
    @MainActor
    private func wait<T>(_ host: NSView, _ found: ([Item]) -> T?) -> T? {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let v = found(items(host)) { return v }
        } while Date() < deadline
        return nil
    }
}

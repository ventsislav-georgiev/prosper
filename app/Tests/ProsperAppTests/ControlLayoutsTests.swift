import Foundation
import XCTest
@testable import ProsperApp

/// #1841: saved layouts over the control channel, on the window model's own seams (no dch, no window shown).
final class ControlLayoutsTests: XCTestCase {
    let base = AgentWindowD1Tests()

    @MainActor
    func withModel(_ body: (AgentWindowModel) throws -> Void) rethrows {
        let saved = (ControlSessions.model, AgentPaneLayout.splitsEnabled)
        defer { (ControlSessions.model, AgentPaneLayout.splitsEnabled) = saved }
        let m = base.windowModel(base.store([base.session("api", .idle), base.session("web", .idle)]), layouts: base.layoutSuite())
        defer { m.close() }
        AgentPaneLayout.splitsEnabled = true
        ControlSessions.model = { m }
        try body(m)
    }

    func args(_ d: [String: String]) -> [String: ControlJSON] { d.mapValues { .string($0) } }

    @MainActor
    func refused<T>(_ expr: @autoclosure () throws -> T, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) {
            XCTAssertEqual(($0 as? ControlError)?.message, message, file: file, line: line)
        }
    }

    func names(_ j: ControlJSON) -> [String] {
        guard case .object(let o) = j, case .array(let a)? = o["layouts"] else { return [] }
        return a.compactMap { if case .object(let r) = $0, case .string(let n)? = r["name"] { n } else { nil } }
    }

    /// A lone layout lists as one row; new (named) and its undo; rename and its undo.
    @MainActor
    func testNewAndRenameAndTheirUndos() throws {
        try withModel { m in
            XCTAssertEqual(names(try ControlLayouts.list()).count, 1)
            let first = m.layout.id
            let made = try ControlLayouts.new(args(["name": "  Review  "]))
            XCTAssertEqual(names(try ControlLayouts.list()).last, "Review")
            let second = m.layout.id
            XCTAssertEqual(made.result, .string(second.uuidString))
            XCTAssertNotEqual(first, second)
            let ren = try ControlLayouts.rename(args(["id": second.uuidString, "name": "Docs"]))
            XCTAssertEqual(names(try ControlLayouts.list()).last, "Docs")
            ren.undo?()
            XCTAssertEqual(names(try ControlLayouts.list()).last, "Review")
            made.undo?()
            XCTAssertEqual(m.layouts?.layouts.map(\.id), [first], "undo deletes the new layout")
            XCTAssertEqual(m.layout.id, first)
            refused(try ControlLayouts.new(["name": .string("  ")]), "argument 'name' is empty")
        }
    }

    /// Switch by id, name (case folded) and previous; undo switches back; the active one is refused.
    @MainActor
    func testSwitchByIdNamePreviousAndUndo() throws {
        try withModel { m in
            let first = m.layout.id
            _ = try ControlLayouts.new(args(["name": "Review"]))
            let second = m.layout.id
            let a = try ControlLayouts.switchTo(["previous": .bool(true)])
            XCTAssertEqual(m.layout.id, first)
            XCTAssertTrue(a.undo != nil, "undo is set")
            a.undo?()
            XCTAssertEqual(m.layout.id, second)
            _ = try ControlLayouts.switchTo(args(["id": first.uuidString]))
            XCTAssertEqual(m.layout.id, first)
            let b = try ControlLayouts.switchTo(args(["name": "review"]))
            XCTAssertEqual(m.layout.id, second)
            b.undo?()
            XCTAssertEqual(m.layout.id, first)
            refused(try ControlLayouts.switchTo(args(["id": first.uuidString])), "\(ControlLayouts.rows(m).first?.name ?? "") is already the active layout")
            refused(try ControlLayouts.switchTo(args(["name": "nope"])), "no layout named nope (layouts.list lists them)")
            refused(try ControlLayouts.switchTo([:]), "give exactly one of id, name or previous")
            refused(try ControlLayouts.switchTo(args(["id": first.uuidString, "name": "Review"])), "give exactly one of id, name or previous")
        }
    }

    /// Delete: no undo, the last layout is refused; the 9-layout cap refuses new; the gate off refuses all.
    @MainActor
    func testDeleteCapAndGate() throws {
        try withModel { m in
            let first = m.layout.id
            refused(try ControlLayouts.delete(args(["id": first.uuidString])), "the only layout cannot be deleted")
            let made = try ControlLayouts.new([:])
            let del = try ControlLayouts.delete(args(["id": m.layout.id.uuidString]))
            XCTAssertNil(del.undo, "no inverse")
            XCTAssertTrue(del.summary.contains("cannot be undone"), "the notice says the delete is final")
            XCTAssertEqual(m.layouts?.layouts.map(\.id), [first], "deleted through the model")
            let ghost = "00000000-0000-0000-0000-000000000001"
            refused(try ControlLayouts.delete(args(["id": ghost])), "no layout with id \(ghost) (layouts.list lists them)")
            refused(try ControlLayouts.delete(args(["id": "nope"])), "no layout with id nope (layouts.list lists them)")
            XCTAssertEqual(m.layouts?.layouts.map(\.id), [first], "an unknown id deletes nothing")
            XCTAssertEqual(m.layout.id, first)
            _ = made
            for _ in 0..<8 { _ = try ControlLayouts.new([:]) }
            XCTAssertEqual(m.layouts?.layouts.count, 9)
            refused(try ControlLayouts.new([:]), PaneRefusal.layoutCap.notice ?? "")
            AgentPaneLayout.splitsEnabled = false
            refused(try ControlLayouts.list(), ControlLayouts.off)
            refused(try ControlLayouts.new([:]), ControlLayouts.off)
        }
        let saved = ControlSessions.model
        defer { ControlSessions.model = saved }
        ControlSessions.model = { nil }
        refused(try ControlLayouts.list(), "Agent Sessions is not open")
    }

    /// #1895 (replaces QA n134's Edit layout row: there is no mode left): layouts.new makes one empty pane, saved, which
    /// takes the next pick (saved at once); the 9-layout cap is still refused.
    @MainActor
    func testNewMakesAnEmptyPaneThatTakesTheNextPick() throws {
        try withModel { m in
            _ = try ControlLayouts.new([:])
            XCTAssertTrue(m.layout.panes.count == 1 && m.layout.panes.first?.target == nil, "one empty pane")
            m.select(.live(base.paneKey("web")))
            XCTAssertEqual(m.layout.panes.map(\.target), [base.paneTarget("web")], "the empty pane took the pick")
            XCTAssertTrue(m.parked == nil && m.layouts?.activeLayout == m.layout, "saved at once, no single-pane view")
            for _ in 0..<7 { _ = try ControlLayouts.new([:]) }
            XCTAssertEqual(m.layouts?.layouts.count, 9)
            XCTAssertThrowsError(try ControlLayouts.new([:]))
        }
    }

    /// QA n135: none of switch, new, delete closes an open New session form.
    @MainActor
    func testOpenNewSessionFormSurvivesSwitchNewAndDelete() throws {
        try withModel { m in
            let first = m.layout.id
            m.store?.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1])
            _ = try ControlLayouts.new([:])
            m.openNewSession()
            XCTAssertTrue(m.newSession != nil, "form open")
            _ = try ControlLayouts.switchTo(args(["id": first.uuidString]))
            XCTAssertTrue(m.newSession != nil, "switch")
            _ = try ControlLayouts.new([:])
            XCTAssertTrue(m.newSession != nil, "new")
            _ = try ControlLayouts.delete(args(["id": m.layout.id.uuidString]))
            XCTAssertTrue(m.newSession != nil, "delete")
        }
    }

    /// Registered: list is a read, the rest change state.
    @MainActor
    func testRegistration() {
        var r = ControlRegistry()
        ControlRegistry.registerLayouts(&r)
        XCTAssertEqual(r.commands["layouts.list"]?.mutates, false)
        for n in ["switch", "new", "rename", "delete"] { XCTAssertEqual(r.commands["layouts.\(n)"]?.mutates, true) }
        XCTAssertEqual(Set(r.commands.keys), ["layouts.list", "layouts.new", "layouts.rename", "layouts.switch", "layouts.delete"])
    }
}

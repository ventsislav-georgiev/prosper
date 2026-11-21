import AppKit
import Foundation
import XCTest
@testable import ProsperApp

/// #1808: the agent-change helper (notice with Undo, bounded log), `ctl log`, and the Settings switch that refuses
/// changes while reads still work. A fake "color" command stands in for the later phases' real ones; the notice goes
/// to a recorder (ControlChanges.present), and the one panel row builds the panel without ever showing it.
@MainActor
final class ControlNoticeTests: XCTestCase {

    @MainActor private final class Box { var color = "red" }

    private struct Shown { let text: String; let undo: @MainActor () -> Void }

    private var shown: [Shown] = []
    private let box = Box()

    override func setUp() async throws {
        Preferences.defaults.removeObject(forKey: Preferences.agentControlKey)
        addTeardownBlock { Preferences.defaults.removeObject(forKey: Preferences.agentControlKey) }
    }

    /// The standard registry plus a fake mutating "color" command, with its own log and a recording notice.
    private func registry() -> ControlRegistry {
        var reg = ControlRegistry.standard()
        let changes = ControlChanges()
        changes.present = { [weak self] text, undo in self?.shown.append(Shown(text: text, undo: undo)) }
        reg.changes = changes
        let box = box
        reg.register(.change(name: "color", summary: "set the color", args: ["to": ControlArg(type: "string", required: true)]) { _, args in
            guard case .string(let to)? = args["to"] else { throw ControlError("no color") }
            let old = box.color
            box.color = to
            return ControlChange(summary: "color to \(to)", result: .string(to)) { box.color = old }
        })
        return reg
    }

    private func call(_ reg: ControlRegistry, _ json: String) async -> ControlReply {
        await reg.reply(to: Data(json.utf8))
    }

    private func logChanges(_ reg: ControlRegistry) async -> [[String: ControlJSON]] {
        let r = await call(reg, #"{"cmd":"log"}"#)
        guard r.ok, case .object(let o)? = r.result, case .array(let a)? = o["changes"] else { XCTFail("log: \(r)"); return [] }
        return a.compactMap { if case .object(let e) = $0 { return e }; return nil }
    }

    func testChangeRunsShowsTheNoticeLogsAndUndoes() async {
        let reg = registry()
        let r = await call(reg, #"{"cmd":"color","args":{"to":"Royal Purple"}}"#)
        XCTAssertEqual(r, ControlReply(ok: true, result: .string("Royal Purple"), error: nil))
        XCTAssertEqual(box.color, "Royal Purple")
        XCTAssertEqual(shown.map(\.text), ["Agent changed: color to Royal Purple"])
        var log = await logChanges(reg)
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.last?["command"], .string("color"))
        XCTAssertEqual(log.last?["summary"], .string("color to Royal Purple"))
        XCTAssertEqual(log.last?["undone"], .bool(false))

        shown.last?.undo()
        XCTAssertEqual(box.color, "red")
        log = await logChanges(reg)
        XCTAssertEqual(log.last?["undone"], .bool(true))
        // A second click (or a stale notice) never runs the inverse again.
        box.color = "green"
        shown.last?.undo()
        XCTAssertEqual(box.color, "green")
        XCTAssertEqual(reg.changes.undo(1), false)
    }

    func testAFailedChangeIsNotLoggedOrAnnounced() async {
        let reg = registry()
        let r = await call(reg, #"{"cmd":"color","args":{"to":1}}"#)
        XCTAssertEqual(r.ok, false)
        XCTAssertTrue(shown.isEmpty)
        XCTAssertTrue(reg.changes.entries.isEmpty)
    }

    func testSwitchDefaultsOn() {
        XCTAssertTrue(Preferences.defaults.object(forKey: Preferences.agentControlKey) == nil)
        XCTAssertTrue(Preferences.agentControlEnabled)
    }

    func testSwitchOffRefusesChangesButReadsStillWork() async {
        let reg = registry()
        Preferences.agentControlEnabled = false
        let r = await call(reg, #"{"cmd":"color","args":{"to":"blue"}}"#)
        XCTAssertEqual(r, ControlReply(ok: false, result: nil, error: "agent control is off in Settings"))
        XCTAssertEqual(r.line, Data(#"{"error":"agent control is off in Settings","ok":false}"#.utf8) + Data("\n".utf8))
        XCTAssertEqual(box.color, "red")
        XCTAssertTrue(shown.isEmpty)
        for read in ["ping", "describe", "version", "log"] {
            let rr = await call(reg, #"{"cmd":"\#(read)"}"#)
            XCTAssertEqual(rr.ok, true, read)
        }
        let log = await logChanges(reg)
        XCTAssertEqual(log.count, 0)

        Preferences.agentControlEnabled = true
        let again = await call(reg, #"{"cmd":"color","args":{"to":"blue"}}"#)
        XCTAssertEqual(again.ok, true)
        XCTAssertEqual(box.color, "blue")
    }

    func testLogIsBoundedAndDropsTheOldestUndos() {
        let changes = ControlChanges()
        changes.present = { _, _ in }
        var undone = 0
        let extra = 5
        for i in 0..<(ControlChanges.capacity + extra) {
            changes.record(command: "c", summary: "change \(i)") { undone += 1 }
        }
        XCTAssertEqual(changes.entries.count, ControlChanges.capacity)
        XCTAssertEqual(changes.entries.first?.summary, "change \(extra)")
        XCTAssertEqual(changes.entries.last?.summary, "change \(ControlChanges.capacity + extra - 1)")
        XCTAssertFalse(changes.undo(1), "a change that fell out of the log keeps no undo")
        XCTAssertTrue(changes.undo(ControlChanges.capacity + extra))
        XCTAssertEqual(undone, 1)
    }

    func testDescribeMarksChangeCommandsAsMutatingAndLogAsARead() {
        let d = registry().describe
        guard case .object(let o) = d, case .array(let cmds)? = o["commands"] else { return XCTFail("\(d)") }
        var mutates: [String: ControlJSON] = [:]
        for case .object(let c) in cmds { if case .string(let n)? = c["name"] { mutates[n] = c["mutates"] } }
        XCTAssertEqual(mutates["color"], .bool(true))
        XCTAssertEqual(mutates["log"], .bool(false))
    }

    func testNoticePanelNeverTakesFocusAndHidesAfterSixSeconds() {
        let panel = ControlNotice().makePanel()
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(ControlNotice.visibleSeconds, 6)
        XCTAssertEqual(ControlChanges.noticeText("theme to Royal Purple"), "Agent changed: theme to Royal Purple")
    }
}

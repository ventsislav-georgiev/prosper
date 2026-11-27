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
    @MainActor private final class Count { var n = 0 }

    private struct Shown { let text: String; let undo: (@MainActor () -> Void)? }

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

        XCTAssertEqual(log.last?["undoable"], .bool(true))
        XCTAssertTrue(shown.last?.undo != nil)

        shown.last?.undo?()
        XCTAssertEqual(box.color, "red")
        log = await logChanges(reg)
        XCTAssertEqual(log.last?["undone"], .bool(true))
        // A second click (or a stale notice) never runs the inverse again.
        box.color = "green"
        shown.last?.undo?()
        XCTAssertEqual(box.color, "green")
        XCTAssertEqual(reg.changes.undo(1), false)
    }

    func testAChangeWithNoInverseHasNoUndoAndTheLogSaysNotUndoable() async {
        var reg = registry()
        reg.register(.change(name: "fire", summary: "fire it") { _, _ in ControlChange(summary: "fired it", verb: "ran") })
        let r = await call(reg, #"{"cmd":"fire"}"#)
        XCTAssertTrue(r.ok, "\(r)")
        XCTAssertEqual(shown.map(\.text), ["Agent ran: fired it"])
        XCTAssertTrue(shown.last?.undo == nil, "no inverse: the notice model gets no undo, so the panel hides Undo")
        let log = await logChanges(reg)
        XCTAssertEqual(log.last?["undoable"], .bool(false))
        XCTAssertEqual(log.last?["undone"], .bool(false))
        XCTAssertEqual(reg.changes.undo(1), false, "the entry has no undo slot to call")
        XCTAssertEqual(reg.changes.entries.last?.undone, false)
    }

    func testAHostileSummaryIsCleanedAndCappedInTheNoticeAndTheLog() async {
        var reg = registry()
        let hostile = "ok\u{202E}evil\nline\u{0007}two" + String(repeating: "x", count: 10_000)
        reg.register(.change(name: "say", summary: "say it") { _, _ in ControlChange(summary: hostile) })
        _ = await call(reg, #"{"cmd":"say"}"#)
        let want = OutsideText.shown(hostile, max: ControlChanges.summaryMax)
        XCTAssertEqual(want.count, ControlChanges.summaryMax)
        XCTAssertTrue(want.hasPrefix("okevillinetwoxxx") && want.hasSuffix("\u{2026}"))
        XCTAssertEqual(shown.map(\.text), ["Agent changed: " + want])
        let log = await logChanges(reg)
        XCTAssertEqual(log.last?["summary"], .string(want))
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
        XCTAssertEqual(ControlChanges.noticeText("x", verb: "ran"), "Agent ran: x")
    }

    // MARK: - #2047: who sent it, the whole message, time to read it

    /// A change whose request carries the client's DCH_SESSION names that live session (its shown title) in the notice
    /// and the log; a name no live session has, or none, reads as before. A read never looks the sender up.
    func testAChangeFromAKnownSessionNamesItsSenderInTheNoticeAndTheLog() async {
        let saved = (ControlSessions.model, ControlSessions.islandStore)
        defer { (ControlSessions.model, ControlSessions.islandStore) = saved }
        let fakes = AgentWindowD1Tests()
        let st = fakes.store([fakes.session("perf-1", .idle, alias: "Perf"), fakes.session("api", .idle)])
        let count = Count()
        ControlSessions.model = { nil }
        ControlSessions.islandStore = { count.n += 1; return st }
        let reg = registry()

        _ = await call(reg, #"{"cmd":"color","args":{"to":"blue"},"from":"perf-1"}"#)
        XCTAssertEqual(shown.map(\.text).last, "Perf changed: color to blue")
        XCTAssertEqual(count.n, 1, "one lookup for the change")
        var log = await logChanges(reg)
        XCTAssertEqual(log.last?["sender"], .string("Perf"))
        XCTAssertEqual(reg.changes.entries.last?.sender, "Perf")

        _ = await call(reg, #"{"cmd":"color","args":{"to":"green"},"from":"a-terminal"}"#)
        XCTAssertEqual(shown.map(\.text).last, "Agent changed: color to green", "unknown sender: today's text")
        _ = await call(reg, #"{"cmd":"color","args":{"to":"red"}}"#)
        XCTAssertEqual(shown.map(\.text).last, "Agent changed: color to red", "no sender: today's text")
        log = await logChanges(reg)
        XCTAssertTrue(log.last?["sender"] == nil)

        let before = count.n
        _ = await call(reg, #"{"cmd":"log","from":"perf-1"}"#)
        _ = await call(reg, #"{"cmd":"ping","from":"perf-1"}"#)
        XCTAssertEqual(count.n, before, "a read costs no lookup")
    }

    /// The message notice: "<sender> → <target> (<verb>)", then the message whole (300 characters come through), at most
    /// eight lines and a "…" line, every line cleaned of bidi and control characters, the whole at most bodyMax.
    func testMessageNoticeShowsTheWholeMessageUpToEightLinesCleaned() {
        let long = String(repeating: "abcdefghij", count: 30)
        XCTAssertEqual(ControlChanges.messageText(long, target: "API", verb: "messaged", sender: "Perf"),
                       "Perf → API (messaged)\n" + long)
        XCTAssertEqual(ControlChanges.messageText("go on", target: "API", verb: "messaged", sender: nil),
                       "Agent → API (messaged)\ngo on")

        let twelve = (1...12).map { "line \($0)" }.joined(separator: "\n")
        let t = ControlChanges.messageText(twelve, target: "API", verb: "messaged", sender: nil)
        let lines = t.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 1 + 8 + 1, "the title, eight lines, the ellipsis")
        XCTAssertEqual(lines.last, "…")
        XCTAssertTrue(t.contains("line 8") && !t.contains("line 9"))
        let eight = (1...8).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertFalse(ControlChanges.messageText(eight, target: "API", verb: "messaged", sender: nil).hasSuffix("…"))

        let dirty = ControlChanges.messageText("ok\u{202E}evil\u{07}\tnow\nnext\u{200B}", target: "API", verb: "messaged", sender: nil)
        XCTAssertEqual(dirty, "Agent → API (messaged)\nokevilnow\nnext")

        let huge = ControlChanges.messageText(String(repeating: "x", count: 5000), target: "API", verb: "messaged", sender: nil)
        let body = huge.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        XCTAssertEqual(body.count, ControlChanges.bodyMax)
        XCTAssertTrue(body.hasSuffix("…"))
    }

    /// Through record: a change with a target and a message shows the message notice; the log keeps the short summary.
    func testRecordShowsTheMessageNoticeAndKeepsTheLogSummaryShort() {
        let changes = ControlChanges()
        var texts: [String] = []
        changes.present = { text, _ in texts.append(text) }
        let message = String(repeating: "m", count: 300)
        let c = ControlChange(summary: "API: \(message)", verb: "messaged", target: "API", body: message)
        let e = changes.record(command: "sessions.say", change: c, sender: "Perf")
        XCTAssertEqual(texts, ["Perf → API (messaged)\n" + message])
        XCTAssertEqual(e.summary.count, ControlChanges.summaryMax)
        XCTAssertEqual(e.sender, "Perf")
    }

    /// A longer notice stays up longer, never shorter than today's six seconds nor past twelve.
    func testDisplayTimeScalesWithLengthAndStopsAtTheCap() {
        XCTAssertEqual(ControlNotice.seconds(for: "Agent changed: x"), ControlNotice.visibleSeconds)
        XCTAssertEqual(ControlNotice.seconds(for: String(repeating: "a", count: 200)), 10)
        XCTAssertEqual(ControlNotice.seconds(for: String(repeating: "a", count: 1000)), ControlNotice.maxSeconds)
        XCTAssertEqual(ControlNotice.maxSeconds, 12)
    }
}

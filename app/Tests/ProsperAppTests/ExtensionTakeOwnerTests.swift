import XCTest
import IOKit.pwr_mgt
import LuaRuntime
@testable import ProsperApp

/// #1550: each take() carries the generation of the call that made it, and its undo releases (id, key) only while
/// that generation still owns it. Fakes only: no power assertion (the IOPM calls are swapped), no XPC or pmset (the
/// lid override seam records), no menu bar item, key tap or fs watch (the main-actor owner table is tested alone),
/// and a timer is armed a day out on a private scheduler with an in-memory store, then cancelled.
private final class TakeRecorder: ExtensionHostServices, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    /// isCurrent answers true this many more times. The lid take acts on the apply chain, after take() returned,
    /// so its row allows exactly two checks (the gate's and take()'s guard) and the third, after the act, is false.
    private var _checksLeft = Int.max
    var calls: [String] { lock.withLock { _calls } }
    var current: Bool { lock.withLock { guard _checksLeft > 0 else { return false }; _checksLeft -= 1; return true } }
    func makeCurrent(checks: Int = Int.max) { lock.withLock { _checksLeft = checks } }
    /// A take: a teardown overtakes the call while it acts, so take() runs the undo.
    private func took(_ name: String, _ owner: Int) { lock.withLock { _calls.append("\(name) \(owner)"); _checksLeft = 0 } }
    private func undid(_ name: String, _ owner: Int) { lock.withLock { _calls.append("\(name) \(owner)") } }

    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
    func llmChat(_ prompt: String) async -> String { "" }
    func shellRun(_ command: String) async -> String { "" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
    func currentEpochSeconds() -> Double { 0 }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func prefGet(extensionID: String, key: String) -> String? { nil }
    func prefSet(extensionID: String, key: String, value: String) {}
    func notify(title: String, body: String) {}
    func listDirectories(_ path: String) -> [String] { [] }

    func timerSchedule(extensionID: String, id: String, every: Bool, seconds: Double, handler: String, owner: Int) { took("timerSchedule", owner) }
    func timerCancel(extensionID: String, id: String, owner: Int) { undid("timerCancel", owner) }
    func caffeinatePreventIdleSleep(extensionID: String, kind: String, on: Bool, owner: Int) {
        if on { took("idle on", owner) } else { undid("idle off", owner) }
    }
    func caffeinateSetDisableLidSleep(extensionID: String, on: Bool, owner: Int) async { undid(on ? "lid on" : "lid off", owner) }
    func menubarSet(extensionID: String, id: String, json: String, owner: Int) { took("menubarSet", owner) }
    func menubarRemove(extensionID: String, id: String, owner: Int) { undid("menubarRemove", owner) }
    func keysSetRules(extensionID: String, json: String, owner: Int) { took("keysSetRules", owner) }
    func keysClearRules(extensionID: String, owner: Int) { undid("keysClearRules", owner) }
    func fsWatch(extensionID: String, path: String, handler: String, hideSecrets: Bool, owner: Int) { took("fsWatch", owner) }
    func fsUnwatch(extensionID: String, path: String, owner: Int) { undid("fsUnwatch", owner) }
}

final class ExtensionTakeOwnerTests: XCTestCase {

    private final class MemoryStore: TimerStore {
        private let lock = NSLock()
        private var dict: [String: Data] = [:]
        func data(forKey key: String) -> Data? { lock.withLock { dict[key] } }
        func set(_ value: Any?, forKey key: String) { lock.withLock { dict[key] = value as? Data } }
    }

    /// Fake IOPM: hands out ids and records each release; nothing reaches the power manager.
    private final class FakeAssertions: @unchecked Sendable {
        private let lock = NSLock()
        private var next: IOPMAssertionID = 100
        private var _held: Set<IOPMAssertionID> = []
        var held: Set<IOPMAssertionID> { lock.withLock { _held } }
        func create() -> IOPMAssertionID? { lock.withLock { next += 1; _held.insert(next); return next } }
        func release(_ id: IOPMAssertionID) { _ = lock.withLock { _held.remove(id) } }
    }

    private func resources(_ fake: FakeAssertions) -> ExtensionResources {
        ExtensionResources(createAssertion: { _, _ in fake.create() }, releaseAssertion: { fake.release($0) })
    }

    private func drainApplyChain() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            LidSleepHelper.enqueueApply { c.resume() }
        }
    }

    // MARK: ExtensionHost passes the generation with the take and the same one with its undo

    func testTakeAndUndoCarryTheCallsGeneration() async throws {
        let svc = TakeRecorder()
        let lua = try LuaRuntime()
        var registered: [(String, (LuaRuntime) -> Int32)] = []
        try ExtensionHost(extensionID: "com.test.owner1550", services: svc,
                          isCurrent: { [svc] in svc.current }, generation: { 7 })
            .install(into: lua) { name, fn in registered.append((name, fn)) }
        for (name, fn) in registered { lua.register("t" + name, fn) }
        let calls = [#"t__h_timer_schedule("t", false, 5, "h")"#, #"t__h_caf_idle("system", true)"#,
                     #"t__h_menubar_set("m", "{}")"#, #"t__h_keys_rules("[]")"#,
                     #"t__h_fs_watch("/Users/example/notes", "h")"#, #"t__h_caf_lidsleep(true)"#]
        for c in calls {
            svc.makeCurrent(checks: c.contains("lidsleep") ? 2 : Int.max)
            try lua.run(c)
        }
        await drainApplyChain()
        XCTAssertEqual(svc.calls, ["timerSchedule 7", "timerCancel 7", "idle on 7", "idle off 7",
                                   "menubarSet 7", "menubarRemove 7", "keysSetRules 7", "keysClearRules 7",
                                   "fsWatch 7", "fsUnwatch 7", "lid on 7", "lid off 7"])
    }

    // MARK: Power assertions

    func testRetiredUndoLeavesTheLiveAssertionOfTheSameKind() {
        let fake = FakeAssertions(), res = resources(fake), id = "com.test.owner1550.assert"
        res.setAssertion(extID: id, kind: "system", on: true, owner: 3)       // the retired call's take
        res.setAssertion(extID: id, kind: "system", on: true, owner: -1)      // the live generation, same kind
        res.setAssertion(extID: id, kind: "system", on: false, owner: 3)      // the retired call's undo
        XCTAssertTrue(res.holdsAssertion(extID: id, kind: "system"), "the retired undo released the live take")
        XCTAssertEqual(fake.held.count, 1)
        res.releaseAll(extID: id)                                             // teardown: everything under the id
        XCTAssertFalse(res.holdsAssertion(extID: id, kind: "system"))
        XCTAssertEqual(fake.held.count, 0)
    }

    func testRetiredUndoStillReleasesItsOwnAssertion() {
        let fake = FakeAssertions(), res = resources(fake), id = "com.test.owner1550.assertown"
        res.setAssertion(extID: id, kind: "display", on: true, owner: 3)
        res.setAssertion(extID: id, kind: "display", on: false, owner: 3)
        XCTAssertFalse(res.holdsAssertion(extID: id, kind: "display"), "the retired call's own take stayed")
        XCTAssertEqual(fake.held.count, 0)
        // An explicit off (no owner) still releases whoever took it.
        res.setAssertion(extID: id, kind: "display", on: true, owner: -1)
        res.setAssertion(extID: id, kind: "display", on: false)
        XCTAssertEqual(fake.held.count, 0)
    }

    // MARK: Lid override (live service, override seam recorded: no XPC, no pmset)

    func testRetiredLidUndoLeavesTheLiveHold() async {
        let saved = LidSleepHelper.applyExtensionOverride
        let rec = Recorder()
        LidSleepHelper.applyExtensionOverride = { on in rec.record(on); return true }
        let id = "com.test.owner1550.lid.\(UUID().uuidString)"
        let services = LiveExtensionHostServices(defaults: scratchDefaults("owner1550"))
        await services.caffeinateSetDisableLidSleep(extensionID: id, on: true, owner: 3)
        await services.caffeinateSetDisableLidSleep(extensionID: id, on: true, owner: -1)
        await services.caffeinateSetDisableLidSleep(extensionID: id, on: false, owner: 3)
        XCTAssertEqual(rec.calls, [true, true], "the retired undo sent the release")
        XCTAssertTrue(ExtensionResources.shared.holdsLidSleepDisabled(extID: id), "the live hold was dropped")
        services.resetResources(extensionID: id)                              // teardown still releases
        await drainApplyChain()
        XCTAssertEqual(rec.calls, [true, true, false])
        XCTAssertFalse(ExtensionResources.shared.holdsLidSleepDisabled(extID: id))
        LidSleepHelper.applyExtensionOverride = saved
    }

    func testRetiredLidUndoStillReleasesItsOwnHold() async {
        let saved = LidSleepHelper.applyExtensionOverride
        let rec = Recorder()
        LidSleepHelper.applyExtensionOverride = { on in rec.record(on); return true }
        let id = "com.test.owner1550.lidown.\(UUID().uuidString)"
        let services = LiveExtensionHostServices(defaults: scratchDefaults("owner1550"))
        await services.caffeinateSetDisableLidSleep(extensionID: id, on: true, owner: 3)
        await services.caffeinateSetDisableLidSleep(extensionID: id, on: false, owner: 3)
        XCTAssertEqual(rec.calls, [true, false])
        XCTAssertFalse(ExtensionResources.shared.holdsLidSleepDisabled(extID: id))
        ExtensionResources.shared.releaseAll(extID: id)
        LidSleepHelper.applyExtensionOverride = saved
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [Bool] = []
        var calls: [Bool] { lock.withLock { _calls } }
        func record(_ on: Bool) { lock.withLock { _calls.append(on) } }
    }

    // MARK: Timers (private scheduler, in-memory store, a day out: none fires)

    func testRetiredTimerUndoLeavesTheLiveTimerOfTheSameID() {
        let timers = TimerScheduler(store: MemoryStore()), id = "com.test.owner1550.timer"
        defer { timers.cancelAll(extID: id) }
        timers.schedule(extID: id, id: "tick", every: false, seconds: 86_400, handler: "h", owner: 3)
        timers.schedule(extID: id, id: "tick", every: false, seconds: 86_400, handler: "h", owner: -1)
        timers.cancel(extID: id, id: "tick", owner: 3)
        XCTAssertTrue(timers.isScheduled(extID: id, id: "tick"), "the retired undo cancelled the live timer")
        timers.cancelAll(extID: id)                                           // teardown
        XCTAssertFalse(timers.isScheduled(extID: id, id: "tick"))
    }

    func testRetiredTimerUndoStillCancelsItsOwnTimer() {
        let timers = TimerScheduler(store: MemoryStore()), id = "com.test.owner1550.timerown"
        defer { timers.cancelAll(extID: id) }
        timers.schedule(extID: id, id: "tick", every: false, seconds: 86_400, handler: "h", owner: 3)
        timers.cancel(extID: id, id: "tick", owner: 3)
        XCTAssertFalse(timers.isScheduled(extID: id, id: "tick"), "the retired call's own timer stayed")
    }

    // MARK: Menu bar items, key rule sets, fs watches (the main-actor owner table)

    @MainActor
    func testMainActorOwnerTable() {
        let owners = ExtensionTakeOwners.shared, id = "com.test.owner1550.main.\(UUID().uuidString)"
        for kind in ["menubar", "keys", "fs"] {
            owners.claim(id, kind, "k", owner: 3)                             // retired take
            owners.claim(id, kind, "k", owner: -1)                            // live take, same key
            XCTAssertFalse(owners.release(id, kind, "k", owner: 3), "\(kind): the retired undo released the live take")
            owners.claim(id, kind, "own", owner: 3)
            XCTAssertTrue(owners.release(id, kind, "own", owner: 3), "\(kind): the retired call's own take stayed")
        }
        owners.removeAll(id)                                                  // teardown
        XCTAssertFalse(owners.release(id, "menubar", "k", owner: -1), "teardown left an owner")
    }
}

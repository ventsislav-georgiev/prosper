import XCTest
@testable import ProsperApp

/// #1862: ccpool.hold / ccpool.release over a pane rig (temp store, memory secrets, fake labels, the service never
/// started, no port or home of the real pool). Both go through the pane's own hold and release, with undo.
@MainActor
final class ControlCCPoolHoldTests: XCTestCase {
    private let t0 = 1_800_000_000.0

    private func rig() throws -> CCPoolPaneRig {
        let r = try ccpoolPaneRig(t0: t0)
        addTeardownBlock { @MainActor in CCPoolControl.model = { CCPoolRuntime.shared?.model } }
        CCPoolControl.model = { r.model }
        try r.add(["alpha", "bravo"])
        return r
    }

    private func args(_ label: String, _ hours: Double? = nil) -> [String: ControlJSON] {
        var a: [String: ControlJSON] = ["label": .string(label)]
        if let hours { a["hours"] = .number(hours) }
        return a
    }

    private func registry() -> ControlRegistry {
        var r = ControlRegistry()
        ControlRegistry.registerCCPoolHold(&r)
        return r
    }

    private func refused<T>(_ expr: @autoclosure () throws -> T, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), file: file, line: line) {
            XCTAssertEqual(($0 as? ControlError)?.message, message, file: file, line: line)
        }
    }

    func testBothAreChangesWithTheirArgs() {
        let reg = registry()
        XCTAssertEqual(reg.commands.keys.sorted(), ["ccpool.hold", "ccpool.release"])
        XCTAssertTrue(reg.commands.values.allSatisfy(\.mutates))
        XCTAssertEqual(reg.commands["ccpool.hold"]?.args["hours"]?.type, "number")
        XCTAssertEqual(reg.commands["ccpool.hold"]?.args["hours"]?.required, true)
        XCTAssertEqual(reg.commands["ccpool.release"]?.args.keys.sorted(), ["label"])
    }

    /// Hold benches the account like the pane's Hold; its undo puts the account back; release clears it and its undo holds again.
    func testHoldReleaseAndTheirUndos() throws {
        let r = try rig()
        let held = try CCPoolControl.hold(label: " alpha ", hours: 2)
        XCTAssertEqual(held.result, .string("alpha"))
        XCTAssertEqual(r.model.rows.first { $0.label == "alpha" }?.state, .held(until: Int(t0) + 7200))
        XCTAssertEqual(r.model.rows.first { $0.label == "bravo" }?.state, .ready, "only the named account")
        held.undo?()
        XCTAssertEqual(r.model.rows.first { $0.label == "alpha" }?.state, .ready, "undo of hold releases")
        XCTAssertEqual(r.store.snapshot.accounts["alpha"]?.held, nil)

        _ = try CCPoolControl.hold(label: "alpha", hours: 1)
        let freed = try CCPoolControl.release(label: "alpha")
        XCTAssertEqual(r.model.rows.first { $0.label == "alpha" }?.state, .ready)
        freed.undo?()
        XCTAssertEqual(r.model.rows.first { $0.label == "alpha" }?.state, .held(until: Int(t0) + 3600), "undo of release holds again")
    }

    /// A limit the proxy put on (not a hold) comes back with the undo of release.
    func testReleaseOfALimitAndItsUndo() throws {
        let r = try rig()
        let until = Int(t0) + 3600
        r.store.mutate { $0.accounts["bravo"]?.cooldown["seven_day"] = until }
        let freed = try CCPoolControl.release(label: "bravo")
        XCTAssertEqual(r.store.snapshot.accounts["bravo"]?.cooldown, [:])
        freed.undo?()
        XCTAssertEqual(r.store.snapshot.accounts["bravo"]?.cooldown, ["seven_day": until])
    }

    /// n171: an undo puts the account back only while it is still what the change left: a later hold or Release wins.
    func testUndoAfterALaterChangeDoesNothing() throws {
        let r = try rig()
        let held = try CCPoolControl.hold(label: "alpha", hours: 2)
        r.model.hold("alpha", hours: 5)
        held.undo?()
        XCTAssertEqual(r.model.rows.first { $0.label == "alpha" }?.state, .held(until: Int(t0) + 5 * 3600), "the later hold is kept")

        _ = try CCPoolControl.hold(label: "bravo", hours: 1)
        let freed = try CCPoolControl.release(label: "bravo")
        r.model.hold("bravo", hours: 3)
        freed.undo?()
        XCTAssertEqual(r.model.rows.first { $0.label == "bravo" }?.state, .held(until: Int(t0) + 3 * 3600),
                       "the hold made after the release is kept, not the one before it")

        let again = try CCPoolControl.release(label: "bravo")
        r.model.release("bravo")   // nothing to change: the account is still what the release left
        again.undo?()
        XCTAssertEqual(r.model.rows.first { $0.label == "bravo" }?.state, .held(until: Int(t0) + 3 * 3600), "an unchanged account is undone")
    }

    /// n171: the summary says the hold the store applied: a longer limit already on the account wins over the hours asked.
    func testHoldSummaryIsWhatWasApplied() throws {
        let r = try rig()
        XCTAssertEqual(try CCPoolControl.hold(label: "alpha", hours: 2).summary, "hold alpha for 2.0 h")
        r.store.mutate { $0.accounts["bravo"]?.cooldown[CCPoolCore.fiveHour] = Int(t0) + 10 * 3600 }
        XCTAssertEqual(try CCPoolControl.hold(label: "bravo", hours: 2).summary, "hold bravo for 10.0 h")
        XCTAssertEqual(r.store.snapshot.accounts["bravo"]?.held, Int(t0) + 10 * 3600)
    }

    func testRefusals() throws {
        let r = try rig()
        refused(try CCPoolControl.hold(label: "alpha", hours: 0), CCPoolControl.badHours)
        refused(try CCPoolControl.hold(label: "alpha", hours: -1), CCPoolControl.badHours)
        refused(try CCPoolControl.hold(label: "alpha", hours: .nan), CCPoolControl.badHours)
        refused(try CCPoolControl.hold(label: "alpha", hours: .infinity), CCPoolControl.badHours)
        refused(try CCPoolControl.hold(label: "alpha", hours: CCPoolControl.maxHours + 1), CCPoolControl.badHours)
        refused(try CCPoolControl.hold(label: "nobody", hours: 1), "no ccpool account named nobody (ccpool.status lists them)")
        refused(try CCPoolControl.hold(label: "  ", hours: 1), "argument 'label' is empty")
        refused(try CCPoolControl.release(label: "alpha"), "alpha has no hold or limit to release")
        refused(try CCPoolControl.release(label: "nobody"), "no ccpool account named nobody (ccpool.status lists them)")
        XCTAssertEqual(r.store.snapshot.accounts["alpha"]?.cooldown, [:], "a refusal changes nothing")
        XCTAssertNotNil(try? CCPoolControl.hold(label: "alpha", hours: CCPoolControl.maxHours), "the cap itself is allowed")
    }

    /// An expired hold is not a hold to release; an undo after the account was removed does nothing.
    func testExpiredHoldAndRemovedAccount() throws {
        let r = try rig()
        let held = try CCPoolControl.hold(label: "alpha", hours: 1)
        r.clock.advance(7200)
        refused(try CCPoolControl.release(label: "alpha"), "alpha has no hold or limit to release")
        r.store.mutate { _ = $0.accounts.removeValue(forKey: "alpha") }
        held.undo?()
        XCTAssertTrue(r.store.snapshot.accounts["alpha"] == nil, "no account is made by an undo")
    }

    /// Over the registry: ccpool off; a missing argument is the registry's own refusal (ControlCommand.validate, before
    /// the handler runs); hours out of range and a blank label reach the handler's refusals and change nothing. NaN and
    /// infinity have no JSON form (testRefusals holds them).
    func testOffAndMissingArgsAreErrorsOverTheRegistry() async throws {
        CCPoolControl.model = { nil }
        addTeardownBlock { @MainActor in CCPoolControl.model = { CCPoolRuntime.shared?.model } }
        let reg = registry()
        func refusal(_ cmd: String, _ a: [String: ControlJSON]) async throws -> String? {
            await reg.reply(to: try JSONEncoder().encode(ControlRequest(cmd: cmd, args: a))).error
        }
        let off = try await refusal("ccpool.hold", args("alpha", 1))
        XCTAssertEqual(off, "ccpool is off")
        let noHours = try await refusal("ccpool.hold", args("alpha"))
        XCTAssertEqual(noHours, "missing argument 'hours' for ccpool.hold")
        let noLabel = try await refusal("ccpool.release", [:])
        XCTAssertEqual(noLabel, "missing argument 'label' for ccpool.release")

        let r = try rig()
        for h in [0, -1, CCPoolControl.maxHours + 1] {
            let bad = try await refusal("ccpool.hold", args("alpha", h))
            XCTAssertEqual(bad, CCPoolControl.badHours, "hours \(h)")
        }
        let blankHold = try await refusal("ccpool.hold", args("  ", 1))
        XCTAssertEqual(blankHold, "argument 'label' is empty")
        let blankRelease = try await refusal("ccpool.release", args("  "))
        XCTAssertEqual(blankRelease, "argument 'label' is empty")
        XCTAssertTrue(r.store.snapshot.accounts["alpha"]?.cooldown == [:] && r.store.snapshot.accounts["alpha"]?.held == nil,
                      "a refusal changes nothing")
    }
}

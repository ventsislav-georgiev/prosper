import XCTest
@testable import ProsperApp

// #917 S4: the staged-update machine as values. Pure rows: no file system, no clock, no process.
// Fakes only: com.example.kit, Example Author, versions such as "1.0.0".

final class KitUpdateMachineTests: XCTestCase {
    typealias E = KitUpdateEvent
    typealias A = KitUpdateAction

    let slug = "com.example.kit"

    func live(_ v: String = "1.0.0") -> KitRef { KitRef(version: v, treeHash: "h" + v, slug: slug) }
    func fresh(pin: String? = nil) -> KitUpdateState { KitUpdateState(live: live(), publisherPin: pin) }
    func staged(_ v: String, slug s: String? = nil, publisher: String? = "Example Author") -> E {
        .staged(version: v, treeHash: "h" + v, slug: s ?? slug, publisher: publisher)
    }

    func drive(_ s0: KitUpdateState, _ events: [E]) -> (state: KitUpdateState, steps: [[A]]) {
        var s = s0
        var steps: [[A]] = []
        for e in events {
            let (n, a) = KitUpdateMachine.step(s, e)
            s = n
            steps.append(a)
        }
        return (s, steps)
    }

    /// staged .. wiringApplied for one version, in order.
    func goodFlow(_ v: String) -> [E] {
        [staged(v), .validatedOk(v, tree: "h" + v), .rendered(v, tree: "h" + v), .consentGiven(v, tree: "h" + v), .swapped(v, tree: "h" + v), .shimsWritten(v, tree: "h" + v), .wiringApplied(v, tree: "h" + v)]
    }

    func isSwap(_ a: A) -> Bool { if case .swap = a { return true } else { return false } }

    func testNoSwapWithoutValidation() {
        let sequences: [[E]] = [
            [staged("2.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0")],
            [staged("2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0"), .rendered("2.0.0", tree: "h2.0.0")],
            [staged("2.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0")],
            [staged("2.0.0"), .validationRefused("2.0.0", tree: "h2.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0")],
        ]
        let expected: [Set<A>] = [
            [.copyToStaged("2.0.0"), .validateStaged("2.0.0")],
            [.copyToStaged("2.0.0"), .validateStaged("2.0.0")],
            [.copyToStaged("2.0.0"), .validateStaged("2.0.0")],
            [.copyToStaged("2.0.0"), .validateStaged("2.0.0"), .dropStaged("2.0.0")],
        ]
        for (i, seq) in sequences.enumerated() {
            let r = drive(fresh(), seq)
            XCTAssertEqual(Set(r.steps.flatMap { $0 }), expected[i], "sequence \(i)")
            XCTAssertFalse(r.steps.flatMap { $0 }.contains(where: isSwap), "sequence \(i)")
            XCTAssertEqual(r.state.live, live())
        }
    }

    func testNoSwapWithoutConsent() {
        let sequences: [[E]] = [
            [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0"), .rendered("2.0.0", tree: "h2.0.0")],
            [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0")],
            [staged("2.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0")],
            [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .consentDenied("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0")],
        ]
        for (i, seq) in sequences.enumerated() {
            let r = drive(fresh(), seq)
            XCTAssertFalse(r.steps.flatMap { $0 }.contains(where: isSwap), "sequence \(i)")
            XCTAssertEqual(r.state.live, live())
        }
        // consent for another version than the staged one does not count
        let r = drive(fresh(), [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .consentGiven("3.0.0", tree: "h3.0.0")])
        XCTAssertEqual(r.steps.last, [])
        XCTAssertEqual(r.state.phase, .consenting)
    }

    func testDenyLeavesLiveUntouched() {
        let r = drive(fresh(), [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .consentDenied("2.0.0", tree: "h2.0.0")])
        XCTAssertEqual(r.steps.last, [.dropStaged("2.0.0")])
        XCTAssertEqual(r.state.live, live())
        XCTAssertNil(r.state.staged)
        XCTAssertEqual(r.state.phase, .idle)
        XCTAssertEqual(r.state.lastRefusal, .consentDenied)
        let f = drive(fresh(), [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0"), .swapFailed("2.0.0", tree: "h2.0.0")])
        XCTAssertEqual(f.steps.last, [.dropStaged("2.0.0")])
        XCTAssertEqual(f.state.live, live())
        XCTAssertEqual(f.state.phase, .idle)
        let v = drive(fresh(), [staged("2.0.0"), .validationRefused("2.0.0", tree: "h2.0.0")])
        XCTAssertEqual(v.state.live, live())
        XCTAssertEqual(v.state.lastRefusal, .validation)
    }

    func testHappyPathActionsInOrder() {
        let r = drive(fresh(), goodFlow("2.0.0"))
        let expected: [[A]] = [
            [.copyToStaged("2.0.0"), .validateStaged("2.0.0")], [.renderStaged("2.0.0")], [.askConsent("2.0.0")],
            [.swap("2.0.0")], [.keepPrevious("1.0.0"), .writeShims("2.0.0")], [.applyWiring("2.0.0")], [],
        ]
        XCTAssertEqual(r.steps, expected)
        XCTAssertEqual(r.state.live, live("2.0.0"))
        XCTAssertEqual(r.state.previous, live("1.0.0"))
        XCTAssertEqual(r.state.phase, .idle)
        XCTAssertNil(r.state.staged)
    }

    func testWiringFailureSwapsBack() {
        let flow: [E] = [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0"),
                         .swapped("2.0.0", tree: "h2.0.0"), .shimsWritten("2.0.0", tree: "h2.0.0"), .wiringFailed("2.0.0", tree: "h2.0.0")]
        let r = drive(fresh(), flow)
        XCTAssertEqual(r.steps.last, [.swapBack, .writeShims("1.0.0"), .dropStaged("2.0.0")])
        XCTAssertEqual(r.state.live, live("1.0.0"))
        XCTAssertEqual(r.state.phase, .idle)
        XCTAssertNil(r.state.previous)
        XCTAssertNil(r.state.retiring)
    }

    func testAFailedUpdateKeepsTheOlderPrevious() {
        let two = drive(fresh(), goodFlow("2.0.0")).state
        XCTAssertEqual(two.previous, live("1.0.0"))
        let upTo: [E] = [staged("3.0.0"), .validatedOk("3.0.0", tree: "h3.0.0"), .rendered("3.0.0", tree: "h3.0.0"), .consentGiven("3.0.0", tree: "h3.0.0"), .swapped("3.0.0", tree: "h3.0.0"), .shimsWritten("3.0.0", tree: "h3.0.0")]
        let failed = drive(two, upTo + [.wiringFailed("3.0.0", tree: "h3.0.0")])
        XCTAssertEqual(failed.state.live, live("2.0.0"))
        XCTAssertEqual(failed.state.previous, live("1.0.0"))
        XCTAssertNil(failed.state.retiring)
        XCTAssertEqual(failed.state.phase, .idle)
        XCTAssertEqual(failed.steps.last, [.swapBack, .writeShims("2.0.0"), .dropStaged("3.0.0")])
        XCTAssertFalse(failed.steps.flatMap { $0 }.contains(where: { if case .dropPrevious = $0 { return true } else { return false } }))
        // a failure between the swap and the shims keeps it too
        let mid = drive(two, Array(upTo[0...4]))
        XCTAssertEqual(mid.state.retiring, live("1.0.0"))
        // the same path confirmed
        let ok = drive(two, upTo + [.wiringApplied("3.0.0", tree: "h3.0.0")])
        XCTAssertEqual(ok.steps.last, [.dropPrevious("1.0.0")])
        XCTAssertEqual(ok.steps.flatMap { $0 }.filter { if case .dropPrevious = $0 { return true } else { return false } }, [.dropPrevious("1.0.0")])
        XCTAssertEqual(ok.state.live, live("3.0.0"))
        XCTAssertEqual(ok.state.previous, live("2.0.0"))
        XCTAssertNil(ok.state.retiring)
    }

    func testAFailedShimWriteSwapsBackAndKeepsTheOlderPrevious() {
        let two = drive(fresh(), goodFlow("2.0.0")).state
        let upTo: [E] = [staged("3.0.0"), .validatedOk("3.0.0", tree: "h3.0.0"), .rendered("3.0.0", tree: "h3.0.0"), .consentGiven("3.0.0", tree: "h3.0.0"), .swapped("3.0.0", tree: "h3.0.0")]
        let r = drive(two, upTo + [.shimsFailed("3.0.0", tree: "h3.0.0")])
        XCTAssertEqual(r.steps.last, [.swapBack, .writeShims("2.0.0"), .dropStaged("3.0.0")])
        XCTAssertEqual(r.state.live, live("2.0.0"))
        XCTAssertEqual(r.state.previous, live("1.0.0"))
        XCTAssertNil(r.state.retiring)
        XCTAssertNil(r.state.staged)
        XCTAssertEqual(r.state.phase, .idle)
        XCTAssertFalse(r.steps.flatMap { $0 }.contains(where: { if case .dropPrevious = $0 { return true } else { return false } }))
        // a stale answer does nothing
        let before = drive(two, upTo).state
        XCTAssertEqual(KitUpdateMachine.step(before, .shimsFailed("9.0.0", tree: "h9.0.0")).0, before)
        XCTAssertEqual(KitUpdateMachine.step(before, .shimsFailed("9.0.0", tree: "h9.0.0")).1, [])
    }

    func testEverySwapBackRewritesTheShimsOfTheVersionNowLive() {
        let two = drive(fresh(), goodFlow("2.0.0")).state
        let swapped = drive(fresh(), [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0"), .swapped("2.0.0", tree: "h2.0.0")]).state
        let rolling = KitUpdateMachine.step(two, .rollbackRequested).0
        let table: [(String, [A])] = [
            ("wiringFailed in the update flow", KitUpdateMachine.step(KitUpdateMachine.step(swapped, .shimsWritten("2.0.0", tree: "h2.0.0")).0, .wiringFailed("2.0.0", tree: "h2.0.0")).1),
            ("shimsFailed in the update flow", KitUpdateMachine.step(swapped, .shimsFailed("2.0.0", tree: "h2.0.0")).1),
            ("rollbackRequested", KitUpdateMachine.step(two, .rollbackRequested).1),
            ("wiringFailed while rollingBack", KitUpdateMachine.step(rolling, .wiringFailed("1.0.0", tree: "h1.0.0")).1),
        ]
        let expected: [[A]] = [
            [.swapBack, .writeShims("1.0.0"), .dropStaged("2.0.0")],
            [.swapBack, .writeShims("1.0.0"), .dropStaged("2.0.0")],
            [.swapBack, .writeShims("1.0.0"), .applyWiring("1.0.0")],
            [.swapBack, .writeShims("2.0.0")],
        ]
        XCTAssertEqual(table.map { $0.1 }, expected)
    }

    func testShimsWrittenAfterASwapBackChangesNothing() {
        let two = drive(fresh(), goodFlow("2.0.0")).state
        let rolling = KitUpdateMachine.step(two, .rollbackRequested).0
        XCTAssertEqual(KitUpdateMachine.step(rolling, .shimsWritten("1.0.0", tree: "h1.0.0")).0, rolling)
        XCTAssertEqual(KitUpdateMachine.step(rolling, .shimsWritten("1.0.0", tree: "h1.0.0")).1, [])
        let back = KitUpdateMachine.step(rolling, .wiringFailed("1.0.0", tree: "h1.0.0")).0
        XCTAssertEqual(KitUpdateMachine.step(back, .shimsWritten("2.0.0", tree: "h2.0.0")).0, back)
        XCTAssertEqual(KitUpdateMachine.step(back, .shimsWritten("2.0.0", tree: "h2.0.0")).1, [])
        let failed = drive(fresh(), [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0"),
                                     .swapped("2.0.0", tree: "h2.0.0"), .shimsFailed("2.0.0", tree: "h2.0.0")]).state
        XCTAssertEqual(KitUpdateMachine.step(failed, .shimsWritten("1.0.0", tree: "h1.0.0")).0, failed)
        XCTAssertEqual(KitUpdateMachine.step(failed, .shimsWritten("1.0.0", tree: "h1.0.0")).1, [])
    }

    func testRollbackTwiceIsNewer() {
        let s = drive(fresh(), goodFlow("2.0.0")).state
        let r1 = KitUpdateMachine.step(s, .rollbackRequested)
        XCTAssertEqual(r1.1, [.swapBack, .writeShims("1.0.0"), .applyWiring("1.0.0")])
        XCTAssertEqual(r1.0.live, live("1.0.0"))
        XCTAssertEqual(r1.0.previous, live("2.0.0"))
        let ok1 = KitUpdateMachine.step(r1.0, .wiringApplied("1.0.0", tree: "h1.0.0"))
        XCTAssertEqual(ok1.0.phase, .idle)
        let r2 = KitUpdateMachine.step(ok1.0, .rollbackRequested)
        XCTAssertEqual(r2.1, [.swapBack, .writeShims("2.0.0"), .applyWiring("2.0.0")])
        XCTAssertEqual(r2.0.live, live("2.0.0"))
        XCTAssertEqual(r2.0.previous, live("1.0.0"))
        // a rollback whose wiring fails swaps back again
        let bad = KitUpdateMachine.step(r1.0, .wiringFailed("1.0.0", tree: "h1.0.0"))
        XCTAssertEqual(bad.1, [.swapBack, .writeShims("2.0.0")])
        XCTAssertEqual(bad.0.live, live("2.0.0"))
        XCTAssertEqual(bad.0.previous, live("1.0.0"))
        // nothing to roll back to
        let none = KitUpdateMachine.step(fresh(), .rollbackRequested)
        XCTAssertEqual(none.0, fresh())
        XCTAssertEqual(none.1, [])
    }

    func testOnePreviousKept() {
        let r = drive(fresh(), goodFlow("2.0.0") + goodFlow("3.0.0"))
        XCTAssertEqual(r.state.live, live("3.0.0"))
        XCTAssertEqual(r.state.previous, live("2.0.0"))
        XCTAssertEqual(r.steps[11], [.keepPrevious("2.0.0"), .writeShims("3.0.0")])
        XCTAssertEqual(r.steps[13], [.dropPrevious("1.0.0")])
        // the older previous is dropped exactly once, at wiringApplied
        let drops = r.steps.flatMap { $0 }.filter { if case .dropPrevious = $0 { return true } else { return false } }
        XCTAssertEqual(drops, [.dropPrevious("1.0.0")])
    }

    func testANewerStagedReplacesTheOlder() {
        let r = drive(fresh(), [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0"), staged("3.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0")])
        XCTAssertEqual(r.steps[2], [.dropStaged("2.0.0"), .copyToStaged("3.0.0"), .validateStaged("3.0.0")])
        XCTAssertEqual(r.state.staged?.version, "3.0.0")
        XCTAssertEqual(r.state.phase, .validating)
        XCTAssertEqual(r.steps[3], [])
        XCTAssertEqual(r.steps[4], [])
    }

    func testSlugChangeRefused() {
        let r = KitUpdateMachine.step(fresh(), staged("2.0.0", slug: "com.example.renamed"))
        XCTAssertEqual(r.1, [])
        XCTAssertEqual(r.0.lastRefusal, .slugChanged)
        XCTAssertEqual(r.0.phase, .idle)
        XCTAssertNil(r.0.staged)
        XCTAssertEqual(r.0.live, live())
        // a refusal while another version is pending drops nothing
        let p = drive(fresh(), [staged("2.0.0"), staged("3.0.0", slug: "other")])
        XCTAssertEqual(p.steps[1], [])
        XCTAssertEqual(p.state.staged?.version, "2.0.0")
        XCTAssertEqual(p.state.phase, .validating)
    }

    func testPublisherChangeRefused() {
        let pinned = fresh(pin: "Example Author")
        let r = KitUpdateMachine.step(pinned, staged("2.0.0", publisher: "Another Author"))
        XCTAssertEqual(r.1, [])
        XCTAssertEqual(r.0.lastRefusal, .publisherChanged)
        XCTAssertNil(r.0.staged)
        XCTAssertEqual(KitUpdateMachine.step(pinned, staged("2.0.0", publisher: nil)).1, [])
        XCTAssertEqual(KitUpdateMachine.step(pinned, staged("2.0.0", publisher: "Example Author")).1,
                       [.copyToStaged("2.0.0"), .validateStaged("2.0.0")])
    }

    func testNoPinComparesNoPublisher() {
        for p in [nil, "Another Author", "", String(repeating: "x", count: 100_000)] {
            let r = KitUpdateMachine.step(fresh(), staged("2.0.0", publisher: p))
            XCTAssertEqual(r.1, [.copyToStaged("2.0.0"), .validateStaged("2.0.0")])
            XCTAssertNil(r.0.lastRefusal)
        }
    }

    func testAnEventOutOfPhaseChangesNothing() {
        let events: [E] = [.validatedOk("2.0.0", tree: "h2.0.0"), .validationRefused("2.0.0", tree: "h2.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0"),
                           .consentDenied("2.0.0", tree: "h2.0.0"), .swapped("2.0.0", tree: "h2.0.0"), .swapFailed("2.0.0", tree: "h2.0.0"), .shimsWritten("2.0.0", tree: "h2.0.0"), .shimsFailed("1.0.0", tree: "h1.0.0"),
                           .wiringApplied("1.0.0", tree: "h1.0.0"), .wiringFailed("1.0.0", tree: "h1.0.0"), .rollbackRequested]
        for e in events {
            let r = KitUpdateMachine.step(fresh(), e)
            XCTAssertEqual(r.0, fresh(), "\(e)")
            XCTAssertEqual(r.1, [], "\(e)")
        }
        // mid-flight: a staged event while the swap is running, and a rollback in the middle of a flow
        let busy = drive(fresh(), [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0")]).state
        for e in [staged("3.0.0"), .rollbackRequested, .rendered("2.0.0", tree: "h2.0.0"), .wiringApplied("2.0.0", tree: "h2.0.0")] {
            let r = KitUpdateMachine.step(busy, e)
            XCTAssertEqual(r.0, busy, "\(e)")
            XCTAssertEqual(r.1, [], "\(e)")
        }
        // a swapped event for a staged version that was never consented
        let early = drive(fresh(), [staged("2.0.0")]).state
        for e in [E.swapped("2.0.0", tree: "h2.0.0"), .swapFailed("2.0.0", tree: "h2.0.0"), .shimsWritten("2.0.0", tree: "h2.0.0"), .shimsFailed("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0")] {
            let r = KitUpdateMachine.step(early, e)
            XCTAssertEqual(r.0, early, "\(e)")
            XCTAssertEqual(r.1, [], "\(e)")
        }
        // the live version staged again is not an update
        XCTAssertEqual(KitUpdateMachine.step(fresh(), staged("1.0.0")).1, [])
    }

    func testARepeatedEventEmitsNothingTwice() {
        let flow = goodFlow("2.0.0")
        for (i, e) in flow.enumerated() {
            let prefix = Array(flow[0...i])
            let once = drive(fresh(), prefix).state
            let again = KitUpdateMachine.step(once, e)
            XCTAssertEqual(again.1, [], "event \(i) repeated")
            XCTAssertEqual(again.0, once, "event \(i) repeated")
        }
    }

    func testExecutableDiffAddedRemovedChanged() {
        func f(_ size: Int, _ h: String) -> KitFileFact { KitFileFact(size: size, sha256: h) }
        let old = ["bin/b": f(1, "aa"), "bin/a": f(2, "bb"), "bin/gone2": f(3, "cc"), "bin/gone1": f(3, "cc"), "same": f(5, "ee")]
        let new = ["bin/b": f(1, "ab"), "bin/a": f(3, "bb"), "bin/new2": f(7, "dd"), "bin/new1": f(7, "dd"), "same": f(5, "ee")]
        let d = KitUpdateMachine.diffExecutables(old: old, new: new)
        XCTAssertEqual(d.added, ["bin/new1", "bin/new2"])
        XCTAssertEqual(d.removed, ["bin/gone1", "bin/gone2"])
        XCTAssertEqual(d.changed, ["bin/a", "bin/b"])
        // outside values: any size, any text, empty maps; no trap
        let odd = ["": f(Int.max, String(repeating: "z", count: 10_000)), "\u{202E}x": f(Int.min, ""), "-1": f(-1, "\u{0}")]
        let e = KitUpdateMachine.diffExecutables(old: [:], new: odd)
        XCTAssertEqual(e.added, ["", "-1", "\u{202E}x"])
        XCTAssertEqual(e.removed, [])
        XCTAssertEqual(e.changed, [])
        XCTAssertEqual(KitUpdateMachine.diffExecutables(old: odd, new: [:]).removed, ["", "-1", "\u{202E}x"])
        XCTAssertEqual(KitUpdateMachine.diffExecutables(old: odd, new: odd), KitExecutableDiff(added: [], removed: [], changed: []))
    }

    /// Every sequence of length 1...5 over 15 events: 15 + 225 + 3375 + 50625 + 759375 = 813615. A sequence
    /// emits swap only if it holds staged, validated-ok, rendered, consent-given in order with nothing
    /// between them that resets the chain (a refusal at validation, a render failure, a denial, a cancel; a
    /// repeated staged event is a no-op). By a count made outside Swift (count.py, a small automaton), 66 of
    /// them do (S4b: was 402233 and 60 over 13 events; renderFailed and cancel are the two new events).
    func testExhaustiveSequencesSwapOnlyAfterTheFullChain() {
        let v = "2.0.0"
        let events: [(Character, E)] = [
            ("s", staged(v)), ("v", .validatedOk(v, tree: "h" + v)), ("x", .validationRefused(v, tree: "h" + v)), ("r", .rendered(v, tree: "h" + v)),
            ("c", .consentGiven(v, tree: "h" + v)), ("d", .consentDenied(v, tree: "h" + v)), ("w", .swapped(v, tree: "h" + v)), ("f", .swapFailed(v, tree: "h" + v)),
            ("h", .shimsWritten(v, tree: "h" + v)), ("o", .wiringApplied(v, tree: "h" + v)), ("b", .wiringFailed(v, tree: "h" + v)), ("k", .rollbackRequested), ("y", .shimsFailed(v, tree: "h" + v)),
            ("z", .renderFailed(v, tree: "h" + v)), ("a", .cancel),
        ]
        var total = 0, swaps = 0, mismatches = 0
        func walk(_ s: KitUpdateState, _ progress: Int, _ swapped: Bool, _ depth: Int) {
            if depth > 0 {
                total += 1
                if swapped { swaps += 1 }
            }
            if depth == 5 { return }
            for (c, e) in events {
                let (n, a) = KitUpdateMachine.step(s, e)
                let emits = a.contains(where: isSwap)
                // the oracle: a progress counter that only the chain letters advance
                var p = progress
                switch (c, p) {
                case ("s", 0): p = 1
                case ("v", 1): p = 2
                case ("r", 2): p = 3
                case ("c", 3): p = 4
                case ("x", 1), ("z", 2), ("d", 3), ("a", 1), ("a", 2), ("a", 3): p = 0
                default: break
                }
                if emits != (p == 4) && !swapped { mismatches += 1 }
                if swapped { walk(n, progress, true, depth + 1) } else { walk(n, p == 4 ? 0 : p, emits, depth + 1) }
            }
        }
        walk(fresh(), 0, false, 0)
        XCTAssertEqual(total, 813_615)
        XCTAssertEqual(swaps, 66)
        XCTAssertEqual(mismatches, 0)
    }

    // MARK: S4b rows (answers keyed by version AND tree; failure and cancel edges)

    func ref(_ v: String, _ h: String) -> KitRef { KitRef(version: v, treeHash: h, slug: slug) }
    func st(_ v: String, _ h: String) -> E { .staged(version: v, treeHash: h, slug: slug, publisher: "Example Author") }

    /// A/h1 staged, then B, then A/h2: the old A/h1 sheet, validation and render answers are all late.
    func atPhase(_ upTo: Int) -> KitUpdateState {
        let chain: [E] = [.validatedOk("A", tree: "h2"), .rendered("A", tree: "h2")]
        return drive(fresh(), [st("A", "h1"), st("B", "hB"), st("A", "h2")] + Array(chain[0..<upTo])).state
    }

    func testALateAnswerForAnotherTreeOfTheSameVersionIsIgnored() {
        // consenting: the old sheet for A/h1 is still up while A/h2 sits in consenting
        let consenting = atPhase(2)
        XCTAssertEqual(consenting.phase, .consenting)
        XCTAssertEqual(consenting.staged, ref("A", "h2"))
        for late in [E.consentGiven("A", tree: "h1"), .consentDenied("A", tree: "h1"), .validatedOk("A", tree: "h1"), .rendered("A", tree: "h1"),
                     .renderFailed("A", tree: "h1"), .validationRefused("A", tree: "h1"), .swapped("A", tree: "h1"), .swapFailed("A", tree: "h1")] {
            let r = KitUpdateMachine.step(consenting, late)
            XCTAssertEqual(r.0, consenting, "\(late)")
            XCTAssertEqual(r.1, [], "\(late)")
        }
        // validating: a late validatedOk and validationRefused for A/h1
        let validating = atPhase(0)
        XCTAssertEqual(validating.phase, .validating)
        for late in [E.validatedOk("A", tree: "h1"), .validationRefused("A", tree: "h1")] {
            let r = KitUpdateMachine.step(validating, late)
            XCTAssertEqual(r.0, validating, "\(late)")
            XCTAssertEqual(r.1, [], "\(late)")
        }
        // rendering: a late rendered and renderFailed for A/h1
        let rendering = atPhase(1)
        XCTAssertEqual(rendering.phase, .rendering)
        for late in [E.rendered("A", tree: "h1"), .renderFailed("A", tree: "h1")] {
            let r = KitUpdateMachine.step(rendering, late)
            XCTAssertEqual(r.0, rendering, "\(late)")
            XCTAssertEqual(r.1, [], "\(late)")
        }
        // the matching answer (A, h2) goes on as before
        XCTAssertEqual(KitUpdateMachine.step(validating, .validatedOk("A", tree: "h2")).1, [.renderStaged("A")])
        XCTAssertEqual(KitUpdateMachine.step(rendering, .rendered("A", tree: "h2")).1, [.askConsent("A")])
        XCTAssertEqual(KitUpdateMachine.step(consenting, .consentGiven("A", tree: "h2")).1, [.swap("A")])
    }

    func testAnAnswerForTheLiveOrAnotherTreeAfterTheSwapIsIgnored() {
        let swapping = drive(fresh(), [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0")]).state
        XCTAssertEqual(KitUpdateMachine.step(swapping, .swapped("2.0.0", tree: "other")).0, swapping)
        let shims = KitUpdateMachine.step(swapping, .swapped("2.0.0", tree: "h2.0.0")).0
        XCTAssertEqual(KitUpdateMachine.step(shims, .shimsWritten("2.0.0", tree: "other")).0, shims)
        XCTAssertEqual(KitUpdateMachine.step(shims, .shimsFailed("2.0.0", tree: "other")).1, [])
        let wiring = KitUpdateMachine.step(shims, .shimsWritten("2.0.0", tree: "h2.0.0")).0
        XCTAssertEqual(KitUpdateMachine.step(wiring, .wiringApplied("2.0.0", tree: "other")).0, wiring)
        XCTAssertEqual(KitUpdateMachine.step(wiring, .wiringFailed("2.0.0", tree: "other")).1, [])
    }

    func testRenderFailureLeavesRenderingWithARefusal() {
        let flow: [E] = [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0")]
        let rendering = drive(fresh(), flow).state
        XCTAssertEqual(rendering.phase, .rendering)
        let r = KitUpdateMachine.step(rendering, .renderFailed("2.0.0", tree: "h2.0.0"))
        XCTAssertEqual(r.1, [.dropStaged("2.0.0")])
        XCTAssertEqual(r.0.phase, .idle)
        XCTAssertEqual(r.0.lastRefusal, .render)
        XCTAssertTrue(r.0.staged == nil)
        XCTAssertEqual(r.0.live, live())
        // renderFailed in another phase does nothing
        let validating = drive(fresh(), [staged("2.0.0")]).state
        XCTAssertEqual(KitUpdateMachine.step(validating, .renderFailed("2.0.0", tree: "h2.0.0")).0, validating)
        XCTAssertEqual(KitUpdateMachine.step(fresh(), .renderFailed("2.0.0", tree: "h2.0.0")).1, [])
    }

    func testAFailedShimWriteWhileRollingBackSwapsBackOnceAndEndsInIdleWithARefusal() {
        let two = drive(fresh(), goodFlow("2.0.0")).state
        let rolling = KitUpdateMachine.step(two, .rollbackRequested).0
        XCTAssertEqual(rolling.phase, .rollingBack)
        let first = KitUpdateMachine.step(rolling, .shimsFailed("1.0.0", tree: "h1.0.0"))
        XCTAssertEqual(first.1, [.swapBack, .writeShims("2.0.0")])
        XCTAssertEqual(first.0.live, live("2.0.0"))
        XCTAssertEqual(first.0.previous, live("1.0.0"))
        XCTAssertEqual(first.0.phase, .idle)
        XCTAssertEqual(first.0.lastRefusal, .shims)
        // the rewrite after the swap back fails too: out of phase, no action, state unchanged
        let second = KitUpdateMachine.step(first.0, .shimsFailed("2.0.0", tree: "h2.0.0"))
        XCTAssertEqual(second.1, [])
        XCTAssertEqual(second.0, first.0)
        // and the failure of the first answer repeated (stale) does nothing either
        XCTAssertEqual(KitUpdateMachine.step(first.0, .shimsFailed("1.0.0", tree: "h1.0.0")).1, [])
    }

    func testCancelBeforeTheSwapDropsTheStagedCopyWithNoRefusal() {
        let steps: [[E]] = [
            [staged("2.0.0")],
            [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0")],
            [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0"), .rendered("2.0.0", tree: "h2.0.0")],
        ]
        for (i, pre) in steps.enumerated() {
            let before = drive(fresh(), pre).state
            let r = KitUpdateMachine.step(before, .cancel)
            XCTAssertEqual(r.1, [.dropStaged("2.0.0")], "phase \(i)")
            XCTAssertEqual(r.0.phase, .idle, "phase \(i)")
            XCTAssertTrue(r.0.staged == nil, "phase \(i)")
            XCTAssertTrue(r.0.lastRefusal == nil, "phase \(i)")
            XCTAssertEqual(r.0.live, live(), "phase \(i)")
            // the answer that was in flight is ignored afterwards
            XCTAssertEqual(KitUpdateMachine.step(r.0, .validatedOk("2.0.0", tree: "h2.0.0")).1, [], "phase \(i)")
            XCTAssertEqual(KitUpdateMachine.step(r.0, .consentGiven("2.0.0", tree: "h2.0.0")).1, [], "phase \(i)")
        }
    }

    func testCancelInAnyOtherPhaseIsIgnored() {
        let two = drive(fresh(), goodFlow("2.0.0")).state
        let swapping = drive(fresh(), [staged("2.0.0"), .validatedOk("2.0.0", tree: "h2.0.0"), .rendered("2.0.0", tree: "h2.0.0"), .consentGiven("2.0.0", tree: "h2.0.0")]).state
        let shims = KitUpdateMachine.step(swapping, .swapped("2.0.0", tree: "h2.0.0")).0
        let wiring = KitUpdateMachine.step(shims, .shimsWritten("2.0.0", tree: "h2.0.0")).0
        let rolling = KitUpdateMachine.step(two, .rollbackRequested).0
        let named: [(String, KitUpdateState)] = [("idle", fresh()), ("idle with previous", two), ("swapping", swapping),
                                                 ("shims", shims), ("wiring", wiring), ("rollingBack", rolling)]
        for (name, s) in named {
            let r = KitUpdateMachine.step(s, .cancel)
            XCTAssertEqual(r.0, s, name)
            XCTAssertEqual(r.1, [], name)
        }
    }

    /// Second exhaustive row: two versions (A, B), two trees for A (h1, h2): every sequence of length 1...5
    /// over 13 events (3 staged, validatedOk/rendered/consentGiven for each of the 3 refs, cancel) is
    /// 13 + 169 + 2197 + 28561 + 371293 = 402233. A swap of X/h is only ever emitted by consentGiven(X, h)
    /// for exactly the staged X/h after its validatedOk and rendered. By a count made outside Swift
    /// (count.py), 163 of the 402233 sequences hold a swap (the walk counts a sequence after its swap too).
    func testExhaustiveTwoVersionsTwoTreesSwapOnlyForTheExactStagedTree() {
        let refs = [ref("A", "h1"), ref("A", "h2"), ref("B", "hB")]
        var events: [(Character, KitRef?)] = []
        for k in ["s", "v", "r", "c"] as [Character] { for r in refs { events.append((k, r)) } }
        events.append(("a", nil))
        func event(_ k: Character, _ r: KitRef?) -> E {
            guard let r else { return .cancel }
            switch k {
            case "s": return st(r.version, r.treeHash)
            case "v": return .validatedOk(r.version, tree: r.treeHash)
            case "r": return .rendered(r.version, tree: r.treeHash)
            default: return .consentGiven(r.version, tree: r.treeHash)
            }
        }
        var total = 0, swaps = 0, mismatches = 0
        func walk(_ s: KitUpdateState, _ p: Int, _ cur: KitRef?, _ swapped: Bool, _ depth: Int) {
            if depth > 0 { total += 1; if swapped { swaps += 1 } }
            if depth == 5 { return }
            for (k, r) in events {
                let (n, a) = KitUpdateMachine.step(s, event(k, r))
                if swapped { walk(n, p, cur, true, depth + 1); continue }
                // the oracle: the staged ref is the one an accepted staged event named (copyToStaged emitted)
                var np = p, nc = cur
                if k == "s" { if a.contains(where: { if case .copyToStaged = $0 { return true } else { return false } }) { np = 1; nc = r } }
                else if k == "a" { if p >= 1 && p <= 3 { np = 0; nc = nil } }
                else if r == cur {
                    if k == "v" && p == 1 { np = 2 } else if k == "r" && p == 2 { np = 3 } else if k == "c" && p == 3 { np = 4 }
                }
                let emits = a.contains(where: isSwap)
                if emits != (np == 4) { mismatches += 1 }
                if emits, k != "c" || cur == nil || a != [.swap(cur?.version ?? "")] { mismatches += 1 }
                walk(n, np == 4 ? 0 : np, nc, np == 4, depth + 1)
            }
        }
        walk(fresh(), 0, nil, false, 0)
        XCTAssertEqual(total, 402_233)
        XCTAssertEqual(swaps, 163)
        XCTAssertEqual(mismatches, 0)
    }

    /// Closure over the machine: from fresh, every event over the refs {live, A/h1, A/h2, B/hB} (54 events).
    /// Every reachable state has a way back to idle, and no non-idle state is one that no event can leave.
    func testEveryReachableStateHasAWayToIdle() {
        let refs = [live(), ref("A", "h1"), ref("A", "h2"), ref("B", "hB")]
        var events: [E] = [.rollbackRequested, .cancel] + refs.map { st($0.version, $0.treeHash) }
        for r in refs {
            let (v, t) = (r.version, r.treeHash)
            events += [.validatedOk(v, tree: t), .validationRefused(v, tree: t), .rendered(v, tree: t), .renderFailed(v, tree: t),
                       .consentGiven(v, tree: t), .consentDenied(v, tree: t), .swapped(v, tree: t), .swapFailed(v, tree: t),
                       .shimsWritten(v, tree: t), .shimsFailed(v, tree: t), .wiringApplied(v, tree: t), .wiringFailed(v, tree: t)]
        }
        XCTAssertEqual(events.count, 54)
        var seen: Set<KitUpdateState> = [fresh()]
        var order: [KitUpdateState] = [fresh()]
        var edges: [KitUpdateState: Set<KitUpdateState>] = [:]
        var i = 0
        while i < order.count, order.count < 200_000 {
            let s = order[i]; i += 1
            var out: Set<KitUpdateState> = []
            for e in events {
                let n = KitUpdateMachine.step(s, e).0
                out.insert(n)
                if seen.insert(n).inserted { order.append(n) }
            }
            edges[s] = out
        }
        XCTAssertLessThan(order.count, 200_000, "the closure is finite")
        var canIdle = Set(order.filter { $0.phase == .idle })
        var grew = true
        while grew {
            grew = false
            for s in order where !canIdle.contains(s) {
                if let out = edges[s], !out.isDisjoint(with: canIdle) { canIdle.insert(s); grew = true }
            }
        }
        XCTAssertEqual(canIdle.count, order.count, "a reachable state has no way to idle")
        for s in order where s.phase != .idle {
            XCTAssertTrue(edges[s].map { $0.contains(where: { $0 != s }) } ?? false, "phase \(s.phase) cannot be left")
        }
    }
}

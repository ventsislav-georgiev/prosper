import XCTest
@testable import ProsperApp
import ProsperHelperProtocol

/// Entry 1208: which helper answers. The app asks `helperInfo` on a throwaway connection of its own and keeps
/// the answer for the run; only the refusal text reads it. Fakes only: no XPC connection to the Mach service
/// (the live factory returns nil under XCTest and every row replaces it), no helper, no SMC, no pmset, and the
/// 6 s ceiling is a seam the rows fire themselves.
@MainActor
final class FanHelperIdentityTests: XCTestCase {

    /// A connection to nothing, as the helper side sees it: `resume` opens it on a LidHelperCore (the helper's
    /// open-connection count) and a close (the app's invalidate, or the helper closing it) closes it there and
    /// on a FanControlCore, once each (both cores dedupe). The proxy answers `helperInfo` per `mode` and every
    /// Bool method with true at once. Replies and errors come on a background queue, as XPC delivers them.
    final class FakeConn: NSXPCConnection, @unchecked Sendable {
        enum Mode { case old, silent, answers(Int, Int), fails(String, Int) }
        var mode = Mode.silent
        var lid: LidHelperCore?
        var fans: FanControlCore?
        var invalidations = 0
        var onInvalidate: (() -> Void)?
        /// silent: the reply block, kept so a row can answer late.
        var late: (@Sendable (Int, Int) -> Void)?
        override func resume() { lid?.connectionOpened(ObjectIdentifier(self)) }
        override func invalidate() { invalidations += 1; helperCloses(); onInvalidate?() }
        func helperCloses() { _ = lid?.connectionClosed(ObjectIdentifier(self)); fans?.connectionClosed(ObjectIdentifier(self)) }
        override func remoteObjectProxyWithErrorHandler(_ handler: @escaping (Error) -> Void) -> Any {
            let p = Proxy()
            p.conn = self
            p.error = handler
            return p
        }

        final class Proxy: NSObject, ProsperHelperProtocol, @unchecked Sendable {
            weak var conn: FakeConn?
            var error: ((Error) -> Void)?
            func setLidSleepDisabled(_ on: Bool, withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func setRemoteWake(_ json: String, withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func setRemoteSessionActive(_ on: Bool, withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func clearRemoteSession(withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func sleepNow(withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func setFanManualRPM(_ index: Int, rpm: Double, withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func setFanAuto(_ index: Int, holdUnlock: Bool, withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func resetAllFans(withReply reply: @escaping (Bool) -> Void) { reply(true) }
            func setFanManualRPMWithReason(_ index: Int, rpm: Double, withReply reply: @escaping (Int) -> Void) {
                XCTFail("entry 1208 never sends the reason engage")
            }
            func helperInfo(withReply reply: @escaping (Int, Int) -> Void) {
                nonisolated(unsafe) let reply = reply
                guard let conn else { return }
                switch conn.mode {
                case .old:
                    // As the probe showed an old helper doing: it closes the connection, the error handler runs at once.
                    conn.helperCloses()
                    nonisolated(unsafe) let error = error
                    DispatchQueue.global().async { error?(CocoaError(.xpcConnectionInterrupted)) }
                case .silent:
                    conn.late = { v, c in reply(v, c) }
                case .answers(let v, let c):
                    DispatchQueue.global().async { reply(v, c) }
                case .fails(let domain, let code):
                    // Any error XPC may give, e.g. 4099 for a helper not approved, not registered or not reachable.
                    nonisolated(unsafe) let error = error
                    DispatchQueue.global().async { error?(NSError(domain: domain, code: code)) }
                }
            }
        }
    }

    private var made = 0
    private var ceilings: [@Sendable @MainActor () -> Void] = []
    private var retries: [@Sendable @MainActor () -> Void] = []
    private var savedFactory: (() -> NSXPCConnection?)?
    private var savedCeiling: ((@escaping @Sendable @MainActor () -> Void) -> Void)?
    private var savedRetry: ((@escaping @Sendable @MainActor () -> Void) -> Void)?
    private var savedPrefs: (manual: Bool, hold: Bool) = (false, false)

    /// Manual off, the fast re-engage hold off (the rows leave the fan connection nil or a fake), nothing in
    /// flight, no answer yet; the factory hands out `conn`, the ceiling and the retry are kept for the row to fire.
    private func start(_ conn: FakeConn) {
        savedPrefs = (Preferences.fanManualEnabled, Preferences.fanHoldUnlock)
        Preferences.fanHoldUnlock = false
        Preferences.fanManualEnabled = false
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        FanControlHelper.helperMayHaveChanged()
        savedFactory = FanControlHelper.makeIdentityConnection
        savedCeiling = FanControlHelper.identityCeiling
        savedRetry = FanControlHelper.identityRetry
        use(conn)
        FanControlHelper.identityCeiling = { [unowned self] in ceilings.append($0) }
        FanControlHelper.identityRetry = { [unowned self] in retries.append($0) }
    }

    private func use(_ conn: FakeConn) {
        FanControlHelper.makeIdentityConnection = { [unowned self] in made += 1; return conn }
    }

    private func finish() {
        FanControlHelper.helperMayHaveChanged()   // the next row (and every other class) starts with no answer
        if let savedFactory { FanControlHelper.makeIdentityConnection = savedFactory }
        if let savedCeiling { FanControlHelper.identityCeiling = savedCeiling }
        if let savedRetry { FanControlHelper.identityRetry = savedRetry }
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        Preferences.fanManualEnabled = savedPrefs.manual
        Preferences.fanHoldUnlock = savedPrefs.hold
    }

    /// Ask, and wait for the throwaway's invalidate (every exit of an ask ends there).
    private func askAndAwaitClose(_ conn: FakeConn) async {
        let closed = expectation(description: "throwaway invalidated")
        conn.onInvalidate = { closed.fulfill() }
        FanControlHelper.askHelperIdentityIfIdle()
        await fulfillment(of: [closed], timeout: 5)
        conn.onInvalidate = nil
    }

    /// Fire the kept retry (the second ask after a first interruption) on `conn`, and wait for its close.
    private func retryAndAwaitClose(_ conn: FakeConn) async {
        XCTAssertEqual(retries.count, 1, "one retry kept")
        guard let retry = retries.popLast() else { return }
        use(conn)
        let closed = expectation(description: "second throwaway invalidated")
        conn.onInvalidate = { closed.fulfill() }
        retry()
        await fulfillment(of: [closed], timeout: 5)
        conn.onInvalidate = nil
    }

    private func helperSide() -> (LidHelperCore, FanControlCore, NSObject) {
        let lid = LidHelperCore(apply: { _ in true }, onIdle: {})
        let fans = FanControlCore(reset: { true }, maxCelsius: { nil })
        return (lid, fans, NSObject())
    }

    // (i) D1208-a: an old helper's error. Verdict old; the throwaway closed once; the fan connection object, the
    // manual preference, and on the helper side the lid override with its own connection and a fan pin held by
    // another connection, all as before.
    func testOldHelperReadsOldAndTouchesNoFanOrLidState() async {
        let t = FakeConn()
        t.mode = .old
        start(t); defer { finish() }
        let (lid, fans, lidConn) = helperSide()
        let fanFake = FakeConn()
        lid.connectionOpened(ObjectIdentifier(lidConn))
        XCTAssertTrue(lid.setOverride(true))
        XCTAssertTrue(fans.manualRequest(index: 0, rpm: 2000, holder: ObjectIdentifier(fanFake), maxCelsius: nil, macOSRPM: nil))
        t.lid = lid; t.fans = fans
        FanControlHelper.inject(connection: fanFake, engagesInFlight: 0)

        await askAndAwaitClose(t)
        XCTAssertTrue(FanControlHelper.helperIdentity == nil, "one interruption is not proof (D1208-f)")
        XCTAssertEqual(t.invalidations, 1)
        let t2 = FakeConn()
        t2.mode = .old
        t2.lid = lid; t2.fans = fans
        await retryAndAwaitClose(t2)

        XCTAssertEqual(made, 2)
        XCTAssertTrue(FanControlHelper.helperIdentity == .old, "two interruptions in a row on two throwaways")
        XCTAssertEqual(t.invalidations, 1)
        XCTAssertEqual(t2.invalidations, 1)
        XCTAssertTrue(FanControlHelper.identityConnection == nil)
        XCTAssertTrue(FanControlHelper.connection === fanFake, "the fan connection is the same object")
        XCTAssertEqual(fanFake.invalidations, 0, "the fan connection was never closed")
        XCTAssertFalse(Preferences.fanManualEnabled)
        XCTAssertEqual(lid.connections, 1)
        XCTAssertTrue(lid.overrideOn, "the lid override stays with the lid connection")
        XCTAssertTrue(fans.holder == ObjectIdentifier(fanFake) && fans.manualHeld && fans.heldTargets == [0: 2000],
                      "the other connection's pin stays")
    }

    // (ii) A silent helper: the ceiling (a seam, fired here) reads unknown (D1208-g) and closes the throwaway; a
    // later idle trigger asks again; a reply after that ask's ceiling still reads current (D1208-d).
    func testSilentHelperReadsUnknownAtTheCeilingAndALateReplyIsCurrent() async {
        let t = FakeConn()
        t.mode = .silent
        start(t); defer { finish() }
        let (lid, _, _) = helperSide()
        t.lid = lid
        FanControlHelper.askHelperIdentityIfIdle()
        XCTAssertEqual(made, 1)
        XCTAssertEqual(lid.connections, 1, "the ask is open on the helper")
        XCTAssertTrue(FanControlHelper.helperIdentity == nil, "no answer before the ceiling")
        XCTAssertTrue(FanControlHelper.identityConnection === t)
        XCTAssertEqual(ceilings.count, 1)
        ceilings.last?()
        XCTAssertTrue(FanControlHelper.helperIdentity == nil, "silence is unknown")
        XCTAssertEqual(t.invalidations, 1)
        XCTAssertEqual(lid.connections, 0, "closed at the ceiling")
        XCTAssertTrue(FanControlHelper.identityConnection == nil)
        XCTAssertTrue(retries.isEmpty, "silence is no interruption")

        let t2 = FakeConn()
        t2.mode = .silent
        t2.lid = lid
        use(t2)
        FanControlHelper.askHelperIdentityIfIdle()
        XCTAssertEqual(made, 2, "a later idle trigger asks again")
        XCTAssertEqual(ceilings.count, 2)
        ceilings.last?()
        XCTAssertTrue(FanControlHelper.helperIdentity == nil)
        XCTAssertEqual(lid.connections, 0)

        let late = try? XCTUnwrap(t2.late)
        DispatchQueue.global().async { late?(1, 1) }
        // The reply hops to main in a Task; yield (no sleep, no clock) until it ran.
        for _ in 0..<10_000 where FanControlHelper.helperIdentity != .current { await Task.yield() }
        XCTAssertTrue(FanControlHelper.helperIdentity == .current, "a late reply is accepted")
        XCTAssertEqual(t2.invalidations, 1)
        ceilings.last?()   // a second ceiling call changes nothing
        XCTAssertTrue(FanControlHelper.helperIdentity == .current)
    }

    // (iii) Only version >= 1 with capability bit 0 reads current; any Int is taken without a trap.
    func testReplyValuesDecideTheVerdict() async {
        let t = FakeConn()
        start(t); defer { finish() }
        let table: [(Int, Int, FanControlHelper.HelperIdentity)] = [
            (0, 1, .old), (1, 0, .old), (1, 2, .old), (-1, 1, .old), (Int.min, -1, .old),
            (1, 1, .current), (7, -1, .current), (2, 3, .current), (Int.max, Int.max, .current),
        ]
        for (v, c, want) in table {
            FanControlHelper.helperMayHaveChanged()
            let conn = FakeConn()
            conn.mode = .answers(v, c)
            use(conn)
            await askAndAwaitClose(conn)
            XCTAssertTrue(FanControlHelper.helperIdentity == want, "version \(v) caps \(c)")
            XCTAssertEqual(conn.invalidations, 1, "version \(v) caps \(c)")
        }
    }

    // (iv) D1208-e: not asked while manual is on or an engage is in flight; asked once both are false, and from
    // the hook at the end of a reset that went to the helper.
    func testAskedOnlyWithManualOffAndNothingInFlight() async {
        let t = FakeConn()
        t.mode = .answers(1, 1)
        start(t); defer { finish() }
        Preferences.fanManualEnabled = true
        FanControlHelper.askHelperIdentityIfIdle()
        XCTAssertEqual(made, 0, "manual on")
        Preferences.fanManualEnabled = false
        FanControlHelper.inject(connection: nil, engagesInFlight: 1)
        FanControlHelper.askHelperIdentityIfIdle()
        XCTAssertEqual(made, 0, "an engage in flight")
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        await askAndAwaitClose(t)
        XCTAssertEqual(made, 1)
        XCTAssertTrue(FanControlHelper.helperIdentity == .current)

        // The hook: a reset with manual on does not ask; with manual off it does.
        FanControlHelper.helperMayHaveChanged()
        let fanFake = FakeConn()
        let second = FakeConn()
        second.mode = .answers(1, 1)
        use(second)
        FanControlHelper.inject(connection: fanFake, engagesInFlight: 0)
        Preferences.fanManualEnabled = true
        let resetOn = await FanControlHelper.resetAll()
        XCTAssertTrue(resetOn)
        XCTAssertEqual(made, 1, "a reset with manual on does not ask")
        Preferences.fanManualEnabled = false
        let closed = expectation(description: "throwaway invalidated")
        second.onInvalidate = { closed.fulfill() }
        let resetOff = await FanControlHelper.resetAll()
        XCTAssertTrue(resetOff)
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(made, 2, "the reset's hook asked")
        XCTAssertTrue(FanControlHelper.helperIdentity == .current)
        XCTAssertTrue(FanControlHelper.connection === fanFake)
        XCTAssertEqual(fanFake.invalidations, 0)
    }

    // (v) Once per run: an answer is kept; an open ask is not doubled; the re-ask hook (a re-registration, or the
    // fan connection dropping from the helper's side) asks again.
    func testAskedOncePerRunUntilTheHelperMayHaveChanged() async {
        let t = FakeConn()
        t.mode = .silent
        start(t); defer { finish() }
        FanControlHelper.askHelperIdentityIfIdle()
        FanControlHelper.askHelperIdentityIfIdle()
        XCTAssertEqual(made, 1, "an open ask is not doubled")
        ceilings.last?()
        XCTAssertTrue(FanControlHelper.helperIdentity == nil, "the ceiling is no answer")

        let next = FakeConn()
        next.mode = .answers(1, 1)
        use(next)
        FanControlHelper.helperMayHaveChanged()
        XCTAssertTrue(FanControlHelper.helperIdentity == nil)
        await askAndAwaitClose(next)
        XCTAssertEqual(made, 2)
        XCTAssertTrue(FanControlHelper.helperIdentity == .current)
        FanControlHelper.askHelperIdentityIfIdle()
        XCTAssertEqual(made, 2, "an answer (current) is kept")

        // A reply to an ask the hook dropped changes nothing; the hook closed that ask.
        let dropped = FakeConn()
        dropped.mode = .silent
        use(dropped)
        FanControlHelper.helperMayHaveChanged()
        FanControlHelper.askHelperIdentityIfIdle()
        XCTAssertEqual(made, 3)
        FanControlHelper.helperMayHaveChanged()
        XCTAssertEqual(dropped.invalidations, 1, "the hook closes an open ask")
        dropped.late?(1, 1)
        for _ in 0..<1_000 { await Task.yield() }   // let the reply's hop run; it must change nothing
        XCTAssertTrue(FanControlHelper.helperIdentity == nil)
    }

    // (vi) D1208-b: after every exit (error, reply, ceiling) the helper's open-connection count is back where it
    // was and the throwaway was invalidated exactly once.
    func testEveryExitClosesTheThrowaway() async {
        let t = FakeConn()
        start(t); defer { finish() }
        let (lid, _, lidConn) = helperSide()
        lid.connectionOpened(ObjectIdentifier(lidConn))
        for mode in [FakeConn.Mode.old, .answers(1, 1), .answers(0, 0), .silent] {
            FanControlHelper.helperMayHaveChanged()
            let conn = FakeConn()
            conn.mode = mode
            conn.lid = lid
            use(conn)
            if case .silent = mode {
                FanControlHelper.askHelperIdentityIfIdle()
                XCTAssertEqual(lid.connections, 2, "open while the ask is")
                ceilings.last?()
            } else {
                await askAndAwaitClose(conn)
            }
            XCTAssertEqual(lid.connections, 1, "\(mode)")
            XCTAssertEqual(conn.invalidations, 1, "\(mode)")
            XCTAssertTrue(FanControlHelper.identityConnection == nil, "\(mode)")
        }
    }

    // (vii) The refusal text: with an old helper the two refusals the app names by its own speed read carry one
    // more sentence; unknown and current read exactly today's text; the other replies never change.
    func testRefusalTextNamesAnOldHelperOnly() async {
        let refused = "Fans are held automatic until the Mac cools down — the overheat cut-off tripped, and macOS "
            + "runs them faster than this. Try again in a few minutes, or pick a faster speed."
        let settling = "The overheat cut-off just handed the fans to macOS. Try again in a few seconds."
        let sentence = "The Prosper helper is from an older version, so Prosper can’t tell why."
        let others: [FanManualReply] = [.engaged, .unavailable, .needsApproval, .writeFailed]
        let today = others.map(\.errorText)
        let t = FakeConn()
        t.mode = .answers(1, 1)
        start(t); defer { finish() }

        XCTAssertTrue(FanControlHelper.helperIdentity == nil)
        XCTAssertEqual(FanManualReply.refused.errorText, refused, "unknown")
        XCTAssertEqual(FanManualReply.settling.errorText, settling, "unknown")

        await askAndAwaitClose(t)
        XCTAssertTrue(FanControlHelper.helperIdentity == .current)
        XCTAssertEqual(FanManualReply.refused.errorText, refused, "current")
        XCTAssertEqual(FanManualReply.settling.errorText, settling, "current")

        FanControlHelper.helperMayHaveChanged()
        let old = FakeConn()
        old.mode = .old
        use(old)
        await askAndAwaitClose(old)
        XCTAssertTrue(FanControlHelper.helperIdentity == nil, "one interruption, the retry not fired yet")
        XCTAssertEqual(FanManualReply.refused.errorText, refused, "one interruption")
        XCTAssertEqual(FanManualReply.settling.errorText, settling, "one interruption")
        let old2 = FakeConn()
        old2.mode = .old
        await retryAndAwaitClose(old2)
        XCTAssertTrue(FanControlHelper.helperIdentity == .old)
        XCTAssertEqual(FanManualReply.refused.errorText, refused + " " + sentence)
        XCTAssertEqual(FanManualReply.settling.errorText, settling + " " + sentence)
        XCTAssertEqual(others.map(\.errorText), today, "only the two refusals change")

        FanControlHelper.helperMayHaveChanged()
        XCTAssertEqual(FanManualReply.refused.errorText, refused, "back to unknown")
    }

    // Round 3 (F1208-1): the two refusal texts as they read with no sentence (today's text, literal).
    private static let refusedToday = "Fans are held automatic until the Mac cools down — the overheat cut-off tripped, "
        + "and macOS runs them faster than this. Try again in a few minutes, or pick a faster speed."
    private static let settlingToday = "The overheat cut-off just handed the fans to macOS. Try again in a few seconds."

    private func assertTodaysText(_ why: String, line: UInt = #line) {
        XCTAssertEqual(FanManualReply.refused.errorText, Self.refusedToday, why, line: line)
        XCTAssertEqual(FanManualReply.settling.errorText, Self.settlingToday, why, line: line)
    }

    // (viii) Round 3 (a), rows (ii) and (v): an error that is not an older helper's interruption (4099, the
    // connection invalid: a helper not approved, not registered or not reachable) leaves the verdict unknown,
    // closes the throwaway, puts the helper's open count back, records nothing at the ceiling, keeps today's
    // text, and the next idle moment asks again.
    func testInvalidConnectionLeavesTheVerdictUnknownAndAsksAgain() async {
        let t = FakeConn()
        t.mode = .fails(NSCocoaErrorDomain, 4099)
        start(t); defer { finish() }
        let (lid, _, lidConn) = helperSide()
        lid.connectionOpened(ObjectIdentifier(lidConn))
        t.lid = lid
        await askAndAwaitClose(t)
        XCTAssertEqual(made, 1)
        XCTAssertTrue(FanControlHelper.helperIdentity == nil, "4099 is no evidence of an older helper")
        XCTAssertEqual(t.invalidations, 1)
        XCTAssertTrue(FanControlHelper.identityConnection == nil)
        XCTAssertEqual(lid.connections, 1, "back to its earlier value")
        XCTAssertEqual(ceilings.count, 1)
        ceilings.last?()   // the ceiling of an ask that already ended records nothing
        XCTAssertTrue(FanControlHelper.helperIdentity == nil, "the ceiling after the exit")
        assertTodaysText("after a 4099")

        let next = FakeConn()
        next.mode = .fails(NSCocoaErrorDomain, 4099)
        next.lid = lid
        use(next)
        await askAndAwaitClose(next)
        XCTAssertEqual(made, 2, "the next idle moment asks again")
        XCTAssertTrue(FanControlHelper.helperIdentity == nil)
        XCTAssertEqual(next.invalidations, 1)
        XCTAssertEqual(lid.connections, 1)
        XCTAssertTrue(retries.isEmpty, "4099 asks no retry")

        // A 4099 clears a pending first interruption: one more interruption after it is still not old.
        let first = FakeConn()
        first.mode = .old
        use(first)
        await askAndAwaitClose(first)
        XCTAssertEqual(FanControlHelper.identityInterruptions, 1)
        let invalid = FakeConn()
        invalid.mode = .fails(NSCocoaErrorDomain, 4099)
        await retryAndAwaitClose(invalid)
        XCTAssertEqual(FanControlHelper.identityInterruptions, 0, "another error clears the count")
        let again = FakeConn()
        again.mode = .old
        use(again)
        await askAndAwaitClose(again)
        XCTAssertTrue(FanControlHelper.helperIdentity == nil, "4097, 4099, 4097 is not two in a row")
        assertTodaysText("after 4097, 4099, 4097")
    }

    // (ix) Round 3 (a), rows (i) and (iii): only NSCocoaErrorDomain with code 4097 (the interruption the probe
    // saw from an older helper), twice in a row, reads old; every other domain or code, twice, reads unknown.
    // Each ask closes its throwaway.
    func testOnlyTheOlderHelpersInterruptionReadsOld() async {
        let t = FakeConn()
        start(t); defer { finish() }
        let table: [(String, Int, FanControlHelper.HelperIdentity?)] = [
            (NSCocoaErrorDomain, 4097, .old), (NSCocoaErrorDomain, 4099, nil), (NSCocoaErrorDomain, 4096, nil),
            (NSCocoaErrorDomain, 0, nil), (NSCocoaErrorDomain, -4097, nil), (NSPOSIXErrorDomain, 4097, nil),
            (NSOSStatusErrorDomain, 4097, nil), ("eu.example.other", 4097, nil), ("eu.example.other", Int.min, nil),
        ]
        for (domain, code, want) in table {
            FanControlHelper.helperMayHaveChanged()
            let conn = FakeConn()
            conn.mode = .fails(domain, code)
            use(conn)
            await askAndAwaitClose(conn)
            XCTAssertTrue(FanControlHelper.helperIdentity == nil, "\(domain) \(code): one error")
            let second = FakeConn()
            second.mode = .fails(domain, code)
            if want == .old {
                await retryAndAwaitClose(second)
            } else {
                XCTAssertTrue(retries.isEmpty, "\(domain) \(code): no retry")
                use(second)
                await askAndAwaitClose(second)
            }
            XCTAssertTrue(FanControlHelper.helperIdentity == want, "\(domain) \(code)")
            XCTAssertEqual(conn.invalidations, 1, "\(domain) \(code)")
            XCTAssertEqual(second.invalidations, 1, "\(domain) \(code)")
            XCTAssertTrue(FanControlHelper.identityConnection == nil, "\(domain) \(code)")
        }
    }

    // (x) Round 3 (c), rows (iv) and (v): a new fan connection puts an old verdict back to unknown (today's text,
    // asked again at the next idle moment); a current verdict and an unknown one stay as they are.
    func testANewFanConnectionResetsOnlyAnOldVerdict() async {
        let t = FakeConn()
        t.mode = .answers(1, 0)   // a reply without the bit reads old at once
        start(t); defer { finish() }
        await askAndAwaitClose(t)
        XCTAssertTrue(FanControlHelper.helperIdentity == .old)
        FanControlHelper.fanConnectionMade()
        XCTAssertTrue(FanControlHelper.helperIdentity == nil, "old plus a new connection")
        assertTodaysText("after a new fan connection")

        let current = FakeConn()
        current.mode = .answers(1, 1)
        use(current)
        await askAndAwaitClose(current)
        XCTAssertEqual(made, 2, "asked again at the next idle moment")
        XCTAssertTrue(FanControlHelper.helperIdentity == .current)
        FanControlHelper.fanConnectionMade()
        XCTAssertTrue(FanControlHelper.helperIdentity == .current, "current plus a new connection")

        FanControlHelper.helperMayHaveChanged()
        FanControlHelper.fanConnectionMade()
        XCTAssertTrue(FanControlHelper.helperIdentity == nil, "nil plus a new connection")
        XCTAssertEqual(current.invalidations, 1)
    }

    // (xi) D1208-f: one interruption then a current reply on the second ask reads current and clears the count.
    func testOneInterruptionThenACurrentReplyReadsCurrent() async {
        let t = FakeConn()
        t.mode = .old
        start(t); defer { finish() }
        let (lid, _, lidConn) = helperSide()
        lid.connectionOpened(ObjectIdentifier(lidConn))
        t.lid = lid
        await askAndAwaitClose(t)
        XCTAssertTrue(FanControlHelper.helperIdentity == nil)
        XCTAssertEqual(FanControlHelper.identityInterruptions, 1)
        XCTAssertEqual(lid.connections, 1)
        let next = FakeConn()
        next.mode = .answers(1, 1)
        next.lid = lid
        await retryAndAwaitClose(next)
        XCTAssertEqual(made, 2)
        XCTAssertTrue(FanControlHelper.helperIdentity == .current)
        XCTAssertEqual(FanControlHelper.identityInterruptions, 0)
        XCTAssertEqual(lid.connections, 1, "back to its earlier value")
        assertTodaysText("current after one interruption")
    }

    // (xii) D1208-f: the second ask is made only while idle; with manual on or an engage in flight the kept
    // retry asks nothing, the count waits, and the next idle moment's interruption reads old.
    func testTheRetryAsksOnlyWhileIdle() async {
        let t = FakeConn()
        t.mode = .old
        start(t); defer { finish() }
        await askAndAwaitClose(t)
        XCTAssertEqual(made, 1)
        let retry = retries.popLast()
        XCTAssertNotNil(retry)
        let second = FakeConn()
        second.mode = .old
        use(second)
        Preferences.fanManualEnabled = true
        retry?()
        XCTAssertEqual(made, 1, "manual on")
        Preferences.fanManualEnabled = false
        FanControlHelper.inject(connection: nil, engagesInFlight: 1)
        retry?()
        XCTAssertEqual(made, 1, "an engage in flight")
        FanControlHelper.inject(connection: nil, engagesInFlight: 0)
        XCTAssertTrue(FanControlHelper.helperIdentity == nil)
        XCTAssertEqual(FanControlHelper.identityInterruptions, 1, "the count waits for the next idle moment")
        await askAndAwaitClose(second)
        XCTAssertEqual(made, 2)
        XCTAssertTrue(FanControlHelper.helperIdentity == .old)
        XCTAssertEqual(second.invalidations, 1)
    }
}

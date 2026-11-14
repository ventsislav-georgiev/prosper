import Foundation
import XCTest
@testable import ProsperApp

/// #947: the consent panel's queue, driven through ManagedConfigSheetConsent's presenter seam and the panel's
/// show seam. No panel is built or ordered front. The caller's give-up is a cancel of the confirming task, which
/// is what ExtensionHost.awaitSync does after its 5 minutes: no timer, no wait beyond an expectation.
/// One value, set and read on main only.
private final class MCQBox<T>: @unchecked Sendable { var value: T? }

@MainActor
final class ManagedConfigConsentQueueTests: XCTestCase {
    @MainActor final class Log {
        var shown: [ManagedConfigConsentModel] = []
        var closed = 0
        var enqueued: XCTestExpectation?
    }

    /// A panel behind its show seam, and a sheet consent whose presenter enqueues on it (both run on main).
    private func rig() -> (Log, ManagedConfigSheetConsent) {
        let log = Log()
        let panel = ManagedConfigConsentPanel { model in
            log.shown.append(model)
            return { log.closed += 1 }
        }
        let consent = ManagedConfigSheetConsent { changes, done in
            let withdraw = panel.enqueue(changes, done: done)
            log.enqueued?.fulfill()
            return withdraw
        }
        return (log, consent)
    }

    /// A hand-built set with a made-up identity (one target), so equal sets of one kit and operation can join.
    private static func set(_ owner: String, _ action: ManagedConfigChangeSet.Action = .apply,
                            identity: [[String]]? = [["/Users/example/.claude/CLAUDE.md", "no file", "new 00", "mode 644"]]) -> ManagedConfigChangeSet {
        ManagedConfigChangeSet(action: action, owner: owner, files: [], pieces: [], identity: identity)
    }

    /// Starts one confirm off main and returns once the panel holds it.
    private func ask(_ consent: ManagedConfigSheetConsent, _ set: ManagedConfigChangeSet, _ log: Log) async -> Task<Bool, Never> {
        let e = expectation(description: "enqueued \(set.owner)")
        log.enqueued = e
        let task = Task.detached { await consent.confirm(set) }
        await fulfillment(of: [e], timeout: 10)
        log.enqueued = nil
        return task
    }

    private func owners(_ log: Log) -> [String] { log.shown.map(\.changes.owner) }

    /// The task's value, or nil when it has none within 10 s (a broken queue under a mutant): never hangs the run.
    /// The waiting task is cancelled on the way out (it only awaits `task`, which is left as it is).
    private func value<T: Sendable>(_ task: Task<T, Never>) async -> T? {
        let box = MCQBox<T>(), e = expectation(description: "answered")
        let waiter = Task { @MainActor in box.value = await task.value; e.fulfill() }
        await fulfillment(of: [e], timeout: 10)
        waiter.cancel()
        return box.value
    }

    /// Answers every sheet still up or queued, so no request of a row is left waiting (no-op when the row is green).
    private func drain(_ log: Log) { for m in log.shown where !m.answered { m.answer(false) } }

    // MARK: B-INFO-2

    func testAGivenUpShownRequestLeavesTheQueueAndTheNextIsShown() async {
        let (log, consent) = rig()
        let first = await ask(consent, Self.set("kit-a"), log)
        let second = await ask(consent, Self.set("kit-b"), log)
        XCTAssertEqual(owners(log), ["kit-a"], "one at a time")
        first.cancel() // the caller gave up
        let got1 = await value(first)
        XCTAssertEqual(got1, false)
        XCTAssertEqual(owners(log), ["kit-a", "kit-b"], "the next request is shown")
        XCTAssertEqual(log.closed, 1, "the given-up sheet closed")
        log.shown.first?.answer(true) // a late click on the given-up sheet
        XCTAssertEqual(owners(log), ["kit-a", "kit-b"], "the late answer changes nothing")
        XCTAssertEqual(log.closed, 1)
        log.shown.last?.answer(true)
        drain(log)
        let got2 = await value(second)
        XCTAssertEqual(got2, true)
        XCTAssertEqual(log.closed, 2)
    }

    func testAGivenUpQueuedRequestIsNeverShown() async {
        let (log, consent) = rig()
        let first = await ask(consent, Self.set("kit-a"), log)
        let second = await ask(consent, Self.set("kit-b"), log)
        second.cancel()
        let got3 = await value(second)
        XCTAssertEqual(got3, false)
        XCTAssertEqual(owners(log), ["kit-a"])
        XCTAssertEqual(log.closed, 0, "the shown sheet stays for its caller")
        log.shown.first?.answer(true)
        let got4 = await value(first)
        XCTAssertEqual(got4, true)
        XCTAssertEqual(owners(log), ["kit-a"], "the given-up request was never presented")
        let third = await ask(consent, Self.set("kit-c"), log)
        XCTAssertEqual(owners(log), ["kit-a", "kit-c"], "idle: a new request shows at once")
        log.shown.last?.answer(false)
        drain(log)
        let got5 = await value(third)
        XCTAssertEqual(got5, false)
    }

    // MARK: B-INFO-9 (a)

    func testAnIdenticalRequestJoinsThePendingSheetAndKeepsItWhenTheFirstGivesUp() async {
        let (log, consent) = rig()
        let first = await ask(consent, Self.set("kit-a", .remove), log)
        let second = await ask(consent, Self.set("kit-a", .remove), log)
        XCTAssertEqual(owners(log), ["kit-a"], "one sheet")
        first.cancel()
        let got6 = await value(first)
        XCTAssertEqual(got6, false)
        XCTAssertEqual(log.closed, 0, "the sheet stays: the second request still waits on it")
        log.shown.first?.answer(true)
        XCTAssertEqual(log.shown.count, 1)
        for m in log.shown where !m.answered { m.answer(true) } // a mutant's second sheet: the row still ends
        let got7 = await value(second)
        XCTAssertEqual(got7, true, "the second request gets the sheet's answer")
    }

    func testADoubleUninstallPresentsOneSheet() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        let applied = await env.mc.apply([MCPieces.block()], owner: env.owner)
        XCTAssertEqual(applied.status, .done)
        let (log, consent) = rig()
        let mc = ManagedConfig(roots: env.mc.roots, consent: consent)
        let owner = env.owner
        let both = expectation(description: "both removes asked")
        both.expectedFulfillmentCount = 2
        log.enqueued = both
        // what ExtensionRegistry.uninstall calls, twice
        let r1 = Task.detached { await mc.remove(owner: owner) }
        let r2 = Task.detached { await mc.remove(owner: owner) }
        await fulfillment(of: [both], timeout: 10)
        log.enqueued = nil
        XCTAssertEqual(log.shown.count, 1, "one sheet for both")
        log.shown.first?.answer(true)
        XCTAssertEqual(log.shown.count, 1, "never a second sheet")
        drain(log)
        let a = await value(r1), b = await value(r2)
        XCTAssertTrue([a?.status, b?.status].contains(.done), "\(String(describing: a)) \(String(describing: b))")
        XCTAssertTrue(a?.ok == true && b?.ok == true)
        XCTAssertEqual(env.read(env.claudeMD), "# mine\n")
        XCTAssertEqual(mc.ownerIDs(), [])
    }

    func testAnApplyAndAnUninstallOfOneKitPresentTwo() async throws {
        let env = makeMCEnv()
        try env.write("# mine\n", env.claudeMD)
        _ = await env.mc.apply([MCPieces.block()], owner: env.owner)
        let before = env.bytes(env.claudeMD)
        let (log, consent) = rig()
        let mc = ManagedConfig(roots: env.mc.roots, consent: consent)
        let owner = env.owner
        let both = expectation(description: "both asked")
        both.expectedFulfillmentCount = 2
        log.enqueued = both
        let r1 = Task.detached { await mc.apply([MCPieces.block("more", text: "More kit rules.")], owner: owner) }
        let r2 = Task.detached { await mc.remove(owner: owner) }
        await fulfillment(of: [both], timeout: 10)
        log.enqueued = nil
        XCTAssertEqual(log.shown.count, 1, "one at a time")
        log.shown.first?.answer(false)
        XCTAssertEqual(log.shown.count, 2, "the other operation has its own sheet")
        log.shown.last?.answer(false)
        drain(log)
        let a = await value(r1), b = await value(r2)
        XCTAssertEqual(a?.status, .denied)
        XCTAssertEqual(b?.status, .denied)
        XCTAssertEqual(Set(log.shown.map(\.changes.action)), [.apply, .remove])
        XCTAssertEqual(env.bytes(env.claudeMD), before, "both declined: nothing written")
    }

    // MARK: F947-1: a join only on the full identity of the write

    /// Two applies of one kit and one piece; `between` changes the file after the first sheet is up. The two
    /// sheets look the same (`==`, round 1's join rule) yet must be two sheets, one at a time, two answers.
    private func assertTwoSheets(_ start: [UInt8], between: (MCEnv) throws -> Void, line: UInt = #line) async throws {
        let env = makeMCEnv()
        try Data(start).write(to: env.claudeMD)
        XCTAssertEqual(chmod(env.claudeMD.path, 0o644), 0, line: line) // the row's own file, whatever the umask
        let (log, consent) = rig()
        let mc = ManagedConfig(roots: env.mc.roots, consent: consent)
        let owner = env.owner
        func asked() async -> Task<ManagedConfigResult, Never> {
            let e = expectation(description: "asked")
            log.enqueued = e
            let t = Task.detached { await mc.apply([MCPieces.block()], owner: owner) }
            await fulfillment(of: [e], timeout: 10)
            log.enqueued = nil
            return t
        }
        let r1 = await asked()
        try between(env)
        let after = env.bytes(env.claudeMD)
        let r2 = await asked()
        XCTAssertEqual(log.shown.count, 1, "one at a time", line: line)
        log.shown.first?.answer(false)
        XCTAssertEqual(log.shown.count, 2, "the second request has its own sheet", line: line)
        if let a = log.shown.first?.changes, let b = log.shown.last?.changes {
            XCTAssertTrue(a == b, "the two sheets show the same: only hidden facts differ", line: line)
            XCTAssertNotEqual(a.identity, b.identity, line: line)
        }
        log.shown.last?.answer(false)
        drain(log)
        let a = await value(r1), b = await value(r2)
        XCTAssertEqual(a?.status, .denied, line: line)
        XCTAssertEqual(b?.status, .denied, line: line)
        XCTAssertEqual(env.bytes(env.claudeMD), after, "both declined: nothing written", line: line)
    }

    private static let mine: [UInt8] = Array("# mine\n".utf8)

    func testALeadingByteOrderMarkIsItsOwnSheet() async throws {
        // the sheet leaves the mark out of line 0 (Lines skips it), so both sheets read the same
        try await assertTwoSheets(Self.mine) { env in try Data([0xEF, 0xBB, 0xBF] + Self.mine).write(to: env.claudeMD) }
    }

    func testCRLFAgainstLFIsItsOwnSheet() async throws {
        // the sheet shows a line's text without its terminator, so CRLF and LF read the same
        try await assertTwoSheets(Self.mine) { env in try Data(Array("# mine\r\n".utf8)).write(to: env.claudeMD) }
    }

    func testAChangePastTheShownLinesIsItsOwnSheet() async throws {
        // a different base: line 1 of 8 changes, two lines of context above the appended block never show it
        let lines = (1...8).map { "line \($0)\n" }.joined()
        try await assertTwoSheets(Array(lines.utf8)) { env in try env.write("LINE 1\n" + lines.dropFirst(7), env.claudeMD) }
    }

    func testADifferentModeIsItsOwnSheet() async throws {
        var url: URL?
        defer { if let url { _ = chmod(url.path, 0o644) } }
        try await assertTwoSheets(Self.mine) { env in
            url = env.claudeMD
            XCTAssertEqual(chmod(env.claudeMD.path, 0o600), 0) // the same bytes, only the mode differs
        }
    }

    func testARequestWithNoIdentityNeverJoins() async {
        let (log, consent) = rig()
        let first = await ask(consent, Self.set("kit-a", identity: nil), log)
        let second = await ask(consent, Self.set("kit-a", identity: nil), log)
        log.shown.first?.answer(true)
        XCTAssertEqual(log.shown.count, 2, "no identity: its own sheet")
        log.shown.last?.answer(false)
        drain(log)
        let got1 = await value(first), got2 = await value(second)
        XCTAssertEqual(got1, true)
        XCTAssertEqual(got2, false)
    }

    func testEachFactOfATargetIsInItsIdentity() {
        func t(_ path: String = "/Users/example/.claude/CLAUDE.md", base: [UInt8]? = ManagedConfigConsentQueueTests.mine,
               new: [UInt8]? = ManagedConfigConsentQueueTests.mine + [0x78, 0x0A],
               deletes: Bool = false, mode: mode_t = 0o644) -> [String] {
            ManagedConfigChangeSet.target(path: path, base: base, newBytes: new, deletes: deletes, mode: mode)
        }
        let all = [t(), t("/Users/example/other/CLAUDE.md"), t(base: [0xEF, 0xBB, 0xBF] + Self.mine), t(base: nil),
                   t(new: [0xEF, 0xBB, 0xBF] + Self.mine + [0x78, 0x0A]), t(new: Array("# mine\r\nx\r\n".utf8)), t(new: nil),
                   t(deletes: true), t(mode: 0o600)]
        XCTAssertEqual(Set(all).count, all.count, "every fact tells two targets apart")
        XCTAssertEqual(t(), t(), "the same facts, the same identity")
        XCTAssertEqual(t().count, 4)
        XCTAssertEqual(t().last, "mode 644")
        XCTAssertEqual(t(base: nil).dropFirst().first, "no file")
        XCTAssertEqual(t(deletes: true).dropFirst(2).first, "deletes the file")
        XCTAssertEqual(t().dropFirst(2).first, "new " + OrderedJSON.sha256(Self.mine + [0x78, 0x0A]), "a SHA-256 digest of the bytes")
        XCTAssertEqual(OrderedJSON.sha256(Self.mine).count, 64)
    }
}

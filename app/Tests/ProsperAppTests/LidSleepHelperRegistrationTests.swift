import XCTest
@testable import ProsperApp

/// QA #74 F1: a wedged smd blocks registration; each ensureRegistered retry must not
/// pin another pool thread. N concurrent callers share ONE underlying registration.
@MainActor
final class LidSleepHelperRegistrationTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    // ensureRegistered writes prosper.lidHelper.enabled to Preferences.defaults
    // (the xctest tool's domain); put back whatever was there.
    private var savedEnabled: Any?
    override func setUp() async throws { savedEnabled = Preferences.defaults.object(forKey: "prosper.lidHelper.enabled") }
    override func tearDown() async throws {
        if let v = savedEnabled { Preferences.defaults.set(v, forKey: "prosper.lidHelper.enabled") }
        else { Preferences.defaults.removeObject(forKey: "prosper.lidHelper.enabled") }
    }

    func testConcurrentEnsureRegisteredSharesOneRegistration() async throws {
        let saved = LidSleepHelper.registration
        defer { LidSleepHelper.registration = saved }
        let calls = Counter()
        let gate = DispatchGroup()
        gate.enter()   // the fake smd is wedged until the test releases it
        LidSleepHelper.registration = {
            calls.bump()
            gate.wait()
            return .failed   // .failed: no modal, no real SMAppService
        }

        let n = 8
        var tasks: [Task<Bool, Never>] = []
        for _ in 0..<n {
            tasks.append(Task { await LidSleepHelper.ensureRegistered(presentModal: false) })
        }
        // Let every caller arrive while the registration is still blocked.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(calls.value, 1, "callers must join the in-flight registration, not start their own")
        gate.leave()
        for t in tasks { _ = await t.value }
        XCTAssertEqual(calls.value, 1, "\(n) concurrent callers must resolve from ONE registration")
    }

    /// inFlight is cleared when a registration finishes, so a failed one is retried.
    func testFailedRegistrationIsRetriedByLaterCaller() async {
        let saved = LidSleepHelper.registration
        defer { LidSleepHelper.registration = saved }
        let calls = Counter()
        LidSleepHelper.registration = { calls.bump(); return .failed }
        let first = await LidSleepHelper.ensureRegistered(presentModal: false)
        XCTAssertFalse(first)
        let second = await LidSleepHelper.ensureRegistered(presentModal: false)
        XCTAssertFalse(second)
        XCTAssertEqual(calls.value, 2, "a failed registration must not be reused; the next caller starts a fresh one")
    }

    /// The check-and-set of inFlight runs under inFlightLock: while it is held, no caller starts a registration.
    func testSharedRegistrationSerializesOnInFlightLock() async {
        let saved = LidSleepHelper.registration
        defer { LidSleepHelper.registration = saved }
        let calls = Counter()
        LidSleepHelper.registration = { calls.bump(); return .failed }
        let caller: Task<LidSleepHelper.RegisterOutcome, Never> = LidSleepHelper.inFlightLock.withLock {
            let t = Task.detached { await LidSleepHelper.sharedRegistration().value }
            Thread.sleep(forTimeInterval: 0.3)
            XCTAssertEqual(calls.value, 0, "sharedRegistration must wait for inFlightLock")
            return t
        }
        _ = await caller.value
        XCTAssertEqual(calls.value, 1)
    }

    /// QA #83: the in-flight wait is its own lock, not registerLock (held across the smd IPC).
    func testSharedRegistrationDoesNotWaitOnRegisterLock() async {
        let saved = LidSleepHelper.registration
        defer { LidSleepHelper.registration = saved }
        let started = DispatchSemaphore(value: 0)
        LidSleepHelper.registration = { started.signal(); return .failed }
        let caller: Task<LidSleepHelper.RegisterOutcome, Never> = LidSleepHelper.registerLock.withLock {
            let t = Task.detached { await LidSleepHelper.sharedRegistration().value }
            XCTAssertEqual(started.wait(timeout: .now() + 2), .success,
                           "sharedRegistration must proceed while registerLock is held")
            return t
        }
        let outcome = await caller.value
        XCTAssertEqual(outcome, .failed, "the registration completes once registerLock is released")
    }
}

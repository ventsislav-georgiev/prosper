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
}

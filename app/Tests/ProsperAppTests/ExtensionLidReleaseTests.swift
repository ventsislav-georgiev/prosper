import XCTest
@testable import ProsperApp

/// #1549: a teardown's lid release is ordered on LidSleepHelper's apply chain and releases only when THIS
/// extension held the flag, including a flag set by an apply queued before the teardown and confirmed after it.
/// Every row runs the live caffeinateSetDisableLidSleep / resetResources with the applyExtensionOverride seam
/// swapped for a recorder: no XPC, no pmset, no helper registration. Ordering comes from a gate, never a sleep.
final class ExtensionLidReleaseTests: XCTestCase {

    private final class OverrideRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [Bool] = []
        var calls: [Bool] { lock.lock(); defer { lock.unlock() }; return _calls }
        func record(_ on: Bool) { lock.lock(); _calls.append(on); lock.unlock() }
    }

    /// Holds a chain op until opened.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private var savedOverride: (@Sendable (Bool) async -> Bool)?
    private var recorder = OverrideRecorder()
    private var ids: [String] = []

    override func setUp() {
        super.setUp()
        savedOverride = LidSleepHelper.applyExtensionOverride
        let rec = OverrideRecorder()
        recorder = rec
        LidSleepHelper.applyExtensionOverride = { on in rec.record(on); return true }
    }

    override func tearDown() async throws {
        await drainApplyChain()
        for id in ids { ExtensionResources.shared.releaseAll(extID: id) }
        if let savedOverride { LidSleepHelper.applyExtensionOverride = savedOverride }
        try await super.tearDown()
    }

    private func newID(_ name: String) -> String {
        let id = "com.test.lid1549.\(name).\(UUID().uuidString)"
        ids.append(id)
        return id
    }

    private func host() -> LiveExtensionHostServices {
        LiveExtensionHostServices(defaults: scratchDefaults("lid1549"))
    }

    /// Every op queued so far has run (the chain is serial).
    private func drainApplyChain() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            LidSleepHelper.enqueueApply { c.resume() }
        }
    }

    func testApplyQueuedBeforeTeardownAndConfirmedAfterIsReleased() async {
        let id = newID("queued"), services = host(), gate = Gate()
        // As __h_caf_lidsleep does: the set(true) goes on the chain; the gate keeps it unconfirmed until after the teardown.
        LidSleepHelper.enqueueApply {
            await gate.wait()
            await services.caffeinateSetDisableLidSleep(extensionID: id, on: true)
        }
        XCTAssertFalse(ExtensionResources.shared.holdsLidSleepDisabled(extID: id), "the apply confirmed before the teardown")
        services.resetResources(extensionID: id)
        await gate.open()
        await drainApplyChain()
        XCTAssertEqual(recorder.calls, [true, false], "the late-confirmed hold was not released after it landed")
        XCTAssertFalse(ExtensionResources.shared.holdsLidSleepDisabled(extID: id))
    }

    func testConfirmedHoldIsReleasedOnTeardown() async {
        let id = newID("confirmed"), services = host()
        await services.caffeinateSetDisableLidSleep(extensionID: id, on: true)
        XCTAssertTrue(ExtensionResources.shared.holdsLidSleepDisabled(extID: id))
        services.resetResources(extensionID: id)
        await drainApplyChain()
        XCTAssertEqual(recorder.calls, [true, false])
        XCTAssertFalse(ExtensionResources.shared.holdsLidSleepDisabled(extID: id))
    }

    func testPlainDisableWithNothingInFlightReleasesNothing() async {
        let id = newID("plain"), services = host()
        // The extension took and dropped its own hold; nothing is queued when it is disabled.
        await services.caffeinateSetDisableLidSleep(extensionID: id, on: true)
        await services.caffeinateSetDisableLidSleep(extensionID: id, on: false)
        services.resetResources(extensionID: id)
        await drainApplyChain()
        XCTAssertEqual(recorder.calls, [true, false], "a disable with no hold and nothing in flight released the override")
    }

    func testExtensionThatNeverHeldTheFlagReleasesNothing() async {
        let other = newID("holder"), id = newID("never"), services = host()
        await services.caffeinateSetDisableLidSleep(extensionID: other, on: true)
        services.resetResources(extensionID: id)
        await drainApplyChain()
        XCTAssertEqual(recorder.calls, [true], "tearing down an extension that never held the flag released another's hold")
        XCTAssertTrue(ExtensionResources.shared.holdsLidSleepDisabled(extID: other))
    }
}

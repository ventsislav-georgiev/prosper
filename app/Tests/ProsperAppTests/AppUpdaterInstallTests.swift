import XCTest
@testable import ProsperApp

/// #1871 updates.install: AppUpdater.installNow through the SparkleCalls seam (no SPUUpdater exists under XCTest, no
/// network). A fake probe feeds Sparkle's cycle callbacks synchronously, as the channel delegate would.
@MainActor
final class AppUpdaterInstallTests: XCTestCase {
    private final class Calls {
        var probes = 0
        var installs: [Bool] = []   // driver.userInitiated at each install call
    }

    /// An AppUpdater whose Sparkle answers `events` to each probe (nil: the probe never ends on its own).
    private func updater(_ calls: Calls, canCheck: Bool = true, events: [AppUpdater.ProbeEvent]? = [.found("9.9.9")]) -> AppUpdater {
        let u = AppUpdater()
        u.sparkle = AppUpdater.SparkleCalls(
            canCheck: { canCheck },
            probe: { [weak u] in
                calls.probes += 1
                guard let u, let events else { return }
                events.forEach { u.probeEvent($0) }
                u.probeEvent(nil)
            },
            install: { [weak u] in calls.installs.append(u?.driver.userInitiated ?? true) })
        return u
    }

    func testOffWhenNoSparkle() async {
        let u = AppUpdater()
        XCTAssertTrue(u.sparkle == nil, "no updater under XCTest")
        let r = await u.installNow()
        XCTAssertEqual(r, .off)
    }

    func testBusyWhileSparkleCannotCheck() async {
        let calls = Calls(), u = updater(calls, canCheck: false)
        let r = await u.installNow()
        XCTAssertEqual(r, .busy)
        XCTAssertEqual(calls.probes, 0)
        XCTAssertEqual(calls.installs.count, 0)
    }

    func testBusyWhileADownloadRuns() async {
        let calls = Calls(), u = updater(calls)
        u.driver.onDownloadingChanged?(true)
        let r = await u.installNow()
        XCTAssertEqual(r, .busy)
        XCTAssertEqual(calls.probes, 0)
    }

    func testBusyWhileAnUpdatesCheckProbeRuns() async {
        let calls = Calls(), u = updater(calls, events: nil)
        let check = Task { await u.probeForUpdate() }
        for _ in 0..<100 where calls.probes == 0 { await Task.yield() }
        XCTAssertEqual(calls.probes, 1, "the updates.check probe is running")
        u.sparkle?.probe = { [weak u] in calls.probes += 1; u?.probeEvent(.found("9.9.9")); u?.probeEvent(nil) } // no hang if it gets through
        let r = await u.installNow()
        XCTAssertEqual(r, .busy)
        XCTAssertEqual(calls.probes, 1)
        guard r == .busy else { check.cancel(); return } // the check's continuation was overwritten: never awaited
        u.probeEvent(.notFound)
        u.probeEvent(nil)
        let p = await check.value
        XCTAssertEqual(p, .upToDate)
        XCTAssertEqual(calls.installs.count, 0, "an updates.check probe never installs")
    }

    /// A found update starts the silent install once, inside the probe's cycle end, never user-initiated (no UI, no
    /// notices) even right after a menu check left the flag set.
    func testFoundStartsTheSilentInstallOnce() async {
        let calls = Calls(), u = updater(calls)
        u.driver.userInitiated = true
        let r = await u.installNow()
        XCTAssertEqual(r, .started("9.9.9"))
        XCTAssertEqual(calls.probes, 1)
        XCTAssertEqual(calls.installs, [false])
    }

    func testUpToDateAndFailedInstallNothing() async {
        let calls = Calls()
        var r = await updater(calls, events: [.notFound]).installNow()
        XCTAssertEqual(r, .upToDate)
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                              userInfo: [NSLocalizedDescriptionKey: "offline"])
        r = await updater(calls, events: [.aborted(offline)]).installNow()
        XCTAssertEqual(r, .failed("offline"))
        XCTAssertEqual(calls.installs.count, 0)
    }

    /// updates.check's probe finding an update stays information only, also right after an install probe.
    func testAPlainProbeThatFindsNeverInstalls() async {
        let calls = Calls(), u = updater(calls)
        let p = await u.probeForUpdate()
        XCTAssertEqual(p, .found("9.9.9"))
        XCTAssertEqual(calls.installs.count, 0)
        _ = await u.installNow()
        _ = await u.probeForUpdate()
        XCTAssertEqual(calls.installs.count, 1)
    }

    /// An install probe that found nothing leaves no install armed for the next updates.check that finds one.
    func testAnUpToDateInstallLeavesTheNextCheckInformationOnly() async {
        let calls = Calls(), u = updater(calls, events: [.notFound])
        let r = await u.installNow()
        XCTAssertEqual(r, .upToDate)
        u.sparkle?.probe = { [weak u] in u?.probeEvent(.found("9.9.9")); u?.probeEvent(nil) }
        let p = await u.probeForUpdate()
        XCTAssertEqual(p, .found("9.9.9"))
        XCTAssertEqual(calls.installs.count, 0)
    }

    // MARK: - the background-staged update installs now (willInstallUpdateOnQuit)

    func testStagedUpdateInstallsAtOnceWhenClean() {
        let d = SilentUserDriver()
        d.dirtyViewers = TextViewerDirty()
        var installs = 0
        d.installOnQuit { installs += 1 }
        XCTAssertEqual(installs, 1)
    }

    func testStagedUpdateWaitsForAnUnsavedTextViewerFile() {
        let dirty = TextViewerDirty(), a = NSObject()
        let d = SilentUserDriver()
        d.dirtyViewers = dirty
        dirty.report(a, dirty: true)
        var installs = 0
        d.installOnQuit { installs += 1 }
        XCTAssertEqual(installs, 0, "held while a file is dirty")
        dirty.report(a, dirty: false)
        XCTAssertEqual(installs, 1)
    }

    /// The channel delegate takes the staged update (YES) only when AppUpdater wired the hook.
    func testTheDelegateTakesTheStagedUpdateOnlyWhenWired() {
        let del = UpdaterChannelDelegate()
        var taken = 0
        XCTAssertFalse(del.takeStagedUpdate {})
        del.onInstallOnQuit = { install in taken += 1; install() }
        var ran = 0
        XCTAssertTrue(del.takeStagedUpdate { ran += 1 })
        XCTAssertEqual(taken, 1)
        XCTAssertEqual(ran, 1)
    }
}

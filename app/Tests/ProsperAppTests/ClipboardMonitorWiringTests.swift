import AppKit
import XCTest
@testable import ProsperApp

/// #1292 (QA #42, #51): the glue between the monitor and the screen gate. The two notification
/// centers are private ones the test posts on (nothing reaches the real workspace or distributed
/// center), the pasteboard is the XCTest-private `Pasteboard.general`, and no history store is written.
@MainActor
final class ClipboardMonitorWiringTests: XCTestCase {
    private final class Events { var payloads: [String] = [] }

    private let workspace = NotificationCenter()
    private let distributed = NotificationCenter()
    private var monitors: [ClipboardMonitor] = []

    override func tearDown() {
        monitors.forEach { $0.stop() }
        monitors = []
        super.tearDown()
    }

    private func make(_ events: Events) -> ClipboardMonitor {
        let m = ClipboardMonitor(workspaceCenter: workspace, distributedCenter: distributed)
        m.captureHistory = false
        m.emitChange = { events.payloads.append($0) }
        monitors.append(m)
        return m
    }

    /// The observers hop to the main queue; pump it. Shorter than the monitor's 1 s timer, so only
    /// a poll made by the notification handler itself can show up.
    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }

    private func post(_ name: Notification.Name, on center: NotificationCenter) {
        center.post(name: name, object: nil)
        settle()
    }

    private let lock = Notification.Name("com.apple.screenIsLocked")
    private let unlock = Notification.Name("com.apple.screenIsUnlocked")

    private func copySomething() {
        Pasteboard.general.clearContents()
        Pasteboard.general.setString("example text \(UUID().uuidString)", forType: .string)
    }

    /// QA #51: lock and unlock are read on the distributed center, sleep and wake on the workspace
    /// one, and not the other way round.
    func testEachEventIsObservedOnItsOwnCenter() {
        let m = make(Events())
        post(lock, on: workspace)
        XCTAssertFalse(m.screen.screenLocked, "lock is not a workspace notification")
        post(NSWorkspace.screensDidSleepNotification, on: distributed)
        XCTAssertFalse(m.screen.displayAsleep, "sleep is not a distributed notification")

        post(lock, on: distributed)
        XCTAssertTrue(m.screen.screenLocked)
        post(NSWorkspace.screensDidSleepNotification, on: workspace)
        XCTAssertTrue(m.screen.displayAsleep)
        post(unlock, on: distributed)
        XCTAssertFalse(m.screen.screenLocked)
        post(NSWorkspace.screensDidWakeNotification, on: workspace)
        XCTAssertFalse(m.screen.displayAsleep)
    }

    /// QA #42, `hidden:`: a started monitor on a visible screen has its timer, a hidden one has none.
    func testTimerFollowsTheScreen() {
        let m = make(Events())
        m.start()
        XCTAssertTrue(m.timer != nil, "visible screen: timer scheduled")
        post(lock, on: distributed)
        XCTAssertTrue(m.timer == nil, "locked: timer torn down")
        post(unlock, on: distributed)
        XCTAssertTrue(m.timer != nil, "unlocked: timer back")
        post(NSWorkspace.screensDidSleepNotification, on: workspace)
        XCTAssertTrue(m.timer == nil, "display asleep: timer torn down")
        m.stop()
        XCTAssertTrue(m.timer == nil)
    }

    /// QA #42, the resume `poll()`: a copy made while the screen was hidden is reported at once on
    /// unlock, without waiting for the first timer tick.
    func testResumePollsAtOnce() {
        let events = Events()
        let m = make(events)
        m.start()
        post(lock, on: distributed)
        copySomething()
        settle()
        XCTAssertTrue(events.payloads.isEmpty, "hidden: nothing polls")
        post(unlock, on: distributed)
        XCTAssertEqual(events.payloads.count, 1, "resume polled before any timer tick")
        XCTAssertTrue(events.payloads.first?.contains("\"kind\":\"text\"") ?? false, "\(events.payloads)")
    }

    /// QA #42, `timerActive:`: a second pause decision while the timer lives neither polls nor
    /// replaces the timer.
    func testLiveTimerIsNotDoubled() {
        let events = Events()
        let m = make(events)
        m.start()
        let first = m.timer
        XCTAssertTrue(first != nil)
        copySomething()
        m.applyPause()
        settle()
        XCTAssertTrue(m.timer === first, "same timer")
        XCTAssertTrue(events.payloads.isEmpty, "no poll on .none")
    }
}

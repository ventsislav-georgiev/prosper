import XCTest
@testable import ProsperApp

/// #228: the clipboard poll timer's pause decision (#194), driven through the same
/// `ScreenGate` events the monitor observes.
@MainActor
final class ClipboardMonitorPauseTests: XCTestCase {
    private func action(_ running: Bool, _ gate: ScreenGate, timer: Bool) -> ClipboardMonitor.PauseAction {
        ClipboardMonitor.pauseAction(isRunning: running, hidden: gate.hidden, timerActive: timer)
    }

    /// (c) display sleep or screen lock tears the timer down.
    func testPausesOnSleepAndLock() {
        for e in [ScreenGate.Event.sleep, .lock] {
            var g = ScreenGate()
            g.apply(e)
            XCTAssertEqual(action(true, g, timer: true), .pause, "\(e) must stop the poll timer")
        }
        XCTAssertEqual(action(false, ScreenGate(), timer: true), .pause, "stopped monitor keeps no timer")
    }

    /// (d) lock, sleep, wake, unlock in any order resumes exactly once, on the last
    /// clearing event, and never doubles a live timer.
    func testResumesOnceAfterWakeAndUnlock() {
        var g = ScreenGate()
        var timer = true
        var resumes = 0
        for e in [ScreenGate.Event.lock, .sleep, .wake, .unlock, .wake, .unlock] {
            g.apply(e)
            switch action(true, g, timer: timer) {
            case .pause: timer = false
            case .resume: timer = true; resumes += 1
            case .none: break
            }
        }
        XCTAssertEqual(resumes, 1, "resume (poll + new timer) must happen once, after both flags clear")
        XCTAssertTrue(timer)
        XCTAssertEqual(action(true, ScreenGate(), timer: true), .none, "a live timer must not be doubled")
    }

    /// (e) start() on a visible screen polls at once; started while hidden it waits.
    func testStartPollsImmediatelyWhenVisible() {
        XCTAssertEqual(action(true, ScreenGate(), timer: false), .resume)
        var locked = ScreenGate()
        locked.apply(.lock)
        XCTAssertEqual(action(true, locked, timer: false), .pause)
    }
}

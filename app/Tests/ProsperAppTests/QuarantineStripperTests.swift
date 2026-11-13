import XCTest
@testable import ProsperApp

final class QuarantineStripperTests: XCTestCase {
    /// launchd refuses a quarantined daemon plist, so the probe must reach the
    /// nested helper plist and binary, not just the bundle root.
    func testPathsToCheckCoverNestedHelperFiles() {
        let paths = QuarantineStripper.pathsToCheck(bundlePath: "/Applications/Prosper.app")
        XCTAssertEqual(paths, [
            "/Applications/Prosper.app",
            "/Applications/Prosper.app/Contents/Library/LaunchDaemons/eu.illegible.prosper.helper.plist",
            "/Applications/Prosper.app/Contents/MacOS/ProsperHelper",
        ])
    }

    func testLaunchFailureIsAFailedOutcome() {
        let r = QuarantineStripper.run(["/nonexistent/xattr"], timeout: 5)
        guard case .failed(let why) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(why.hasPrefix("launch:"), why)
        XCTAssertFalse(r.isClean)
    }

    func testNonZeroExitIsAFailedOutcome() {
        XCTAssertEqual(QuarantineStripper.run(["/usr/bin/false"], timeout: 5), .failed("exit 1"))
    }

    /// A hung xattr must not wedge registerLock: the run is terminated at the bound.
    /// The child is recorded at launch and SIGKILLed by its own pid on every path, so a
    /// failing run leaves no 30 s sleep behind (#1003, QA #52).
    func testHungProcessIsTerminatedAtTimeout() {
        let start = Date()
        var child: Process?
        defer { if let child, child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        XCTAssertEqual(QuarantineStripper.run(["/bin/sleep", "30"], timeout: 0.3, launched: { child = $0 }), .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        guard let proc = child else { return XCTFail("run never reported its child") }
        // The child must actually be gone, not orphaned still sleeping. A poll with a ceiling:
        // SIGTERM lands at once, and Foundation reaps it on its own queue.
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning, Date() < deadline { usleep(20_000) }
        XCTAssertFalse(proc.isRunning, "hung child survived the timeout")
        guard !proc.isRunning else { return }   // terminationReason raises on a live process
        XCTAssertEqual(proc.terminationReason, .uncaughtSignal)
        XCTAssertEqual(proc.terminationStatus, SIGTERM)
    }

    func testOnlyNotNeededAndStrippedAreClean() {
        XCTAssertTrue(QuarantineStripper.Outcome.notNeeded.isClean)
        XCTAssertTrue(QuarantineStripper.Outcome.stripped.isClean)
        XCTAssertFalse(QuarantineStripper.Outcome.timedOut.isClean)
        XCTAssertFalse(QuarantineStripper.Outcome.failed("x").isClean)
    }

    func testStripsQuarantineFromAScratchFile() throws {
        let url = tempDir("qs").appendingPathComponent("x")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let attr = QuarantineStripper.attribute
        XCTAssertEqual(QuarantineStripper.run(["/usr/bin/xattr", "-w", attr, "0081;00000000;Test;", url.path], timeout: 5), .stripped)
        XCTAssertGreaterThanOrEqual(getxattr(url.path, attr, nil, 0, 0, 0), 0)
        XCTAssertEqual(QuarantineStripper.run(["/usr/bin/xattr", "-dr", attr, url.path], timeout: 5), .stripped)
        XCTAssertLessThan(getxattr(url.path, attr, nil, 0, 0, 0), 0)
    }
}

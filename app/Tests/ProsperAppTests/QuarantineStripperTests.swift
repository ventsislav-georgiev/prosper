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
    func testHungProcessIsTerminatedAtTimeout() {
        let start = Date()
        // Unique duration so pgrep matches only this test's child.
        let marker = "30.\(Int.random(in: 100_000...999_999))"
        XCTAssertEqual(QuarantineStripper.run(["/bin/sleep", marker], timeout: 0.3), .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        // The child must actually be gone, not orphaned still sleeping.
        var alive = true
        for _ in 0..<20 where alive {
            let pg = Process()
            pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pg.arguments = ["-f", "^/bin/sleep \(marker)$"]
            try? pg.run()
            pg.waitUntilExit()
            alive = pg.terminationStatus == 0
            if alive { usleep(100_000) }
        }
        XCTAssertFalse(alive, "hung child survived the timeout")
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

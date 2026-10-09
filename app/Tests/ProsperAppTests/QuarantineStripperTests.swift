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
}

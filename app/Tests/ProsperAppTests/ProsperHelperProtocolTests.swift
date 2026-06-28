import XCTest
import ProsperHelperProtocol

/// The privileged daemon's pmset call + XPC plumbing can only run as root under
/// launchd, so it isn't exercised here. What we CAN pin down cheaply is the shared
/// contract both executables compile against — a drift in these identifiers would
/// silently break the XPC connection (the app would talk to a Mach service the
/// daemon never vends). bundle.sh hardcodes the same strings into the LaunchDaemon
/// plist, so this guards that they stay in lockstep.
final class ProsperHelperProtocolTests: XCTestCase {
    func testSharedIdentifiersMatchBundledPlist() {
        XCTAssertEqual(helperLabel, "eu.illegible.prosper.helper")
        XCTAssertEqual(helperMachServiceName, "eu.illegible.prosper.helper")
        // Label == Mach service name is a deliberate convention (see plist).
        XCTAssertEqual(helperLabel, helperMachServiceName)
        // Legacy label retired but still pinned for the one-time unregister migration.
        XCTAssertEqual(legacyHelperLabel, "eu.illegible.prosper.lidhelper")
        XCTAssertNotEqual(legacyHelperLabel, helperLabel)
    }
}

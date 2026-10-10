import XCTest
@testable import ProsperApp

final class PerfSignpostTests: XCTestCase {
    /// The operator's verify predicate is `subsystem == "eu.illegible.prosper"`.
    func testSubsystemAndCategoryArePinned() {
        XCTAssertEqual(Perf.subsystem, "eu.illegible.prosper")
        XCTAssertEqual(Perf.category, "perf")
    }

    func testBeginEndAndEventDoNotTrap() {
        let state = Perf.signposter.beginInterval("test.interval", id: Perf.signposter.makeSignpostID())
        Perf.signposter.emitEvent("test.event")
        Perf.signposter.endInterval("test.interval", state)
    }
}

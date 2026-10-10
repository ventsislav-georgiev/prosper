import XCTest
@testable import ProsperApp

/// #258: selectPrev/selectNext publish on a later main-queue turn and wrap.
@MainActor
final class RunnerSelectionTests: XCTestCase {
    private func step(from i: Int, by s: Int, count n: Int) -> (sync: Int, after: Int) {
        let model = RunnerModel()
        model.selectedIndex = i
        model.scheduleSelect(step: s) { n }
        let sync = model.selectedIndex
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return (sync, model.selectedIndex)
    }

    func testRunnerSelectPrevWrapsFromFirstAfterHop() {
        let r = step(from: 0, by: -1, count: 4)
        XCTAssertEqual(r.sync, 0, "must not publish synchronously")
        XCTAssertEqual(r.after, 3)
    }

    func testRunnerSelectNextWrapsFromLastAfterHop() {
        let r = step(from: 3, by: 1, count: 4)
        XCTAssertEqual(r.sync, 3, "must not publish synchronously")
        XCTAssertEqual(r.after, 0)
    }
}

import XCTest
@testable import ProsperApp

/// #234: owningApps unions item owners across every active display.
final class MenuBarSpacingTests: XCTestCase {
    func testUnionKeepsDisplayOrderAndDeduplicates() {
        XCTAssertEqual(MenuBarSpacing.union([[3, 1, 3], [2, 1, 4]]), [3, 1, 2, 4])
    }

    func testUnionSingleDisplayIsThatDisplaysOwners() {
        XCTAssertEqual(MenuBarSpacing.union([[5, 7]]), [5, 7])
        XCTAssertEqual(MenuBarSpacing.union([]), [])
    }
}

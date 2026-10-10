import XCTest
@testable import ProsperApp

/// #333: extension status items need a stable autosaveName, else macOS keys their
/// position by creation order ("Item-N") and the icon drifts between launches.
final class ExtensionMenuBarAutosaveTests: XCTestCase {

    func testTwoItemsOfOneExtensionGetDistinctNames() {
        let a = ExtensionMenuBar.autosaveName(extensionID: "openlid", id: "main")
        let b = ExtensionMenuBar.autosaveName(extensionID: "openlid", id: "status")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, "ProsperExt:openlid:main")
        XCTAssertEqual(b, "ProsperExt:openlid:status")
    }

    func testSamePairGivesSameNameAcrossCalls() {
        XCTAssertEqual(ExtensionMenuBar.autosaveName(extensionID: "com.x.ext", id: "i-1"),
                       ExtensionMenuBar.autosaveName(extensionID: "com.x.ext", id: "i-1"))
    }

    func testSpacesSlashesAndNonASCIIAreSanitized() {
        XCTAssertEqual(ExtensionMenuBar.autosaveName(extensionID: "my ext/v2", id: "a b/é"),
                       "ProsperExt:my_ext_v2:a_b__")
    }
}

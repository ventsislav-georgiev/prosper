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

    func testColonInsidePartsCannotShiftTheSplit() {
        let a = ExtensionMenuBar.autosaveName(extensionID: "a:b", id: "c")
        let b = ExtensionMenuBar.autosaveName(extensionID: "a", id: "b:c")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, "ProsperExt:a%3Ab:c")
        XCTAssertEqual(b, "ProsperExt:a:b%3Ac")
    }

    func testSamePairGivesSameNameAcrossCalls() {
        XCTAssertEqual(ExtensionMenuBar.autosaveName(extensionID: "com.x.ext", id: "i-1"),
                       ExtensionMenuBar.autosaveName(extensionID: "com.x.ext", id: "i-1"))
    }

    func testSpacesSlashesAndNonASCIIAreSanitized() {
        XCTAssertEqual(ExtensionMenuBar.autosaveName(extensionID: "my ext/v2", id: "a b/é"),
                       "ProsperExt:my%20ext%2Fv2:a%20b%2F%C3%A9")
    }
}

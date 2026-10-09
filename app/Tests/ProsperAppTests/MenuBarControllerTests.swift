import XCTest

@testable import ProsperApp

final class MenuBarControllerTests: XCTestCase {
    private let pos = "NSStatusItem Preferred Position "
    private let vis = "NSStatusItem Visible "

    private func suite() -> UserDefaults {
        let name = "MenuBarControllerTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return d
    }

    func testCarriesPositionAndVisibilityWhenNewKeyAbsent() {
        let d = suite()
        d.set(1234.0, forKey: pos + "Item-0")
        d.set(false, forKey: vis + "Item-0")
        MenuBarController.carryAutosave(from: "Item-0", to: "ProsperLauncher", in: d)
        XCTAssertEqual(d.double(forKey: pos + "ProsperLauncher"), 1234.0)
        XCTAssertEqual(d.object(forKey: vis + "ProsperLauncher") as? Bool, false)
    }

    func testKeepsExistingNewKeys() {
        let d = suite()
        d.set(1234.0, forKey: pos + "Item-0")
        d.set(false, forKey: vis + "Item-0")
        d.set(99.0, forKey: pos + "ProsperLauncher")
        d.set(true, forKey: vis + "ProsperLauncher")
        MenuBarController.carryAutosave(from: "Item-0", to: "ProsperLauncher", in: d)
        XCTAssertEqual(d.double(forKey: pos + "ProsperLauncher"), 99.0)
        XCTAssertEqual(d.object(forKey: vis + "ProsperLauncher") as? Bool, true)
    }

    func testNoOldValueWritesNothing() {
        let d = suite()
        MenuBarController.carryAutosave(from: "Item-0", to: "ProsperLauncher", in: d)
        XCTAssertNil(d.object(forKey: pos + "ProsperLauncher"))
        XCTAssertNil(d.object(forKey: vis + "ProsperLauncher"))
    }
}

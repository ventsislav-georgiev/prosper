import XCTest
@testable import ProsperApp

/// #232: Bypass (danger-full-access) is a per-device trust call — it must neither
/// leave this Mac in a sync payload nor arrive from one.
final class AgentBypassPerDeviceTests: XCTestCase {
    private let keys = ["agentBypassAll", "agentBypassLocal", "agentTopP"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        for k in keys { if let v = UserDefaults.standard.object(forKey: k) { saved[k] = v } }
    }

    override func tearDown() {
        for k in keys { UserDefaults.standard.set(saved[k], forKey: k) }
    }

    func testBypassIsNotSyncedButHooksAre() {
        XCTAssertFalse(SyncedKeys.isSynced("agentBypassAll"))
        XCTAssertFalse(SyncedKeys.isSynced("agentWritableRoots"))
        XCTAssertFalse(SyncedKeys.isSynced("agentBypassLocal"), "the reset marker is per device too")
        XCTAssertTrue(SyncedKeys.isSynced("agentHooks"))
    }

    func testIncomingPayloadCannotTurnBypassOn() throws {
        UserDefaults.standard.set(false, forKey: "agentBypassAll")
        UserDefaults.standard.set(0.42, forKey: "agentTopP")
        let defaults = try PropertyListSerialization.data(
            fromPropertyList: ["agentBypassAll": true, "agentTopP": 0.5], format: .binary, options: 0)
        let root = try PropertyListSerialization.data(
            fromPropertyList: ["schema": 1, "defaults": defaults], format: .binary, options: 0)
        SyncSnapshotBuilder.apply(try XCTUnwrap(root.prosperCompressed()))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "agentBypassAll"))
        XCTAssertEqual(UserDefaults.standard.double(forKey: "agentTopP"), 0.5)   // synced keys still apply
    }

    func testBypassResetsOnceThenHoldsTheUsersChoice() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "agentBypassLocal")
        d.set(true, forKey: "agentBypassAll")             // carried in by a pre-#232 sync
        XCTAssertFalse(Preferences.agentBypassAll)
        XCTAssertFalse(d.bool(forKey: "agentBypassAll"))
        Preferences.agentBypassAll = true                 // the user turns it on, on this Mac
        XCTAssertTrue(Preferences.agentBypassAll)
        XCTAssertTrue(Preferences.agentBypassAll)
    }
}

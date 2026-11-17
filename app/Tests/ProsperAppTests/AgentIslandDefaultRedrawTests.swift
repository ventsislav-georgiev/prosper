import XCTest
@testable import ProsperApp

/// #1455 b: saving the Default model or Default effort reaches the open island's row details at once (scratch
/// controller with no panel, scratch XCTestDefaults; no Settings window).
final class AgentIslandDefaultRedrawTests: XCTestCase {
    private let geometry = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)

    @MainActor
    private func withIsland(_ body: (AgentIslandController, AgentIslandStore) -> Void) {
        XCTAssertTrue(Preferences.defaults is XCTestDefaults, "the scratch in-memory suite, never the app's")
        let keys = ["agentIslandDefaultModel", "agentIslandDefaultEffort"]
        let saved = keys.map { Preferences.defaults.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { Preferences.defaults.set(v, forKey: k) } }
        Preferences.defaults.set(nil, forKey: keys[0]); Preferences.defaults.set(nil, forKey: keys[1])
        let c = AgentIslandController()
        c.showsPanel = false
        let store = AgentIslandStore(geometry: geometry)
        c.store = store
        body(c, store)
    }

    @MainActor
    func testSavedDefaultModelReachesTheStoreAtOnceAndARefusedOneLeavesIt() {
        withIsland { c, store in
            XCTAssertEqual(store.details.defaultModel, "")
            XCTAssertTrue(AgentIslandPane.commitModel(" opus\n", c) == nil)
            XCTAssertEqual(store.details.defaultModel, "opus")
            XCTAssertTrue(AgentIslandPane.commitModel("op us", c) != nil)
            XCTAssertEqual(store.details.defaultModel, "opus", "refused: nothing redrawn")
            XCTAssertTrue(AgentIslandPane.commitModel("  ", c) == nil)
            XCTAssertEqual(store.details.defaultModel, "", "cleared reaches the store too")
        }
    }

    @MainActor
    func testSavedDefaultEffortReachesTheStoreAtOnceAndOneOutsideTheLevelsLeavesIt() {
        withIsland { c, store in
            XCTAssertEqual(store.details.defaultEffort, "")
            AgentIslandPane.commitEffort("high", c)
            XCTAssertEqual(store.details.defaultEffort, "high")
            AgentIslandPane.commitEffort("ultra", c)
            XCTAssertEqual(store.details.defaultEffort, "high", "outside the levels: nothing redrawn")
            AgentIslandPane.commitEffort("", c)
            XCTAssertEqual(store.details.defaultEffort, "", "cleared reaches the store too")
        }
    }
}

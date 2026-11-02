import Foundation
import XCTest

/// #710: tests that are slow, memory-heavy or wall-clock sensitive run only with
/// `PROSPER_HEAVY_TESTS=1` in the environment of `swift test`. CI sets it, but its --skip
/// regex (#172) still leaves out the timing budgets, so only the Codex mock rows, the 17 MB
/// framer line and the ping rows gate a merge there; the budgets run in QA's heavy suites.
/// A local run skips them all unless a change touches their area:
/// - agent harness / Codex controller (`CodexHarness`, `AgentController`, `JSONLProtocol`):
///   every CodexHarnessE2ETests row that spawns the python mock app-server (via `makeMock`),
///   HarnessProtocolTests.testFramerDropsOverCapLineAndKeepsReading (a 17 MB line).
/// - autocomplete / runner / window-snap hot paths: AutocompleteHotPathBudgetTests,
///   AutocompleteReconcileTests.testReconcilePerformanceBudget, FallbackSearchTests' two
///   HotPathBudget rows, DragSnapTests.testHotPathBudget.
/// - extension / marketplace / bookmarks / analytics hot paths: ExtensionInstallTests.testRoutePerformance,
///   MarketplaceBrowseModelTests.testInstalledMembershipRenderBudget,
///   BookmarksExtensionTests.testSearchHotPathBudget,
///   AnalyticsSnapshotTests.testBuildScalesLinearlyWithExtensionCount.
/// - lid helper / remote wake cores: LidHelperCoreTests.testTransitionThroughputUnderBudget,
///   RemoteWakeCorePerfTests.
/// - stats popup ping thread (`StatsPoller`, `NetPingReader`): StatsPopupGateTests' two ping rows.
/// Run one area: `PROSPER_HEAVY_TESTS=1 swift test --filter <Class>`.
func requireHeavyTests() throws {
    guard ProcessInfo.processInfo.environment["PROSPER_HEAVY_TESTS"] == "1" else {
        throw XCTSkip("heavy: set PROSPER_HEAVY_TESTS=1")
    }
}

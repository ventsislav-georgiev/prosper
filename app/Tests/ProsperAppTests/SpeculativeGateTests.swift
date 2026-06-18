import XCTest

@testable import ProsperApp

/// Tests the pure path-selection gate (WS2) that decides whether the inline entry
/// point runs the speculative-decoding path or the proven single-model path. The
/// real GPU decode is not unit-testable here (needs a loaded model + Metal); this
/// covers only the eligibility logic, which is the part that must never silently
/// route to speculative when the draft is absent.
final class SpeculativeGateTests: XCTestCase {

    private func gate(_ enabled: Bool, _ draftLoaded: Bool) -> Bool {
        MLXEngine.shouldUseSpeculative(enabled: enabled, draftLoaded: draftLoaded)
    }

    // Feature on AND draft resident: the only case that takes the speculative path.
    func testEnabledAndLoadedUsesSpeculative() {
        XCTAssertTrue(gate(true, true))
    }

    // Feature on but draft not loaded yet (still downloading / load failed): must
    // stay on the single-model path — never route to a missing draft.
    func testEnabledButNotLoadedFallsBack() {
        XCTAssertFalse(gate(true, false))
    }

    // Feature off: the shipped default. Draft presence is irrelevant.
    func testDisabledNeverSpeculatesEvenWhenLoaded() {
        XCTAssertFalse(gate(false, true))
    }

    func testDisabledAndNotLoadedFallsBack() {
        XCTAssertFalse(gate(false, false))
    }
}

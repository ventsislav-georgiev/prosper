import MLXLLM
import XCTest
@testable import ProsperApp

/// Covers the model-picker catalog invariants, including the 12B/26B-A4B QAT rows
/// re-enabled once mlx-swift-lm 3.32.3 registered gemma4_unified and the MoE text path.
final class ModelSelectionTests: XCTestCase {
    private let key = "coreModel"
    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = Preferences.defaults.string(forKey: key)
    }
    override func tearDown() {
        if let saved { Preferences.defaults.set(saved, forKey: key) }
        else { Preferences.defaults.removeObject(forKey: key) }
        super.tearDown()
    }

    func testFullSizeQATModelsAreSelectable() {
        let full = [Preferences.qat12B4Id, Preferences.qat12B6Id, Preferences.qat12B8Id,
                    Preferences.qat26B4Id, Preferences.qat26B6Id, Preferences.qat26B8Id]
        let offered = AIModelSection.models.map(\.0)
        for id in full {
            XCTAssertTrue(Preferences.selectableModelIds.contains(id), "\(id) not selectable")
            XCTAssertTrue(offered.contains(id), "\(id) not in the picker")
            // A stored selection is returned as-is, no longer healed to the recommended model.
            Preferences.defaults.set(id, forKey: key)
            XCTAssertEqual(Preferences.coreModel, id)
        }
    }

    /// The 12B ships `model_type: gemma4_unified`, the 26B-A4B ships `gemma4` with an MoE
    /// text_config. Both must stay registered on the LLM path MLXEngine loads through, or the
    /// rows above go back to failing at load (they were hidden on mlx-swift-lm 3.31.3).
    func testLLMRegistryKnowsFullSizeGemma4Types() async {
        for type in ["gemma4_unified", "gemma4"] {
            let known = await LLMTypeRegistry.shared.contains(type)
            XCTAssertTrue(known, "\(type) not registered in LLMTypeRegistry")
        }
    }

    func testPickerOnlyOffersSelectableModels() {
        let selectable = Set(Preferences.selectableModelIds)
        for (id, _) in AIModelSection.models {
            XCTAssertTrue(selectable.contains(id), "picker offers \(id) not in selectableModelIds")
        }
        XCTAssertEqual(AIModelSection.models.map(\.0), Preferences.selectableModelIds)
    }

    func testRecommendedIsSelectable() {
        XCTAssertTrue(Preferences.selectableModelIds.contains(Preferences.recommendedModelId))
    }
}

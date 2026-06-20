import XCTest
@testable import ProsperApp

/// Covers the model-picker catalog invariants and the `coreModel` self-heal that
/// recovers a user stuck on a checkpoint the current fork can't load (the pulled
/// 12B/26B QAT models).
final class ModelSelectionTests: XCTestCase {
    private let key = "coreModel"
    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.string(forKey: key)
    }
    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    func testCoreModelSelfHealsUnsupportedSelection() {
        // A stored 12B/26B id (exists on HF, but no loader in the fork) heals to the
        // recommended model so the user isn't stuck on a model that never loads.
        for id in Preferences.unsupportedModelIds {
            UserDefaults.standard.set(id, forKey: key)
            XCTAssertEqual(Preferences.coreModel, Preferences.recommendedModelId,
                           "unsupported \(id) should heal to recommended")
        }
        // A supported selection is returned untouched.
        UserDefaults.standard.set(Preferences.qatE2B4Id, forKey: key)
        XCTAssertEqual(Preferences.coreModel, Preferences.qatE2B4Id)
    }

    func testUnsupportedDisjointFromSelectable() {
        let selectable = Set(Preferences.selectableModelIds)
        XCTAssertTrue(selectable.isDisjoint(with: Preferences.unsupportedModelIds),
                      "a model can't be both offered and unsupported")
    }

    func testPickerOnlyOffersSelectableModels() {
        let selectable = Set(Preferences.selectableModelIds)
        for (id, _) in AIModelSection.models {
            XCTAssertTrue(selectable.contains(id), "picker offers \(id) not in selectableModelIds")
        }
        XCTAssertEqual(AIModelSection.models.count, Preferences.selectableModelIds.count)
    }

    func testRecommendedIsSelectable() {
        XCTAssertTrue(Preferences.selectableModelIds.contains(Preferences.recommendedModelId))
    }
}

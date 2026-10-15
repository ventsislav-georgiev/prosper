import MLXLLM
import XCTest
@testable import ProsperApp

/// Covers the model-picker catalog invariants, including the 12B/26B-A4B QAT rows
/// re-enabled once mlx-swift-lm 3.32.3 registered gemma4_unified and the MoE text path.
@MainActor
final class ModelSelectionTests: XCTestCase {
    private let key = "coreModel"
    nonisolated(unsafe) private var saved: String?
    nonisolated(unsafe) private var savedGB = 0

    override func setUp() {
        super.setUp()
        saved = Preferences.defaults.string(forKey: key)
        savedGB = AgentModelRegistry.physicalMemoryGB
    }
    override func tearDown() {
        if let saved { Preferences.defaults.set(saved, forKey: key) }
        else { Preferences.defaults.removeObject(forKey: key) }
        Preferences.defaults.removeObject(forKey: Preferences.coreModelOverrideKey)
        AgentModelRegistry.physicalMemoryGB = savedGB
        super.tearDown()
    }

    func testFullSizeQATModelsAreSelectable() {
        AgentModelRegistry.physicalMemoryGB = 64 // every row fits, so a stored id reads as-is
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

    /// #436: the AI Models pane's Download / Use-for gate. Inline rows use the picker's RAM
    /// tier, agent rows their minRAMGB floor; ids the pane does not know fit.
    func testPaneFitsGatesInlineAndAgentRowsByRAM() {
        AgentModelRegistry.physicalMemoryGB = 8 // the default argument must read the seam
        XCTAssertFalse(AIModelsPane.fits(Preferences.qat26B8Id, role: .inline))
        XCTAssertTrue(AIModelsPane.fits(Preferences.qat26B8Id, role: .inline, physicalGB: 36))
        let agent = "unsloth/Qwen3-Coder-Next-GGUF"
        XCTAssertEqual(AgentModelRegistry.all().first { $0.id == agent }?.minRAMGB, 64)
        XCTAssertFalse(AIModelsPane.fits(agent, role: .agent))
        XCTAssertTrue(AIModelsPane.fits(agent, role: .agent, physicalGB: 64))
        XCTAssertTrue(AIModelsPane.fits("unknown/model", role: .agent, physicalGB: 8))
        XCTAssertTrue(AIModelsPane.fits("unknown/model", role: .inline, physicalGB: 8))
    }

    func testRecommendedIsSelectable() {
        XCTAssertTrue(Preferences.selectableModelIds.contains(Preferences.recommendedModelId))
    }

    // MARK: - RAM gate (#435)

    private let ids = Preferences.selectableModelIds
    /// The machines QA checks: marketed GiB → the gb the gate compares.
    private func gb(_ gib: Int) -> Int { AgentModelRegistry.physicalGB(bytes: UInt64(gib) * 1_073_741_824) }

    /// Tier per row by the ModelCatalog rule (max(8, ceil(size × 1.15) + 2), next Apple tier).
    func testRAMTiersFollowTheCatalogRule() {
        let tiers = Preferences.selectableModels.map { Preferences.ramTierGB(sizeGB: $0.gb) }
        XCTAssertEqual(tiers, [8, 8, 16, 16, 16, 16, 16, 16, 18, 24, 32, 36])
        for (row, tier) in zip(AIModelSection.models, tiers) {
            XCTAssertTrue(row.1.hasSuffix(", \(tier) GB+ RAM"), "label \(row.1) lacks its tier \(tier)")
        }
    }

    /// Which of the twelve rows fit on each Mac (rows are ordered by size, so a prefix).
    func testFitsAtEachMacRAM() {
        let expected = [8: 2, 16: 8, 18: 9, 24: 10, 32: 11, 36: 12, 48: 12, 64: 12]
        for (gib, n) in expected.sorted(by: { $0.key < $1.key }) {
            let fit = ids.filter { Preferences.modelFits($0, physicalGB: gb(gib)) }
            XCTAssertEqual(fit, Array(ids.prefix(n)), "\(gib) GB Mac")
        }
    }

    /// QA #248: every row is enabled on a Mac of its labelled tier and disabled on the tier below.
    func testLabelledTierIsTheGate() {
        let apple = [8, 16, 18, 24, 32, 36, 48, 64]
        for row in Preferences.selectableModels {
            let tier = Preferences.ramTierGB(sizeGB: row.gb)
            XCTAssertTrue(Preferences.modelFits(row.id, physicalGB: gb(tier)), "\(row.id) off on a \(tier) GB Mac")
            if let below = apple.last(where: { $0 < tier }) {
                XCTAssertFalse(Preferences.modelFits(row.id, physicalGB: gb(below)), "\(row.id) on at \(below) GB")
            }
        }
    }

    /// The fallback must fit too: at 8 GB a stored 26B lands on the largest row that fits
    /// (E2B 6-bit, tier 8), never the recommended E4B 8-bit (16 GB+).
    func testStoredIdThatDoesNotFitResolvesToLargestFitting() {
        let at8 = gb(8)
        XCTAssertEqual(Preferences.resolveModelId(Preferences.qat26B8Id, physicalGB: at8), Preferences.qatE2B6Id)
        XCTAssertNotEqual(Preferences.resolveModelId(Preferences.qat26B8Id, physicalGB: at8), Preferences.recommendedModelId)
        XCTAssertEqual(Preferences.resolveModelId(Preferences.qat26B8Id, physicalGB: gb(24)), Preferences.qat26B4Id)
        XCTAssertEqual(Preferences.resolveModelId(Preferences.qat26B8Id, physicalGB: gb(36)), Preferences.qat26B8Id)
        // Already the smallest (and fitting): itself. Nothing fits: "" (no automatic load).
        XCTAssertEqual(Preferences.resolveModelId(Preferences.qatE2B4Id, physicalGB: at8), Preferences.qatE2B4Id)
        XCTAssertEqual(Preferences.resolveModelId(Preferences.qatE2B4Id, physicalGB: 4), "")
        // Outside the table (legacy, none): untouched. Resolving is idempotent at every RAM.
        XCTAssertEqual(Preferences.resolveModelId(Preferences.liteModelId, physicalGB: at8), Preferences.liteModelId)
        XCTAssertEqual(Preferences.resolveModelId("", physicalGB: at8), "")
        for g in [4, 8, 16, 18, 24, 32, 36, 48, 64] { for id in ids {
            let once = Preferences.resolveModelId(id, physicalGB: g)
            XCTAssertEqual(Preferences.resolveModelId(once, physicalGB: g), once)
            XCTAssertTrue(once.isEmpty || Preferences.modelFits(once, physicalGB: g))
        } }
    }

    /// The gate sits where coreModel is read, stored and default alike.
    func testCoreModelReadThroughTheGate() {
        AgentModelRegistry.physicalMemoryGB = gb(8)
        Preferences.defaults.set(Preferences.qat26B8Id, forKey: key)
        XCTAssertEqual(Preferences.coreModel, Preferences.qatE2B6Id)
        XCTAssertEqual(Preferences.defaults.string(forKey: key), Preferences.qat26B8Id, "never written back (synced)")
        Preferences.defaults.removeObject(forKey: key)
        XCTAssertEqual(Preferences.coreModel, Preferences.qatE2B6Id, "the default must fit too")
        AgentModelRegistry.physicalMemoryGB = gb(16)
        XCTAssertEqual(Preferences.coreModel, Preferences.recommendedModelId)
    }

    // MARK: - Per-Mac launch override (OQ-38)

    /// The launch fallback's override wins over the synced pick on this Mac, through the same gate.
    func testLocalOverrideReadsThroughTheGate() {
        let o = Preferences.coreModelOverrideKey
        AgentModelRegistry.physicalMemoryGB = gb(8)
        Preferences.defaults.set(Preferences.qatE4B8Id, forKey: key)
        Preferences.defaults.set(Preferences.qat26B8Id, forKey: o)
        XCTAssertEqual(Preferences.coreModel, Preferences.qatE2B6Id)
        Preferences.defaults.set(Preferences.qatE2B4Id, forKey: o)
        XCTAssertEqual(Preferences.coreModel, Preferences.qatE2B4Id)
        Preferences.defaults.set("", forKey: o)
        XCTAssertEqual(Preferences.coreModel, "", "an empty override is no model, not unset")
        XCTAssertEqual(Preferences.defaults.string(forKey: key), Preferences.qatE4B8Id, "the synced pick is untouched")
    }

    /// A pick (Settings picker, AI Models pane, revert after a failed switch) ends the step-down.
    func testUserPickClearsLocalOverride() {
        AgentModelRegistry.physicalMemoryGB = gb(16)
        Preferences.defaults.set("", forKey: Preferences.coreModelOverrideKey)
        Preferences.coreModel = Preferences.qatE4B8Id
        XCTAssertNil(Preferences.defaults.string(forKey: Preferences.coreModelOverrideKey))
        XCTAssertEqual(Preferences.coreModel, Preferences.qatE4B8Id)
    }

    func testLocalOverrideIsNotSynced() {
        XCTAssertFalse(SyncedKeys.isSynced(Preferences.coreModelOverrideKey))
        XCTAssertTrue(SyncedKeys.isSynced(key))
    }

    // MARK: - Launch crash-loop marker (#435)

    private func markerDefaults() -> UserDefaults {
        let name = tempDir().appendingPathComponent("defaults").path
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// Disk seam for the marker tests, so none reads the real hub cache.
    private let everyRow: (String) -> Bool = { _ in true }

    func testMarkerArmsBeforeLoadAndSkipsAfterADeath() {
        let d = markerDefaults(), k = Preferences.modelLoadMarkerKey, x = Preferences.qatE4B8Id
        // Launch 1: armed before the load, nothing to skip.
        XCTAssertNil(Preferences.launchLoadFallback(for: x, physicalGB: gb(16), defaults: d))
        XCTAssertEqual(d.string(forKey: k), x, "marker must be set before the load")
        // Launch 2 with no success in between: the previous launch died loading x.
        XCTAssertEqual(Preferences.launchLoadFallback(for: x, physicalGB: gb(16), defaults: d, isOnDisk: everyRow), Preferences.qatE4B6Id)
        XCTAssertEqual(d.string(forKey: k), x, "the marker is never cleared at launch")
        // A success for another id leaves it; a success for x clears it, and the next launch loads.
        Preferences.modelLoadSucceeded(Preferences.qatE2B4Id, defaults: d)
        XCTAssertEqual(d.string(forKey: k), x)
        Preferences.modelLoadSucceeded(x, defaults: d)
        XCTAssertNil(d.string(forKey: k))
        XCTAssertNil(Preferences.launchLoadFallback(for: x, physicalGB: gb(16), defaults: d))
    }

    /// Every death steps strictly down, so repeated deaths end at "" and never loop.
    func testRepeatedDeathsEndAtNoModel() {
        let d = markerDefaults()
        var id = Preferences.qatE2B6Id, path: [String] = []
        for _ in 0..<8 where !id.isEmpty {
            if let next = Preferences.launchLoadFallback(for: id, physicalGB: gb(8), defaults: d, isOnDisk: everyRow) { id = next; path.append(next) }
        }
        XCTAssertEqual(path, [Preferences.qatE2B4Id, ""])
        // From the smallest, a death means no automatic load.
        XCTAssertEqual(Preferences.launchLoadFallback(for: Preferences.qatE2B4Id, physicalGB: gb(8), defaults: d, isOnDisk: everyRow), "")
    }

    /// The fallback is only ever a model already on disk, so no launch starts a download (#438).
    func testLaunchFallbackIsOnDiskOnly() {
        let d = markerDefaults(), x = Preferences.qat26B8Id
        d.set(x, forKey: Preferences.modelLoadMarkerKey) // the previous launch died loading x
        XCTAssertEqual(Preferences.launchLoadFallback(for: x, physicalGB: gb(64), defaults: d,
                                                      isOnDisk: { $0 == Preferences.qatE4B8Id }), Preferences.qatE4B8Id)
        XCTAssertEqual(Preferences.launchLoadFallback(for: x, physicalGB: gb(64), defaults: d, isOnDisk: { _ in false }), "")
    }

    func testAgentPickerRowLabelShowsRAMFloorOnlyWhenRowDoesNotFit() throws {
        let coder = try XCTUnwrap(AgentModelRegistry.all().first { $0.id == "unsloth/Qwen3-Coder-Next-GGUF" })
        XCTAssertEqual(coder.minRAMGB, 64)
        AgentModelRegistry.physicalMemoryGB = 8 // the default argument must read the seam
        XCTAssertTrue(AgentPane.rowLabel(for: coder, name: coder.label).hasSuffix(" · needs 64 GB RAM"))
        XCTAssertFalse(AgentPane.rowLabel(for: coder, name: coder.label, physicalGB: 64).contains("needs"))
        AgentModelRegistry.physicalMemoryGB = 16
        let fitting = try XCTUnwrap(AgentModelRegistry.all().first { $0.minRAMGB <= 16 })
        XCTAssertEqual(AgentPane.rowLabel(for: fitting, name: "N"), "N — \(fitting.note)")
    }

    func testSetupFailureNetworkClassification() {
        XCTAssertTrue(ModelSetup.isNetworkError(URLError(.notConnectedToInternet)))
        XCTAssertFalse(ModelSetup.isNetworkError(MLXEngineError.mlxRuntime("load: [metal::malloc] too large")))
    }

    func testSetupFailureNetworkClassificationReadsTheUnderlyingError() {
        let wrapped = { (underlying: Error) in NSError(domain: "HubApi", code: 1, userInfo: [NSUnderlyingErrorKey: underlying]) }
        XCTAssertTrue(ModelSetup.isNetworkError(wrapped(URLError(.timedOut))))
        XCTAssertFalse(ModelSetup.isNetworkError(wrapped(CocoaError(.fileReadNoSuchFile))))
    }
}

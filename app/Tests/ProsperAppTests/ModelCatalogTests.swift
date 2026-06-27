import XCTest
@testable import ProsperApp

/// Round-trip + mapping checks for the custom-model store and label overrides that back
/// the AI Models pane's "add your own" / rename features. Uses `.standard` defaults with
/// sentinel ids it cleans up, so it doesn't disturb real entries.
final class ModelCatalogTests: XCTestCase {
    private let idA = "test-owner/Model-A-zzz"
    private let idB = "test-owner/Model-B-zzz"

    override func tearDown() {
        CustomModelStore.remove(idA)
        CustomModelStore.remove(idB)
        super.tearDown()
    }

    private func model(_ id: String, size: Int64 = 0, fmt: ToolCallFormat = .qwenXML) -> CustomAgentModel {
        CustomAgentModel(id: id, label: "Label \(id)", sizeBytes: size, note: "note", toolFormat: fmt)
    }

    func testUpsertExistsRemoveRoundTrip() {
        XCTAssertFalse(CustomModelStore.exists(idA))
        CustomModelStore.upsert(model(idA))
        XCTAssertTrue(CustomModelStore.exists(idA))
        XCTAssertEqual(CustomModelStore.all().first { $0.id == idA }?.label, "Label \(idA)")

        // upsert replaces by id, no duplicate
        CustomModelStore.upsert(model(idA, fmt: .mistral))
        XCTAssertEqual(CustomModelStore.all().filter { $0.id == idA }.count, 1)
        XCTAssertEqual(CustomModelStore.all().first { $0.id == idA }?.toolFormat, .mistral)

        CustomModelStore.remove(idA)
        XCTAssertFalse(CustomModelStore.exists(idA))
    }

    func testAsAgentModelsRAMMapping() {
        CustomModelStore.upsert(model(idA, size: 20_000_000_000)) // 20 GB
        let am = CustomModelStore.asAgentModels().first { $0.id == idA }
        XCTAssertNotNil(am)
        XCTAssertEqual(am!.approxRAMGB, 20.0 * 1.15, accuracy: 0.001) // ×1.15 expand
        XCTAssertEqual(am!.minRAMGB, 25)                              // max(8, ceil(23)+2)
        XCTAssertEqual(am!.toolFormat, .qwenXML)
    }

    func testAsAgentModelsUnknownSizeFloors() {
        CustomModelStore.upsert(model(idB, size: 0))
        let am = CustomModelStore.asAgentModels().first { $0.id == idB }
        XCTAssertEqual(am!.approxRAMGB, 0)
        XCTAssertEqual(am!.minRAMGB, 8) // floor when size unknown
    }

    func testLabelOverrideFallbackAndClear() {
        XCTAssertEqual(CustomModelStore.label(for: idA, fallback: "Built-in"), "Built-in")
        CustomModelStore.setLabel(idA, "  My Name  ")
        XCTAssertEqual(CustomModelStore.label(for: idA, fallback: "Built-in"), "My Name") // trimmed
        CustomModelStore.setLabel(idA, "   ")                                              // blank clears
        XCTAssertEqual(CustomModelStore.label(for: idA, fallback: "Built-in"), "Built-in")

        CustomModelStore.setLabel(idA, "X")
        CustomModelStore.clearLabel(idA)
        XCTAssertEqual(CustomModelStore.label(for: idA, fallback: "Built-in"), "Built-in")
    }

    func testAllDedupesCustomCollidingWithBuiltin() {
        let builtin = AgentModelRegistry.models[0]
        // A custom entry that collides with a built-in id (e.g. shipped later) must not
        // duplicate it in all() — built-in wins, so ForEach never sees a dup id.
        CustomModelStore.upsert(CustomAgentModel(id: builtin.id, label: "SHADOW",
                                                 sizeBytes: 1, note: "x", toolFormat: .qwenXML))
        defer { CustomModelStore.remove(builtin.id) }
        let matches = AgentModelRegistry.all().filter { $0.id == builtin.id }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.label, builtin.label) // built-in kept, not "SHADOW"
    }

    func testRemoveClearsLabelOverride() {
        CustomModelStore.upsert(model(idA))
        CustomModelStore.setLabel(idA, "Renamed")
        CustomModelStore.remove(idA)
        XCTAssertEqual(CustomModelStore.label(for: idA, fallback: "Built-in"), "Built-in")
    }
}

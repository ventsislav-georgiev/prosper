import MLXLMCommon   // ToolSpec, as in AgentModelReadOnceTests (a type only: no model is loaded)
import XCTest
import os
import Synchronization
@testable import ProsperApp

/// #1181 (R1181-a, R1181-d): codex's config names the model the run LOADED, never a second read of the
/// setting. The rows call AgentController.spawnCodexHarness with a coordinator whose engine is a fake, then
/// read the config as a VALUE (CodexHarness.configText()): codex is never started and nothing is written.
/// spawnCodexHarness starts the in-process server on a loopback port 0, as AgentModelReadOnceTests does;
/// the rows stop it. The setting lives in the tree's scratch XCTestDefaults store (`Preferences.defaults`
/// under XCTest); every key a row writes is saved and restored.
/// Ids: A is a catalog GGUF row (codex is told its context window), B a made-up custom MLX row (no
/// context window line), so the two values the config takes from the id both show which id was used.
private let modelA = "unsloth/Qwen3.5-4B-GGUF", modelB = "example-model-b"

final class AgentModelSpawnReadTests: XCTestCase {

    private final class FakeChatEngine: AgentChatEngine {
        nonisolated func generateChat(
            messages: [MLXEngine.ChatTurn], tools: [ToolSpec], maxTokens: Int,
            temperature: Float, topP: Float, stop: [String]
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func unload() async {}
    }

    private let contextLine = "model_context_window = \(LlamaAgentEngine.contextTokens)"

    /// A coordinator recording every load, a controller (its store in the row's tempDir()), and the
    /// setting, the custom list, the RAM pin, the residency flag and the server restored after `body`.
    @MainActor
    private func withSpawn(_ body: (AgentController, ModelResidencyCoordinator, OSAllocatedUnfairLock<[String]>, URL) async throws -> Void) async throws {
        let d = Preferences.defaults, keys = ["agentModel", "customAgentModelsV1", "modelLabelOverridesV1"]
        let saved = keys.map { d.object(forKey: $0) }
        let savedGB = AgentModelRegistry.physicalMemoryGB
        let savedFlag = ModelResidencyCoordinator.activeFlag.load(ordering: .acquiring)
        defer {
            ProsperLLMServer.shared.stop()
            for (k, v) in zip(keys, saved) { d.set(v, forKey: k) }
            AgentModelRegistry.physicalMemoryGB = savedGB
            ModelResidencyCoordinator.activeFlag.store(savedFlag, ordering: .releasing)
        }
        AgentModelRegistry.physicalMemoryGB = 64   // both rows fit, so the setting is not healed away
        CustomModelStore.upsert(CustomAgentModel(id: modelB, label: "B", sizeBytes: 0, note: "", toolFormat: .qwenXML))
        XCTAssertTrue(AgentModelRegistry.gguf(for: modelA) != nil, "A is a GGUF catalog row")
        XCTAssertTrue(AgentModelRegistry.gguf(for: modelB) == nil, "B is an MLX custom row")
        Preferences.agentModel = modelA
        XCTAssertEqual(Preferences.agentModel, modelA)
        let dir = tempDir()
        let loads = OSAllocatedUnfairLock<[String]>(initialState: [])
        let c = ModelResidencyCoordinator(makeEngine: { id, _ in
            loads.withLock { $0.append(id) }
            return FakeChatEngine()
        })
        let controller = AgentController(store: AgentSessionStore(directory: dir.appendingPathComponent("store")),
                                         resolveCodex: { dir.appendingPathComponent("codex-never-run") },
                                         releaseModel: {}, agentModel: { modelA })
        try await body(controller, c, loads, dir.appendingPathComponent("codex-never-run"))
        await c.releaseAgent()
    }

    private func topLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).prefix(3).map(String.init)
    }

    /// R1181-a: the run loaded A; the setting moves to B before codex's config is built. The config
    /// names A and keeps A's context window. Before #1181 it read the setting again: B, no window.
    @MainActor
    func testConfigNamesTheLoadedModelWhenTheSettingMovesAfterTheLoad() async throws {
        try await withSpawn { controller, c, loads, exe in
            let spawned = try await controller.spawnCodexHarness(exe, model: modelA, residency: c)
            XCTAssertEqual(spawned.loaded, modelA)
            Preferences.agentModel = modelB
            let text = await spawned.harness.configText()
            let top = topLines(text)
            XCTAssertEqual(top.first, "model = \"\(modelA)\"", text)
            XCTAssertTrue(top.contains(contextLine), "A's context window. \(text)")
            XCTAssertFalse(text.contains(modelB), text)
            XCTAssertEqual(loads.withLock { $0 }, [modelA])
        }
    }

    /// R1181-d: another model (B) is resident, as when the phone chat loaded it. The run asks for A; the
    /// engine holds B, so codex's config and the session name B. Before #1181 they named A.
    @MainActor
    func testConfigNamesTheResidentModelNotTheRunsValue() async throws {
        try await withSpawn { controller, c, loads, exe in
            _ = try await c.acquireLoadedAgent(modelId: modelB) { _, _ in }
            let spawned = try await controller.spawnCodexHarness(exe, model: modelA, residency: c)
            XCTAssertEqual(spawned.loaded, modelB, "the id the engine holds")
            let text = await spawned.harness.configText()
            XCTAssertEqual(topLines(text).first, "model = \"\(modelB)\"", text)
            XCTAssertFalse(text.contains(contextLine), "B has no context window. \(text)")
            XCTAssertEqual(loads.withLock { $0 }, [modelB], "nothing else loaded")
        }
    }

    /// The setting does not change: the config is byte for byte the one built from the setting (today's
    /// rule, the init's default argument), and its first lines are the literal ones.
    @MainActor
    func testUnchangedSettingGivesTodaysConfig() async throws {
        try await withSpawn { controller, c, _, exe in
            let spawned = try await controller.spawnCodexHarness(exe, model: modelA, residency: c)
            let text = await spawned.harness.configText()
            let fromSetting = CodexHarness(executableURL: exe, codexHome: AgentController.codexHomeURL(),
                                           llmBaseURL: ProsperLLMServer.shared.baseURL, llmToken: "unused")
            let today = await fromSetting.configText()
            XCTAssertEqual(text, today)
            XCTAssertEqual(topLines(text), ["model = \"\(modelA)\"", "model_provider = \"prosper\"", contextLine], text)
        }
    }
}

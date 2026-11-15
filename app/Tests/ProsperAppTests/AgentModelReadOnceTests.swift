import MLXLMCommon   // ToolSpec, as in DchChatTests (a type only: no model is loaded)
import XCTest
import os
@testable import ProsperApp

/// #1181: one agent run reads the agent model setting ONCE (AgentController, where the run starts) and
/// passes it down: the load takes that value, and the server takes the tool format and the label from
/// the id of the model that is LOADED, never from a second read of the setting. The setting lives in
/// the tree's scratch XCTestDefaults store (`Preferences.defaults` under XCTest: in memory, per
/// process); every key a row writes is saved and restored. No model is loaded: fake engines only, and
/// the server row talks to the in-process server on a loopback port 0.
/// Made-up custom models of two tool formats: every built-in catalog row is qwenXML, so another
/// model's format can only be shown with custom rows. File scope: a @Sendable closure never captures self.
private let modelA = "example-model-a", modelB = "example-model-b"

final class AgentModelReadOnceTests: XCTestCase {

    private final class FakeChatEngine: AgentChatEngine {
        let output: String
        init(output: String) { self.output = output }
        nonisolated func generateChat(
            messages: [MLXEngine.ChatTurn], tools: [ToolSpec], maxTokens: Int,
            temperature: Float, topP: Float, stop: [String]
        ) -> AsyncThrowingStream<String, Error> {
            let output = output
            return AsyncThrowingStream { c in c.yield(output); c.finish() }
        }
        func unload() async {}
    }

    /// A (mistral) and B (qwenXML) as custom models on a Mac both fit; the setting, the custom list,
    /// the RAM pin and the residency flag are restored after `body`.
    private func withTwoModels(_ body: () async throws -> Void) async rethrows {
        let d = Preferences.defaults, keys = ["agentModel", "customAgentModelsV1", "modelLabelOverridesV1"]
        let saved = keys.map { d.object(forKey: $0) }
        let savedGB = AgentModelRegistry.physicalMemoryGB
        let savedFlag = ModelResidencyCoordinator.activeFlag.withLock { $0 }
        defer {
            for (k, v) in zip(keys, saved) { d.set(v, forKey: k) }
            AgentModelRegistry.physicalMemoryGB = savedGB
            ModelResidencyCoordinator.activeFlag.withLock { $0 = savedFlag }
        }
        AgentModelRegistry.physicalMemoryGB = 64
        CustomModelStore.upsert(CustomAgentModel(id: modelA, label: "A", sizeBytes: 0, note: "", toolFormat: .mistral))
        CustomModelStore.upsert(CustomAgentModel(id: modelB, label: "B", sizeBytes: 0, note: "", toolFormat: .qwenXML))
        XCTAssertEqual(AgentModelRegistry.toolFormat(for: modelA), .mistral)
        XCTAssertEqual(AgentModelRegistry.toolFormat(for: modelB), .qwenXML)
        try await body()
    }

    /// The load takes the run's value (A) although the setting says B by then, and the coordinator
    /// answers with the id it LOADED, on the resident path too.
    func testLoadTakesTheRunsValueNotASecondRead() async throws {
        try await withTwoModels {
            Preferences.agentModel = modelB
            let loads = OSAllocatedUnfairLock<[String]>(initialState: [])
            let c = ModelResidencyCoordinator(makeEngine: { id, _ in
                loads.withLock { $0.append(id) }
                return FakeChatEngine(output: "")
            })
            let first = try await c.acquireLoadedAgent(modelId: modelA) { _, _ in }
            XCTAssertEqual(first.modelId, modelA)
            let resident = try await c.acquireLoadedAgent { _, _ in }   // default argument: reads B
            XCTAssertEqual(resident.modelId, modelA, "the resident engine holds A")
            XCTAssertEqual(loads.withLock { $0 }, [modelA])
            await c.releaseAgent()
        }
    }

    /// A caller that joins an in-flight load learns the id being loaded, not the id it asked for.
    func testJoinerLearnsTheIdOfTheLoadItJoins() async throws {
        try await withTwoModels {
            let loads = OSAllocatedUnfairLock<[String]>(initialState: [])
            let joined = OSAllocatedUnfairLock(initialState: false)
            // The fake load ticks progress once per gate element and ends when the gate finishes.
            let (gate, open) = AsyncStream<Void>.makeStream()
            let c = ModelResidencyCoordinator(makeEngine: { id, progress in
                loads.withLock { $0.append(id) }
                for await _ in gate { progress(0, "tick") }
                return FakeChatEngine(output: "")
            })
            async let first = c.acquireLoadedAgent(modelId: modelA) { _, _ in }
            // Budgets of yields, not deadlines. The joiner's progress sink only hears a tick once it
            // has joined the in-flight load (a resident engine would return before registering it).
            for _ in 0..<100_000 { if !loads.withLock({ $0.isEmpty }) { break }; await Task.yield() }
            XCTAssertEqual(loads.withLock { $0 }, [modelA])
            async let joiner = c.acquireLoadedAgent(modelId: modelB) { _, _ in joined.withLock { $0 = true } }
            for _ in 0..<100_000 { if joined.withLock({ $0 }) { break }; open.yield(); await Task.yield() }
            XCTAssertTrue(joined.withLock { $0 }, "the joiner joined the in-flight load")
            open.finish()
            let a = try await first, b = try await joiner
            XCTAssertEqual(a.modelId, modelA)
            XCTAssertEqual(b.modelId, modelA, "joined A's load")
            XCTAssertEqual(loads.withLock { $0 }, [modelA])
            await c.releaseAgent()
        }
    }

    /// THE FAULT: the run loaded A (mistral), then the setting moved to B (qwenXML) before codex's
    /// request. The request must render, parse and label with A: one tool call, model A. Before
    /// #1181 the request read the setting (B): no call (A's call read as qwenXML prose) and label B.
    func testRequestUsesTheLoadedModelAfterTheSettingChanged() async throws {
        try await withTwoModels {
            let server = ProsperLLMServer.shared
            let savedAcquire = server.acquireAgent
            defer { server.acquireAgent = savedAcquire; server.stop() }
            let loaded = modelA
            let call = #"[TOOL_CALLS][{"name": "shell", "arguments": {"command": "ls"}}]"#
            server.acquireAgent = { (engine: FakeChatEngine(output: call), modelId: loaded) }
            Preferences.agentModel = modelB
            let (port, token) = try server.start()
            func post(_ path: String, _ json: String) async throws -> (body: [String: Any], text: String) {
                var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/\(path)")!)
                req.httpMethod = "POST"
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 30
                req.httpBody = Data(json.utf8)
                let (data, _) = try await URLSession.shared.data(for: req)
                let text = String(decoding: data, as: UTF8.self)
                return (try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], text), text)
            }
            let params = #"{"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}"#
            // Chat Completions wire.
            let chat = try await post("chat/completions", #"{"messages": [{"role": "user", "content": "list the files"}], "#
                + #""stream": false, "tools": [{"type": "function", "function": {"name": "shell", "parameters": "#
                + params + "}}]}")
            XCTAssertEqual(chat.body["model"] as? String, modelA, "label: the loaded model. \(chat.text)")
            let message = (chat.body["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            let calls = message?["tool_calls"] as? [[String: Any]]
            XCTAssertEqual(calls?.count, 1, "parsed with A's format (mistral). \(chat.text)")
            XCTAssertEqual((calls?.first?["function"] as? [String: Any])?["name"] as? String, "shell", chat.text)
            // Responses wire (codex >= 0.139): flat tools, string input.
            let resp = try await post("responses", #"{"input": "list the files", "stream": false, "#
                + #""tools": [{"type": "function", "name": "shell", "parameters": "# + params + "}]}")
            XCTAssertEqual(resp.body["model"] as? String, modelA, "label: the loaded model. \(resp.text)")
            let items = (resp.body["output"] as? [[String: Any]])?.filter { $0["type"] as? String == "function_call" }
            XCTAssertEqual(items?.count, 1, "parsed with A's format (mistral). \(resp.text)")
            XCTAssertEqual(items?.first?["name"] as? String, "shell", resp.text)
        }
    }
}

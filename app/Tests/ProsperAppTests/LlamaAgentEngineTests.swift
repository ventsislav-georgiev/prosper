import XCTest
import MLXLMCommon
@testable import ProsperApp

/// Model-free units of the llama.cpp agent engine: prompt rendering, the
/// tool-call grammar builder, UTF-8 stream assembly, and GGUF catalog routing.
/// (Decode-path behavior needs a loaded model — covered by the agent bench.)
final class LlamaAgentEngineTests: XCTestCase {

    // MARK: ChatML rendering

    func testRenderChatMLBasicTurns() {
        let out = LlamaAgentEngine.renderChatML(
            messages: [
                .init(role: "system", content: "You are helpful."),
                .init(role: "user", content: "hi"),
                .init(role: "assistant", content: "hello"),
                .init(role: "user", content: "bye"),
            ], tools: [])
        XCTAssertEqual(out, """
        <|im_start|>system
        You are helpful.<|im_end|>
        <|im_start|>user
        hi<|im_end|>
        <|im_start|>assistant
        hello<|im_end|>
        <|im_start|>user
        bye<|im_end|>
        <|im_start|>assistant

        """)
    }

    func testRenderChatMLToolResponseTurn() {
        let out = LlamaAgentEngine.renderChatML(
            messages: [
                .init(role: "user", content: "run it"),
                .init(role: "tool", content: "exit 0"),
            ], tools: [])
        XCTAssertTrue(out.contains("<|im_start|>user\n<tool_response>\nexit 0\n</tool_response><|im_end|>\n"))
    }

    func testRenderChatMLInjectsToolsIntoExistingSystem() {
        // ToolSpec == [String: any Sendable]; annotate each nested level so the
        // literal doesn't infer non-Sendable Any.
        let tool: ToolSpec = [
            "type": "function",
            "function": [
                "name": "read_file",
                "parameters": ["type": "object"] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
        let out = LlamaAgentEngine.renderChatML(
            messages: [
                .init(role: "system", content: "Base prompt."),
                .init(role: "user", content: "go"),
            ], tools: [tool])
        // One system turn, carrying both the base prompt and the tools block.
        XCTAssertEqual(out.components(separatedBy: "<|im_start|>system").count - 1, 1)
        XCTAssertTrue(out.contains("Base prompt."))
        XCTAssertTrue(out.contains("<tools>"))
        XCTAssertTrue(out.contains("\"read_file\""))
        XCTAssertTrue(out.contains("<tool_call></tool_call> XML tags"))
    }

    func testRenderChatMLSynthesizesSystemWhenMissing() {
        let tool: ToolSpec = [
            "type": "function",
            "function": ["name": "ls"] as [String: any Sendable],
        ]
        let out = LlamaAgentEngine.renderChatML(
            messages: [.init(role: "user", content: "go")], tools: [tool])
        XCTAssertTrue(out.hasPrefix("<|im_start|>system\n# Tools"))
    }

    // MARK: tool-call grammar

    func testToolCallGrammarBakesNameEnum() throws {
        let g = try XCTUnwrap(LlamaAgentEngine.toolCallGrammar(toolNames: ["read_file", "shell.exec"]))
        XCTAssertTrue(g.contains(#"name ::= "\"read_file\"" | "\"shell.exec\"""#))
        XCTAssertTrue(g.contains(#"block ::= "<tool_call>""#))
        XCTAssertTrue(g.contains("</tool_call>"))
    }

    func testToolCallGrammarRefusesUnsafeNames() {
        // A name that could break out of a GBNF string literal must kill the
        // grammar entirely (SchemaValidator backstop remains), not ship escaped-ish.
        XCTAssertNil(LlamaAgentEngine.toolCallGrammar(toolNames: [#"a"b"#]))
        XCTAssertNil(LlamaAgentEngine.toolCallGrammar(toolNames: ["ok", "bad name"]))
        XCTAssertNil(LlamaAgentEngine.toolCallGrammar(toolNames: []))
    }

    // MARK: UTF-8 assembly

    func testUTF8AssemblerPassesASCIIThrough() {
        var a = UTF8Assembler()
        XCTAssertEqual(a.push(Array("hello".utf8)), "hello")
        XCTAssertEqual(a.push(Array(" world".utf8)), " world")
    }

    func testUTF8AssemblerHoldsSplitMultibyte() {
        // "я" = D1 8F, split across two pushes.
        var a = UTF8Assembler()
        XCTAssertEqual(a.push([0xD1]), "")
        XCTAssertEqual(a.push([0x8F]), "я")
    }

    func testUTF8AssemblerSplitFourByteEmoji() {
        // "😀" = F0 9F 98 80 split 1+3, prefixed by complete text.
        var a = UTF8Assembler()
        XCTAssertEqual(a.push(Array("ok".utf8) + [0xF0]), "ok")
        XCTAssertEqual(a.push([0x9F, 0x98, 0x80]), "😀")
    }

    func testUTF8AssemblerBulgarianStream() {
        var a = UTF8Assembler()
        var out = ""
        for b in Array("Здравей, свят".utf8) { out += a.push([b]) }
        XCTAssertEqual(out, "Здравей, свят")
    }

    // MARK: GGUF catalog routing

    func testGGUFLookupIsExactMatchOnly() {
        XCTAssertNotNil(AgentModelRegistry.gguf(for: "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"))
        // Unknown ids must NOT fall back to the recommended model here —
        // this lookup routes engine selection.
        XCTAssertNil(AgentModelRegistry.gguf(for: "mlx-community/some-unknown-model"))
        // MLX rows carry no GGUF.
        XCTAssertNil(AgentModelRegistry.gguf(for: "mlx-community/Qwen3-8B-4bit-DWQ"))
    }

    func testRecommendedIsGGUFRow() {
        XCTAssertNotNil(AgentModelRegistry.gguf(for: AgentModelRegistry.recommendedId))
        XCTAssertEqual(AgentModelRegistry.model(for: AgentModelRegistry.recommendedId).toolFormat, .qwenXML)
    }

    func testGGUFRowsSurviveCatalogMerge() {
        let all = AgentModelRegistry.all()
        let ggufRows = all.filter { $0.gguf != nil }
        XCTAssertEqual(ggufRows.count, 7)
        // No duplicate ids after the custom-model merge.
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    }

    // MARK: on-device e2e (gated — GGUF download + Metal load)

    /// The llama twin of `AgentToolCallE2ETests`: full production path
    /// (download → load → ChatML render → lazy-grammar decode → stream), asserting
    /// the `<tool_call>` wire form survives to `ToolCallParser`. Uses the smallest
    /// catalog GGUF (Qwen3.5 4B, ~2.6 GB). Run:
    ///   PROSPER_AGENT_E2E=1 swift test --filter testLlamaAgentToolCall 2>&1 | tee /tmp/llama-agent-e2e.log
    func testLlamaAgentToolCallE2E() async throws {
        guard ProcessInfo.processInfo.environment["PROSPER_AGENT_E2E"] == "1" else {
            throw XCTSkip("Set PROSPER_AGENT_E2E=1 to run the on-device llama agent e2e.")
        }
        let spec = try XCTUnwrap(AgentModelRegistry.gguf(for: "unsloth/Qwen3.5-4B-GGUF"))
        let engine = LlamaAgentEngine.shared
        try await engine.ensureModel(spec) { p, s in
            NSLog("llama-agent-e2e: %3.0f%% %@", p * 100, s)
        }

        let commandProp: [String: any Sendable] = [
            "type": "array",
            "items": ["type": "string"] as [String: any Sendable],
            "description": "argv of the command to run, e.g. [\"ls\", \"-la\"].",
        ]
        let parameters: [String: any Sendable] = [
            "type": "object",
            "properties": ["command": commandProp] as [String: any Sendable],
            "required": ["command"] as [any Sendable],
        ]
        let shellTool: ToolSpec = [
            "type": "function",
            "function": [
                "name": "shell",
                "description": "Run a shell command and return its stdout/stderr.",
                "parameters": parameters,
            ] as [String: any Sendable],
        ]

        let messages: [MLXEngine.ChatTurn] = [
            .init(role: "system",
                  content: "You are a coding agent. Use the provided tools to accomplish "
                      + "the user's goal. To run a shell command, emit a tool call."),
            .init(role: "user", content: "List the files in the current directory."),
        ]
        var out = ""
        let stream = engine.generateChat(
            messages: messages, tools: [shellTool],
            maxTokens: 512, temperature: 0, topP: 1, stop: [])
        for try await chunk in stream { out += chunk }
        NSLog("llama-agent-e2e: output(len=%d) = %@", out.count, out)

        let parsed = ToolCallParser.parse(out, format: .qwenXML)
        XCTAssertTrue(parsed.hasToolCalls,
                      "llama stream did not yield a parseable tool call: \(out)")
        // Grammar-locked call must also validate against the schema (the whole
        // point of the GBNF path: the repair ladder should never be needed).
        XCTAssertTrue(SchemaValidator.validate(
            toolCalls: parsed.toolCalls, against: [shellTool]).isEmpty)
        await engine.unload()
    }
}

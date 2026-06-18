import Foundation
import MLX
import MLXLMCommon
import XCTest

@testable import ProsperApp

/// ON-DEVICE validation of the **coding-agent tool-calling path** through the exact
/// production `MLXEngine.generateChat` → `streamChat` pipeline — headless, no GUI,
/// no Accessibility, no secure-input interference. This replaces the brittle
/// "swap binary into the bundle, drive ⌥G via System Events" loop, which fails
/// outright when the display is asleep/locked.
///
/// Regression under test: on long prompts the model opens its turn with the native
/// `<tool_call>` token. The high-level `MLXLMCommon.generate` loop intercepts that
/// into a typed `.toolCall` and suppresses the surrounding text, so the turn reached
/// the agent server as EMPTY. `streamChat` now uses the raw-token API and detokenizes
/// itself (the bytes `mlx_lm.stream_generate` would yield), so the
/// `<tool_call>…</tool_call>` wire form survives for `ToolCallParser`. This test
/// asserts the wire form is present in the streamed output.
///
/// Gated behind `PROSPER_AGENT_E2E=1` (multi-GB model load + GPU). Model id is
/// overridable via `PROSPER_AGENT_MODEL`. Run:
///   PROSPER_AGENT_E2E=1 swift test --filter AgentToolCallE2ETests 2>&1 | tee /tmp/agent-e2e.log
final class AgentToolCallE2ETests: XCTestCase {

    private var modelId: String {
        ProcessInfo.processInfo.environment["PROSPER_AGENT_MODEL"]
            ?? "mlx-community/Qwen3-8B-4bit-DWQ"
    }

    private func requireE2E() throws {
        guard ProcessInfo.processInfo.environment["PROSPER_AGENT_E2E"] == "1" else {
            throw XCTSkip("Set PROSPER_AGENT_E2E=1 to run the on-device agent tool-call e2e.")
        }
    }

    /// Minimal OpenAI-style `shell` tool schema — the same shape the codex harness
    /// sends, so the chat template renders a real `tools` block and the model is
    /// expected to answer with a `<tool_call>` (Qwen XML format), not EOS.
    private var shellTool: ToolSpec {
        // ToolSpec == [String: any Sendable]; annotate each nested level so the
        // heterogeneous literals don't infer [String: Any] (Any isn't Sendable).
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
        let function: [String: any Sendable] = [
            "name": "shell",
            "description": "Run a shell command and return its stdout/stderr.",
            "parameters": parameters,
        ]
        return ["type": "function", "function": function]
    }

    func testAgentToolCallProducesNonEmptyOutput() async throws {
        try requireE2E()
        ModelPaths.bootstrap()

        let engine = MLXEngine(modelId: modelId)
        let loadStart = Date()
        try await engine.load { fraction, status in
            if fraction > 0 { NSLog("agent-e2e: load %.0f%% — %@", fraction * 100, status) }
        }
        let loaded = await engine.isLoaded
        XCTAssertTrue(loaded, "\(modelId) failed to load")
        NSLog("agent-e2e: loaded %@ in %.1fs", modelId, Date().timeIntervalSince(loadStart))

        // Optional long prompt to cross the 512-token `prefillStepSize` and exercise
        // CHUNKED prefill — the regime where the EOS collapse appears (short prompts
        // <512 prefill in one shot and work). PROSPER_AGENT_PROMPT_FILE points at a
        // dump (text after a "PROMPT:\n" marker is used, matching the engine's
        // /tmp/prosper-prompt.txt format); otherwise the short default is used.
        var userContent = "List the files in the current directory."
        if let pf = ProcessInfo.processInfo.environment["PROSPER_AGENT_PROMPT_FILE"],
           let raw = try? String(contentsOfFile: pf, encoding: .utf8) {
            if let r = raw.range(of: "PROMPT:\n") {
                userContent = String(raw[r.upperBound...])
            } else {
                userContent = raw
            }
            NSLog("agent-e2e: long prompt from %@ (chars=%d)", pf, userContent.count)
        } else if let n = ProcessInfo.processInfo.environment["PROSPER_AGENT_PADTOKENS"],
                  let padTokens = Int(n) {
            // Synthesize a long prompt to cross 512-token chunks. Realistic code-ish
            // filler (~1.3 tokens/word) prepended as "context", then the real ask.
            // This is content-agnostic: it exercises the chunked-prefill ORCHESTRATION
            // (RoPE offsets, per-chunk masks, KVCacheSimple growth), which is what
            // differs between a single-shot <512 prefill and a multi-chunk one.
            let para = "The repository contains Swift source files, build scripts, and "
                + "configuration. Each module defines types, functions, and tests that "
                + "interact through well-defined interfaces and shared utilities. "
            let reps = max(1, padTokens / 30)
            userContent = String(repeating: para, count: reps)
                + "\n\nNow: list the files in the current directory."
            NSLog("agent-e2e: synthetic long prompt (~%d pad tokens, chars=%d)",
                  padTokens, userContent.count)
        }

        let messages: [MLXEngine.ChatTurn] = [
            .init(role: "system",
                  content: "You are a coding agent. Use the provided tools to accomplish "
                      + "the user's goal. To run a shell command, emit a tool call."),
            .init(role: "user", content: userContent),
        ]

        var out = ""
        // 512, not 128: thinking models (Qwen3 non-coder) spend >128 tokens in their
        // <think> preamble before the tool call; production budgets are far larger.
        let stream = engine.generateChat(
            messages: messages, tools: [shellTool],
            maxTokens: 512, temperature: 0.0
        )
        for try await chunk in stream { out += chunk }
        NSLog("agent-e2e: output(len=%d) = %@", out.count, out)

        XCTAssertFalse(
            out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "agent tool-call produced EMPTY output for \(modelId)")

        // The whole point: the native `<tool_call>` wire form must survive to the
        // server's `ToolCallParser`, which extracts an OpenAI tool call from it.
        let parsed = ToolCallParser.parse(out, format: .qwenXML)
        XCTAssertTrue(
            parsed.hasToolCalls,
            "streamed output did not yield a parseable tool call for \(modelId): \(out)")
    }
}

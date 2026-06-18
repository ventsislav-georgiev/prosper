import XCTest
@testable import ProsperApp

final class ToolCallParserTests: XCTestCase {

    // MARK: Qwen / Hermes tagged blocks

    func testQwenSingleToolCall() {
        let text = """
        I'll read the file.
        <tool_call>
        {"name": "read_file", "arguments": {"path": "src/main.swift"}}
        </tool_call>
        """
        let r = ToolCallParser.parse(text, format: .qwenXML)
        XCTAssertTrue(r.hasToolCalls)
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls[0].name, "read_file")
        XCTAssertEqual(r.content, "I'll read the file.")
        let args = json(r.toolCalls[0].argumentsJSON)
        XCTAssertEqual(args["path"] as? String, "src/main.swift")
    }

    func testQwenMultipleToolCalls() {
        let text = """
        <tool_call>
        {"name": "a", "arguments": {"x": 1}}
        </tool_call>
        <tool_call>
        {"name": "b", "arguments": {"y": 2}}
        </tool_call>
        """
        let r = ToolCallParser.parse(text, format: .qwenXML)
        XCTAssertEqual(r.toolCalls.map(\.name), ["a", "b"])
        XCTAssertTrue(r.content.isEmpty)
    }

    func testQwenTruncatedStreamUnterminated() {
        // Closing tag never arrives (truncated decode) — still extract the call.
        let text = """
        <tool_call>
        {"name": "search", "arguments": {"q": "hello"}}
        """
        let r = ToolCallParser.parse(text, format: .qwenXML)
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls[0].name, "search")
    }

    func testNoToolCallIsPlainContent() {
        let text = "Just a normal answer with no tools."
        let r = ToolCallParser.parse(text, format: .qwenXML)
        XCTAssertFalse(r.hasToolCalls)
        XCTAssertEqual(r.content, text)
    }

    func testParametersKeyFallback() {
        let text = #"<tool_call>{"name": "f", "parameters": {"a": "b"}}</tool_call>"#
        let r = ToolCallParser.parse(text, format: .qwenXML)
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(json(r.toolCalls[0].argumentsJSON)["a"] as? String, "b")
    }

    /// Qwen3-Coder emits the xml_function body inside `<tool_call>`, not JSON.
    func testQwenCoderXMLFunctionBody() {
        let text = """
        <tool_call>
        <function=shell>
        <parameter=command>
        ["ls", "-la"]
        </parameter>
        </function>
        </tool_call>
        """
        let r = ToolCallParser.parse(text, format: .qwenXML)
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls[0].name, "shell")
        // The JSON-array value is typed, not left as a string.
        XCTAssertEqual(json(r.toolCalls[0].argumentsJSON)["command"] as? [String], ["ls", "-la"])
    }

    /// Qwen3-Coder routinely SKIPS the opening `<tool_call>` tag — the turn starts
    /// directly with `<function=…>` and ends with a stray `</tool_call>` (observed
    /// verbatim from Qwen3-Coder-30B-A3B-Instruct-4bit-DWQ at temp 0). The parser
    /// back-off must still extract the call.
    func testQwenCoderMissingOpeningToolCallTag() {
        let text = """
        <function=shell>
        <parameter=command>
        ["ls", "-la"]
        </parameter>
        </function>
        </tool_call>
        """
        let r = ToolCallParser.parse(text, format: .qwenXML)
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls[0].name, "shell")
        XCTAssertEqual(json(r.toolCalls[0].argumentsJSON)["command"] as? [String], ["ls", "-la"])
        XCTAssertEqual(r.content, "", "stray </tool_call> must not leak into content")
    }

    /// Back-off with prose around the bare block and a truncated final block.
    func testQwenCoderBareFunctionWithProseAndTruncation() {
        let text = "I'll list the files.\n<function=shell>\n<parameter=command>\n[\"ls\"]\n</parameter>\n</function>\nDone. <function=say>\n<parameter=text>\nhi"
        let r = ToolCallParser.parse(text, format: .qwenXML)
        XCTAssertEqual(r.toolCalls.count, 2)
        XCTAssertEqual(r.toolCalls[0].name, "shell")
        XCTAssertEqual(r.toolCalls[1].name, "say")
        XCTAssertTrue(r.content.contains("I'll list the files."))
    }

    /// Plain text with no function blocks must NOT trigger the back-off.
    func testQwenPlainTextUnaffectedByBackoff() {
        let r = ToolCallParser.parse("Just an answer, no tools.", format: .qwenXML)
        XCTAssertTrue(r.toolCalls.isEmpty)
        XCTAssertEqual(r.content, "Just an answer, no tools.")
    }

    /// Prose that merely MENTIONS `<function=` (no closing tag, no parameters)
    /// must stay prose — the back-off needs call-structure evidence.
    func testQwenProseMentioningFunctionTagIsNotEaten() {
        let text = "To invoke a tool the model emits a block opening with <function=name> and then the arguments."
        let r = ToolCallParser.parse(text, format: .qwenXML)
        XCTAssertTrue(r.toolCalls.isEmpty)
        XCTAssertEqual(r.content, text)
    }

    /// Non-JSON parameter values stay plain strings.
    func testQwenCoderXMLFunctionStringValue() {
        let text = "<tool_call><function=say><parameter=text>hello world</parameter></function></tool_call>"
        let r = ToolCallParser.parse(text, format: .qwenXML)
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(json(r.toolCalls[0].argumentsJSON)["text"] as? String, "hello world")
    }

    // MARK: Mistral / Devstral

    func testMistralToolCalls() {
        let text = #"Sure.[TOOL_CALLS][{"name": "run", "arguments": {"cmd": "ls"}}]"#
        let r = ToolCallParser.parse(text, format: .mistral)
        XCTAssertEqual(r.content, "Sure.")
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls[0].name, "run")
        XCTAssertEqual(json(r.toolCalls[0].argumentsJSON)["cmd"] as? String, "ls")
    }

    // MARK: Harmony (gpt-oss)

    func testHarmonyToolCall() {
        let text = "<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>{\"city\": \"Berlin\"}<|call|>"
        let r = ToolCallParser.parse(text, format: .harmony)
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls[0].name, "get_weather")
        XCTAssertEqual(json(r.toolCalls[0].argumentsJSON)["city"] as? String, "Berlin")
    }

    func testHarmonyFinalChannelContent() {
        let text = "<|channel|>final<|message|>The answer is 42.<|end|>"
        let r = ToolCallParser.parse(text, format: .harmony)
        XCTAssertFalse(r.hasToolCalls)
        XCTAssertEqual(r.content, "The answer is 42.")
    }

    func testHarmonyCapDoesNotCrashWithCallNearStart() {
        // Call sits in the first chunk; tail is >256KB of padding. The cap trims the
        // scan target — call must still parse and no NSRange/substring crash.
        let call = "<|channel|>commentary to=functions.ping <|constrain|>json<|message|>{\"x\":1}<|call|>"
        let text = call + String(repeating: "z", count: 300 * 1024)
        let r = ToolCallParser.parse(text, format: .harmony)
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls[0].name, "ping")
    }

    // MARK: Nemotron 3

    func testNemotronToolCall() {
        let text = "<think>I should read it.</think>Reading.<toolcall>{\"name\": \"read_file\", \"arguments\": {\"path\": \"a.swift\"}}</toolcall>"
        let r = ToolCallParser.parse(text, format: .nemotron)
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls[0].name, "read_file")
        XCTAssertEqual(r.content, "Reading.")
        XCTAssertEqual(json(r.toolCalls[0].argumentsJSON)["path"] as? String, "a.swift")
    }

    func testNemotronStripsUnterminatedThink() {
        let text = "before<think>reasoning that never closes"
        let r = ToolCallParser.parse(text, format: .nemotron)
        XCTAssertFalse(r.hasToolCalls)
        XCTAssertEqual(r.content, "before")
    }

    // MARK: GLM

    func testGLMArgKeyValueCall() {
        let text = "<tool_call>get_weather\n<arg_key>city</arg_key>\n<arg_value>Berlin</arg_value>\n<arg_key>days</arg_key>\n<arg_value>3</arg_value>\n</tool_call>"
        let r = ToolCallParser.parse(text, format: .glm)
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls[0].name, "get_weather")
        let args = json(r.toolCalls[0].argumentsJSON)
        XCTAssertEqual(args["city"] as? String, "Berlin")
        XCTAssertEqual(args["days"] as? Int, 3) // JSON-typed value
    }

    func testGLMJSONCompatBody() {
        let text = #"<tool_call>{"name": "f", "arguments": {"a": "b"}}</tool_call>"#
        let r = ToolCallParser.parse(text, format: .glm)
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls[0].name, "f")
        XCTAssertEqual(json(r.toolCalls[0].argumentsJSON)["a"] as? String, "b")
    }

    // MARK: Kimi K2

    func testKimiToolCall() {
        let text = "Sure.<|tool_calls_section_begin|><|tool_call_begin|>functions.run:0<|tool_call_argument_begin|>{\"cmd\": \"ls\"}<|tool_call_end|><|tool_calls_section_end|>"
        let r = ToolCallParser.parse(text, format: .kimi)
        XCTAssertEqual(r.content, "Sure.")
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls[0].name, "run")
        XCTAssertEqual(json(r.toolCalls[0].argumentsJSON)["cmd"] as? String, "ls")
    }

    func testKimiMultipleCalls() {
        let text = "<|tool_calls_section_begin|><|tool_call_begin|>functions.a:0<|tool_call_argument_begin|>{\"x\":1}<|tool_call_end|><|tool_call_begin|>functions.b:1<|tool_call_argument_begin|>{\"y\":2}<|tool_call_end|><|tool_calls_section_end|>"
        let r = ToolCallParser.parse(text, format: .kimi)
        XCTAssertEqual(r.toolCalls.map(\.name), ["a", "b"])
    }

    // MARK: MiniMax M2

    func testMiniMaxToolCall() {
        let text = "<minimax:tool_call><invoke name=\"search\"><parameter name=\"q\">hello</parameter><parameter name=\"limit\">5</parameter></invoke></minimax:tool_call>"
        let r = ToolCallParser.parse(text, format: .minimax)
        XCTAssertEqual(r.toolCalls.count, 1)
        XCTAssertEqual(r.toolCalls[0].name, "search")
        let args = json(r.toolCalls[0].argumentsJSON)
        XCTAssertEqual(args["q"] as? String, "hello")
        XCTAssertEqual(args["limit"] as? Int, 5)
        XCTAssertTrue(r.content.isEmpty)
    }

    // MARK: Round-trip serialize (per-family)

    func testSerializeRoundTripNemotron() {
        let calls = [ParsedToolCall(id: "c", name: "f", argumentsJSON: #"{"a":1}"#)]
        let s = ToolCallParser.serializeAssistant(content: "hi", toolCalls: calls, format: .nemotron)
        let r = ToolCallParser.parse(s, format: .nemotron)
        XCTAssertEqual(r.content, "hi")
        XCTAssertEqual(r.toolCalls.first?.name, "f")
        XCTAssertEqual(json(r.toolCalls[0].argumentsJSON)["a"] as? Int, 1)
    }

    func testSerializeRoundTripGLM() {
        let calls = [ParsedToolCall(id: "c", name: "f", argumentsJSON: #"{"a":"b"}"#)]
        let s = ToolCallParser.serializeAssistant(content: "", toolCalls: calls, format: .glm)
        let r = ToolCallParser.parse(s, format: .glm)
        XCTAssertEqual(r.toolCalls.first?.name, "f")
        XCTAssertEqual(json(r.toolCalls[0].argumentsJSON)["a"] as? String, "b")
    }

    func testSerializeRoundTripKimi() {
        let calls = [ParsedToolCall(id: "c", name: "f", argumentsJSON: #"{"a":1}"#)]
        let s = ToolCallParser.serializeAssistant(content: "", toolCalls: calls, format: .kimi)
        let r = ToolCallParser.parse(s, format: .kimi)
        XCTAssertEqual(r.toolCalls.first?.name, "f")
        XCTAssertEqual(json(r.toolCalls[0].argumentsJSON)["a"] as? Int, 1)
    }

    func testSerializeRoundTripMiniMax() {
        let calls = [ParsedToolCall(id: "c", name: "f", argumentsJSON: #"{"a":"b"}"#)]
        let s = ToolCallParser.serializeAssistant(content: "", toolCalls: calls, format: .minimax)
        let r = ToolCallParser.parse(s, format: .minimax)
        XCTAssertEqual(r.toolCalls.first?.name, "f")
        XCTAssertEqual(json(r.toolCalls[0].argumentsJSON)["a"] as? String, "b")
    }

    // MARK: Round-trip serialize

    func testSerializeRoundTripQwen() {
        let calls = [ParsedToolCall(id: "call_1", name: "f", argumentsJSON: #"{"a":1}"#)]
        let serialized = ToolCallParser.serializeAssistant(content: "hi", toolCalls: calls, format: .qwenXML)
        let reparsed = ToolCallParser.parse(serialized, format: .qwenXML)
        XCTAssertEqual(reparsed.content, "hi")
        XCTAssertEqual(reparsed.toolCalls.count, 1)
        XCTAssertEqual(reparsed.toolCalls[0].name, "f")
        XCTAssertEqual(json(reparsed.toolCalls[0].argumentsJSON)["a"] as? Int, 1)
    }

    // MARK: Schema validation

    func testSchemaValidationPasses() {
        let tools = [tool(name: "read", required: ["path"], props: ["path": "string"])]
        let calls = [ParsedToolCall(id: "1", name: "read", argumentsJSON: #"{"path": "x"}"#)]
        XCTAssertTrue(SchemaValidator.validate(toolCalls: calls, against: tools).isEmpty)
    }

    func testSchemaValidationMissingRequired() {
        let tools = [tool(name: "read", required: ["path"], props: ["path": "string"])]
        let calls = [ParsedToolCall(id: "1", name: "read", argumentsJSON: "{}")]
        let errs = SchemaValidator.validate(toolCalls: calls, against: tools)
        XCTAssertEqual(errs.count, 1)
        XCTAssertTrue(errs[0].contains("missing required"))
    }

    func testSchemaValidationWrongType() {
        let tools = [tool(name: "read", required: [], props: ["count": "integer"])]
        let calls = [ParsedToolCall(id: "1", name: "read", argumentsJSON: #"{"count": "nope"}"#)]
        let errs = SchemaValidator.validate(toolCalls: calls, against: tools)
        XCTAssertEqual(errs.count, 1)
        XCTAssertTrue(errs[0].contains("should be integer"))
    }

    func testSchemaValidationUnknownTool() {
        let calls = [ParsedToolCall(id: "1", name: "ghost", argumentsJSON: "{}")]
        let errs = SchemaValidator.validate(toolCalls: calls, against: [])
        XCTAssertEqual(errs.count, 1)
        XCTAssertTrue(errs[0].contains("unknown tool"))
    }

    // MARK: Helpers

    private func json(_ s: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
    }

    private func tool(name: String, required: [String], props: [String: String]) -> [String: any Sendable] {
        var properties: [String: any Sendable] = [:]
        for (k, t) in props { properties[k] = ["type": t] }
        return [
            "type": "function",
            "function": [
                "name": name,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
    }
}

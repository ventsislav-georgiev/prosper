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

    // MARK: #893 think block on the qwenXML format (Qwen3.6 is a thinking model)

    /// Think then call: the block is not answer text, the call after it is the call.
    func testQwenThinkThenCallDropsThink() {
        let text = "<think>\nThe user wants the files listed. I will call shell.\n</think>\n\n<tool_call>\n{\"name\": \"shell\", \"arguments\": {\"command\": [\"ls\"]}}\n</tool_call>"
        let r = ToolCallParser.parse(text, format: .qwenXML)
        XCTAssertEqual(r.content, "")
        XCTAssertEqual(r.toolCalls.map(\.name), ["shell"])
        XCTAssertEqual(r.toolCalls.first?.argumentsJSON, #"{"command":["ls"]}"#)
    }

    /// A tool_call written inside the think block is the model planning, not a call; the real
    /// call after `</think>` is the only one, and the prose between is the visible text.
    func testQwenToolCallInsideThinkIsNotACall() {
        let text = "<think>\nMaybe <tool_call>\n{\"name\": \"rm\", \"arguments\": {\"path\": \"/\"}}\n</tool_call> no, read first.\n</think>\n\nReading the file.\n<tool_call>\n{\"name\": \"read_file\", \"arguments\": {\"path\": \"a.swift\"}}\n</tool_call>"
        let r = ToolCallParser.parse(text, format: .qwenXML)
        XCTAssertEqual(r.toolCalls.map(\.name), ["read_file"])
        XCTAssertEqual(r.content, "Reading the file.")
    }

    /// No closing tag: the whole output is thinking. Neither its JSON call nor a bare
    /// Qwen3-Coder function block inside it becomes a call, and none of it is answer text.
    func testQwenUnclosedThinkIsNotAnswerNorCall() {
        let jsonForm = ToolCallParser.parse("<think>\nPlan: <tool_call>\n{\"name\": \"rm\", \"arguments\": {}}\n</tool_call> then more thinking", format: .qwenXML)
        XCTAssertTrue(jsonForm.toolCalls.isEmpty)
        XCTAssertEqual(jsonForm.content, "")
        let bare = ToolCallParser.parse("<think>plan <function=rm>\n<parameter=path>\n/\n</parameter>\n</function>\n</tool_call>", format: .qwenXML)
        XCTAssertTrue(bare.toolCalls.isEmpty)
        XCTAssertEqual(bare.content, "")
    }

    /// No think at all (Qwen3-Coder): the bytes parse exactly as before #893, literal expectations.
    func testQwenCoderBytesUnchangedWithoutThink() {
        let bare = "I'll list the files.\n<function=shell>\n<parameter=command>\n[\"ls\", \"-la\"]\n</parameter>\n</function>\n</tool_call>"
        let tagged = "Listing.\n<tool_call>\n<function=shell>\n<parameter=command>\n[\"ls\"]\n</parameter>\n</function>\n</tool_call>"
        XCTAssertEqual(ToolCallParser.dropLeadingThink(bare), bare)
        XCTAssertEqual(ToolCallParser.dropLeadingThink(tagged), tagged)
        let r1 = ToolCallParser.parse(bare, format: .qwenXML)
        XCTAssertEqual(r1.content, "I'll list the files.")
        XCTAssertEqual(r1.toolCalls.map(\.name), ["shell"])
        XCTAssertEqual(r1.toolCalls.first?.argumentsJSON, #"{"command":["ls","-la"]}"#)
        let r2 = ToolCallParser.parse(tagged, format: .qwenXML)
        XCTAssertEqual(r2.content, "Listing.")
        XCTAssertEqual(r2.toolCalls.first?.argumentsJSON, #"{"command":["ls"]}"#)
    }

    /// Only a block that OPENS the output is thinking: prose about the tag, a call whose argument
    /// holds it, or a block after leading whitespace stay as they were.
    func testQwenThinkElsewhereIsText() {
        let prose = "The <think> tag wraps reasoning, so a lone <think> here is text."
        XCTAssertEqual(ToolCallParser.parse(prose, format: .qwenXML).content, prose)
        let call = ToolCallParser.parse("<tool_call>\n{\"name\": \"write\", \"arguments\": {\"text\": \"<think>\"}}\n</tool_call>", format: .qwenXML)
        XCTAssertEqual(call.toolCalls.first?.argumentsJSON, #"{"text":"<think>"}"#)
        XCTAssertEqual(ToolCallParser.parse(" <think>x</think>y", format: .qwenXML).content, "<think>x</think>y")
        // Nested opener: the first `</think>` ends the block (the stream and the grammar gate agree).
        XCTAssertEqual(ToolCallParser.parse("<think>a<think>b</think>c</think>answer", format: .qwenXML).content, "c</think>answer")
    }

    /// The think block is not replayed in history: the assistant turn re-serializes the visible text only.
    func testQwenThinkNotReplayed() {
        let text = "<think>\nread it first\n</think>\n\nReading the file.\n<tool_call>\n{\"name\": \"read_file\", \"arguments\": {\"path\": \"a.swift\"}}\n</tool_call>"
        let r = ToolCallParser.parse(text, format: .qwenXML)
        let replay = ToolCallParser.serializeAssistant(content: r.content, toolCalls: r.toolCalls, format: .qwenXML)
        XCTAssertEqual(replay, "Reading the file.\n<tool_call>\n{\"name\": \"read_file\", \"arguments\": {\"path\":\"a.swift\"}}\n</tool_call>")
    }

    /// Megabytes of think text, unclosed or with many nested openers: one forward search, the same answer.
    func testQwenThinkMegabytesParseOnce() {
        let unclosed = "<think>" + String(repeating: "<think><tool_call>{\"name\": \"rm\", \"arguments\": {}}</tool_call>", count: 20_000)
        XCTAssertGreaterThan(unclosed.utf8.count, 1_000_000)
        let r1 = ToolCallParser.parse(unclosed, format: .qwenXML)
        XCTAssertTrue(r1.toolCalls.isEmpty)
        XCTAssertEqual(r1.content, "")
        let closed = "<think>" + String(repeating: "<think>a", count: 150_000) + "</think>ok"
        XCTAssertEqual(ToolCallParser.parse(closed, format: .qwenXML).content, "ok")
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

    // MARK: Unencodable JSON (#294) — each case used to abort the process

    func testJSONTextRejectsInsteadOfRaising() {
        XCTAssertNil(ToolCallParser.jsonText(NSNull()))
        XCTAssertNil(ToolCallParser.jsonText(5))
        XCTAssertNil(ToolCallParser.jsonText(["n": -Double.infinity]))
        XCTAssertNil(ToolCallParser.jsonText(-Double.infinity, fragments: true))
        XCTAssertEqual(ToolCallParser.jsonText(5, fragments: true), "5")
        XCTAssertEqual(ToolCallParser.jsonText("x", fragments: true), "\"x\"")
        XCTAssertEqual(ToolCallParser.jsonText(["b": 1, "a": [2]], fragments: true), #"{"a":[2],"b":1}"#)
    }

    func testScalarArgumentsFallBack() {
        for (arg, expected) in [("null", "{}"), ("5", "{}"), (#""x""#, "x")] {
            let r = ToolCallParser.parse(#"<tool_call>{"name": "f", "arguments": \#(arg)}</tool_call>"#, format: .qwenXML)
            XCTAssertEqual(r.toolCalls.count, 1, arg)
            XCTAssertEqual(r.toolCalls.first?.argumentsJSON, expected, arg)
        }
    }

    func testNonFiniteParameterValueFallsBackToEmptyObject() {
        let cases: [(String, ToolCallFormat)] = [
            (#"<minimax:tool_call><invoke name="f"><parameter name="n">-1e999</parameter></invoke></minimax:tool_call>"#, .minimax),
            ("<tool_call><function=f><parameter=n>\n-1e999\n</parameter></function></tool_call>", .qwenXML),
        ]
        for (text, format) in cases {
            let r = ToolCallParser.parse(text, format: format)
            XCTAssertEqual(r.toolCalls.first?.name, "f", "\(format)")
            XCTAssertEqual(r.toolCalls.first?.argumentsJSON, "{}", "\(format)")
        }
        // stringifyValue: a -inf value re-serialized for MiniMax replay falls back to "\(v)".
        let s = ToolCallParser.serializeAssistant(
            content: "", toolCalls: [ParsedToolCall(id: "c0", name: "f", argumentsJSON: #"{"n":-1e999}"#)], format: .minimax)
        XCTAssertTrue(s.contains(#"<parameter name="n">-inf</parameter>"#), s)
    }

    /// #294 / #313: stringifyValue (via MiniMax/GLM replay) encodes non-string scalars
    /// as JSON fragments; without `fragments: true` the "\(v)" fallback gives "1" / "<null>".
    func testReplayStringifiesScalarArgumentsAsJSON() {
        let call = ParsedToolCall(id: "c0", name: "f", argumentsJSON: #"{"b":true,"n":null,"i":5,"l":[1,{"k":"v"}],"s":"x"}"#)
        let mm = ToolCallParser.serializeAssistant(content: "", toolCalls: [call], format: .minimax)
        XCTAssertTrue(mm.contains(#"<parameter name="b">true</parameter><parameter name="i">5</parameter><parameter name="l">[1,{"k":"v"}]</parameter><parameter name="n">null</parameter><parameter name="s">x</parameter>"#), mm)
        let glm = ToolCallParser.serializeAssistant(content: "", toolCalls: [call], format: .glm)
        XCTAssertTrue(glm.contains("<arg_key>b</arg_key>\n<arg_value>true</arg_value>"), glm)
        XCTAssertTrue(glm.contains("<arg_key>n</arg_key>\n<arg_value>null</arg_value>"), glm)
    }

    /// History replay (the normalizedArgs route of OpenAIChat.chatTurns /
    /// ProsperLLMServer repair loop): a poisoned stored argument passes through raw.
    func testPoisonedHistoryArgumentsReplayWithoutCrash() throws {
        let body = #"""
        {"messages": [
          {"role": "user", "content": "hi"},
          {"role": "assistant", "content": "", "tool_calls": [
            {"id": "a", "type": "function", "function": {"name": "f", "arguments": "{\"n\":-1e999}"}},
            {"id": "b", "type": "function", "function": {"name": "g", "arguments": {"n": -1e999}}}
          ]}
        ]}
        """#
        let req = try XCTUnwrap(OpenAIChatRequest(data: Data(body.utf8)))
        XCTAssertEqual(req.messages[1].toolCalls.map(\.argumentsJSON), [#"{"n":-1e999}"#, "{}"])
        let turns = req.chatTurns(format: .qwenXML)
        XCTAssertTrue(turns[1].content.contains(#"{"name": "f", "arguments": {"n":-1e999}}"#), turns[1].content)
        XCTAssertTrue(turns[1].content.contains(#"{"name": "g", "arguments": {}}"#), turns[1].content)
    }

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

// MARK: #1181 the stream and the final text agree at every chunk cut around a think tag

extension ToolCallParserTests {
    /// The qwenXML stream of `text` cut once at scalar `cut` (with `finish`, as the no-tools paths call
    /// it), one scalar per chunk, and the parser's content on the whole text.
    private func streamsAndFinal(_ text: String, cut: Int) -> (cutOnce: String, perScalar: String, final: String) {
        let scalars = text.unicodeScalars
        let at = scalars.index(scalars.startIndex, offsetBy: cut, limitedBy: scalars.endIndex) ?? scalars.endIndex
        var once = StreamSplitter(format: .qwenXML)
        let cutOnce = once.ingest(String(scalars[..<at])) + once.ingest(String(scalars[at...])) + once.finish()
        var each = StreamSplitter(format: .qwenXML)
        let perScalar = scalars.map { each.ingest(String($0)) }.joined() + each.finish()
        return (cutOnce, perScalar, ToolCallParser.parse(text, format: .qwenXML).content)
    }

    /// #1181: a combining mark (U+0301) right after "<think>" or "</think>". Both sides compare the tags
    /// by Unicode scalars: the tag is a tag, the mark is the first scalar of the text after it. Before,
    /// the parser saw ">" + mark as one Character (no tag) while a stream cut after ">" took the tag.
    func testThinkTagThenCombiningMarkStreamAgreesWithFinalAtEveryCut() {
        let cases: [(text: String, stream: String, final: String)] = [
            ("<think>\u{0301}plan</think>ok", "ok", "ok"),
            ("<think>plan</think>\u{0301}ok", "\u{0301}ok", "\u{0301}ok"),
        ]
        for c in cases {
            for cut in 0...c.text.unicodeScalars.count {
                let got = streamsAndFinal(c.text, cut: cut)
                XCTAssertEqual(got.cutOnce, c.stream, "stream cut at \(cut) of \(c.text.debugDescription)")
                XCTAssertEqual(got.perScalar, c.stream, "stream per scalar of \(c.text.debugDescription)")
                XCTAssertEqual(got.final, c.final, "final of \(c.text.debugDescription)")
            }
        }
    }

    /// #1181 (893's rule, unchanged): a think block after leading whitespace is text, in the stream and
    /// the final text alike, at every cut.
    func testThinkAfterLeadingWhitespaceIsTextAtEveryCut() {
        let text = " \n<think>plan</think>ok"
        for cut in 0...text.unicodeScalars.count {
            let got = streamsAndFinal(text, cut: cut)
            XCTAssertEqual(got.cutOnce, " \n<think>plan</think>ok", "stream cut at \(cut)")
            XCTAssertEqual(got.perScalar, " \n<think>plan</think>ok")
            XCTAssertEqual(got.final, "<think>plan</think>ok")
        }
    }

    /// #1181 (R1181-c): the tool-call markers are compared by Unicode scalars in the splitter and in parseTagged, as
    /// the think tags: a marker followed by a combining mark (U+0301) is a marker. The table: the stream's text (the
    /// same at every scalar cut, and per scalar), the parse's content and its call count, as literals. The stream's
    /// text is a scalar prefix of the content in every row (the codex path sends the rest as its last delta).
    func testToolCallMarkerThenCombiningMarkStreamAndParseAgreeAtEveryCut() {
        let json = #"{"name": "shell", "arguments": {"command": "ls"}}"#
        let coder = "\n<function=shell>\n<parameter=command>\nls\n</parameter>\n</function>\n"
        let cases: [(text: String, stream: String, content: String, calls: Int)] = [
            // The body starts with the mark: no JSON, no XML function: no call (before: all text, at most cuts).
            ("ok<tool_call>\u{0301}" + json + "</tool_call>", "ok", "ok", 0),
            // Qwen3-Coder body: the call (before: the back-off ran it too, while the stream showed the raw tag).
            ("ok<tool_call>\u{0301}" + coder + "</tool_call>", "ok", "ok", 1),
            // A mark after the closing tag: the block is whole, so the call (before: dropped as unterminated).
            ("ok<tool_call>" + json + "</tool_call>\u{0301}", "ok", "ok\u{0301}", 1),
            // Unterminated, the mark first: no call.
            ("ok<tool_call>\u{0301}" + json, "ok", "ok", 0),
            // The mark INSIDE the marker: its scalars are not there: text in both.
            ("ok<tool_call\u{0301}>" + json + "</tool_call>", "ok<tool_call\u{0301}>" + json + "</tool_call>",
             "ok<tool_call\u{0301}>" + json + "</tool_call>", 0),
            // No mark: today's call.
            ("ok<tool_call>" + json + "</tool_call>", "ok", "ok", 1),
            // R1181-n: the back-off compares "<function=" and "</function>" by scalars too, as the splitter: one call
            // whose name carries the mark (the schema check rejects it: the eighth's row below). Before: content the
            // whole text, 0 calls, and the codex tail sent the raw markup as prose.
            ("ok<function=\u{0301}shell></function>", "ok", "ok", 1),
        ]
        for c in cases {
            let parsed = ToolCallParser.parse(c.text, format: .qwenXML)
            XCTAssertEqual(parsed.content, c.content, "content of \(c.text.debugDescription)")
            XCTAssertEqual(parsed.toolCalls.count, c.calls, "calls of \(c.text.debugDescription)")
            XCTAssertTrue(parsed.content.unicodeScalars.starts(with: c.stream.unicodeScalars), c.text.debugDescription)
            for cut in 0...c.text.unicodeScalars.count {
                let got = streamsAndFinal(c.text, cut: cut)
                XCTAssertEqual(got.cutOnce, c.stream, "stream cut at \(cut) of \(c.text.debugDescription)")
                XCTAssertEqual(got.perScalar, c.stream, "stream per scalar of \(c.text.debugDescription)")
            }
        }
    }
}

// MARK: #1181 seventh dispatch: every format's markers by Unicode scalars (R1181-r5-a, R1181-k)

extension ToolCallParserTests {
    /// The `format` stream of `text` (with `finish`, as the no-tools paths call it) cut once at every scalar,
    /// then one scalar per chunk.
    private func streams(_ text: String, _ format: ToolCallFormat) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var out = (0...scalars.count).map { i -> String in
            var s = StreamSplitter(format: format)
            return s.ingest(String(String.UnicodeScalarView(scalars[..<i])))
                + s.ingest(String(String.UnicodeScalarView(scalars[i...]))) + s.finish()
        }
        var each = StreamSplitter(format: format)
        out.append(scalars.map { each.ingest(String($0)) }.joined() + each.finish())
        return out
    }

    /// #1181 (QA R1181-r5-a): for nemotron, glm, kimi and minimax "<think>" is a stream marker compared by scalars;
    /// stripThink now compares its tags by scalars too. Before: a combining mark (U+0301) after "<think>" kept the
    /// whole block in the content (the codex tail delta then sent the think text); after "</think>" the block was
    /// taken as unterminated and the answer dropped. The content never holds the think text; the stream stops at
    /// "<think>" for these formats (no leading-think phase), so it sends "" at every cut, a prefix of the content.
    func testStripThinkComparesTagsByScalarsForEveryThinkFormat() {
        let cases: [(format: ToolCallFormat, text: String, content: String)] = [
            (.nemotron, "<think>\u{0301}plan</think>answer", "answer"),
            (.nemotron, "<think>plan</think>\u{0301}answer", "\u{0301}answer"),
            (.nemotron, "<think>plan</think>answer", "answer"),
            (.glm, "<think>\u{0301}plan</think>answer", "answer"),
            (.glm, "<think>plan</think>\u{0301}answer", "\u{0301}answer"),
            (.glm, "<think>plan</think>answer", "answer"),
            (.kimi, "<think>\u{0301}plan</think>answer", "answer"),
            (.kimi, "<think>plan</think>\u{0301}answer", "\u{0301}answer"),
            (.kimi, "<think>plan</think>answer", "answer"),
            (.minimax, "<think>\u{0301}plan</think>answer", "answer"),
            (.minimax, "<think>plan</think>\u{0301}answer", "\u{0301}answer"),
            (.minimax, "<think>plan</think>answer", "answer"),
        ]
        for c in cases {
            let parsed = ToolCallParser.parse(c.text, format: c.format)
            XCTAssertEqual(parsed.content, c.content, "\(c.format) \(c.text.debugDescription)")
            XCTAssertFalse(parsed.content.contains("plan"), "\(c.format) \(c.text.debugDescription): think text")
            XCTAssertEqual(parsed.toolCalls.count, 0, "\(c.format) \(c.text.debugDescription)")
            for s in streams(c.text, c.format) { XCTAssertEqual(s, "", "\(c.format) \(c.text.debugDescription)") }
        }
    }

    /// #1181 (R1181-k): each format's marker followed by a combining mark (U+0301). The stream stops at the marker by
    /// scalars at every cut; the parse (mistral, GLM, kimi, minimax now by scalars; harmony's regex already matches code
    /// points; nemotron's parseTagged since e32706e2) gives a content the stream's text is a scalar prefix of. The
    /// Qwen3-Coder back-off by scalars since the eighth dispatch (R1181-n).
    func testEveryFormatMarkerThenCombiningMarkStreamIsAPrefixOfTheParse() {
        let json = #"{"name": "shell", "arguments": {"command": "ls"}}"#
        let harmony = "ok<|channel|>\u{0301}final<|message|>hi<|end|>"
        let bare = "ok<function=\u{0301}shell>\n<parameter=command>\nls\n</parameter>\n</function>"
        let cases: [(format: ToolCallFormat, text: String, stream: String, content: String, calls: Int)] = [
            // Before: the whole text, 0 calls. The body starts with the mark: not JSON: no call.
            (.mistral, "ok[TOOL_CALLS]\u{0301}[" + json + "]", "ok", "ok", 0),
            // Unchanged: the final channel needs "<|channel|>final" whole; no channel matched: all text.
            (.harmony, harmony, "ok", harmony, 0),
            (.nemotron, "ok<toolcall>\u{0301}" + json + "</toolcall>", "ok", "ok", 0),
            // Before: the whole text, 0 calls. The same text without the mark is a call too.
            (.glm, "ok<tool_call>\u{0301}shell<arg_key>command</arg_key><arg_value>ls</arg_value></tool_call>", "ok", "ok", 1),
            (.kimi, "ok<|tool_calls_section_begin|>\u{0301}<|tool_call_begin|>functions.shell:0<|tool_call_argument_begin|>"
                + #"{"command": "ls"}<|tool_call_end|><|tool_calls_section_end|>"#, "ok", "ok", 1),
            // Before: "ok<minimax:tool_call>" + mark (the wrapper tag was kept), 1 call.
            (.minimax, "ok<minimax:tool_call>\u{0301}<invoke name=\"shell\"><parameter name=\"command\">ls</parameter></invoke>"
                + "</minimax:tool_call>", "ok", "ok\u{0301}", 1),
            // R1181-n (eighth): the back-off by scalars: one call named "\u{0301}shell". Before: all text, 0 calls.
            (.qwenXML, bare, "ok", "ok", 1),
        ]
        for c in cases {
            let parsed = ToolCallParser.parse(c.text, format: c.format)
            XCTAssertEqual(parsed.content, c.content, "\(c.format) \(c.text.debugDescription)")
            XCTAssertEqual(parsed.toolCalls.count, c.calls, "\(c.format) \(c.text.debugDescription)")
            XCTAssertTrue(parsed.content.unicodeScalars.starts(with: c.stream.unicodeScalars), "\(c.format) \(c.text.debugDescription)")
            for s in streams(c.text, c.format) { XCTAssertEqual(s, c.stream, "\(c.format) \(c.text.debugDescription)") }
        }
    }
}

// MARK: #1181 eighth dispatch: the Qwen3-Coder back-off by Unicode scalars (R1181-n)

extension ToolCallParserTests {
    /// R1181-n: "<function=", "</function>" and "<parameter=" are compared by scalars in the back-off, as the splitter's
    /// "<function=" stop. Per marker, a combining mark (U+0301) right after it, and the same text without the mark: a
    /// call is recognised with the mark only where the same text without it is a call (the markers are ASCII: a scalar
    /// match in the marked text is a match once the mark is removed). Before, by Characters: the "<function=" and
    /// "<parameter=" rows gave 0 calls and the whole text as content; the "</function>" row gave content "ok" (the block
    /// ran to the end). A mark INSIDE the marker matches neither way. A parsed call is a value: the schema check is
    /// called as a function and rejects the marked name as an unknown tool, or the marked key as a missing argument.
    func testBackOffMarkersByScalarsRecogniseOnlyWhatTheUnmarkedTextDoes() {
        let tools = [tool(name: "shell", required: ["command"], props: ["command": "string"])]
        // (marked text, its content, its call name or nil, the schema error or "" when valid, the unmarked text)
        let cases: [(text: String, content: String, name: String?, error: String, unmarked: String)] = [
            ("ok<function=\u{0301}shell></function>", "ok", "\u{0301}shell", "unknown tool",
             "ok<function=shell></function>"),
            ("ok<function=shell>\n<parameter=command>\nls\n</parameter>\n</function>\u{0301}", "ok\u{0301}", "shell", "",
             "ok<function=shell>\n<parameter=command>\nls\n</parameter>\n</function>"),
            ("ok<function=shell><parameter=\u{0301}command>ls</parameter>", "ok", "shell", "missing required",
             "ok<function=shell><parameter=command>ls</parameter>"),
            ("ok<function\u{0301}=shell></function>", "ok<function\u{0301}=shell></function>", nil, "",
             "ok<function=shell></function>"),
        ]
        for c in cases {
            let parsed = ToolCallParser.parse(c.text, format: .qwenXML)
            let unmarked = ToolCallParser.parse(c.unmarked, format: .qwenXML)
            XCTAssertEqual(parsed.content, c.content, c.text.debugDescription)
            XCTAssertEqual(parsed.toolCalls.map(\.name), c.name.map { [$0] } ?? [], c.text.debugDescription)
            XCTAssertEqual(unmarked.toolCalls.map(\.name), ["shell"], c.unmarked.debugDescription)
            XCTAssertLessThanOrEqual(parsed.toolCalls.count, unmarked.toolCalls.count, c.text.debugDescription)
            let errors = SchemaValidator.validate(toolCalls: parsed.toolCalls, against: tools)
            if c.error.isEmpty {
                XCTAssertEqual(errors, [], c.text.debugDescription)
            } else {
                XCTAssertEqual(errors.count, 1, c.text.debugDescription)
                XCTAssertTrue(errors.first?.contains(c.error) ?? false, "\(c.text.debugDescription): \(errors)")
            }
            // The stream never shows text the parse took as a call: it is a scalar prefix of the content.
            for s in streams(c.text, .qwenXML) {
                XCTAssertTrue(parsed.content.unicodeScalars.starts(with: s.unicodeScalars), "\(c.text.debugDescription): \(s)")
            }
        }
    }
}

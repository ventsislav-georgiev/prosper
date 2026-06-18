import XCTest
@testable import ProsperApp

/// Covers the Responses-API (`POST /v1/responses`) wire reduction to the chat
/// representation + the SSE/event payload builders. codex ≥ 0.139 speaks only this
/// wire, so a regression here breaks every agent run at the first turn.
final class ResponsesRequestTests: XCTestCase {

    private func parse(_ json: String) -> ResponsesRequest? {
        ResponsesRequest(data: Data(json.utf8))
    }

    // MARK: - input → messages

    func testStringInputBecomesUserMessage() throws {
        let r = try XCTUnwrap(parse(#"{"model":"m","input":"hello"}"#))
        XCTAssertEqual(r.model, "m")
        XCTAssertEqual(r.chatRequest.messages.count, 1)
        XCTAssertEqual(r.chatRequest.messages[0].role, "user")
        XCTAssertEqual(r.chatRequest.messages[0].content, "hello")
    }

    func testInstructionsBecomeLeadingSystemMessage() throws {
        let r = try XCTUnwrap(parse(#"{"instructions":"be terse","input":"hi"}"#))
        XCTAssertEqual(r.chatRequest.messages.first?.role, "system")
        XCTAssertEqual(r.chatRequest.messages.first?.content, "be terse")
        XCTAssertEqual(r.chatRequest.messages.last?.role, "user")
    }

    func testMessageItemContentPartsAreJoined() throws {
        let json = """
        {"input":[{"type":"message","role":"user","content":[
            {"type":"input_text","text":"foo "},
            {"type":"input_text","text":"bar"}]}]}
        """
        let r = try XCTUnwrap(parse(json))
        XCTAssertEqual(r.chatRequest.messages.count, 1)
        XCTAssertEqual(r.chatRequest.messages[0].content, "foo bar")
    }

    func testFunctionCallItemBecomesAssistantToolCall() throws {
        let json = """
        {"input":[{"type":"function_call","call_id":"call_9","name":"shell",
                   "arguments":"{\\"cmd\\":\\"ls\\"}"}]}
        """
        let r = try XCTUnwrap(parse(json))
        let m = try XCTUnwrap(r.chatRequest.messages.first)
        XCTAssertEqual(m.role, "assistant")
        XCTAssertEqual(m.toolCalls.count, 1)
        XCTAssertEqual(m.toolCalls[0].id, "call_9")
        XCTAssertEqual(m.toolCalls[0].name, "shell")
        XCTAssertEqual(m.toolCalls[0].argumentsJSON, #"{"cmd":"ls"}"#)
    }

    func testFunctionCallOutputBecomesToolMessage() throws {
        let json = """
        {"input":[{"type":"function_call_output","call_id":"call_9","output":"file.txt"}]}
        """
        let r = try XCTUnwrap(parse(json))
        let m = try XCTUnwrap(r.chatRequest.messages.first)
        XCTAssertEqual(m.role, "tool")
        XCTAssertEqual(m.toolCallID, "call_9")
        XCTAssertEqual(m.content, "file.txt")
    }

    func testNonStringFunctionCallArgumentsAreReEncoded() throws {
        // codex usually sends arguments as a JSON string, but tolerate an object too.
        let json = #"{"input":[{"type":"function_call","name":"f","arguments":{"a":1}}]}"#
        let r = try XCTUnwrap(parse(json))
        XCTAssertEqual(r.chatRequest.messages.first?.toolCalls.first?.argumentsJSON, #"{"a":1}"#)
    }

    // MARK: - tools (flat → nested)

    func testFlatFunctionToolConvertedToNested() throws {
        let json = """
        {"input":"x","tools":[{"type":"function","name":"shell",
            "description":"run","parameters":{"type":"object","properties":{}}}]}
        """
        let r = try XCTUnwrap(parse(json))
        XCTAssertEqual(r.chatRequest.tools.count, 1)
        let fn = try XCTUnwrap(r.chatRequest.tools[0]["function"] as? [String: any Sendable])
        XCTAssertEqual(fn["name"] as? String, "shell")
        XCTAssertEqual(fn["description"] as? String, "run")
        XCTAssertNotNil(fn["parameters"])
    }

    func testToolChoiceNoneStripsTools() throws {
        let json = #"{"input":"x","tool_choice":"none","tools":[{"type":"function","name":"f"}]}"#
        let r = try XCTUnwrap(parse(json))
        XCTAssertTrue(r.chatRequest.tools.isEmpty)
        XCTAssertTrue(r.chatRequest.toolChoiceNone)
    }

    // MARK: - sampling params

    func testMaxOutputTokensMapsToMaxTokens() throws {
        let r = try XCTUnwrap(parse(#"{"input":"x","max_output_tokens":512,"stream":true}"#))
        XCTAssertEqual(r.chatRequest.maxTokens, 512)
        XCTAssertTrue(r.stream)
    }

    func testInvalidBodyReturnsNil() {
        XCTAssertNil(parse("not json"))
    }

    // MARK: - payload builders

    func testNonStreamingBodyHasMessageOutput() throws {
        let data = ResponsesPayload.nonStreaming(
            id: "resp_1", model: "m", content: "done", toolCalls: [],
            promptTokens: 3, completionTokens: 1)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["object"] as? String, "response")
        XCTAssertEqual(obj["status"] as? String, "completed")
        let output = try XCTUnwrap(obj["output"] as? [[String: Any]])
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0]["type"] as? String, "message")
        let content = try XCTUnwrap(output[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["text"] as? String, "done")
    }

    func testNonStreamingBodyEmitsFunctionCallItems() throws {
        let call = ParsedToolCall(id: "call_1", name: "shell", argumentsJSON: #"{"cmd":"ls"}"#)
        let data = ResponsesPayload.nonStreaming(
            id: "resp_1", model: "m", content: "", toolCalls: [call],
            promptTokens: 1, completionTokens: 1)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try XCTUnwrap(obj["output"] as? [[String: Any]])
        let fc = try XCTUnwrap(output.first { ($0["type"] as? String) == "function_call" })
        XCTAssertEqual(fc["call_id"] as? String, "call_1")
        XCTAssertEqual(fc["name"] as? String, "shell")
        XCTAssertEqual(fc["arguments"] as? String, #"{"cmd":"ls"}"#)
    }

    func testEventCarriesTypeAndSequence() throws {
        let data = ResponsesPayload.outputTextDelta(sequence: 4, itemID: "msg_1", index: 0, delta: "hi")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "response.output_text.delta")
        XCTAssertEqual(obj["sequence_number"] as? Int, 4)
        XCTAssertEqual(obj["delta"] as? String, "hi")
    }

    func testCompletedEventWrapsResponse() throws {
        let resp = ResponsesPayload.responseObject(
            id: "resp_1", model: "m", status: "completed", output: [],
            promptTokens: 2, completionTokens: 3)
        let data = ResponsesPayload.completed(sequence: 9, response: resp)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "response.completed")
        let inner = try XCTUnwrap(obj["response"] as? [String: Any])
        XCTAssertEqual(inner["status"] as? String, "completed")
        let usage = try XCTUnwrap(inner["usage"] as? [String: Any])
        XCTAssertEqual(usage["total_tokens"] as? Int, 5)
    }
}

import Foundation
import MLXLMCommon

/// Parser + payload builders for the OpenAI **Responses** API (`POST /v1/responses`).
///
/// codex ≥ 0.139 dropped `wire_api = "chat"` and speaks only the Responses wire, so
/// the agent harness now hits this endpoint. Rather than a parallel generation path,
/// a Responses request is reduced to the existing `OpenAIChatRequest` representation
/// (system/user/assistant/tool turns + nested function tools) so it reuses the chat
/// pipeline's tool-call parsing, schema validation, and repair-retry ladder. Only the
/// wire envelope differs — and that lives here.
///
/// Wire shape (the subset codex emits):
///   • `instructions`  — system prompt (→ a leading system turn).
///   • `input`         — a string, or an array of items:
///       - `message`              → role + content parts (`input_text`/`output_text`).
///       - `function_call`        → an assistant tool call (`call_id`,`name`,`arguments`).
///       - `function_call_output` → a `tool` turn carrying that call's result.
///   • `tools`         — FLAT function tools (`{type,name,description,parameters}`),
///                       unlike chat's nested `{function:{…}}`; converted on the way in.
///   • `tool_choice`, `stream`, `temperature`, `top_p`, `max_output_tokens`.
struct ResponsesRequest {
    let chatRequest: OpenAIChatRequest
    let model: String?
    let stream: Bool

    init?(data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let model = root["model"] as? String
        let stream = (root["stream"] as? Bool) ?? false
        // Sampling is the user's knob (Settings → Coding Agent), not codex's: read
        // the prefs and ignore whatever codex put in the request body.
        let temperature = Float(Preferences.agentTemperature)
        let topP = Float(Preferences.agentTopP)
        let maxTokens = (root["max_output_tokens"] as? Int)
            ?? (root["max_tokens"] as? Int) ?? 4096
        let toolChoiceNone = (root["tool_choice"] as? String) == "none"

        var messages: [OAMessage] = []
        // `instructions` is the Responses-API system prompt.
        if let instructions = root["instructions"] as? String, !instructions.isEmpty {
            messages.append(OAMessage(role: "system", content: instructions, toolCalls: [], toolCallID: nil))
        }
        messages.append(contentsOf: Self.inputMessages(root["input"]))

        // FLAT Responses tools → nested chat ToolSpec so SchemaValidator / the Jinja
        // template (which both read `function.name` / `function.parameters`) work
        // unchanged. A tool already in nested form is passed through.
        let tools: [ToolSpec]
        if toolChoiceNone {
            tools = []
        } else if let rawTools = root["tools"] as? [Any] {
            tools = rawTools.compactMap { Self.toolSpec(from: $0) }
        } else {
            tools = []
        }

        self.model = model
        self.stream = stream
        self.chatRequest = OpenAIChatRequest(
            model: model, messages: messages, tools: tools, stream: stream,
            temperature: temperature, maxTokens: maxTokens, topP: topP,
            stop: [], toolChoiceNone: toolChoiceNone
        )
    }

    // MARK: - input → messages

    private static func inputMessages(_ any: Any?) -> [OAMessage] {
        switch any {
        case let s as String:
            return [OAMessage(role: "user", content: s, toolCalls: [], toolCallID: nil)]
        case let items as [Any]:
            return items.compactMap { message(fromItem: $0) }
        default:
            return []
        }
    }

    private static func message(fromItem any: Any) -> OAMessage? {
        guard let d = any as? [String: Any] else { return nil }
        switch d["type"] as? String {
        case "function_call":
            guard let name = d["name"] as? String else { return nil }
            let callID = (d["call_id"] as? String) ?? (d["id"] as? String) ?? "call_0"
            let args = stringify(d["arguments"]) ?? "{}"
            return OAMessage(role: "assistant", content: "",
                             toolCalls: [OAToolCall(id: callID, name: name, argumentsJSON: args)],
                             toolCallID: nil)
        case "function_call_output":
            let callID = (d["call_id"] as? String) ?? (d["id"] as? String)
            let output = stringify(d["output"]) ?? ""
            return OAMessage(role: "tool", content: output, toolCalls: [], toolCallID: callID)
        case "message", nil:
            // Either an explicit message item or a bare {role, content} object.
            guard let role = d["role"] as? String else { return nil }
            return OAMessage(role: role, content: contentText(d["content"]),
                             toolCalls: [], toolCallID: nil)
        default:
            // reasoning / web_search_call / etc. — not replayable as a chat turn; skip.
            return nil
        }
    }

    /// Join the text of Responses content parts (`input_text` / `output_text`), or a
    /// bare string.
    private static func contentText(_ any: Any?) -> String {
        switch any {
        case let s as String: return s
        case let parts as [Any]:
            return parts.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
        default: return ""
        }
    }

    /// A value that may be a JSON string already, or an object/array to re-encode.
    private static func stringify(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case .some(let v):
            return (try? JSONSerialization.data(withJSONObject: v))
                .flatMap { String(data: $0, encoding: .utf8) }
        case .none: return nil
        }
    }

    // MARK: - tools

    private static func toolSpec(from any: Any) -> ToolSpec? {
        guard let d = any as? [String: Any] else { return nil }
        // Already nested ({type:"function", function:{…}}) — pass through.
        if d["function"] != nil { return OpenAIChatRequest.sendableObject(d) }
        // Flat Responses function tool → nested chat form.
        guard (d["type"] as? String) == "function", let name = d["name"] as? String else { return nil }
        var function: [String: Any] = ["name": name]
        if let desc = d["description"] as? String { function["description"] = desc }
        if let params = d["parameters"] { function["parameters"] = params }
        return OpenAIChatRequest.sendableObject(["type": "function", "function": function])
    }

    private static func float(_ any: Any?, default def: Float) -> Float {
        if let d = any as? Double { return Float(d) }
        if let i = any as? Int { return Float(i) }
        return def
    }
}

/// Builds Responses-API payloads: the non-streaming `response` object and the
/// streaming SSE event bodies. Dictionary builders + `JSONSerialization`, mirroring
/// `OpenAIChatResponse`.
///
/// codex assembles output items from `response.output_item.done` and finalizes on
/// `response.completed`; `response.output_text.delta` feeds its live display. Every
/// streamed event carries a monotonic `sequence_number` and a `type` discriminator
/// (codex deserializes the SSE `data` JSON on `type`).
enum ResponsesPayload {

    // MARK: Items

    static func messageItem(id: String, text: String, status: String = "completed") -> [String: Any] {
        [
            "type": "message", "id": id, "status": status, "role": "assistant",
            "content": [["type": "output_text", "text": text, "annotations": []] as [String: Any]],
        ]
    }

    static func functionCallItem(id: String, call: ParsedToolCall, status: String = "completed") -> [String: Any] {
        [
            "type": "function_call", "id": id, "call_id": call.id,
            "name": call.name, "arguments": call.argumentsJSON, "status": status,
        ]
    }

    /// The full `response` object (used in `response.created` minimally and in
    /// `response.completed` with the assembled output + usage).
    static func responseObject(
        id: String, model: String, status: String, output: [[String: Any]],
        promptTokens: Int, completionTokens: Int
    ) -> [String: Any] {
        [
            "id": id, "object": "response", "model": model, "status": status,
            "output": output,
            "usage": [
                "input_tokens": promptTokens, "output_tokens": completionTokens,
                "total_tokens": promptTokens + completionTokens,
            ],
        ]
    }

    // MARK: Event bodies

    static func event(_ type: String, sequence: Int, extra: [String: Any]) -> Data {
        var body: [String: Any] = ["type": type, "sequence_number": sequence]
        for (k, v) in extra { body[k] = v }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    static func created(sequence: Int, response: [String: Any]) -> Data {
        event("response.created", sequence: sequence, extra: ["response": response])
    }

    static func outputItemAdded(sequence: Int, index: Int, item: [String: Any]) -> Data {
        event("response.output_item.added", sequence: sequence, extra: ["output_index": index, "item": item])
    }

    static func outputTextDelta(sequence: Int, itemID: String, index: Int, delta: String) -> Data {
        event("response.output_text.delta", sequence: sequence,
              extra: ["item_id": itemID, "output_index": index, "content_index": 0, "delta": delta])
    }

    static func functionCallArgsDelta(sequence: Int, itemID: String, index: Int, delta: String) -> Data {
        event("response.function_call_arguments.delta", sequence: sequence,
              extra: ["item_id": itemID, "output_index": index, "delta": delta])
    }

    static func outputItemDone(sequence: Int, index: Int, item: [String: Any]) -> Data {
        event("response.output_item.done", sequence: sequence, extra: ["output_index": index, "item": item])
    }

    static func completed(sequence: Int, response: [String: Any]) -> Data {
        event("response.completed", sequence: sequence, extra: ["response": response])
    }

    static func failed(sequence: Int, message: String) -> Data {
        event("response.failed", sequence: sequence, extra: [
            "response": ["status": "failed", "error": ["message": message]] as [String: Any],
        ])
    }

    /// Non-streaming `response` body (status completed) with assembled output.
    static func nonStreaming(
        id: String, model: String, content: String, toolCalls: [ParsedToolCall],
        promptTokens: Int, completionTokens: Int
    ) -> Data {
        var output: [[String: Any]] = []
        if !content.isEmpty || toolCalls.isEmpty {
            output.append(messageItem(id: "msg_\(id)", text: content))
        }
        for (i, call) in toolCalls.enumerated() {
            output.append(functionCallItem(id: "fc_\(id)_\(i)", call: call))
        }
        let response = responseObject(
            id: id, model: model, status: "completed", output: output,
            promptTokens: promptTokens, completionTokens: completionTokens
        )
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }
}

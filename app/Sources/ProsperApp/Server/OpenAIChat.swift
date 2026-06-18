import Foundation
import MLXLMCommon

/// One tool call as it arrives in a request's assistant message history.
struct OAToolCall: Sendable, Equatable {
    let id: String
    let name: String
    let argumentsJSON: String
}

/// One OpenAI chat message (request side), flattened to the fields the agent path
/// needs. `content` is coalesced to a string (multimodal content arrays are joined
/// to their text parts; null → "").
struct OAMessage: Sendable, Equatable {
    let role: String
    let content: String
    let toolCalls: [OAToolCall]
    let toolCallID: String?
}

/// A parsed `/v1/chat/completions` request. Built from `JSONSerialization` output so
/// it tolerates the polymorphic shapes real clients send (string-or-array content,
/// string-or-object tool arguments, string-or-array stop). `Sendable` so it crosses
/// into the generation Task.
struct OpenAIChatRequest: Sendable {
    let model: String?
    let messages: [OAMessage]
    let tools: [ToolSpec]
    let stream: Bool
    let temperature: Float
    let maxTokens: Int
    let topP: Float
    let stop: [String]
    /// `tool_choice: "none"` — caller forbids tool calls this turn.
    let toolChoiceNone: Bool

    /// Memberwise init for callers that build the request from a non-chat wire
    /// format (e.g. the Responses API parser) and then reuse the chat generation
    /// pipeline (`generateValidated`, `streamCompletion`).
    init(model: String?, messages: [OAMessage], tools: [ToolSpec], stream: Bool,
         temperature: Float, maxTokens: Int, topP: Float, stop: [String],
         toolChoiceNone: Bool) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.stream = stream
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.stop = stop
        self.toolChoiceNone = toolChoiceNone
    }

    init?(data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        self.model = root["model"] as? String
        self.stream = (root["stream"] as? Bool) ?? false
        self.temperature = Self.float(root["temperature"], default: 0.7)
        self.maxTokens = (root["max_tokens"] as? Int) ?? (root["max_completion_tokens"] as? Int) ?? 4096
        self.topP = Self.float(root["top_p"], default: 1.0)

        switch root["stop"] {
        case let s as String: self.stop = [s]
        case let a as [Any]: self.stop = a.compactMap { $0 as? String }
        default: self.stop = []
        }
        self.toolChoiceNone = (root["tool_choice"] as? String) == "none"

        // Tools: pass each function-tool dict through as a Sendable ToolSpec for the
        // model's Jinja template. Strip non-function tools (unsupported).
        if self.toolChoiceNone {
            self.tools = []
        } else if let rawTools = root["tools"] as? [Any] {
            self.tools = rawTools.compactMap { t in
                guard let d = t as? [String: Any] else { return nil }
                guard (d["type"] as? String) == "function" || d["function"] != nil else { return nil }
                return Self.sendableObject(d)
            }
        } else {
            self.tools = []
        }

        let rawMessages = (root["messages"] as? [Any]) ?? []
        self.messages = rawMessages.compactMap { Self.message(from: $0) }
    }

    /// Convert to engine chat turns, re-embedding assistant tool calls into the
    /// model's native syntax so the chat template reproduces the original turn.
    func chatTurns(format: ToolCallFormat) -> [MLXEngine.ChatTurn] {
        messages.map { m in
            if m.role == "assistant", !m.toolCalls.isEmpty {
                let parsed = m.toolCalls.map { ParsedToolCall(id: $0.id, name: $0.name, argumentsJSON: $0.argumentsJSON) }
                let serialized = ToolCallParser.serializeAssistant(content: m.content, toolCalls: parsed, format: format)
                return MLXEngine.ChatTurn(role: "assistant", content: serialized)
            }
            return MLXEngine.ChatTurn(role: m.role, content: m.content)
        }
    }

    // MARK: - Parsing helpers

    private static func message(from any: Any) -> OAMessage? {
        guard let d = any as? [String: Any], let role = d["role"] as? String else { return nil }
        let content = coalesceContent(d["content"])
        var calls: [OAToolCall] = []
        if let raw = d["tool_calls"] as? [Any] {
            for t in raw {
                guard let td = t as? [String: Any],
                      let fn = td["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                let id = (td["id"] as? String) ?? "call_\(calls.count)"
                let args: String
                switch fn["arguments"] {
                case let s as String: args = s
                case let o as [String: Any]:
                    args = (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                default: args = "{}"
                }
                calls.append(OAToolCall(id: id, name: name, argumentsJSON: args))
            }
        }
        return OAMessage(role: role, content: content, toolCalls: calls, toolCallID: d["tool_call_id"] as? String)
    }

    /// content may be a string, null, or an array of `{type:"text",text:…}` parts.
    private static func coalesceContent(_ any: Any?) -> String {
        switch any {
        case let s as String: return s
        case let parts as [Any]:
            return parts.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
        default: return ""
        }
    }

    private static func float(_ any: Any?, default def: Float) -> Float {
        if let d = any as? Double { return Float(d) }
        if let i = any as? Int { return Float(i) }
        return def
    }

    /// Recursively rebuild a JSON value from `JSONSerialization` output into pure
    /// Swift `Sendable` types (`JSONSerialization` returns NS-bridged reference
    /// types that are not statically `Sendable`).
    static func sendableValue(_ any: Any) -> any Sendable {
        switch any {
        case let d as [String: Any]: return sendableObject(d)
        case let a as [Any]: return a.map { sendableValue($0) } as [any Sendable]
        case let s as String: return s
        case let b as Bool: return b
        case let i as Int: return i
        case let d as Double: return d
        case let n as NSNumber: return n.doubleValue
        default: return String(describing: any)
        }
    }

    static func sendableObject(_ d: [String: Any]) -> [String: any Sendable] {
        var out: [String: any Sendable] = [:]
        for (k, v) in d { out[k] = sendableValue(v) }
        return out
    }
}

/// Builds OpenAI-shaped response payloads (non-streaming body + streaming SSE
/// chunks). Kept as dictionary builders + `JSONSerialization` to mirror the request
/// parser and avoid a parallel set of Codable types.
enum OpenAIChatResponse {
    static func nonStreaming(
        id: String, model: String, content: String, toolCalls: [ParsedToolCall],
        promptTokens: Int, completionTokens: Int
    ) -> Data {
        var message: [String: Any] = ["role": "assistant"]
        message["content"] = content.isEmpty && !toolCalls.isEmpty ? NSNull() : content
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls.enumerated().map { i, tc in
                ["id": tc.id, "type": "function", "index": i,
                 "function": ["name": tc.name, "arguments": tc.argumentsJSON]] as [String: Any]
            }
        }
        let body: [String: Any] = [
            "id": id, "object": "chat.completion", "model": model,
            "choices": [[
                "index": 0, "message": message,
                "finish_reason": toolCalls.isEmpty ? "stop" : "tool_calls",
            ] as [String: Any]],
            "usage": [
                "prompt_tokens": promptTokens, "completion_tokens": completionTokens,
                "total_tokens": promptTokens + completionTokens,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// A streaming `chat.completion.chunk` carrying a content delta.
    static func contentChunk(id: String, model: String, delta: String) -> Data {
        chunk(id: id, model: model, delta: ["content": delta], finish: nil)
    }

    /// A chunk carrying the full set of tool calls (emitted once at end, before the
    /// finish chunk — the server buffers tool calls since they are parsed whole).
    static func toolCallsChunk(id: String, model: String, toolCalls: [ParsedToolCall]) -> Data {
        let tc = toolCalls.enumerated().map { i, t in
            ["index": i, "id": t.id, "type": "function",
             "function": ["name": t.name, "arguments": t.argumentsJSON]] as [String: Any]
        }
        return chunk(id: id, model: model, delta: ["tool_calls": tc], finish: nil)
    }

    static func finishChunk(id: String, model: String, reason: String) -> Data {
        chunk(id: id, model: model, delta: [:], finish: reason)
    }

    private static func chunk(id: String, model: String, delta: [String: Any], finish: String?) -> Data {
        let body: [String: Any] = [
            "id": id, "object": "chat.completion.chunk", "model": model,
            "choices": [[
                "index": 0, "delta": delta,
                "finish_reason": finish as Any? ?? NSNull(),
            ] as [String: Any]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}

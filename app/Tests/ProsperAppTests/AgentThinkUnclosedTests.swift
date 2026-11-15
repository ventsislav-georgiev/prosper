import MLXLMCommon   // ToolSpec, as in AgentModelReadOnceTests (a type only: no model is loaded)
import XCTest
import os
@testable import ProsperApp

/// #1181 item 2: a turn whose output ends inside its leading think block (the token budget reached, or the block never
/// closed) has no answer and no call. Before, the server sent nothing (the codex path: a Responses stream with no output
/// item) and the agent window showed only "Finished in ...". Now every path answers the one fixed line, in the stream and
/// the final text alike; every other turn is unchanged. No model is loaded: a fake engine through the server's acquire
/// seam (as AgentModelReadOnceTests), the in-process server on a loopback port 0; no defaults are written (the model id
/// is the catalog's own first qwenXML row, so the format needs no custom model).
final class AgentThinkUnclosedTests: XCTestCase {

    private let notice = StreamSplitter.unclosedThinkNotice

    /// Yields the chunks the row last set (one list per request; the server runs one request at a time).
    private final class FakeChatEngine: AgentChatEngine {
        let chunks: OSAllocatedUnfairLock<[String]>
        init(chunks: OSAllocatedUnfairLock<[String]>) { self.chunks = chunks }
        nonisolated func generateChat(
            messages: [MLXEngine.ChatTurn], tools: [ToolSpec], maxTokens: Int,
            temperature: Float, topP: Float, stop: [String]
        ) -> AsyncThrowingStream<String, Error> {
            let list = chunks.withLock { $0 }
            return AsyncThrowingStream { c in for s in list { c.yield(s) }; c.finish() }
        }
        func unload() async {}
    }

    /// One request shape: the wire, streamed or not, with the shell tool or none.
    private struct Path: CustomStringConvertible {
        let wire: String, stream: Bool, tools: Bool
        var description: String { "\(wire) stream=\(stream) tools=\(tools)" }
    }
    /// The four paths, the stream ones with and without tools (the splitter only runs live without tools on the chat
    /// wire, and with tools on the Responses wire too: codex always sends tools).
    private let paths = [
        Path(wire: "chat/completions", stream: false, tools: true),
        Path(wire: "chat/completions", stream: true, tools: true),
        Path(wire: "chat/completions", stream: true, tools: false),
        Path(wire: "responses", stream: false, tools: true),
        Path(wire: "responses", stream: true, tools: true),
        Path(wire: "responses", stream: true, tools: false),
    ]

    /// What a client gets: the streamed deltas joined (stream paths), the final answer text, the tool calls, and on the
    /// Responses wire the number of message items in the final output.
    private struct Answer { var deltas = "", final = "", calls = 0, messageItems = 0 }

    private static func json(_ s: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    private static func messageText(_ item: [String: Any]) -> String {
        ((item["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
    }

    private static func read(_ body: String, _ p: Path) -> Answer {
        var a = Answer()
        func takeOutput(_ output: [[String: Any]]) {
            for item in output {
                if item["type"] as? String == "message" { a.messageItems += 1; a.final += messageText(item) }
                if item["type"] as? String == "function_call" { a.calls += 1 }
            }
        }
        guard p.stream else {
            guard let obj = json(Substring(body)) else { return a }
            if p.wire == "responses" {
                takeOutput(obj["output"] as? [[String: Any]] ?? [])
            } else {
                let msg = (obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
                a.final = msg?["content"] as? String ?? ""
                a.calls = (msg?["tool_calls"] as? [Any])?.count ?? 0
            }
            return a
        }
        for line in body.split(separator: "\n") where line.hasPrefix("data: {") {
            guard let obj = json(line.dropFirst(6)) else { continue }
            if p.wire == "responses" {
                switch obj["type"] as? String {
                case "response.output_text.delta": a.deltas += obj["delta"] as? String ?? ""
                case "response.completed":
                    takeOutput((obj["response"] as? [String: Any])?["output"] as? [[String: Any]] ?? [])
                default: break
                }
            } else {
                let delta = (obj["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
                a.deltas += delta?["content"] as? String ?? ""
                a.calls += (delta?["tool_calls"] as? [Any])?.count ?? 0
            }
        }
        if p.wire != "responses" { a.final = a.deltas }   // the chat stream has no final message
        return a
    }

    /// Runs `body` with the server up on a loopback port 0 and the acquire seam on the fake engine; both restored.
    private func withServer(_ body: (_ ask: (Path, [String]) async throws -> (Answer, String)) async throws -> Void) async throws {
        let id = try XCTUnwrap(AgentModelRegistry.models.first { $0.toolFormat == .qwenXML }?.id)
        XCTAssertEqual(AgentModelRegistry.toolFormat(for: id), .qwenXML)
        let chunks = OSAllocatedUnfairLock<[String]>(initialState: [])
        let server = ProsperLLMServer.shared
        let savedAcquire = server.acquireAgent
        defer { server.acquireAgent = savedAcquire; server.stop() }
        let engine = FakeChatEngine(chunks: chunks)
        server.acquireAgent = { (engine: engine, modelId: id) }
        let (port, token) = try server.start()
        let params = #"{"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}"#
        try await body { p, list in
            chunks.withLock { $0 = list }
            let tools: String
            switch (p.tools, p.wire) {
            case (false, _): tools = ""
            case (true, "responses"): tools = #", "tools": [{"type": "function", "name": "shell", "parameters": "# + params + "}]"
            default: tools = #", "tools": [{"type": "function", "function": {"name": "shell", "parameters": "# + params + "}}]"
            }
            let input = p.wire == "responses" ? #""input": "list the files""#
                : #""messages": [{"role": "user", "content": "list the files"}]"#
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/\(p.wire)")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 30
            req.httpBody = Data(("{" + input + #", "stream": "# + (p.stream ? "true" : "false") + tools + "}").utf8)
            guard p.stream else {
                let (data, _) = try await URLSession.shared.data(for: req)
                let text = String(decoding: data, as: UTF8.self)
                return (Self.read(text, p), text)
            }
            // The SSE reply is keep-alive with no length: read lines up to the server's last frame, then cancel.
            let (bytes, _) = try await URLSession.shared.bytes(for: req)
            defer { bytes.task.cancel() }
            var lines: [String] = []
            for try await line in bytes.lines {
                lines.append(line)
                if line == "data: [DONE]" { break }
            }
            let text = lines.joined(separator: "\n")
            return (Self.read(text, p), text)
        }
    }

    // MARK: Rows on the splitter and the rule alone (no server)

    /// The rule on a whole output: only a leading think block that never closes, by scalars, qwenXML/hermesJSON only.
    func testEndsInThinkOnlyForAnUnclosedLeadingBlock() {
        for text in ["<think>", "<think>plan", "<think>plan</think", "<think>\u{0301}plan", "<think>plan <tool_call>{}"] {
            XCTAssertTrue(StreamSplitter.endsInThink(text, format: .qwenXML), text)
            XCTAssertTrue(StreamSplitter.endsInThink(text, format: .hermesJSON), text)
            XCTAssertFalse(StreamSplitter.endsInThink(text, format: .mistral), text)
        }
        for text in ["", "  ", "ok", "<think>plan</think>", "<think>plan</think>ok", " <think>plan", "x<think>plan", "<thin"] {
            XCTAssertFalse(StreamSplitter.endsInThink(text, format: .qwenXML), text)
        }
        XCTAssertFalse(notice.isEmpty)
        XCTAssertTrue(notice.unicodeScalars.allSatisfy { $0.isASCII }, "a fixed plain line")
    }

    /// The splitter ends in its think phase exactly when the whole text ends inside the block, at every scalar cut and
    /// one scalar per chunk, and never streams any of it.
    func testSplitterEndedInThinkAgreesWithTheRuleAtEveryCut() {
        for text in ["<think>plan</think", "<think>plan</think>ok", "ok", ""] {
            let scalars = Array(text.unicodeScalars)
            var cuts = (0...scalars.count).map { i in
                [String(String.UnicodeScalarView(scalars[..<i])), String(String.UnicodeScalarView(scalars[i...]))]
            }
            cuts.append(scalars.map { String($0) })
            for chunks in cuts {
                var s = StreamSplitter(format: .qwenXML)
                let shown = chunks.map { s.ingest($0) }.joined() + s.finish()
                XCTAssertEqual(s.endedInThink, StreamSplitter.endsInThink(text, format: .qwenXML), "\(chunks)")
                if s.endedInThink { XCTAssertEqual(shown, "", "think text is never shown: \(chunks)") }
            }
        }
    }

    // MARK: Rows through the server (the line is added by the server's paths, not by the splitter)

    /// THE CASE: the output ends inside the think block (a call written in it is planning, not a call). Every path
    /// answers the fixed line, once, with no call; the stream's deltas joined are the final text. Before #1181: "" on
    /// every path, and no output item at all on the codex path (responses, stream, tools).
    func testUnclosedThinkAnswersTheLineOnEveryPath() async throws {
        try await withServer { ask in
            for p in paths {
                let (a, text) = try await ask(p, ["<think>plan: ", #"<tool_call>{"name": "shell", "arguments": {"command": "ls"}}</tool_call>"#])
                XCTAssertEqual(a.final, notice, "\(p): \(text)")
                XCTAssertEqual(a.calls, 0, "\(p): \(text)")
                if p.stream { XCTAssertEqual(a.deltas, notice, "\(p): the deltas joined are the final text. \(text)") }
                if p.wire == "responses" { XCTAssertEqual(a.messageItems, 1, "\(p): \(text)") }
                XCTAssertFalse(text.contains("plan"), "\(p): think text is never shown. \(text)")
            }
        }
    }

    /// The unclosed output cut at every scalar position (and one scalar per chunk) gives the line once on every stream
    /// path: never twice, never a part of it.
    func testUnclosedThinkCutAtEveryScalarGivesTheLineOnce() async throws {
        let scalars = Array("<think>a</think".unicodeScalars)
        var cuts = (0...scalars.count).map { i in
            [String(String.UnicodeScalarView(scalars[..<i])), String(String.UnicodeScalarView(scalars[i...]))]
        }
        cuts.append(scalars.map { String($0) })
        try await withServer { ask in
            for p in paths where p.stream {
                for chunks in cuts {
                    let (a, text) = try await ask(p, chunks)
                    XCTAssertEqual(a.deltas, notice, "\(p) \(chunks): \(text)")
                    XCTAssertEqual(a.final, notice, "\(p) \(chunks): \(text)")
                }
            }
        }
    }

    /// Every other turn is today's: a closed block then text, an empty answer with no think block, a think block then a
    /// tool call. The line never appears.
    func testOtherTurnsAreUnchanged() async throws {
        let call = #"<tool_call>{"name": "shell", "arguments": {"command": "ls"}}</tool_call>"#
        try await withServer { ask in
            for p in paths {
                // A closed block, then the answer: the answer only. Longer than the marker guard (10 scalars): on the
                // codex path an answer that short streams no delta today (the guard's tail is never flushed there).
                let answer = "the files are listed above"
                var (a, text) = try await ask(p, ["<think>plan</think>", "\n\n" + answer])
                XCTAssertEqual(a.final, answer, "\(p): \(text)")
                if p.stream { XCTAssertEqual(a.deltas, answer, "\(p): \(text)") }
                XCTAssertEqual(a.calls, 0, "\(p): \(text)")
                XCTAssertFalse(text.contains(notice), "\(p): \(text)")
                // An honest empty answer, no think block: still empty; on the codex path still no output item.
                (a, text) = try await ask(p, [""])
                XCTAssertEqual(a.final, "", "\(p): \(text)")
                XCTAssertEqual(a.deltas, "", "\(p): \(text)")
                XCTAssertEqual(a.calls, 0, "\(p): \(text)")
                if p.wire == "responses" {
                    XCTAssertEqual(a.messageItems, p.stream && p.tools ? 0 : 1, "\(p): today's shape. \(text)")
                }
                XCTAssertFalse(text.contains(notice), "\(p): \(text)")
                // A closed block, then a call: the call, no text (with tools; without tools the call is never parsed).
                guard p.tools else { continue }
                (a, text) = try await ask(p, ["<think>plan</think>\n", call])
                XCTAssertEqual(a.calls, 1, "\(p): \(text)")
                XCTAssertEqual(a.final, "", "\(p): \(text)")
                XCTAssertFalse(text.contains(notice), "\(p): \(text)")
            }
        }
    }
}

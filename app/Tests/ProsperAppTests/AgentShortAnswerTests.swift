import MLXLMCommon   // ToolSpec, as in AgentModelReadOnceTests (a type only: no model is loaded)
import XCTest
import os
@testable import ProsperApp

/// #1181 (R1181-e, R1181-c). An answer of 10 characters or fewer ("Done.") streamed NO delta on the codex path (the
/// Responses wire, streamed, with tools): the marker guard held it and nothing flushed it there, and the agent window
/// shows assistant text from deltas only. Now on every stream path the deltas joined equal the final text, however
/// short. And the tool-call markers are compared by Unicode scalars in the stream and the parse alike, so a marker
/// followed by a combining mark gives one answer on the wire at every chunk cut. No model is loaded: a fake engine
/// through the server's acquire seam, the in-process server on a loopback port 0; no defaults are written (the model
/// id is the catalog's own first qwenXML row, so the format needs no custom model). No tool call is run: the rows
/// read the wire only. The helpers are AgentThinkUnclosedTests' (copied, that file is not edited).
final class AgentShortAnswerTests: XCTestCase {

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
        var isCodex: Bool { wire == "responses" && stream && tools }
    }
    private let paths = [
        Path(wire: "chat/completions", stream: false, tools: true),
        Path(wire: "chat/completions", stream: true, tools: true),
        Path(wire: "chat/completions", stream: true, tools: false),
        Path(wire: "responses", stream: false, tools: true),
        Path(wire: "responses", stream: true, tools: true),
        Path(wire: "responses", stream: true, tools: false),
    ]

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

    /// `text` in two chunks cut at every scalar position, and one scalar per chunk.
    private static func cuts(_ text: String) -> [[String]] {
        let scalars = Array(text.unicodeScalars)
        var all = (0...scalars.count).map { i in
            [String(String.UnicodeScalarView(scalars[..<i])), String(String.UnicodeScalarView(scalars[i...]))]
        }
        all.append(scalars.map { String($0) })
        return all
    }

    private static let call = #"<tool_call>{"name": "shell", "arguments": {"command": "ls"}}</tool_call>"#

    // MARK: R1181-e: a short answer

    /// THE TABLE (no think block, the answer as one chunk). Before #1181 the codex path (responses, stream, tools) sent
    /// deltas "" for the answers of 1, 5 and 10 characters (the 10-character marker guard held them and nothing flushed
    /// it there) while its final text was the answer; every other cell was already deltas == final == the answer.
    /// After: every cell, the codex column included.
    func testShortAnswersStreamTheirTextOnEveryPath() async throws {
        let table: [(answer: String, length: Int, deltas: String, final: String)] = [
            ("k", 1, "k", "k"),
            ("Done.", 5, "Done.", "Done."),
            ("Done, yes.", 10, "Done, yes.", "Done, yes."),
            ("Done, yes!!", 11, "Done, yes!!", "Done, yes!!"),
            ("The files are listed above now", 30, "The files are listed above now", "The files are listed above now"),
        ]
        try await withServer { ask in
            for row in table {
                XCTAssertEqual(row.answer.count, row.length)
                for p in paths {
                    let (a, text) = try await ask(p, [row.answer])
                    XCTAssertEqual(a.final, row.final, "\(p): \(text)")
                    if p.stream { XCTAssertEqual(a.deltas, row.deltas, "\(p): the deltas joined are the final text. \(text)") }
                    XCTAssertEqual(a.calls, 0, "\(p): \(text)")
                    if p.wire == "responses" { XCTAssertEqual(a.messageItems, 1, "\(p): \(text)") }
                }
            }
        }
    }

    /// A short answer (and one just past the guard) cut at every scalar: the same joined deltas on every stream path,
    /// never twice, never a part.
    func testShortAnswerCutAtEveryScalarGivesTheSameDeltas() async throws {
        try await withServer { ask in
            for answer in ["Done.", "Done, yes!!"] {
                for p in paths where p.stream {
                    for chunks in Self.cuts(answer) {
                        let (a, text) = try await ask(p, chunks)
                        XCTAssertEqual(a.deltas, answer, "\(p) \(chunks): \(text)")
                        XCTAssertEqual(a.final, answer, "\(p) \(chunks): \(text)")
                    }
                }
            }
        }
    }

    /// A closed think block, then a short answer: the answer only, in the deltas and the final text; the think text is
    /// never sent (the flushed suffix is the parsed answer, not the raw output).
    func testClosedThinkThenShortAnswer() async throws {
        try await withServer { ask in
            for p in paths {
                for chunks in [["<think>plan</think>", "\n\nok"]] + (p.stream ? Self.cuts("<think>plan</think>ok") : []) {
                    let (a, text) = try await ask(p, chunks)
                    XCTAssertEqual(a.final, "ok", "\(p) \(chunks): \(text)")
                    if p.stream { XCTAssertEqual(a.deltas, "ok", "\(p) \(chunks): \(text)") }
                    XCTAssertFalse(text.contains("plan"), "\(p) \(chunks): think text is never sent. \(text)")
                    XCTAssertFalse(text.contains(StreamSplitter.unclosedThinkNotice), "\(p) \(chunks): \(text)")
                }
            }
        }
    }

    /// A short answer then a tool call (with tools): the text once, the call once. A call and no text: still no text
    /// delta and, on the codex path, still no message item.
    func testShortAnswerThenToolCallSendsTheTextOnceAndTheCallOnce() async throws {
        try await withServer { ask in
            for p in paths where p.tools {
                for chunks in [["ok", Self.call]] + (p.isCodex ? Self.cuts("ok" + Self.call) : []) {
                    let (a, text) = try await ask(p, chunks)
                    XCTAssertEqual(a.final, "ok", "\(p) \(chunks): \(text)")
                    if p.stream { XCTAssertEqual(a.deltas, "ok", "\(p) \(chunks): \(text)") }
                    XCTAssertEqual(a.calls, 1, "\(p) \(chunks): \(text)")
                    if p.wire == "responses" { XCTAssertEqual(a.messageItems, 1, "\(p) \(chunks): \(text)") }
                }
                let (a, text) = try await ask(p, [Self.call])
                XCTAssertEqual(a.calls, 1, "\(p): \(text)")
                XCTAssertEqual(a.final, "", "\(p): \(text)")
                XCTAssertEqual(a.deltas, "", "\(p): \(text)")
                if p.isCodex {
                    XCTAssertEqual(a.messageItems, 0, "\(p): a call and no text has no message item. \(text)")
                    XCTAssertFalse(text.contains("response.output_text.delta"), "\(p): no text delta. \(text)")
                }
            }
        }
    }

    // MARK: R1181-c: a tool-call marker followed by a combining mark (U+0301), on the wire

    /// One answer on every stream path at every scalar cut: the deltas joined are the final text, and the call count
    /// is the parse's. Before #1181 the stream compared the markers by Characters: a cut right after ">" stopped the
    /// stream while the parse (the whole text) saw no tag, and for the Qwen3-Coder body the stream showed the raw tag
    /// while the parse ran the call.
    func testMarkerThenCombiningMarkGivesOneAnswerOnTheWire() async throws {
        let json = #"{"name": "shell", "arguments": {"command": "ls"}}"#
        let coder = "\n<function=shell>\n<parameter=command>\nls\n</parameter>\n</function>\n"
        // (text, the final text, calls with tools, the stream paths it runs on)
        let cases: [(text: String, final: String, calls: Int, toolsOnly: Bool)] = [
            ("ok<tool_call>\u{0301}" + json + "</tool_call>", "ok", 0, false),
            ("ok<tool_call>\u{0301}" + coder + "</tool_call>", "ok", 1, false),
            // A mark after the closing tag: the call is whole; the mark is the text after it. Without tools the
            // stream stops at the call and never sends text after it (as for any text after a call): tools only.
            ("ok<tool_call>" + json + "</tool_call>\u{0301}", "ok\u{0301}", 1, true),
        ]
        try await withServer { ask in
            for c in cases {
                for p in paths where p.stream && (p.tools || !c.toolsOnly) {
                    for chunks in Self.cuts(c.text) {
                        let (a, text) = try await ask(p, chunks)
                        XCTAssertEqual(a.deltas, c.final, "\(p) \(chunks): \(text)")
                        XCTAssertEqual(a.final, c.final, "\(p) \(chunks): \(text)")
                        XCTAssertEqual(a.calls, p.tools ? c.calls : 0, "\(p) \(chunks): \(text)")
                    }
                }
            }
        }
    }
}

// MARK: #1181 seventh dispatch: no think text in the tail delta for the other think formats (QA R1181-r5-a); a long
// answer with leading whitespace keeps its last characters on the codex path (R1181-j)

extension AgentShortAnswerTests {
    /// Made-up custom model id (no catalog row has a non-Qwen format); its format is set per case in the scratch
    /// XCTestDefaults store (Preferences.defaults under XCTest), every key it writes saved and restored.
    private static let customId = "example-model-b"

    /// QA R1181-r5-a on the wire: nemotron, glm, kimi, minimax (a made-up custom row of each format; the catalog has
    /// none). A combining mark (U+0301) after "<think>" or after "</think>": before, the parse kept the think block (the
    /// codex tail delta sent it) or dropped the answer. Now no think text in any delta or final text, on the six paths,
    /// at every scalar cut on the codex path. The stream stops at "<think>" for these formats (a stream marker), so the
    /// two no-tools stream paths send no delta (as before); the codex path sends the parsed answer as its one delta.
    func testThinkFormatsSendNoThinkTextInTheTailDelta() async throws {
        let d = Preferences.defaults, keys = ["customAgentModelsV1", "modelLabelOverridesV1"]
        let saved = keys.map { d.object(forKey: $0) }
        let savedGB = AgentModelRegistry.physicalMemoryGB
        defer {
            for (k, v) in zip(keys, saved) { d.set(v, forKey: k) }
            AgentModelRegistry.physicalMemoryGB = savedGB
        }
        AgentModelRegistry.physicalMemoryGB = 64
        let cases: [(text: String, answer: String)] = [
            ("<think>\u{0301}plan</think>answer", "answer"),
            ("<think>plan</think>\u{0301}answer", "\u{0301}answer"),
            ("<think>plan</think>answer", "answer"),
        ]
        try await withServer { ask in
            // The fake engine as withServer set it, reported as the custom model (withServer restores the seam).
            let server = ProsperLLMServer.shared, inner = server.acquireAgent, id = Self.customId
            server.acquireAgent = { let r = try await inner(); return (engine: r.engine, modelId: id) }
            for format in [ToolCallFormat.nemotron, .glm, .kimi, .minimax] {
                CustomModelStore.upsert(CustomAgentModel(id: Self.customId, label: "B", sizeBytes: 0, note: "", toolFormat: format))
                XCTAssertEqual(AgentModelRegistry.toolFormat(for: Self.customId), format)
                for c in cases {
                    for p in paths {
                        for chunks in [[c.text]] + (p.isCodex ? Self.cuts(c.text) : []) {
                            let (a, text) = try await ask(p, chunks)
                            let where_ = "\(format) \(p) \(chunks): \(text)"
                            XCTAssertFalse(text.contains("plan"), "think text is never sent. \(where_)")
                            XCTAssertEqual(a.calls, 0, where_)
                            // The no-tools stream paths stop at "<think>": no delta; the chat stream has no final.
                            let streamsNothing = p.stream && !p.tools
                            if p.stream { XCTAssertEqual(a.deltas, streamsNothing ? "" : c.answer, where_) }
                            XCTAssertEqual(a.final, p.wire == "chat/completions" && streamsNothing ? "" : c.answer, where_)
                        }
                    }
                }
            }
        }
    }

    /// R1181-j: an answer over 10 characters that starts with whitespace, no think block. Before, on the codex path
    /// (responses, stream, tools) the stream sent the whitespace and all but the last 10 characters, the parse trimmed
    /// the whitespace, the tail compare failed and the last 10 characters never went out ("\nThe files are listed").
    /// Now the tail compares past leading whitespace: the deltas joined are the whitespace then the whole answer; only
    /// that cell changes. The other cells, as before: the chat stream with tools sends the trimmed parse; the no-tools
    /// stream paths send the whitespace too (their final texts are trimmed, as every parse is).
    func testLeadingWhitespaceAnswerKeepsItsTailOnEveryPath() async throws {
        try await withServer { ask in
            for lead in ["\n", "  ", "\n\n"] {
                for answer in ["Done, yes!!", "The files are listed above now"] {
                    let text = lead + answer
                    for p in paths {
                        for chunks in [[text]] + (p.stream ? Self.cuts(text) : []) {
                            let (a, body) = try await ask(p, chunks)
                            let where_ = "\(p) \(chunks): \(body)"
                            let raw = p.stream && !(p.wire == "chat/completions" && p.tools)
                            if p.stream { XCTAssertEqual(a.deltas, raw ? text : answer, where_) }
                            XCTAssertEqual(a.final, p.wire == "chat/completions" && raw ? text : answer, where_)
                            XCTAssertEqual(a.calls, 0, where_)
                            if p.wire == "responses" { XCTAssertEqual(a.messageItems, 1, where_) }
                        }
                    }
                }
            }
        }
    }
}

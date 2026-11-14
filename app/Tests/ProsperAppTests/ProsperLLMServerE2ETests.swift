import XCTest
@testable import ProsperApp

/// End-to-end test of `ProsperLLMServer` over a real loopback socket — the seam
/// between the Codex harness and the in-process MLX engine. Exercises the HTTP/1.1
/// transport, bearer auth, and the unauthenticated liveness route WITHOUT loading
/// a model (so it runs in CI): `/health` and `/v1/models` need no inference.
final class ProsperLLMServerE2ETests: XCTestCase {

    private func get(_ url: String, token: String?) async throws -> (status: Int, body: String) {
        var req = URLRequest(url: URL(string: url)!)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 5
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        return (code, String(data: data, encoding: .utf8) ?? "")
    }

    func testServerBootsHealthAndAuth() async throws {
        let (port, token) = try ProsperLLMServer.shared.start()
        defer { ProsperLLMServer.shared.stop() }
        XCTAssertGreaterThan(port, 0)
        XCTAssertFalse(token.isEmpty)
        let base = "http://127.0.0.1:\(port)"

        // /health is unauthenticated liveness.
        let health = try await get("\(base)/health", token: nil)
        XCTAssertEqual(health.status, 200)
        XCTAssertTrue(health.body.contains("ok"), "health body: \(health.body)")

        // /v1/models requires the bearer token.
        let unauth = try await get("\(base)/v1/models", token: nil)
        XCTAssertEqual(unauth.status, 401, "missing token must be rejected")

        let wrong = try await get("\(base)/v1/models", token: "not-the-token")
        XCTAssertEqual(wrong.status, 401, "wrong token must be rejected")

        // With the minted token, /v1/models advertises the resident agent model.
        let ok = try await get("\(base)/v1/models", token: token)
        XCTAssertEqual(ok.status, 200)
        // JSONSerialization escapes "/" as "\/"; un-escape before comparing.
        let body = ok.body.replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(body.contains(Preferences.agentModel),
                      "models body should advertise \(Preferences.agentModel); got \(ok.body)")
    }

    func testStartIsIdempotent() throws {
        let first = try ProsperLLMServer.shared.start()
        defer { ProsperLLMServer.shared.stop() }
        let second = try ProsperLLMServer.shared.start()
        XCTAssertEqual(first.port, second.port, "start() must reuse the bound port")
        XCTAssertEqual(first.token, second.token, "start() must reuse the minted token")
    }

    // MARK: #893 stream markers: a think block that opens the output never streams (no socket, no model)

    /// The deltas `chunks` stream as through the format's splitter; `finish` as the no-tools paths
    /// call it (the tools paths never do).
    private func streamed(_ chunks: [String], _ format: ToolCallFormat = .qwenXML, finish: Bool = true) -> String {
        var splitter = StreamSplitter(format: format)
        return chunks.map { splitter.ingest($0) }.joined() + (finish ? splitter.finish() : "")
    }

    /// One rule for the stream and the final text: what streamed is what the parsed message shows.
    private func assertStreamMatchesFinal(_ chunks: [String], file: StaticString = #filePath, line: UInt = #line) {
        let final = ToolCallParser.parse(chunks.joined(), format: .qwenXML).content
        XCTAssertEqual(streamed(chunks).trimmingCharacters(in: .whitespacesAndNewlines), final, file: file, line: line)
    }

    /// Think then call: nothing streams, the final message is empty too.
    func testStreamQwenThinkThenCallShowsNoThink() {
        let chunks = ["<think>", "\nI will list the files.", "\n</think>", "\n\n", "<tool_call>",
                      "\n{\"name\": \"shell\", \"arguments\": {\"command\": [\"ls\"]}}\n", "</tool_call>"]
        XCTAssertEqual(streamed(chunks), "")
        assertStreamMatchesFinal(chunks)
    }

    /// A tool_call inside the think block streams nothing; the prose after `</think>` (split across
    /// chunks) streams up to the real call.
    func testStreamQwenToolCallInsideThinkThenRealCall() {
        let chunks = ["<think>", "Maybe ", "<tool_call>", "{\"name\": \"rm\", \"arguments\": {}}", "</tool_call>", " no.",
                      "</th", "ink>", "\n", "Reading", " the file.", "\n", "<tool_call>",
                      "{\"name\": \"read_file\", \"arguments\": {\"path\": \"a.swift\"}}", "</tool_call>"]
        XCTAssertEqual(streamed(chunks), "Reading the file.\n")
        assertStreamMatchesFinal(chunks)
    }

    /// No closing tag: nothing streams, at the end either.
    func testStreamQwenUnclosedThinkShowsNothing() {
        let chunks = ["<think>", "plan ", "<tool_call>", "{}", "</tool_call>", " still thinking"]
        XCTAssertEqual(streamed(chunks), "")
        XCTAssertEqual(streamed(chunks, finish: false), "")
        assertStreamMatchesFinal(chunks)
    }

    /// No think at all (Qwen3-Coder): the streamed bytes are what the splitter streamed before #893.
    func testStreamQwenWithoutThinkBytesUnchanged() {
        XCTAssertEqual(streamed(["I'll ", "list the files.\n<fun", "ction=shell>\n<parameter=command>\n[\"ls\"]\n</parameter>\n</function>\n</tool_call>"]),
                       "I'll list the files.\n")
        XCTAssertEqual(streamed(["<", "thi", "s is prose"]), "<this is prose")
        XCTAssertEqual(streamed(["\n\nHello ", "world"]), "\n\nHello world")
        XCTAssertEqual(streamed([" <think>x</think>y"]), " <think>x</think>y")
        XCTAssertEqual(streamed(["<thi"]), "<thi")
    }

    /// Tags split at every boundary still open and close the block.
    func testStreamQwenThinkTagsSplitAcrossChunks() {
        let chunks = ["<thi", "nk>abc</th", "ink>", "Hi"]
        XCTAssertEqual(streamed(chunks), "Hi")
        assertStreamMatchesFinal(chunks)
    }

    /// The tools path never calls finish() and sends the final's unsent suffix only when the
    /// streamed text is its prefix: the whitespace after `</think>` must not stream.
    func testStreamQwenAnswerAfterThinkIsAPrefixOfTheFinal() {
        let chunks = ["<think>", "x", "</think>", "\n\n", "The answer", " is 42."]
        let sent = streamed(chunks, finish: false)
        let final = ToolCallParser.parse(chunks.joined(), format: .qwenXML).content
        XCTAssertFalse(sent.isEmpty)
        XCTAssertTrue(final.hasPrefix(sent), "streamed \(sent.debugDescription), final \(final.debugDescription)")
    }

    /// Formats that already strip think in their parser keep `<think>` as a stop marker, as before.
    func testStreamOtherFormatsKeepThinkStopMarker() {
        XCTAssertEqual(streamed(["before", "<think>x</think>after"], .nemotron), "before")
    }

    /// Bound: inside an unclosed think block the splitter holds at most `</think>`.count - 1 bytes,
    /// whatever the block's length; in prose, at most the guard tail (longest marker - 1).
    func testStreamThinkBufferIsBounded() {
        var splitter = StreamSplitter(format: .qwenXML)
        XCTAssertEqual(splitter.ingest("<think>"), "")
        var maxHeld = 0, out = ""
        // A broken bound stops the loop at once instead of rescanning a growing buffer.
        for _ in 0..<50_000 where maxHeld <= 7 {
            out += splitter.ingest("thinking <tool_call> </thin")
            maxHeld = max(maxHeld, splitter.heldCount)
        }
        XCTAssertEqual(out, "")
        XCTAssertLessThanOrEqual(maxHeld, 7)
        out += splitter.ingest("k>done")
        for _ in 0..<50_000 where maxHeld <= 10 {
            out += splitter.ingest(" word")
            maxHeld = max(maxHeld, splitter.heldCount)
        }
        XCTAssertLessThanOrEqual(maxHeld, 10)
        out += splitter.finish()
        XCTAssertEqual(out, "done" + String(repeating: " word", count: 50_000))
    }
}

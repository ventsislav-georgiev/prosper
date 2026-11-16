import MLXLMCommon
import XCTest
import os
@testable import ProsperApp

/// QA #219 (b) call sites (#1298): the two catch sites of ProsperLLMServer's CancellationError (chat and
/// responses) answer a cancelled request through `cancelledReply`. Rows drive an HTTPConnection through its
/// `sink` seam: no listener, no port, no socket, no model (fake engines only).
final class LLMServerCancelReplyTests: XCTestCase {

    /// Yields nothing and ends cancelled: the header is already out when the stream is read.
    private final class CancelledEngine: AgentChatEngine {
        nonisolated func generateChat(
            messages: [MLXEngine.ChatTurn], tools: [ToolSpec], maxTokens: Int,
            temperature: Float, topP: Float, stop: [String]
        ) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
        }
        func unload() async {}
    }

    /// Runs one request through a sink-only connection and returns every write, in order. `headerOut`
    /// picks the cancel point: false = the acquire is cancelled (before any header), true = the stream is.
    private func writes(path: String, body: String, headerOut: Bool) async throws -> [String] {
        let server = ProsperLLMServer.shared
        let savedAcquire = server.acquireAgent, savedToken = server.token
        defer { server.acquireAgent = savedAcquire; server.token = savedToken }
        server.token = "fake-token"
        server.acquireAgent = {
            if headerOut { return (CancelledEngine(), "example-model-a") }
            throw CancellationError()
        }
        let got = OSAllocatedUnfairLock<[String]>(initialState: [])
        let conn = HTTPConnection(
            conn: nil, server: server, queue: DispatchQueue(label: "cancel-reply-test"),
            log: Logger(subsystem: "com.prosper.app", category: "test"),
            sink: { d in got.withLock { $0.append(String(decoding: d, as: UTF8.self)) } },
            onClose: { _ in })
        let req = "POST \(path) HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer fake-token\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        conn.feed(Data(req.utf8))
        // The reply is the last write of the request: wait (bounded) for [DONE] or a 499.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let now = got.withLock { $0 }
            if now.last?.hasPrefix("HTTP/1.1 499 ") == true || now.last == "data: [DONE]\n\n" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        conn.cancelInflight()
        return got.withLock { $0 }
    }

    private let chatBody = #"{"stream":true,"messages":[{"role":"user","content":"hi"}]}"#
    private let responsesBody = #"{"stream":true,"input":"hi"}"#

    private func assertA499(_ w: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(w.count, 1, "\(w)", file: file, line: line)
        XCTAssertTrue(w.first?.hasPrefix("HTTP/1.1 499 Client Closed Request\r\n") == true, "\(w)", file: file, line: line)
        XCTAssertTrue(w.first?.hasSuffix(#"{"error":{"message":"request cancelled","type":"cancelled"}}"#) == true,
                      "\(w)", file: file, line: line)
    }

    private func assertDone(_ w: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(w.first?.hasPrefix("HTTP/1.1 200 OK\r\n") == true, "\(w)", file: file, line: line)
        XCTAssertEqual(w.last, "data: [DONE]\n\n", file: file, line: line)
        XCTAssertTrue(w.allSatisfy { !$0.contains(" 499 ") }, "\(w)", file: file, line: line)
    }

    func testChatCancelledBeforeTheHeaderGetsA499() async throws {
        assertA499(try await writes(path: "/v1/chat/completions", body: chatBody, headerOut: false))
    }

    func testChatCancelledAfterTheHeaderGetsTheStreamEnd() async throws {
        assertDone(try await writes(path: "/v1/chat/completions", body: chatBody, headerOut: true))
    }

    func testResponsesCancelledBeforeTheHeaderGetsA499() async throws {
        assertA499(try await writes(path: "/v1/responses", body: responsesBody, headerOut: false))
    }

    func testResponsesCancelledAfterTheHeaderGetsTheStreamEnd() async throws {
        assertDone(try await writes(path: "/v1/responses", body: responsesBody, headerOut: true))
    }
}

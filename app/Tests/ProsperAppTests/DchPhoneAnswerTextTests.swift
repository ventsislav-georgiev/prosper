import Foundation
import MLXLMCommon
import Network
import os
import XCTest
@testable import ProsperApp

/// #988: the phone gets a fixed sentence, never the Mac's own error text or Tailscale's raw state.
/// No model, no Tailscale: DchChat's seams are fakes and parseHost is fed made-up status JSON.
/// Every expectation below is a literal; nothing is built from the product's own strings.
/// Closures run where DchChat runs them (cooperative pool); the test bodies are not main-actor.
final class DchPhoneAnswerTextTests: XCTestCase {
    private static let modelId = AgentModelRegistry.models[0].id
    private static let path = "/Users/example/models/x.gguf"

    /// An error whose description holds a made-up path and file name.
    private struct LeakyError: Error, CustomStringConvertible {
        var description: String { "cannot open \(DchPhoneAnswerTextTests.path): x.gguf is damaged" }
    }

    private final class Engine: AgentChatEngine, @unchecked Sendable {
        let chunks: [String], failure: Error?
        init(chunks: [String] = [], failure: Error? = nil) { self.chunks = chunks; self.failure = failure }
        nonisolated func generateChat(messages: [MLXEngine.ChatTurn], tools: [ToolSpec], maxTokens: Int,
                                      temperature: Float, topP: Float, stop: [String]) -> AsyncThrowingStream<String, Error> {
            let chunks = chunks, failure = failure
            return AsyncThrowingStream { c in
                for s in chunks { c.yield(s) }
                c.finish(throwing: failure)
            }
        }
        func unload() async {}
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ v: T) { value = v }
        func with<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&value) } }
    }

    private func makeChat(acquire: @escaping @Sendable (String) async throws -> (engine: any AgentChatEngine, modelId: String)) -> DchChat {
        let chat = DchChat(), id = Self.modelId
        chat.modelId = { id }
        chat.isModelOnDisk = { $0 == id }
        chat.isResident = { false }
        chat.acquire = acquire
        chat.release = {}
        chat.macAgentBusy = { false }
        chat.macChatOpen = { false }
        chat.schedule = { _, _ in }   // the idle timer never fires on its own
        return chat
    }

    private static let body = Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8)

    private static func message(_ f: Data?) -> String {
        guard let f, f.count > 5,
              let o = try? JSONSerialization.jsonObject(with: f.subdata(in: (f.startIndex + 5)..<f.endIndex)) as? [String: Any]
        else { return "" }
        return o["message"] as? String ?? ""
    }

    /// One chat; its one final reply (the reply is called before `chat` returns).
    private func answer(_ chat: DchChat) async -> Data? {
        let final = Box<Data?>(nil)
        await chat.chat(Self.body, send: { _ in }, reply: { f in final.with { $0 = f } })
        return final.with { $0 }
    }

    private func assertFixed(_ text: String, _ want: String, line: UInt = #line) {
        XCTAssertEqual(text, want, line: line)
        for leak in ["/Users/example", "x.gguf", "damaged", "model load error", "inference error", "LeakyError"] {
            XCTAssertFalse(text.contains(leak), "\(leak) reached the phone", line: line)
        }
    }

    // MARK: Item 1: the two chat answers

    func testALoadErrorGivesTheFixedLoadSentence() async {
        let rows: [(String, Error, String)] = [
            ("any error", LeakyError(), "The model could not be loaded on the Mac."),
            ("loadFailed", LlamaAgentEngine.EngineError.loadFailed("\(Self.path) x.gguf damaged"), "The model could not be loaded on the Mac."),
            ("modelMissing", LlamaAgentEngine.EngineError.modelMissing(Self.path), "The model file is missing on the Mac."),
            ("decodeFailed", LlamaAgentEngine.EngineError.decodeFailed, "The model could not be loaded on the Mac."),
        ]
        for (name, error, want) in rows {
            let chat = makeChat(acquire: { _ in throw error })
            let f = await answer(chat)
            XCTAssertEqual(f?.first, DchFrame.error, name)
            assertFixed(Self.message(f), want)
        }
    }

    func testAnInferenceErrorGivesTheFixedInferenceSentence() async {
        let rows: [(String, Error, String)] = [
            ("any error", LeakyError(), "The Mac could not finish the answer."),
            ("decodeFailed", LlamaAgentEngine.EngineError.decodeFailed, "The Mac could not finish the answer."),
            ("modelMissing", LlamaAgentEngine.EngineError.modelMissing(Self.path), "The Mac could not finish the answer."),
            ("promptTooLong", LlamaAgentEngine.EngineError.promptTooLong(tokens: 9000, ctx: 8192),
             "The conversation is too long for the model on the Mac."),
        ]
        for (name, error, want) in rows {
            let engine = Engine(chunks: ["partial"], failure: error)
            let chat = makeChat(acquire: { id in (engine, id) })
            let f = await answer(chat)
            XCTAssertEqual(f?.first, DchFrame.error, name)
            assertFixed(Self.message(f), want)
            XCTAssertFalse(Self.message(f).contains("9000"), name)
        }
    }

    // MARK: Item 2: Tailscale's backend state

    private func cause(_ status: [String: Any]) -> WhoisUnusable? {
        let data = (try? JSONSerialization.data(withJSONObject: status)) ?? Data()
        do { _ = try DchOwnerCheck.parseHost(data) } catch { return error as? WhoisUnusable }
        return nil
    }

    func testEachNamedStateGivesItsLiteralSentence() {
        let me: [String: Any] = ["UserID": 1]
        XCTAssertEqual(cause(["BackendState": "Stopped", "Self": me]),
                       WhoisUnusable(cause: "Tailscale on this Mac is turned off", askAgain: true))
        XCTAssertEqual(cause(["BackendState": "NeedsLogin", "Self": me]),
                       WhoisUnusable(cause: "Tailscale on this Mac needs a login", askAgain: true))
        XCTAssertEqual(cause(["BackendState": "Starting", "Self": me]),
                       WhoisUnusable(cause: "Tailscale on this Mac is still starting", askAgain: true))
        XCTAssertEqual(cause(["BackendState": "Running", "Self": me]) == nil, true, "Running passes this line")
    }

    func testAnyOtherStateGivesOneGenericSentenceWithNoRawValue() {
        let me: [String: Any] = ["UserID": 1]
        let generic = "Tailscale on this Mac is not connected"
        let raws = ["Weird\u{202E}State", "", String(repeating: "Q", count: 10_000), "NoState", "stopped", "Stopped ", "Running\n"]
        for raw in raws {
            let c = cause(["BackendState": raw, "Self": me])
            XCTAssertEqual(c, WhoisUnusable(cause: generic, askAgain: true), "state of \(raw.count) characters")
            XCTAssertTrue(raw.isEmpty || c?.cause.contains(raw) == false)
            XCTAssertFalse(c?.cause.contains("Weird") ?? true)
            XCTAssertLessThan(c?.cause.count ?? .max, 60)
        }
        XCTAssertEqual(cause(["Self": me]), WhoisUnusable(cause: generic, askAgain: true), "a missing state")
        XCTAssertEqual(cause(["BackendState": NSNull(), "Self": me]), WhoisUnusable(cause: generic, askAgain: true), "a null state")
    }

    // MARK: Q1 and Q2 of the phone chat (no product change)

    /// QA #500 INFO-8 (Q1): `running` is cleared before the reply goes out. At the moment the fake sees the
    /// reply a second request is made and must run, not be refused as busy. The wait is a ceiling.
    func testRunningIsClearedBeforeTheReplyIsSent() async {
        let engine = Engine(chunks: ["a"])
        let chat = makeChat(acquire: { id in (engine, id) })
        let second = Box<Data?>(nil)
        let replies = Box(0)
        let done = DispatchSemaphore(value: 0)
        let secondReply: @Sendable (Data) -> Void = { f in second.with { $0 = f }; done.signal() }
        await chat.chat(Self.body, send: { _ in }, reply: { _ in
            guard replies.with({ $0 += 1; return $0 }) == 1 else { return }
            // Runs on the cooperative thread that finished the first chat; the second chat runs in its own Task.
            Task { await chat.chat(Self.body, send: { _ in }, reply: secondReply) }
            _ = done.wait(timeout: .now() + 10)
        })
        let f = second.with { $0 }
        XCTAssertEqual(f?.first, DchFrame.chatDone, "the second request ran: \(Self.message(f))")
        XCTAssertFalse(Self.message(f).contains("busy"))
    }

    /// QA #500 INFO-7 (Q2): the delta callback's work runs on the connection's queue (DchConnection
    /// hops with queue.async), not on the thread that generates. The ceiling is the expectation's timeout.
    func testChatDeltasReachTheConnectionOnItsQueue() async {
        let engine = Engine(chunks: ["Hel", "lo"])
        let chat = makeChat(acquire: { id in (engine, id) })
        let queue = DispatchQueue(label: "test.dchconn.phoneanswer")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { @Sendable _ in })
        let seen = Box<[(UInt8, Bool)]>([])
        let finished = expectation(description: "chatDone")
        conn.sendOverride = { f in   // runs where the connection sends: asserted below to be `queue`
            let onQueue = DispatchQueue.getSpecific(key: key) == true
            seen.with { $0.append((f[f.startIndex], onQueue)) }
            if f[f.startIndex] == DchFrame.chatDone { finished.fulfill() }
        }
        conn.chat = chat
        addTeardownBlock { queue.sync { conn.close() } }
        queue.sync { conn.ingest(DchFrame.encode(DchFrame.chat, json: ["messages": [["role": "user", "content": "hi"]]])) }
        await fulfillment(of: [finished], timeout: 10)
        let frames = seen.with { $0 }
        XCTAssertEqual(frames.filter { $0.0 == DchFrame.chatDelta }.count, 2)
        XCTAssertTrue(frames.allSatisfy { $0.1 }, "every frame, the deltas included, left on the connection queue")
        XCTAssertEqual(frames.last?.0, DchFrame.chatDone)
    }
}

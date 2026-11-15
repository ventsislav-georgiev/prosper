import Foundation
import MLXLMCommon   // ToolSpec (a type only: no model is loaded)
import XCTest
@testable import ProsperApp

/// #1181 (R1181-f): the phone chat sends no think text. A leading think block is dropped by the server's
/// StreamSplitter (qwenXML/hermesJSON only); an output that ends inside it sends the fixed line
/// StreamSplitter.unclosedThinkNotice once; every other turn's text is sent as today. No model, no phone:
/// DchChat's seams are fakes (as in DchPhoneAnswerTextTests) and `send` is a recorder. Closures run where
/// DchChat runs them (cooperative pool); the test bodies are not main-actor.
final class DchChatThinkTests: XCTestCase {
    /// The first catalog row (qwenXML, as every built-in row); the made-up custom row is mistral.
    private static let catalogId = AgentModelRegistry.models[0].id
    private static let mistralId = "example-model-a"

    private final class Engine: AgentChatEngine, @unchecked Sendable {
        let chunks: [String]
        init(_ chunks: [String]) { self.chunks = chunks }
        nonisolated func generateChat(messages: [MLXEngine.ChatTurn], tools: [ToolSpec], maxTokens: Int,
                                      temperature: Float, topP: Float, stop: [String]) -> AsyncThrowingStream<String, Error> {
            let chunks = chunks
            return AsyncThrowingStream { c in
                for s in chunks { c.yield(s) }
                c.finish()
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

    private static let body = Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8)

    /// One phone chat over `chunks`: the text of every chatDelta frame, in order, and the final reply's type.
    private func run(_ chunks: [String], model: String = DchChatThinkTests.catalogId) async -> (texts: [String], done: UInt8?) {
        let chat = DchChat(), engine = Engine(chunks)
        chat.modelId = { model }
        chat.isModelOnDisk = { $0 == model }
        chat.isResident = { false }
        chat.acquire = { id in (engine, id) }
        chat.release = {}
        chat.macAgentBusy = { false }
        chat.macChatOpen = { false }
        chat.schedule = { _, _ in }   // the idle timer never fires on its own
        let frames = Box<[Data]>([]), final = Box<Data?>(nil)
        await chat.chat(Self.body, send: { f in frames.with { $0.append(f) } }, reply: { f in final.with { $0 = f } })
        let texts = frames.with { $0 }.map { f -> String in
            guard f.first == DchFrame.chatDelta, f.count > 5,
                  let o = try? JSONSerialization.jsonObject(with: f.subdata(in: (f.startIndex + 5)..<f.endIndex)) as? [String: Any]
            else { return "<not a chatDelta frame>" }
            return o["text"] as? String ?? "<no text>"
        }
        return (texts, final.with { $0 }?.first)
    }

    /// `text` cut into two chunks at every scalar boundary (the whole text as one chunk included).
    private func cuts(_ text: String) -> [[String]] {
        let s = Array(text.unicodeScalars)
        return (0...s.count).map { i in
            [String(String.UnicodeScalarView(s[..<i])), String(String.UnicodeScalarView(s[i...]))]
        }
    }

    func testCatalogModelIsQwenXML() {
        XCTAssertEqual(AgentModelRegistry.toolFormat(for: Self.catalogId), .qwenXML)
    }

    /// A closed leading think block: only the answer reaches the phone, at every cut.
    func testThinkBlockIsNeverSent() async {
        for chunks in cuts("<think>plan the reply</think>\n\nHello there.") {
            let r = await run(chunks)
            XCTAssertEqual(r.texts.joined(), "Hello there.", "\(chunks)")
            XCTAssertFalse(r.texts.contains { $0.contains("plan") || $0.contains("think>") }, "\(chunks) -> \(r.texts)")
            XCTAssertEqual(r.done, DchFrame.chatDone, "\(chunks)")
        }
    }

    /// The output ends inside the block: the fixed line, once, and no think text, at every cut.
    func testUnclosedBlockSendsTheFixedLineOnce() async {
        for chunks in cuts("<think>still thinking") {
            let r = await run(chunks)
            XCTAssertEqual(r.texts, [StreamSplitter.unclosedThinkNotice], "\(chunks)")
            XCTAssertEqual(r.done, DchFrame.chatDone, "\(chunks)")
        }
    }

    /// Every other turn: the same frames as today (each non-empty chunk as it arrives), tool-call text and a
    /// think tag after leading whitespace included. One exception, by design: first chunks that could
    /// still open `<think>` (at most 6 scalars) are held and go out with the next frame; the text is the same.
    func testOtherTurnsAreSentAsToday() async {
        let today: [[String]] = [
            ["Hello", " world", "!"],
            ["a", "b"],
            ["Use <tool_call> like this", " and <function=x> too"],
            ["  <think>x</think>y"],
            ["no think here: ", "<think>x</think>"],
        ]
        for chunks in today {
            let r = await run(chunks)
            XCTAssertEqual(r.texts, chunks, "\(chunks)")
            XCTAssertEqual(r.done, DchFrame.chatDone)
        }
        let empty = await run(["", "a", ""])
        XCTAssertEqual(empty.texts, ["a"], "empty chunks are not sent, as today")
        let held = await run(["<", "b>bold</b>"])
        XCTAssertEqual(held.texts.joined(), "<b>bold</b>", "a held prefix of <think> goes out with the next frame")
        XCTAssertFalse(held.texts.contains(""))
    }

    /// A model of another format (a made-up custom mistral row): its output is sent as today, think tag and all,
    /// as the server's splitter leaves it. The setting's scratch keys are restored.
    func testOtherFormatIsSentAsToday() async {
        let d = Preferences.defaults, keys = ["customAgentModelsV1", "modelLabelOverridesV1"]
        let saved = keys.map { d.object(forKey: $0) }
        let savedGB = AgentModelRegistry.physicalMemoryGB
        defer {
            for (k, v) in zip(keys, saved) { d.set(v, forKey: k) }
            AgentModelRegistry.physicalMemoryGB = savedGB
        }
        AgentModelRegistry.physicalMemoryGB = 64
        CustomModelStore.upsert(CustomAgentModel(id: Self.mistralId, label: "A", sizeBytes: 0, note: "", toolFormat: .mistral))
        XCTAssertEqual(AgentModelRegistry.toolFormat(for: Self.mistralId), .mistral)
        let chunks = ["<think>x</think>", "answer"]
        let r = await run(chunks, model: Self.mistralId)
        XCTAssertEqual(r.texts, chunks)
    }

    // MARK: R1181-b: the acquire seam takes the id the chat read and the think rule follows the id it returns

    /// One phone chat whose acquire records the ids it is called with and answers `returned`'s id (the id
    /// the engine holds). The closure runs on the cooperative pool; the Box is the lock.
    private func runWithAcquire(_ chunks: [String], reads model: String, returns returned: String) async
        -> (texts: [String], acquiredWith: [String]) {
        let chat = DchChat(), engine = Engine(chunks), ids = Box<[String]>([])
        chat.modelId = { model }
        chat.isModelOnDisk = { $0 == model }
        chat.isResident = { false }
        chat.acquire = { id in ids.with { $0.append(id) }; return (engine, returned) }
        chat.release = {}
        chat.macAgentBusy = { false }
        chat.macChatOpen = { false }
        chat.schedule = { _, _ in }
        let frames = Box<[Data]>([])
        await chat.chat(Self.body, send: { f in frames.with { $0.append(f) } }, reply: { _ in })
        let texts = frames.with { $0 }.compactMap { f -> String? in
            guard f.first == DchFrame.chatDelta, f.count > 5,
                  let o = try? JSONSerialization.jsonObject(with: f.subdata(in: (f.startIndex + 5)..<f.endIndex)) as? [String: Any]
            else { return nil }
            return o["text"] as? String
        }
        return (texts, ids.with { $0 })
    }

    /// (a) acquire is called once, with the id the chat read (the setting is read once for the chat's checks).
    func testAcquireIsCalledOnceWithTheIdTheChatRead() async {
        let r = await runWithAcquire(["hi"], reads: Self.catalogId, returns: Self.catalogId)
        XCTAssertEqual(r.acquiredWith, [Self.catalogId])
        XCTAssertEqual(r.texts, ["hi"])
    }

    /// (b) the returned id decides the think rule, in both directions. Ids: the catalog row (qwenXML) and a
    /// made-up custom mistral row; the scratch keys are restored.
    func testThinkRuleFollowsTheReturnedId() async {
        let d = Preferences.defaults, keys = ["customAgentModelsV1", "modelLabelOverridesV1"]
        let saved = keys.map { d.object(forKey: $0) }
        let savedGB = AgentModelRegistry.physicalMemoryGB
        defer {
            for (k, v) in zip(keys, saved) { d.set(v, forKey: k) }
            AgentModelRegistry.physicalMemoryGB = savedGB
        }
        AgentModelRegistry.physicalMemoryGB = 64
        CustomModelStore.upsert(CustomAgentModel(id: Self.mistralId, label: "A", sizeBytes: 0, note: "", toolFormat: .mistral))
        XCTAssertEqual(AgentModelRegistry.toolFormat(for: Self.mistralId), .mistral)
        let chunks = ["<think>plan</think>", "answer"]
        // The chat read a qwenXML id, but the engine holds a mistral one: the block is sent as today.
        let sent = await runWithAcquire(chunks, reads: Self.catalogId, returns: Self.mistralId)
        XCTAssertEqual(sent.texts, chunks)
        XCTAssertEqual(sent.acquiredWith, [Self.catalogId])
        // The chat read a mistral id, but the engine holds a qwenXML one: the block is dropped.
        let dropped = await runWithAcquire(chunks, reads: Self.mistralId, returns: Self.catalogId)
        XCTAssertEqual(dropped.texts.joined(), "answer")
        XCTAssertFalse(dropped.texts.contains { $0.contains("plan") })
        XCTAssertEqual(dropped.acquiredWith, [Self.mistralId])
    }
}

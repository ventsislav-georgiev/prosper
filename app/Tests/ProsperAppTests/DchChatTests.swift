import Foundation
import MLXLMCommon
import Network
import os
import XCTest
@testable import ProsperApp

/// #618: the phone's chat with the Mac's local model, through DchConnection.ingest and the
/// sendOverride frame sink. Each test builds its own DchChat whose every seam is a fake: no
/// coordinator, no Preferences.agentModel, no model files, no MLX or llama. The engine is a
/// fake AgentChatEngine; the idle timer is captured and fired by hand. The NWConnection is
/// never started.
final class DchChatTests: XCTestCase {
    private static let modelId = AgentModelRegistry.models[0].id

    private struct Boom: Error {}

    private final class FakeEngine: AgentChatEngine, @unchecked Sendable {
        enum Mode { case chunks([String]), waitForCancel, fail }
        struct Call {
            let turns: [MLXEngine.ChatTurn], tools: Int, maxTokens: Int, temperature: Float, topP: Float, stop: [String]
        }
        let mode: Mode
        let lock = NSLock()
        private var _calls: [Call] = []
        private var _cancelled = false
        var calls: [Call] { lock.withLock { _calls } }
        var cancelled: Bool { lock.withLock { _cancelled } }
        init(_ mode: Mode) { self.mode = mode }

        nonisolated func generateChat(
            messages: [MLXEngine.ChatTurn], tools: [ToolSpec], maxTokens: Int,
            temperature: Float, topP: Float, stop: [String]
        ) -> AsyncThrowingStream<String, Error> {
            lock.withLock {
                _calls.append(Call(turns: messages, tools: tools.count, maxTokens: maxTokens,
                                   temperature: temperature, topP: topP, stop: stop))
            }
            return AsyncThrowingStream { c in
                switch mode {
                case .chunks(let all):
                    for s in all { c.yield(s) }
                    c.finish()
                case .fail:
                    c.yield("partial")
                    c.finish(throwing: Boom())
                case .waitForCancel:
                    // The real engines cancel their generation task here.
                    c.onTermination = { reason in
                        if case .cancelled = reason { self.lock.withLock { self._cancelled = true } }
                    }
                    c.yield("first")
                }
            }
        }

        func unload() async {}
    }

    /// Every seam's state, shared by the fakes.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var onDisk = true, resident = false, macBusy = false, windowOpen = false, holdRelease = false
        var acquires = 0, releases = 0
        var engine = FakeEngine(.chunks(["Hel", "", "lo", " world"]))
        var scheduled: [(delay: TimeInterval, fire: @Sendable () async -> Void)] = []
        func get<T>(_ f: (State) -> T) -> T { lock.withLock { f(self) } }
        func set(_ f: (State) -> Void) { lock.withLock { f(self) } }
    }

    private func makeChat(_ s: State) -> DchChat {
        let chat = DchChat(), id = Self.modelId
        chat.modelId = { id }
        chat.isModelOnDisk = { m in m == id && s.get { $0.onDisk } }
        chat.isResident = { s.get { $0.resident } }
        chat.acquire = {
            s.get { s in
                s.acquires += 1
                s.resident = true
                return s.engine
            }
        }
        chat.release = {
            s.set { $0.releases += 1 }
            while s.get({ $0.holdRelease }) { try? await Task.sleep(for: .milliseconds(5)) }
            s.set { $0.resident = false }
        }
        chat.macAgentBusy = { s.get { $0.macBusy } }
        chat.macChatOpen = { s.get { $0.windowOpen } }
        chat.schedule = { delay, fire in s.set { $0.scheduled.append((delay, fire)) } }
        return chat
    }

    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var all: [Data] = []
    }

    private struct Rig {
        let conn: DchConnection
        let queue: DispatchQueue
        let frames: Frames
    }

    private func connection(_ chat: DchChat) -> Rig {
        let queue = DispatchQueue(label: "test.dchconn.chat")
        let frames = Frames()
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { @Sendable _ in })
        conn.sendOverride = { f in frames.lock.withLock { frames.all.append(f) } }
        conn.chat = chat
        addTeardownBlock { queue.sync { conn.close() } }
        return Rig(conn: conn, queue: queue, frames: frames)
    }

    // MARK: Frame helpers

    private static func type(_ f: Data) -> UInt8 { f[f.startIndex] }
    private static func json(_ f: Data) -> Any? { try? JSONSerialization.jsonObject(with: f.subdata(in: (f.startIndex + 5)..<f.endIndex)) }
    private static func object(_ f: Data?) -> [String: Any] { f.flatMap { json($0) as? [String: Any] } ?? [:] }
    private static func message(_ f: Data?) -> String { object(f)["message"] as? String ?? "" }
    private static let finalTypes: Set<UInt8> = [DchFrame.error, DchFrame.chatDone, DchFrame.modelsResp, DchFrame.machineInfoResp]

    private func all(_ r: Rig) -> [Data] { r.frames.lock.withLock { r.frames.all } }
    private func finals(_ r: Rig) -> [Data] { all(r).filter { Self.finalTypes.contains(Self.type($0)) } }
    private func deltas(_ r: Rig) -> [String] {
        all(r).filter { Self.type($0) == DchFrame.chatDelta }.map { Self.object($0)["text"] as? String ?? "?" }
    }

    private func ingest(_ r: Rig, _ frames: Data...) {
        r.queue.sync { r.conn.ingest(frames.reduce(Data(), +)) }
    }

    private static func frame(_ type: UInt8, _ obj: Any) -> Data { DchFrame.encode(type, json: obj) }

    private static func chatBody(_ messages: [[String: Any]] = [["role": "user", "content": "hi"]],
                                 extra: [String: Any] = [:]) -> [String: Any] {
        (["messages": messages] as [String: Any]).merging(extra) { $1 }
    }

    /// Polls until `cond`, failing after 10 s.
    private func waitUntil(_ what: String, _ cond: () -> Bool, line: UInt = #line) async {
        let end = Date().addingTimeInterval(10)
        while !cond() {
            guard Date() < end else { return XCTFail("timed out waiting for \(what)", line: line) }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Sends a chat and waits for its `n`th final frame on the connection.
    @discardableResult
    private func chat(_ r: Rig, _ body: Any, final n: Int = 1, line: UInt = #line) async -> Data? {
        ingest(r, Self.frame(DchFrame.chat, body))
        await waitUntil("final reply \(n)", { finals(r).count >= n }, line: line)
        return finals(r).last
    }

    private func fire(_ s: State, _ i: Int, line: UInt = #line) async {
        guard let fire = s.get({ $0.scheduled.indices.contains(i) ? $0.scheduled[i].fire : nil }) else {
            return XCTFail("no timer \(i) was armed", line: line)
        }
        await fire()
    }

    // MARK: Codes and ops

    func testFrameCodesAreThePhonesContractAndCollideWithNone() {
        XCTAssertEqual([DchFrame.models, DchFrame.chat, DchFrame.chatDelta, DchFrame.chatDone, DchFrame.modelsResp],
                       [0x1e, 0x1f, 0x20, 0x21, 0x27])
        let every: [UInt8] = [DchFrame.attach, DchFrame.create, DchFrame.list, DchFrame.kill, DchFrame.resize, DchFrame.rename,
                              DchFrame.redraw, DchFrame.machineInfo, DchFrame.snapshot, DchFrame.putClipboard, DchFrame.history,
                              DchFrame.revive, DchFrame.restart, DchFrame.stop, DchFrame.library, DchFrame.pin, DchFrame.forget,
                              DchFrame.forgetAll, DchFrame.data, DchFrame.listResp, DchFrame.exit, DchFrame.error, DchFrame.ok,
                              DchFrame.machineInfoResp, DchFrame.snapshotResp, DchFrame.historyResp, DchFrame.libraryResp,
                              DchFrame.clipboardList, DchFrame.clipboardItem, DchFrame.putClipboardText,
                              DchFrame.clipboardItemResp, DchFrame.clipboardResp, DchFrame.addClipboardHistory,
                              DchFrame.clipboardUpload, DchFrame.models, DchFrame.chat, DchFrame.chatDelta,
                              DchFrame.chatDone, DchFrame.modelsResp]
        XCTAssertEqual(Set(every).count, every.count, "no two frames share a code")
    }

    func testModelsListsTheOnDiskAgentModelWithItsResidency() async {
        let s = State()
        for (resident, payload) in [(false, Data()), (true, Data("{}".utf8))] {
            s.set { $0.resident = resident }
            let r = connection(makeChat(s))
            ingest(r, DchFrame.encode(DchFrame.models, [UInt8](payload)))
            await waitUntil("modelsResp") { !finals(r).isEmpty }
            let f = finals(r)
            XCTAssertEqual(f.count, 1)
            XCTAssertEqual(f.first.map(Self.type), DchFrame.modelsResp)
            let rows = f.first.flatMap(Self.json) as? [[String: Any]] ?? []
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?["id"] as? String, Self.modelId)
            XCTAssertEqual(rows.first?["name"] as? String, AgentModelRegistry.model(for: Self.modelId).label)
            XCTAssertEqual(rows.first?["loaded"] as? Bool, resident)
        }
        XCTAssertEqual(s.get { $0.acquires }, 0, "listing never loads")
    }

    func testOffDiskModelsIsEmptyAndChatLeavesOps() async {
        let s = State()
        for onDisk in [false, true] {
            s.set { $0.onDisk = onDisk }
            let r = connection(makeChat(s))
            ingest(r, DchFrame.encode(DchFrame.models, []))
            await waitUntil("modelsResp") { !finals(r).isEmpty }
            XCTAssertEqual((finals(r).first.flatMap(Self.json) as? [Any])?.count, onDisk ? 1 : 0)
            ingest(r, DchFrame.encode(DchFrame.machineInfo, []))
            let ops = Self.object(all(r).last)["ops"] as? [String] ?? []
            XCTAssertEqual(ops.contains("chat"), onDisk)
        }
        XCTAssertFalse(DchFrame.ops.contains("chat"))
        XCTAssertFalse(DchChat().available, "the production default is off under XCTest")
    }

    func testAMalformedModelsRequestIsRefused() async {
        let r = connection(makeChat(State()))
        ingest(r, Self.frame(DchFrame.models, ["x": 1]))
        await waitUntil("reply") { !finals(r).isEmpty }
        XCTAssertEqual(Self.message(finals(r).first), "malformed models request: send nothing or {}")
    }

    // MARK: Chat

    func testChatStreamsTheDeltasInOrderThenDone() async {
        let s = State()
        let r = connection(makeChat(s))
        let messages: [[String: Any]] = [["role": "system", "content": "be brief"], ["role": "user", "content": "hi"],
                                         ["role": "assistant", "content": "hello"], ["role": "user", "content": "more"]]
        let done = await chat(r, Self.chatBody(messages, extra: ["model": Self.modelId, "stream": true]))
        XCTAssertEqual(deltas(r), ["Hel", "lo", " world"], "in order, empty chunks dropped")
        XCTAssertEqual(all(r).count, 4, "three deltas, then the one final")
        XCTAssertEqual(done.map(Self.type), DchFrame.chatDone)
        XCTAssertEqual(Self.object(done)["stop"] as? String, "stop")
        let call = s.get { $0.engine }.calls
        XCTAssertEqual(call.count, 1)
        XCTAssertEqual(call.first?.turns, messages.map { MLXEngine.ChatTurn(role: $0["role"] as! String, content: $0["content"] as! String) })
        XCTAssertEqual(call.first?.tools, 0)
        XCTAssertEqual(call.first?.maxTokens, 1024)
        XCTAssertEqual(call.first?.temperature, 0.7)
        XCTAssertEqual(call.first?.topP, 0.95)
        XCTAssertEqual(call.first?.stop, [])
    }

    func testMalformedChatShapesAreRefused() async {
        let s = State()
        let r = connection(makeChat(s))
        let user: [String: Any] = ["role": "user", "content": "hi"]
        let bodies: [(String, Data)] = [
            ("not JSON", Data("nope".utf8)),
            ("an array", try! JSONSerialization.data(withJSONObject: [user])),
            ("no messages", Data("{}".utf8)),
            ("empty messages", try! JSONSerialization.data(withJSONObject: ["messages": [Any]()])),
            ("messages not a list", try! JSONSerialization.data(withJSONObject: ["messages": "hi"])),
            ("tool role", try! JSONSerialization.data(withJSONObject: Self.chatBody([["role": "tool", "content": "x"], user]))),
            ("no content", try! JSONSerialization.data(withJSONObject: Self.chatBody([["role": "user"]]))),
            ("content not a string", try! JSONSerialization.data(withJSONObject: Self.chatBody([["role": "user", "content": 5]]))),
            ("last is assistant", try! JSONSerialization.data(withJSONObject: Self.chatBody([user, ["role": "assistant", "content": "b"]]))),
            ("last is system", try! JSONSerialization.data(withJSONObject: Self.chatBody([user, ["role": "system", "content": "b"]]))),
            ("model not a string", try! JSONSerialization.data(withJSONObject: Self.chatBody(extra: ["model": 5]))),
            ("max_tokens a string", try! JSONSerialization.data(withJSONObject: Self.chatBody(extra: ["max_tokens": "9"]))),
            ("max_tokens a bool", try! JSONSerialization.data(withJSONObject: Self.chatBody(extra: ["max_tokens": true]))),
            ("max_tokens a fraction", try! JSONSerialization.data(withJSONObject: Self.chatBody(extra: ["max_tokens": 1.5]))),
        ]
        for (i, (label, body)) in bodies.enumerated() {
            ingest(r, DchFrame.encode(DchFrame.chat, [UInt8](body)))
            await waitUntil(label) { finals(r).count > i }
            XCTAssertEqual(Self.message(finals(r).last), "malformed", label)
        }
        XCTAssertEqual(s.get { $0.acquires }, 0, "nothing loads for a refused shape")
        XCTAssertTrue(deltas(r).isEmpty)
    }

    func testAnUnknownModelIsRefused() async {
        let s = State()
        let r = connection(makeChat(s))
        let f = await chat(r, Self.chatBody(extra: ["model": "someone/else"]))
        XCTAssertEqual(Self.message(f), "unknown model")
        XCTAssertEqual(s.get { $0.acquires }, 0)
    }

    func testNoLocalModelIsRefused() async {
        let s = State()
        s.set { $0.onDisk = false }
        let r = connection(makeChat(s))
        let f = await chat(r, Self.chatBody(extra: ["model": Self.modelId]))
        XCTAssertEqual(Self.message(f), "no local model")
        XCTAssertEqual(s.get { $0.acquires }, 0)
    }

    /// The cap is UTF-8 bytes summed over every message: "é" is two bytes.
    func testTooLongCountsEveryMessagesBytes() async {
        let s = State()
        let r = connection(makeChat(s))
        let quarter = String(repeating: "é", count: DchChat.maxContent / 8)   // maxContent / 4 bytes
        let atCap: [[String: Any]] = [["role": "assistant", "content": quarter + quarter], ["role": "user", "content": quarter + quarter]]
        let ok = await chat(r, Self.chatBody(atCap))
        XCTAssertEqual(ok.map(Self.type), DchFrame.chatDone, "exactly the cap is accepted")
        let over: [[String: Any]] = [["role": "assistant", "content": quarter + quarter], ["role": "user", "content": quarter + quarter + "x"]]
        let refused = await chat(r, Self.chatBody(over), final: 2)
        XCTAssertEqual(Self.message(refused), "too long")
        XCTAssertEqual(s.get { $0.acquires }, 1)
    }

    func testMaxTokensDefaultsAndIsClamped() async {
        let s = State()
        let r = connection(makeChat(s))
        let cases: [(Any?, Int)] = [(nil, 1024), (0, 1), (-5, 1), (1, 1), (77, 77), (4096, 4096), (5000, 4096)]
        for (i, (sent, seen)) in cases.enumerated() {
            let f = await chat(r, Self.chatBody(extra: sent.map { ["max_tokens": $0] } ?? [:]), final: i + 1)
            XCTAssertEqual(f.map(Self.type), DchFrame.chatDone)
            XCTAssertEqual(s.get { $0.engine }.calls.last?.maxTokens, seen, "\(sent ?? "absent")")
        }
    }

    // MARK: One at a time

    func testASecondChatWhileOneRunsIsBusy() async {
        let s = State()
        s.set { $0.engine = FakeEngine(.waitForCancel) }
        let chat = makeChat(s)
        let a = connection(chat), b = connection(chat)
        ingest(a, Self.frame(DchFrame.chat, Self.chatBody()))
        await waitUntil("a's first delta") { deltas(a) == ["first"] }
        let f = await self.chat(b, Self.chatBody())
        XCTAssertEqual(Self.message(f), "busy: another chat is running")
        XCTAssertEqual(s.get { $0.acquires }, 1)
    }

    func testOtherRequestsOnAChattingConnectionAreBusy() async {
        let s = State()
        s.set { $0.engine = FakeEngine(.waitForCancel) }
        let r = connection(makeChat(s))
        ingest(r, Self.frame(DchFrame.chat, Self.chatBody()))
        await waitUntil("first delta") { deltas(r) == ["first"] }
        ingest(r, DchFrame.encode(DchFrame.models, []), Self.frame(DchFrame.chat, Self.chatBody()),
               DchFrame.encode(DchFrame.history, []))
        XCTAssertEqual(finals(r).map { Self.message($0) }, Array(repeating: "busy with an earlier request", count: 3))
        XCTAssertEqual(s.get { $0.acquires }, 1)
    }

    func testAChatWhileTheMacAgentRunsIsBusy() async {
        let s = State()
        s.set { $0.macBusy = true }
        let r = connection(makeChat(s))
        let f = await chat(r, Self.chatBody())
        XCTAssertEqual(Self.message(f), "busy: the Mac's agent is running")
        XCTAssertEqual(s.get { $0.acquires }, 0, "the Mac's agent keeps the engine")
        XCTAssertTrue(s.get { $0.scheduled }.isEmpty)
        s.set { $0.macBusy = false }
        let ok = await chat(r, Self.chatBody(), final: 2)
        XCTAssertEqual(ok.map(Self.type), DchFrame.chatDone, "the refusal left no chat running")
    }

    func testClosingTheConnectionMidChatCancelsTheEngine() async {
        let s = State()
        let waiting = FakeEngine(.waitForCancel)
        s.set { $0.engine = waiting }
        let chat = makeChat(s)
        let r = connection(chat)
        ingest(r, Self.frame(DchFrame.chat, Self.chatBody()))
        await waitUntil("first delta") { deltas(r) == ["first"] }
        r.queue.sync { r.conn.close() }
        await waitUntil("the engine sees the cancel") { waiting.cancelled }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(finals(r).isEmpty, "no chatDone, no error to a closed connection")
        // The cancelled chat is over: the next one runs.
        s.set { $0.engine = FakeEngine(.chunks(["ok"])) }
        let next = connection(chat)
        let f = await self.chat(next, Self.chatBody())
        XCTAssertEqual(f.map(Self.type), DchFrame.chatDone)
    }

    func testAnEngineErrorEndsWithOneErrorAndNoDone() async {
        let s = State()
        s.set { $0.engine = FakeEngine(.fail) }
        let r = connection(makeChat(s))
        await chat(r, Self.chatBody())
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(deltas(r), ["partial"])
        XCTAssertEqual(finals(r).count, 1)
        XCTAssertEqual(finals(r).first.map(Self.type), DchFrame.error)
        XCTAssertTrue(Self.message(finals(r).first).hasPrefix("inference error: "), Self.message(finals(r).first))
    }

    // MARK: Attached connections

    /// dch points at a path that does not exist, so the attach forks a child that fails its exec.
    func testAChatOnAnAttachedConnectionIsRefused() async {
        DchCommand.dchPathOverride = tempDir("no-dch").appendingPathComponent("no-such-dch").path
        defer { DchCommand.dchPathOverride = nil }
        let s = State()
        let r = connection(makeChat(s))
        // One ingest: both frames on the queue in one block, before the child's exit can close it.
        ingest(r, Self.frame(DchFrame.attach, ["name": "qa618-attached", "cols": 80, "rows": 24]),
               Self.frame(DchFrame.chat, Self.chatBody()))
        XCTAssertEqual(r.queue.sync { r.conn.attachedSession }, "qa618-attached")
        XCTAssertEqual(Self.message(all(r).last), "chat needs its own connection")
        XCTAssertEqual(s.get { $0.acquires }, 0)
        XCTAssertFalse(r.queue.sync { r.conn.inFlight })
    }

    func testAConnectionThatChattedNeverAttachesOrCreates() async {
        let noDch = tempDir("no-dch").appendingPathComponent("no-such-dch").path
        DchCommand.dchPathOverride = noDch
        defer { DchCommand.dchPathOverride = nil }
        for type in [DchFrame.attach, DchFrame.create] {
            let r = connection(makeChat(State()))
            await chat(r, Self.chatBody())
            ingest(r, Self.frame(type, ["name": "qa618-never", "cols": 80, "rows": 24]))
            XCTAssertEqual(Self.message(all(r).last), "chat connections cannot attach or create", "\(type)")
            XCTAssertNil(r.queue.sync { r.conn.attachedSession }, "no session started")
        }
    }

    // MARK: Release policy

    func testAPhoneLoadedModelIsReleasedAfterTheIdleDelay() async {
        let s = State()
        let r = connection(makeChat(s))
        await chat(r, Self.chatBody())
        XCTAssertEqual(s.get { $0.scheduled.map(\.delay) }, [300])
        XCTAssertEqual(s.get { $0.releases }, 0)
        await fire(s, 0)
        XCTAssertEqual(s.get { $0.releases }, 1)
        XCTAssertFalse(s.get { $0.resident })
    }

    func testAModelTheMacLoadedIsNeverReleased() async {
        let s = State()
        s.set { $0.resident = true }
        let r = connection(makeChat(s))
        await chat(r, Self.chatBody())
        XCTAssertTrue(s.get { $0.scheduled }.isEmpty, "no timer for the Mac's model")
        XCTAssertEqual(s.get { $0.releases }, 0)
    }

    func testTheIdleReleaseWaitsOutARunningChat() async {
        let s = State()
        let chat = makeChat(s)
        let a = connection(chat)
        await self.chat(a, Self.chatBody())
        s.set { $0.engine = FakeEngine(.waitForCancel) }
        let b = connection(chat)
        ingest(b, Self.frame(DchFrame.chat, Self.chatBody()))
        await waitUntil("b's first delta") { deltas(b) == ["first"] }
        await fire(s, 0)
        XCTAssertEqual(s.get { $0.releases }, 0, "a phone chat is running")
        b.queue.sync { b.conn.close() }
        await waitUntil("b's end re-arms the timer") { s.get { $0.scheduled.count } == 2 }
        await fire(s, 1)
        XCTAssertEqual(s.get { $0.releases }, 1, "the phone still owned it")
    }

    func testNoIdleReleaseWhileTheChatWindowIsOpen() async {
        let s = State()
        let r = connection(makeChat(s))
        await chat(r, Self.chatBody())
        s.set { $0.windowOpen = true }
        await fire(s, 0)
        XCTAssertEqual(s.get { $0.releases }, 0)
        // The Mac took the model over: a later phone chat leaves it to the Mac.
        await chat(r, Self.chatBody(), final: 2)
        XCTAssertEqual(s.get { $0.scheduled.count }, 1)
    }

    func testNoIdleReleaseWhileTheMacAgentRuns() async {
        let s = State()
        let r = connection(makeChat(s))
        await chat(r, Self.chatBody())
        s.set { $0.macBusy = true }
        await fire(s, 0)
        XCTAssertEqual(s.get { $0.releases }, 0)
    }

    func testTheIdleTimerRestartsAfterEachChat() async {
        let s = State()
        let r = connection(makeChat(s))
        await chat(r, Self.chatBody())
        await chat(r, Self.chatBody(), final: 2)
        XCTAssertEqual(s.get { $0.scheduled.count }, 2)
        await fire(s, 0)
        XCTAssertEqual(s.get { $0.releases }, 0, "the first timer is stale")
        await fire(s, 1)
        XCTAssertEqual(s.get { $0.releases }, 1)
    }

    /// A chat that arrives while the idle release unloads waits it out, then loads and owns the model.
    func testAChatDuringTheIdleReleaseWaitsAndReclaims() async {
        let s = State()
        let r = connection(makeChat(s))
        await chat(r, Self.chatBody())
        s.set { $0.holdRelease = true }
        guard let fire = s.get({ $0.scheduled.first?.fire }) else { return XCTFail("no timer was armed") }
        let firing = Task { await fire() }
        await waitUntil("the release starts") { s.get { $0.releases } == 1 }
        ingest(r, Self.frame(DchFrame.chat, Self.chatBody()))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(finals(r).count, 1, "the chat waits for the release")
        XCTAssertEqual(s.get { $0.acquires }, 1)
        s.set { $0.holdRelease = false }
        await firing.value
        await waitUntil("the chat's reply") { finals(r).count == 2 }
        XCTAssertEqual(finals(r).last.map(Self.type), DchFrame.chatDone)
        XCTAssertEqual(s.get { $0.acquires }, 2, "loaded again")
        XCTAssertEqual(s.get { $0.scheduled.count }, 2, "and the phone owns it again")
    }

    /// The Mac's own release (its chat window closing) between two phone chats: the next one
    /// acquires again, and now the phone loaded it.
    func testAfterAMacReleaseTheNextChatAcquiresAgain() async {
        let s = State()
        s.set { $0.resident = true }
        let r = connection(makeChat(s))
        await chat(r, Self.chatBody())
        s.set { $0.resident = false }
        let f = await chat(r, Self.chatBody(), final: 2)
        XCTAssertEqual(f.map(Self.type), DchFrame.chatDone)
        XCTAssertEqual(s.get { $0.acquires }, 2)
        XCTAssertEqual(s.get { $0.scheduled.count }, 1)
        await fire(s, 0)
        XCTAssertEqual(s.get { $0.releases }, 1)
    }
}

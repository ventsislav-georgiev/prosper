import Foundation

/// #618: the phone chats with this Mac's local agent model over Remote Terminal (P3 of the
/// phone-parity plan). DchConnection only dispatches 0x1e models and 0x1f chat here; one
/// instance (`shared`) serves every connection, so one phone chat runs at a time.
///
/// Residency: the engine comes from ModelResidencyCoordinator. While it is resident inline
/// autocomplete is off (CoreBridge checks isAgentActive), so a model the PHONE loaded is
/// released again after `idleDelay` with no phone chat, chat window or agent turn. A model
/// the Mac loaded is the Mac's to release (its chat window closing does it).
///
/// Every closure is a seam with the production default; tests never load a model. Under
/// XCTest the default `isModelOnDisk` is false, so an unstubbed test never reaches the
/// coordinator (the handshake of every connection test asks it).
final class DchChat: @unchecked Sendable {
    static let shared = DchChat()

    typealias Reply = DchControlOps.Reply

    /// The one model the phone can use. Read only: agentModel syncs between Macs.
    var modelId: @Sendable () -> String = { Preferences.agentModel }
    var isModelOnDisk: @Sendable (String) -> Bool = {
        NSClassFromString("XCTestCase") == nil && ModelFiles.isModelDownloaded($0)
    }
    var isResident: @Sendable () async -> Bool = { await ModelResidencyCoordinator.shared.currentAgentEngine() != nil }
    var acquire: @Sendable () async throws -> any AgentChatEngine = {
        try await ModelResidencyCoordinator.shared.acquireAgent { _, _ in }
    }
    var release: @Sendable () async -> Void = { await ModelResidencyCoordinator.shared.releaseAgent() }
    /// The Mac's own agent is mid-turn. The llama engine is one actor and a decode never
    /// yields, so a phone chat would block the Mac's agent for a whole generation.
    var macAgentBusy: @MainActor @Sendable () -> Bool = { AgentController.shared.isActive }
    var macChatOpen: @MainActor @Sendable () -> Bool = { ChatWindow.shared.isOpen }
    var idleDelay: TimeInterval = 300
    /// Runs `fire` after `delay` seconds; tests capture it and fire by hand.
    var schedule: @Sendable (_ delay: TimeInterval, _ fire: @escaping @Sendable () async -> Void) -> Void = { delay, fire in
        Task {
            try? await Task.sleep(for: .seconds(delay))
            await fire()
        }
    }

    static let roles: Set<String> = ["system", "user", "assistant"]
    static let defaultMaxTokens = 1024
    static let maxTokensRange = 1...4096
    /// Total UTF-8 bytes of every message's content.
    static let maxContent = 256 << 10

    private let lock = NSLock()
    /// A phone chat holds the model (any connection).
    private var running = false
    /// The phone's acquire loaded the model; the idle timer may free it.
    private var phoneLoaded = false
    /// Bumped per armed timer: only the newest one may release.
    private var idleGeneration = 0
    /// The idle release in progress; a chat waits it out before its own acquire.
    private var releasing: Task<Void, Never>?

    /// "chat" joins machineInfo's ops only while this is true.
    var available: Bool { isModelOnDisk(modelId()) }

    struct Request {
        var model: String?
        var turns: [MLXEngine.ChatTurn]
        var maxTokens: Int
    }

    static func error(_ message: String) -> Data { DchControlOps.error(message) }

    /// `{model?, messages: [{role, content}], max_tokens?}`; nil for any other shape. Unknown
    /// keys are ignored. max_tokens is clamped to maxTokensRange.
    static func parse(_ payload: Data) -> Request? {
        guard let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let raw = o["messages"] as? [Any], !raw.isEmpty else { return nil }
        var turns: [MLXEngine.ChatTurn] = []
        for m in raw {
            guard let m = m as? [String: Any], let role = m["role"] as? String, roles.contains(role),
                  let content = m["content"] as? String else { return nil }
            turns.append(MLXEngine.ChatTurn(role: role, content: content))
        }
        guard turns.last?.role == "user" else { return nil }
        var req = Request(turns: turns, maxTokens: defaultMaxTokens)
        if let v = o["model"] {
            guard let s = v as? String else { return nil }
            req.model = s
        }
        if let v = o["max_tokens"] {
            // A JSON integer, never a bool (DchSessionMeta.count's rule).
            guard let n = DchSessionMeta.count(v) else { return nil }
            req.maxTokens = min(max(n, maxTokensRange.lowerBound), maxTokensRange.upperBound)
        }
        return req
    }

    /// 0x1e: modelsResp `[{id, name, loaded}]`, the agent model only when it is on disk.
    func models(_ payload: Data, reply: Reply) async {
        let o = payload.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        guard o?.isEmpty == true else { return reply(Self.error("malformed models request: send nothing or {}")) }
        let id = modelId()
        guard isModelOnDisk(id) else { return reply(DchFrame.encode(DchFrame.modelsResp, json: [Any]())) }
        let row: [String: Any] = ["id": id, "name": AgentModelRegistry.model(for: id).label, "loaded": await isResident()]
        reply(DchFrame.encode(DchFrame.modelsResp, json: [row]))
    }

    /// 0x1f: chatDelta frames through `send`, then exactly one `reply`: chatDone or an error.
    /// Nothing goes out before the first delta, which can be 30 s or more on a first load.
    func chat(_ payload: Data, send: @escaping Reply, reply: Reply) async {
        guard let req = Self.parse(payload) else { return reply(Self.error("malformed")) }
        guard req.turns.reduce(0, { $0 + $1.content.utf8.count }) <= Self.maxContent else {
            return reply(Self.error("too long"))
        }
        let id = modelId()
        guard isModelOnDisk(id) else { return reply(Self.error("no local model")) }
        guard req.model == nil || req.model == id else { return reply(Self.error("unknown model")) }
        let claimed = lock.withLock { () -> Bool in
            guard !running else { return false }
            running = true
            return true
        }
        guard claimed else { return reply(Self.error("busy: another chat is running")) }
        if await macAgentBusy() {
            lock.withLock { running = false }
            return reply(Self.error("busy: the Mac's agent is running"))
        }
        let final = await generate(req, send: send)
        // Free before the reply, so the phone's next chat is never refused as busy.
        lock.withLock { running = false }
        armIdleTimer()
        reply(final)
    }

    private func generate(_ req: Request, send: Reply) async -> Data {
        let pending = lock.withLock { releasing }
        await pending?.value
        let engine: any AgentChatEngine
        do {
            let before = await isResident()
            engine = try await acquire()
            if !before { lock.withLock { phoneLoaded = true } }
        } catch {
            return Self.error("model load error: \(error)")
        }
        do {
            // Closing the connection cancels this Task; the stream ends its generation.
            let stream = engine.generateChat(messages: req.turns, tools: [], maxTokens: req.maxTokens,
                                             temperature: 0.7, topP: 0.95, stop: [])
            for try await chunk in stream where !chunk.isEmpty {
                send(DchFrame.encode(DchFrame.chatDelta, json: ["text": chunk]))
            }
        } catch {
            return Self.error("inference error: \(error)")
        }
        // The engine can't tell a natural stop from the max_tokens limit, so this is always "stop".
        // A cancelled chat (connection closed) ends here too; its reply is dropped.
        return DchFrame.encode(DchFrame.chatDone, json: ["stop": "stop"])
    }

    /// (Re)starts the idle release after a chat, only for a model the phone loaded.
    private func armIdleTimer() {
        let gen = lock.withLock { () -> Int? in
            guard phoneLoaded else { return nil }
            idleGeneration += 1
            return idleGeneration
        }
        guard let gen else { return }
        schedule(idleDelay) { [self] in await idleFired(gen) }
    }

    /// The newest timer, with no phone chat running: releases unless the Mac's chat window
    /// is open or its agent is mid-turn. In those two the Mac is using the model and its own
    /// lifecycle releases it, so the phone gives up its claim.
    private func idleFired(_ gen: Int) async {
        func current() -> Bool { phoneLoaded && idleGeneration == gen && !running }
        // One check, after the hop: a chat that claims first makes it false, one that claims
        // later waits on `releasing`.
        let macUsing = await macChatOpen() ? true : await macAgentBusy()
        let task = lock.withLock { () -> Task<Void, Never>? in
            guard current() else { return nil }
            phoneLoaded = false
            guard !macUsing else { return nil }
            let release = release
            let t = Task { await release() }
            releasing = t
            return t
        }
        guard let task else { return }
        await task.value
        lock.withLock { if releasing == task { releasing = nil } }
    }
}

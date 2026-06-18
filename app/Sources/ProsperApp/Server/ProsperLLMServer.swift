import Foundation
import MLXLMCommon
import Network
import os.log

/// Localhost OpenAI-compatible inference server bridging an embedded coding-agent
/// harness (Codex, etc.) to the in-process MLX model.
///
/// Design goals (per the build plan): **lightweight** — Network.framework only, zero
/// new dependencies, no swift-nio; **robust** — tolerant request parsing, per-format
/// tool-call extraction, and a schema-validate + repair-retry ladder since MLX Swift
/// has no grammar-constrained decoding.
///
/// Surface:
///   • `POST /v1/chat/completions` — streaming (SSE) and non-streaming.
///   • `GET  /v1/models` — advertises the resident agent model.
///   • `GET  /health` — unauthenticated liveness.
///
/// The model is acquired from `ModelResidencyCoordinator` (one-resident-model: the
/// inline Gemma model is unloaded while the agent runs) and cached across requests.
/// Auth is a bearer token minted at start; clients pass it as `Authorization: Bearer`.
final class ProsperLLMServer: @unchecked Sendable {
    static let shared = ProsperLLMServer()

    private let log = Logger(subsystem: "com.prosper.app", category: "LLMServer")
    private let queue = DispatchQueue(label: "com.prosper.llmserver")
    private var listener: NWListener?
    /// Live connections, retained until they close. Without this an accepted
    /// `HTTPConnection` would deallocate the moment `accept()` returns (its NWConnection
    /// handlers hold `weak self`), so the reply is never written. Mutated on `queue`.
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]

    /// Bound port, valid after `start()` returns. 0 until then.
    private(set) var port: UInt16 = 0
    /// Bearer token required on `/v1/*`. Minted per `start()`.
    private(set) var token: String = ""

    private init() {}

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }
    var isRunning: Bool { listener != nil }

    // MARK: - Lifecycle

    /// Bind to an ephemeral loopback port and begin accepting connections. Idempotent:
    /// returns the existing endpoint if already running.
    @discardableResult
    func start() throws -> (port: UInt16, token: String) {
        if let listener, listener.state == .ready || listener.state == .setup {
            return (port, token)
        }
        let params = NWParameters.tcp
        // Loopback only — never expose the model to the network.
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        self.listener = listener
        self.token = Self.mintToken()

        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = self.listener?.port?.rawValue ?? 0
                self.log.info("LLM server ready on 127.0.0.1:\(self.port, privacy: .public)")
                sem.signal()
            case .failed(let err):
                self.log.error("LLM server failed: \(String(describing: err), privacy: .public)")
                sem.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)

        // Wait briefly for the port to bind so callers get a usable endpoint.
        if sem.wait(timeout: .now() + 5) == .timedOut {
            self.log.error("LLM server bind timed out")
        }
        guard port != 0 else {
            stop()
            throw ServerError.bindFailed
        }
        return (port, token)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
        queue.async { [weak self] in self?.connections.removeAll() }
    }

    private static func mintToken() -> String {
        "prosper-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    enum ServerError: Error { case bindFailed }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        let handler = HTTPConnection(conn: conn, server: self, queue: queue, log: log) { [weak self] id in
            self?.connections.removeValue(forKey: id)
        }
        connections[ObjectIdentifier(handler)] = handler   // retain until it closes
        handler.start()
    }

    // MARK: - Routing (called by HTTPConnection)

    /// Resolve a request to a response. Streaming responses are produced by the
    /// connection via `streamCompletion`; this returns a non-streaming buffer or an
    /// error status.
    fileprivate func authorize(_ req: HTTPRequest) -> Bool {
        guard let auth = req.header("authorization") else { return false }
        return Self.constantTimeEqual(auth, "Bearer \(token)")
    }

    /// Length-independent, content-constant-time string compare so a local attacker
    /// can't recover the bearer token byte-by-byte via response-timing. Loopback-only
    /// makes this largely belt-and-suspenders, but the token gates all inference.
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        // Compare against y's bytes; when lengths differ the count XOR already forces a
        // mismatch. Index y modulo its length, guarding the empty case so `y[0]` can't
        // fault if this is ever called with an empty expected value.
        guard !y.isEmpty else { return x.isEmpty }
        var diff = x.count ^ y.count
        for i in 0..<x.count { diff |= Int(x[i] ^ y[i % y.count]) }
        return diff == 0
    }

    /// Cancel every in-flight generation across all connections (user pressed Stop).
    /// A codex turn-interrupt may leave the HTTP request open (keep-alive pooling),
    /// so the app cancels server-side directly for an instant GPU stop.
    func cancelActiveGenerations() {
        queue.async { for c in self.connections.values { c.cancelInflight() } }
    }

    fileprivate func modelsBody() -> Data {
        let id = Preferences.agentModel
        let body: [String: Any] = [
            "object": "list",
            "data": [["id": id, "object": "model", "owned_by": "prosper"] as [String: Any]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}

// MARK: - Minimal HTTP/1.1 connection

/// Parses one or more HTTP/1.1 requests off a single connection and dispatches them.
/// Only the subset the agent harness uses is implemented: GET, POST with
/// `Content-Length` bodies, keep-alive, and chunked SSE responses.
private final class HTTPConnection: @unchecked Sendable {
    private let conn: NWConnection
    private unowned let server: ProsperLLMServer
    private let queue: DispatchQueue
    private let log: Logger
    private var buffer = Data()
    /// Called once when the connection closes, so the server drops its retaining
    /// reference. Without the server's retain this object would deallocate before
    /// it could reply (its NWConnection handlers hold `weak self`).
    private let onClose: (ObjectIdentifier) -> Void
    private var closed = false
    /// In-flight generation tasks, cancelled on close (client gone) or on demand
    /// (user Stop) so an abandoned request stops burning GPU immediately.
    /// Mutated on `queue`.
    private var inflight: [UUID: Task<Void, Never>] = [:]
    /// True while a generation request is being answered. Requests are handled
    /// strictly one at a time per connection: a pipelined second request would
    /// otherwise interleave its response bytes into the first one's SSE stream.
    private var busy = false
    /// True once the current request's SSE header hit the wire — decides whether
    /// an error is reported as a 500 JSON response or an in-stream SSE event.
    private var headerSent = false

    init(conn: NWConnection, server: ProsperLLMServer, queue: DispatchQueue, log: Logger,
         onClose: @escaping (ObjectIdentifier) -> Void) {
        self.conn = conn
        self.server = server
        self.queue = queue
        self.log = log
        self.onClose = onClose
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    /// If the server drops us (`stop()` clears its connection map) without going through
    /// `close()`, the generation Tasks would keep decoding on the GPU until their next
    /// cancellation checkpoint. Cancelling here stops them at dealloc. `Task.cancel()` is
    /// thread-safe and we're the last reference, so touching `inflight` is safe.
    deinit { for task in inflight.values { task.cancel() } }

    /// Idempotent teardown: cancel the socket and release the server's reference.
    private func close() {
        guard !closed else { return }
        closed = true
        cancelInflight()
        conn.cancel()
        onClose(ObjectIdentifier(self))
    }

    /// Cancel any in-flight generations on this connection. Runs on `queue`.
    func cancelInflight() {
        for task in inflight.values { task.cancel() }
        inflight.removeAll()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    /// Pull complete requests out of the rolling buffer. Stops while a generation
    /// request is in flight (`busy`); its completion re-drains.
    private func drain() {
        while !busy {
            switch HTTPRequest.parse(&buffer) {
            case .request(let req):
                handle(req)
            case .overflow:
                // Close only after the 413 reaches the wire — `close()` cancels the
                // socket, and an immediate cancel can drop the unflushed response.
                sendJSON(["error": ["message": "request body too large", "type": "invalid_request_error"]],
                         status: 413, thenClose: true)
                return
            case .badRequest:
                sendJSON(["error": ["message": "malformed request framing", "type": "invalid_request_error"]],
                         status: 400, thenClose: true)
                return
            case nil:
                return
            }
        }
    }

    private func handle(_ req: HTTPRequest) {
        // Health is unauthenticated.
        if req.method == "GET", req.path == "/health" {
            sendJSON(["status": "ok"], status: 200)
            return
        }
        guard server.authorize(req) else {
            sendJSON(["error": ["message": "unauthorized", "type": "invalid_request_error"]], status: 401)
            return
        }
        switch (req.method, req.path) {
        case ("GET", "/v1/models"):
            send(server.modelsBody(), status: 200, contentType: "application/json")
        case ("POST", "/v1/chat/completions"):
            handleCompletion(req)
        case ("POST", "/v1/responses"):
            handleResponses(req)
        default:
            sendJSON(["error": ["message": "not found", "type": "invalid_request_error"]], status: 404)
        }
    }

    private func handleCompletion(_ req: HTTPRequest) {
        guard let parsed = OpenAIChatRequest(data: req.body) else {
            sendJSON(["error": ["message": "invalid JSON body", "type": "invalid_request_error"]], status: 400)
            return
        }
        let format = AgentModelRegistry.toolFormat(for: Preferences.agentModel)
        let modelLabel = parsed.model ?? Preferences.agentModel
        let responseID = "chatcmpl-" + UUID().uuidString.prefix(12)

        busy = true
        headerSent = false
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.queue.async {
                    self.inflight.removeValue(forKey: taskID)
                    self.busy = false
                    self.drain()
                }
            }
            do {
                let engine = try await ModelResidencyCoordinator.shared.acquireAgent { _, _ in }
                if parsed.stream {
                    try await self.streamCompletion(
                        engine: engine, request: parsed, format: format,
                        responseID: String(responseID), model: modelLabel
                    )
                } else {
                    try await self.bufferedCompletion(
                        engine: engine, request: parsed, format: format,
                        responseID: String(responseID), model: modelLabel
                    )
                }
            } catch is CancellationError {
                // User stop / client gone. If SSE already started and the socket is
                // still up (user Stop, not a dead peer), terminate the stream so the
                // client isn't left waiting on a half-open event stream.
                if self.headerSent { self.sendSSEDone() }
            } catch {
                self.log.error("completion failed: \(String(describing: error), privacy: .public)")
                if self.headerSent {
                    // SSE already started — a 500 status line mid-stream would corrupt
                    // the framing. Report in-band and terminate the stream.
                    self.sendSSEChunk((try? JSONSerialization.data(withJSONObject:
                        ["error": ["message": "inference error: \(error)", "type": "server_error"]])) ?? Data())
                    self.sendSSEDone()
                } else {
                    self.sendJSON(
                        ["error": ["message": "inference error: \(error)", "type": "server_error"]],
                        status: 500
                    )
                }
            }
        }
        inflight[taskID] = task
    }

    // MARK: Responses API (POST /v1/responses)

    /// codex ≥ 0.139 speaks only the Responses wire. The request is reduced to the
    /// chat representation (see `ResponsesRequest`) so it reuses the same
    /// generate/validate/repair pipeline; only the response envelope differs.
    private func handleResponses(_ req: HTTPRequest) {
        guard let parsed = ResponsesRequest(data: req.body) else {
            sendJSON(["error": ["message": "invalid JSON body", "type": "invalid_request_error"]], status: 400)
            return
        }
        let format = AgentModelRegistry.toolFormat(for: Preferences.agentModel)
        let modelLabel = parsed.model ?? Preferences.agentModel
        let responseID = "resp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)

        busy = true
        headerSent = false
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.queue.async {
                    self.inflight.removeValue(forKey: taskID)
                    self.busy = false
                    self.drain()
                }
            }
            do {
                let engine = try await ModelResidencyCoordinator.shared.acquireAgent { _, _ in }
                if parsed.stream {
                    try await self.streamResponses(
                        engine: engine, request: parsed, format: format,
                        responseID: String(responseID), model: modelLabel
                    )
                } else {
                    try await self.bufferedResponses(
                        engine: engine, request: parsed, format: format,
                        responseID: String(responseID), model: modelLabel
                    )
                }
            } catch is CancellationError {
                // User stop / client gone — close the SSE stream if it was already open.
                if self.headerSent { self.sendSSEDone() }
            } catch {
                self.log.error("responses failed: \(String(describing: error), privacy: .public)")
                if parsed.stream, self.headerSent {
                    self.sendSSEEvent("response.failed", ResponsesPayload.failed(sequence: 0, message: "inference error: \(error)"))
                    self.sendSSEDone()
                } else {
                    // SSE header not on the wire yet (e.g. model load failed) —
                    // a plain 500 keeps the HTTP framing valid.
                    self.sendJSON(
                        ["error": ["message": "inference error: \(error)", "type": "server_error"]],
                        status: 500
                    )
                }
            }
        }
        inflight[taskID] = task
    }

    private func bufferedResponses(
        engine: MLXEngine, request: ResponsesRequest, format: ToolCallFormat,
        responseID: String, model: String
    ) async throws {
        let chat = request.chatRequest
        let result = try await generateValidated(engine: engine, request: chat, format: format)
        let promptTokens = Self.estimateTokens(chat.messages.map(\.content))
        let completionTokens = Self.estimateTokens(result.rawText)
        let body = ResponsesPayload.nonStreaming(
            id: responseID, model: model, content: result.parsed.content,
            toolCalls: result.parsed.toolCalls,
            promptTokens: promptTokens, completionTokens: completionTokens
        )
        send(body, status: 200, contentType: "application/json")
    }

    /// Stream the Responses SSE event sequence codex consumes:
    /// `response.created` → per-item `output_item.added`/`output_text.delta`/
    /// `output_item.done` → `response.completed`. Like the chat path, a tool-capable
    /// turn is buffered whole (tool args must validate before emission); a pure-text
    /// turn streams text deltas live.
    private func streamResponses(
        engine: MLXEngine, request: ResponsesRequest, format: ToolCallFormat,
        responseID: String, model: String
    ) async throws {
        let chat = request.chatRequest
        sendSSEHeader()
        var seq = 0
        func emit(_ type: String, _ data: Data) { sendSSEEvent(type, data); seq += 1 }

        // response.created (in-progress shell).
        emit("response.created", ResponsesPayload.created(
            sequence: seq,
            response: ResponsesPayload.responseObject(
                id: responseID, model: model, status: "in_progress", output: [],
                promptTokens: 0, completionTokens: 0)
        ))

        var output: [[String: Any]] = []
        var outputIndex = 0
        var rawText = ""

        self.log.info("responses: stream turn — msgs=\(chat.messages.count, privacy: .public) tools=\(chat.tools.count, privacy: .public) maxTokens=\(chat.maxTokens, privacy: .public)")

        if !chat.tools.isEmpty {
            // Tool-capable: stream the pre-tool-call prose LIVE (the user other-
            // wise stares at a spinner for the whole decode), then validate the
            // buffered tool calls. Repair retries (rare) stay fully buffered.
            let itemID = "msg_\(responseID)"
            var splitter = StreamSplitter(markers: Self.markers(for: format))
            var addedItem = false
            var streamed = ""
            let result = try await generateValidated(engine: engine, request: chat, format: format) { chunk in
                let delta = splitter.ingest(chunk)
                guard !delta.isEmpty else { return }
                if !addedItem {
                    addedItem = true
                    emit("response.output_item.added", ResponsesPayload.outputItemAdded(
                        sequence: seq, index: outputIndex,
                        item: ResponsesPayload.messageItem(id: itemID, text: "", status: "in_progress")))
                }
                emit("response.output_text.delta", ResponsesPayload.outputTextDelta(
                    sequence: seq, itemID: itemID, index: outputIndex, delta: delta))
                streamed += delta
            }
            rawText = result.rawText
            self.log.info("responses: gen done — rawLen=\(result.rawText.count, privacy: .public) contentLen=\(result.parsed.content.count, privacy: .public) toolCalls=\(result.parsed.toolCalls.count, privacy: .public) rawHead=\(result.rawText.prefix(120), privacy: .public)")
            if !result.parsed.content.isEmpty || addedItem {
                // Final text: the validated parse (falls back to what was streamed
                // when a repair pass produced no prose). Emit only the unsent
                // suffix as a delta; the done item carries the full text.
                let final = result.parsed.content.isEmpty ? streamed : result.parsed.content
                if !addedItem {
                    emit("response.output_item.added", ResponsesPayload.outputItemAdded(
                        sequence: seq, index: outputIndex,
                        item: ResponsesPayload.messageItem(id: itemID, text: "", status: "in_progress")))
                } else if final.hasPrefix(streamed), final.count > streamed.count {
                    emit("response.output_text.delta", ResponsesPayload.outputTextDelta(
                        sequence: seq, itemID: itemID, index: outputIndex,
                        delta: String(final.dropFirst(streamed.count))))
                }
                let item = ResponsesPayload.messageItem(id: itemID, text: final)
                emit("response.output_item.done", ResponsesPayload.outputItemDone(sequence: seq, index: outputIndex, item: item))
                output.append(item); outputIndex += 1
            }
            for (i, call) in result.parsed.toolCalls.enumerated() {
                let item = ResponsesPayload.functionCallItem(id: "fc_\(responseID)_\(i)", call: call)
                emit("response.output_item.added", ResponsesPayload.outputItemAdded(sequence: seq, index: outputIndex, item: item))
                emit("response.output_item.done", ResponsesPayload.outputItemDone(sequence: seq, index: outputIndex, item: item))
                output.append(item); outputIndex += 1
            }
        } else {
            // Pure text: stream deltas live with the marker tail-guard.
            let itemID = "msg_\(responseID)"
            emit("response.output_item.added", ResponsesPayload.outputItemAdded(
                sequence: seq, index: outputIndex,
                item: ResponsesPayload.messageItem(id: itemID, text: "", status: "in_progress")))
            var splitter = StreamSplitter(markers: Self.markers(for: format))
            let stream = engine.generateChat(
                messages: chat.chatTurns(format: format), tools: [],
                maxTokens: chat.maxTokens, temperature: chat.temperature,
                topP: chat.topP, stop: chat.stop
            )
            for try await chunk in stream {
                rawText += chunk
                let delta = splitter.ingest(chunk)
                if !delta.isEmpty {
                    emit("response.output_text.delta", ResponsesPayload.outputTextDelta(
                        sequence: seq, itemID: itemID, index: outputIndex, delta: delta))
                }
            }
            try Task.checkCancellation()
            let tail = splitter.finish()
            if !tail.isEmpty {
                emit("response.output_text.delta", ResponsesPayload.outputTextDelta(
                    sequence: seq, itemID: itemID, index: outputIndex, delta: tail))
            }
            let parsed = ToolCallParser.parse(rawText, format: format)
            let item = ResponsesPayload.messageItem(id: itemID, text: parsed.content)
            emit("response.output_item.done", ResponsesPayload.outputItemDone(sequence: seq, index: outputIndex, item: item))
            output.append(item); outputIndex += 1
        }

        let promptTokens = Self.estimateTokens(chat.messages.map(\.content))
        let completionTokens = Self.estimateTokens(rawText)
        emit("response.completed", ResponsesPayload.completed(
            sequence: seq,
            response: ResponsesPayload.responseObject(
                id: responseID, model: model, status: "completed", output: output,
                promptTokens: promptTokens, completionTokens: completionTokens)
        ))
        sendSSEDone()
    }

    // MARK: Non-streaming

    private func bufferedCompletion(
        engine: MLXEngine, request: OpenAIChatRequest, format: ToolCallFormat,
        responseID: String, model: String
    ) async throws {
        let result = try await generateValidated(engine: engine, request: request, format: format)
        let promptTokens = Self.estimateTokens(request.messages.map(\.content))
        let completionTokens = Self.estimateTokens(result.rawText)
        let body = OpenAIChatResponse.nonStreaming(
            id: responseID, model: model, content: result.parsed.content,
            toolCalls: result.parsed.toolCalls,
            promptTokens: promptTokens, completionTokens: completionTokens
        )
        send(body, status: 200, contentType: "application/json")
    }

    // MARK: Streaming (SSE)

    private func streamCompletion(
        engine: MLXEngine, request: OpenAIChatRequest, format: ToolCallFormat,
        responseID: String, model: String
    ) async throws {
        sendSSEHeader()
        let hasTools = !request.tools.isEmpty

        if hasTools {
            // Tool-capable turn: must buffer fully to validate/repair tool args
            // before emitting (cannot un-send a streamed tool call).
            let result = try await generateValidated(engine: engine, request: request, format: format)
            if !result.parsed.content.isEmpty {
                sendSSEChunk(OpenAIChatResponse.contentChunk(id: responseID, model: model, delta: result.parsed.content))
            }
            if !result.parsed.toolCalls.isEmpty {
                sendSSEChunk(OpenAIChatResponse.toolCallsChunk(id: responseID, model: model, toolCalls: result.parsed.toolCalls))
            }
            let reason = result.parsed.hasToolCalls ? "tool_calls" : "stop"
            sendSSEChunk(OpenAIChatResponse.finishChunk(id: responseID, model: model, reason: reason))
            sendSSEDone()
            return
        }

        // No tools requested → pure content; stream live with a tail-guard so we
        // never split a (defensively watched) marker across a delta.
        var splitter = StreamSplitter(markers: Self.markers(for: format))
        let stream = engine.generateChat(
            messages: request.chatTurns(format: format), tools: [],
            maxTokens: request.maxTokens, temperature: request.temperature,
            topP: request.topP, stop: request.stop
        )
        for try await chunk in stream {
            let delta = splitter.ingest(chunk)
            if !delta.isEmpty {
                sendSSEChunk(OpenAIChatResponse.contentChunk(id: responseID, model: model, delta: delta))
            }
        }
        try Task.checkCancellation()
        let tail = splitter.finish()
        if !tail.isEmpty {
            sendSSEChunk(OpenAIChatResponse.contentChunk(id: responseID, model: model, delta: tail))
        }
        sendSSEChunk(OpenAIChatResponse.finishChunk(id: responseID, model: model, reason: "stop"))
        sendSSEDone()
    }

    // MARK: Generation + validate/repair ladder

    struct GenerationResult {
        let rawText: String
        let parsed: ToolCallParseResult
    }

    /// Run generation, parse tool calls, validate their arguments against the request
    /// tool schemas, and repair-retry up to `maxRepairs` times by feeding the model
    /// its bad call plus a corrective message. Returns the first valid result (or the
    /// last attempt if repairs are exhausted). `onChunk`, when given, observes the
    /// raw stream of the FIRST attempt only (live UI deltas; repair retries stay
    /// buffered so a corrected answer is never streamed twice).
    private func generateValidated(
        engine: MLXEngine, request: OpenAIChatRequest, format: ToolCallFormat,
        maxRepairs: Int = 2, onChunk: ((String) -> Void)? = nil
    ) async throws -> GenerationResult {
        var turns = request.chatTurns(format: format)
        var attempt = 0
        var last: GenerationResult?

        while attempt <= maxRepairs {
            let raw = try await collect(
                engine: engine, turns: turns, tools: request.tools,
                request: request, onChunk: attempt == 0 ? onChunk : nil
            )
            let parsed = ToolCallParser.parse(raw, format: format)
            let result = GenerationResult(rawText: raw, parsed: parsed)
            last = result

            let errors = SchemaValidator.validate(toolCalls: parsed.toolCalls, against: request.tools)
            if errors.isEmpty { return result }

            attempt += 1
            if attempt > maxRepairs { break }
            self.log.info("tool-call validation failed (attempt \(attempt, privacy: .public)): \(errors.joined(separator: "; "), privacy: .public)")
            // Append the model's faulty turn + a corrective instruction, then retry.
            let serialized = ToolCallParser.serializeAssistant(
                content: parsed.content, toolCalls: parsed.toolCalls, format: format
            )
            turns.append(MLXEngine.ChatTurn(role: "assistant", content: serialized))
            turns.append(MLXEngine.ChatTurn(
                role: "user",
                content: "Your tool call was invalid: \(errors.joined(separator: "; ")). "
                    + "Re-issue the tool call with arguments that exactly match the tool's JSON schema."
            ))
        }
        return last ?? GenerationResult(rawText: "", parsed: ToolCallParseResult(content: "", toolCalls: []))
    }

    /// Drain a full generation into one string, optionally observing each chunk.
    private func collect(
        engine: MLXEngine, turns: [MLXEngine.ChatTurn], tools: [ToolSpec],
        request: OpenAIChatRequest, onChunk: ((String) -> Void)? = nil
    ) async throws -> String {
        var out = ""
        let stream = engine.generateChat(
            messages: turns, tools: tools,
            maxTokens: request.maxTokens, temperature: request.temperature,
            topP: request.topP, stop: request.stop
        )
        for try await chunk in stream {
            out += chunk
            onChunk?(chunk)
        }
        // A cancelled consumer ends the stream early without throwing — surface it
        // so the validate/repair ladder (and SSE emission) stops instead of acting
        // on a truncated generation.
        try Task.checkCancellation()
        return out
    }

    private static func estimateTokens(_ s: String) -> Int { max(1, s.count / 4) }
    /// Same ~4-chars/token estimate over many strings without allocating their join
    /// (the prompt can be multi-MB; joining it just to count chars is wasted copying).
    private static func estimateTokens<S: Sequence>(_ parts: S) -> Int where S.Element == String {
        max(1, parts.reduce(0) { $0 + $1.count } / 4)
    }

    /// Open markers we defensively avoid splitting mid-delta while streaming content.
    private static func markers(for format: ToolCallFormat) -> [String] {
        switch format {
        // `<function=` too: Qwen3-Coder routinely skips the opening `<tool_call>`
        // tag and starts the call block directly (ToolCallParser back-off parses
        // it); without the marker the block streams as user-visible prose.
        case .qwenXML, .hermesJSON: return ["<tool_call>", "<function="]
        case .mistral: return ["[TOOL_CALLS]"]
        case .harmony: return ["<|channel|>", "<|message|>", "to=functions."]
        case .nemotron: return ["<toolcall>", "<think>"]
        case .glm: return ["<tool_call>", "<arg_key>", "<arg_value>", "<think>"]
        case .kimi: return ["<|tool_calls_section_begin|>", "<|tool_call_begin|>", "<think>"]
        case .minimax: return ["<minimax:tool_call>", "<invoke name=", "<think>"]
        }
    }

    // MARK: Writers

    private func sendJSON(_ obj: [String: Any], status: Int, thenClose: Bool = false) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        send(data, status: status, contentType: "application/json", thenClose: thenClose)
    }

    private func send(_ body: Data, status: Int, contentType: String, thenClose: Bool = false) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(thenClose ? "close" : "keep-alive")\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        sendRaw(out, thenClose: thenClose)
    }

    private func sendSSEHeader() {
        headerSent = true
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: keep-alive\r\n\r\n"
        sendRaw(Data(head.utf8))
    }

    private func sendSSEChunk(_ json: Data) {
        var out = Data("data: ".utf8)
        out.append(json)
        out.append(Data("\n\n".utf8))
        sendRaw(out)
    }

    /// Responses-API SSE frame: a named `event:` line plus the `data:` JSON. codex
    /// keys on the `type` field inside the JSON, but OpenAI sends both, so we match.
    private func sendSSEEvent(_ event: String, _ json: Data) {
        var out = Data("event: \(event)\ndata: ".utf8)
        out.append(json)
        out.append(Data("\n\n".utf8))
        sendRaw(out)
    }

    private func sendSSEDone() {
        sendRaw(Data("data: [DONE]\n\n".utf8))
    }

    /// All wire writes funnel here: a send error means the peer is gone, so tear
    /// the connection down — which cancels in-flight generation and stops the GPU
    /// instead of decoding for a dead socket.
    private func sendRaw(_ data: Data, thenClose: Bool = false) {
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil || thenClose { self.queue.async { self.close() } }
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

// MARK: - HTTP request

/// A parsed HTTP/1.1 request. `parse` consumes one complete request from `buffer`
/// (headers + Content-Length body) and returns nil if more bytes are needed.
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]   // lowercased keys
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    enum ParseOutcome {
        case request(HTTPRequest)
        /// Declared body exceeds `maxBody` — reject instead of buffering it.
        case overflow
        /// Malformed framing (bad/duplicate Content-Length, chunked encoding we don't
        /// implement) — reject with 400 instead of guessing the body boundary.
        case badRequest
    }

    /// Largest accepted request body. Agent prompts are at most a few MB; the cap
    /// stops a buggy/hostile local client from ballooning the rolling buffer.
    static let maxBody = 32 << 20

    static func parse(_ buffer: inout Data) -> ParseOutcome? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            // No header terminator yet — but never buffer unbounded garbage.
            if buffer.count > 64 << 10 { buffer.removeAll(); return .overflow }
            return nil
        }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            buffer.removeAll()
            return nil
        }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { buffer.removeAll(); return nil }
        let method = String(requestLine[0])
        let path = String(requestLine[1])

        var headers: [String: String] = [:]
        var clCount = 0
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "content-length" { clCount += 1 }
            headers[key] = value
        }

        // We frame bodies by Content-Length only. Chunked transfer-encoding would make
        // the byte count a lie and desync the parser — reject rather than mis-read.
        if let te = headers["transfer-encoding"], te.lowercased().contains("chunked") {
            buffer.removeAll()
            return .badRequest
        }
        // A duplicate or non-numeric Content-Length is a request-smuggling vector and an
        // ambiguous body boundary — reject instead of defaulting to 0 and mis-framing.
        if clCount > 1 { buffer.removeAll(); return .badRequest }
        let contentLength: Int
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { buffer.removeAll(); return .badRequest }
            contentLength = n
        } else {
            contentLength = 0
        }
        guard contentLength <= maxBody else {
            buffer.removeAll()
            return .overflow
        }
        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        if available < contentLength { return nil }   // wait for the rest of the body

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)
        return .request(HTTPRequest(method: method, path: path, headers: headers, body: body))
    }
}

// MARK: - Live content streamer with tail guard

/// Streams decoded content while holding back a small tail so a tool-call open marker
/// can never be emitted as user-visible content split across two deltas. On the first
/// marker occurrence it stops emitting (the buffered remainder is parsed by the
/// caller). For the default Qwen path with no tool request this simply streams prose.
struct StreamSplitter {
    private let markers: [String]
    private let guardLen: Int
    private var acc = ""
    private var sent = 0
    private var stopped = false

    init(markers: [String]) {
        self.markers = markers
        self.guardLen = max(0, (markers.map(\.count).max() ?? 1) - 1)
    }

    mutating func ingest(_ chunk: String) -> String {
        acc += chunk
        guard !stopped else { return "" }
        if let pos = earliestMarker() {
            stopped = true
            return emit(upTo: pos)
        }
        return emit(upTo: max(sent, acc.count - guardLen))
    }

    mutating func finish() -> String {
        guard !stopped else { return "" }
        return emit(upTo: acc.count)
    }

    private func earliestMarker() -> Int? {
        var best: Int?
        for m in markers {
            if let r = acc.range(of: m) {
                let p = acc.distance(from: acc.startIndex, to: r.lowerBound)
                best = min(best ?? p, p)
            }
        }
        return best
    }

    private mutating func emit(upTo pos: Int) -> String {
        guard pos > sent else { return "" }
        let start = acc.index(acc.startIndex, offsetBy: sent)
        let end = acc.index(acc.startIndex, offsetBy: pos)
        sent = pos
        return String(acc[start..<end])
    }
}

// MARK: - Tool-argument schema validation

/// Lightweight JSON-Schema check for tool-call arguments. Not a full validator —
/// covers what matters for local tool calling: arguments parse as an object, required
/// properties are present, and present properties match their declared primitive type.
/// Unknown properties and unconstrained schemas pass.
enum SchemaValidator {
    static func validate(toolCalls: [ParsedToolCall], against tools: [ToolSpec]) -> [String] {
        guard !toolCalls.isEmpty else { return [] }
        var schemas: [String: [String: Any]] = [:]
        for t in tools {
            guard let fn = t["function"] as? [String: any Sendable],
                  let name = fn["name"] as? String else { continue }
            schemas[name] = (fn["parameters"] as? [String: any Sendable]).map { dict in
                dict.reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
            }
        }
        var errors: [String] = []
        for call in toolCalls {
            guard let schema = schemas[call.name] else {
                errors.append("unknown tool '\(call.name)'")
                continue
            }
            errors.append(contentsOf: validateArgs(call.argumentsJSON, schema: schema, tool: call.name))
        }
        return errors
    }

    private static func validateArgs(_ json: String, schema: [String: Any], tool: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ["'\(tool)' arguments are not a valid JSON object"]
        }
        var errors: [String] = []
        if let required = schema["required"] as? [String] {
            for key in required where args[key] == nil {
                errors.append("'\(tool)' missing required argument '\(key)'")
            }
        }
        if let props = schema["properties"] as? [String: Any] {
            for (key, value) in args {
                guard let prop = props[key] as? [String: Any],
                      let type = prop["type"] as? String else { continue }
                if !typeMatches(value, type: type) {
                    errors.append("'\(tool)' argument '\(key)' should be \(type)")
                }
            }
        }
        return errors
    }

    private static func typeMatches(_ value: Any, type: String) -> Bool {
        switch type {
        case "string": return value is String
        case "boolean": return value is Bool
        // JSONSerialization bridges `true`/`false` to NSNumber, which is non-float — so
        // a Bool would otherwise pass as integer. Exclude it explicitly.
        case "integer": return !(value is Bool) && (value is Int || (value as? NSNumber).map { CFNumberIsFloatType($0) == false } ?? false)
        case "number": return !(value is Bool) && (value is Int || value is Double || value is NSNumber)
        case "array": return value is [Any]
        case "object": return value is [String: Any]
        case "null": return value is NSNull
        default: return true
        }
    }
}

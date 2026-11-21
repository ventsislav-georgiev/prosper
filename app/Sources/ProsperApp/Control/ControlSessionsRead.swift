import Combine
import Foundation

/// #1840: watch a session over the control channel: sessions.get (one full row), sessions.wait (awaits the store's next
/// change until a state holds), sessions.screen and sessions.transcript (one awaited read off main each). The awaited
/// ones run under a deadline (ControlXray.within, #1834's runAsync); the loser is cancelled and a cancelled read stops.
/// Nothing runs between calls: no observer outlives a wait, no poll.
@MainActor
enum ControlSessionsRead {
    /// `dch --read <name>` in the session's own socket dir (AgentPromptIO.live's read), under the island's timeout and an
    /// output cap; a cancel SIGTERMs it (XrayPanels.run's way). nil: it timed out or never ran. Never a real dch under
    /// XCTest: rows put a fake.
    static var readScreen: @Sendable (_ key: AgentSessionKey) async -> Data? = { key in
        guard NSClassFromString("XCTestCase") == nil else { return nil }
        let path = DchCommand.dchPath, env = AgentIsland.listEnv(dir: key.dir), child = XrayChild()
        let r = await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                DispatchQueue.global(qos: .userInitiated).async {
                    c.resume(returning: XrayPanels.runBounded(child, path, ["--read", key.name], env,
                                                              timeout: DchCommand.islandTimeout, outputLimit: screenMaxChars * 4))
                }
            }
        } onCancel: { child.cancel() }
        return r.status == -1 || r.status == XrayPanels.overCap ? nil : r.out
    }

    nonisolated static let states = ["idle", "needs-you", "ended"]
    nonisolated static let defaultLines = 60, maxLines = 500
    nonisolated static let screenMaxChars = 64 << 10
    nonisolated static let defaultLimit = 50, maxLimit = 200
    /// Per entry and per reply: an agent reads a bounded answer whatever the transcript holds.
    nonisolated static let entryChars = 2_000, transcriptMaxChars = 200_000
    /// The tail opens on this last page; a `since` read reads at most `transcriptChunk` from there.
    nonisolated static let transcriptPage: UInt64 = 256 << 10
    nonisolated static let transcriptChunk = 2 << 20
    nonisolated static let readTimeout = 10.0, waitTimeout = 30.0
    nonisolated static let cancelled = ControlError("the read was cancelled")

    /// Work counters the rows read: store changes a wait looked at, transcript lines decoded.
    private(set) static var waitChecks = 0
    nonisolated static let decoded = Count()

    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add(_ k: Int = 1) { lock.withLock { n += k } }
        var value: Int { lock.withLock { n } }
        func reset() { lock.withLock { n = 0 } }
    }

    /// Rows: zero the counters.
    static func resetCounts() {
        waitChecks = 0
        decoded.reset()
    }

    /// A whole number in `range` from a JSON number, `fallback` when absent. Checked before Int(): finite, integral, in range.
    nonisolated static func whole(_ args: [String: ControlJSON], _ key: String, _ range: ClosedRange<Int>, fallback: Int) throws -> Int {
        guard case .number(let n)? = args[key] else { return fallback }
        guard n.isFinite, n.rounded() == n, n >= Double(range.lowerBound), n <= Double(range.upperBound) else {
            throw ControlError("argument '\(key)' must be a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return Int(n)
    }

    /// `timeout` in seconds, 1...60 (ControlXray's range and message), `fallback` when absent.
    static func seconds(_ args: [String: ControlJSON], fallback: Double) throws -> Double {
        guard case .number(let t)? = args["timeout"] else { return fallback }
        guard t.isFinite, t >= 1, t <= ControlXray.maxTimeout else { throw ControlError(ControlXray.badTimeout) }
        return t
    }

    /// ControlXray.within with this command's own timeout message (within's names dch).
    static func within(_ seconds: Double, _ cmd: String, late: String,
                       _ work: @escaping @MainActor @Sendable () async -> Result<ControlJSON, ControlError>) async throws -> ControlJSON {
        do { return try await ControlXray.within(seconds, cmd, work) } catch let e as ControlError where e.message == ControlXray.timedOut(cmd, seconds) {
            throw ControlError(late)
        }
    }

    // MARK: - sessions.get

    /// dch's state as one word: "needs-you", "working", "done", "idle".
    nonisolated static func word(_ s: AgentState) -> String {
        switch s {
        case .blocked: "needs-you"
        case .working: "working"
        case .done: "done"
        case .idle: "idle"
        }
    }

    /// sessions.list's row for `s` plus everything else the row knows: alias, status word, last output, subagents, dch
    /// version, model and effort, pty, open PRs and merged count, running shells, whether a transcript is mapped.
    static func row(_ s: AgentSession, in st: AgentIslandStore) throws -> ControlJSON {
        var o: [String: ControlJSON] = [:]
        if case .object(let l) = try ControlSessions.list(), case .array(let rows)? = l["sessions"],
           let i = st.sessions.firstIndex(where: { $0.key == s.key }), i < rows.count, case .object(let r) = rows[i] { o = r }
        let iso = ISO8601DateFormatter()
        o["name"] = .string(s.name)
        o["title"] = .string(s.title)
        o["alias"] = .string(s.alias)
        o["status"] = .string(word(s.state))
        o["activity"] = s.activity > 0 ? .string(iso.string(from: Date(timeIntervalSince1970: s.activity))) : .null
        o["subagents"] = .number(Double(s.agents))
        o["dch_version"] = s.version.isEmpty ? .null : .string(s.version)
        o["model"] = s.model.map { .string($0) } ?? .null
        o["effort"] = s.effort.map { .string($0) } ?? .null
        o["pty"] = s.pty.map { .object(["cols": .number(Double($0.cols)), "rows": .number(Double($0.rows)),
                                        "clients": .number(Double($0.clients))]) } ?? .null
        o["prs"] = .array((s.meta?.openPRs ?? []).map { p in
            .object(["label": p.label.map { .string($0) } ?? .null, "title": .string(String(p.title.prefix(200))),
                     "url": p.pullURL.map { .string($0.absoluteString) } ?? .null])
        })
        o["merged"] = s.meta?.merged.map { .number(Double($0)) } ?? .null
        o["shells"] = .array(s.shells.map { .object(["pid": .number(Double($0.pid)), "command": .string($0.command)]) })
        o["transcript"] = .bool(s.transcriptPath?.isEmpty == false)
        return .object(o)
    }

    static func get(_ args: [String: ControlJSON]) throws -> ControlJSON {
        let st = try ControlSessions.store()
        return try row(try ControlSessions.session(try ControlSessions.required(args, "name"), in: st), in: st)
    }

    // MARK: - sessions.wait

    /// Whether `state` holds for the session now (`s` nil: no longer listed): {"reached": true, "state"} or
    /// {"ended": true} (it ended before `state`); nil: keep waiting. "idle" is idle or done, "needs-you" blocked.
    nonisolated static func verdict(_ s: AgentSession?, _ state: String) -> ControlJSON? {
        guard let s else {
            return state == "ended" ? .object(["reached": .bool(true), "state": .string("ended")]) : .object(["ended": .bool(true)])
        }
        let reached = switch state {
        case "needs-you": s.state == .blocked
        case "ended": false
        default: s.state == .idle || s.state == .done
        }
        return reached ? .object(["reached": .bool(true), "state": .string(word(s.state))]) : nil
    }

    /// The session is found by name once (an unknown or ambiguous name is refused at once), then followed by its key
    /// through the store's own publisher: the current list first, then each change, until `state` holds, it ends, or
    /// `timeout` (1-60 s, default 30) passes. `changed: true` judges only once the session's own state or activity moves. The subscription lives only as long as the call.
    static func wait(_ args: [String: ControlJSON]) async throws -> ControlJSON {
        let st = try ControlSessions.store()
        let first = try ControlSessions.session(try ControlSessions.required(args, "name"), in: st)
        let key = first.key
        let state = ControlSessions.string(args, "state") ?? "idle"
        let changed = args["changed"] == .bool(true)
        let limit = try seconds(args, fallback: waitTimeout)
        let late = "sessions.wait: the session was not \(state) within \(Int(limit.rounded(.up))) s (timeout); ask again"
        return try await within(limit, "sessions.wait", late: late) {
            let (found, cont) = AsyncStream.makeStream(of: ControlJSON.self, bufferingPolicy: .bufferingNewest(1))
            // @Published sends on willSet with the new value (as AgentWindowModel's sink): the value is used as given.
            let sub = st.$sessions.sink { list in
                MainActor.assumeIsolated {
                    waitChecks += 1
                    let me = list.first(where: { $0.key == key })
                    // changed: only the target's own (state, activity) moving counts, not another session's publish; gone = ended.
                    if changed, let me, me.state == first.state, me.activity == first.activity { return }
                    if let v = verdict(me, state) { cont.yield(v); cont.finish() }
                }
            }
            defer { sub.cancel() }
            for await v in found { return .success(v) }
            return .failure(cancelled)
        }
    }

    // MARK: - sessions.screen

    /// The session's visible screen as plain text (dch's mirror): the last `lines` non-trailing-blank lines.
    static func screen(_ args: [String: ControlJSON]) async throws -> ControlJSON {
        let st = try ControlSessions.store(), s = try ControlSessions.session(try ControlSessions.required(args, "name"), in: st)
        let lines = try whole(args, "lines", 1...maxLines, fallback: defaultLines)
        let limit = try seconds(args, fallback: readTimeout)
        let read = readScreen, key = s.key
        return try await within(limit, "sessions.screen", late: ControlXray.timedOut("sessions.screen", limit)) {
            screenText(await read(key), name: key.name, lines: lines)
        }
    }

    nonisolated static func screenText(_ data: Data?, name: String, lines: Int) -> Result<ControlJSON, ControlError> {
        guard let data else { return .failure(ControlError("could not read \(name)'s screen: dch did not answer")) }
        guard !data.isEmpty else { return .failure(ControlError("\(name) has no screen mirror (dch lite or too old)")) }
        var rows = String(decoding: data.prefix(screenMaxChars * 4), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        while let last = rows.last, last.allSatisfy({ $0 == " " || $0 == "\r" }) { rows.removeLast() }
        let shown = rows.suffix(lines)
        var text = shown.joined(separator: "\n")
        if text.count > screenMaxChars { text = String(text.suffix(screenMaxChars)) }
        return .success(.object(["name": .string(name), "lines": .number(Double(shown.count)), "text": .string(text)]))
    }

    // MARK: - sessions.transcript

    /// The mapped Claude Code transcript's entries: with no `since` the last `limit` of its last page, else the first
    /// `limit` from byte offset `since` (a `next` from an earlier reply). {"entries": [{at, kind, text}], "next"}.
    static func transcript(_ args: [String: ControlJSON]) async throws -> ControlJSON {
        let st = try ControlSessions.store(), s = try ControlSessions.session(try ControlSessions.required(args, "name"), in: st)
        let limit = try whole(args, "limit", 1...maxLimit, fallback: defaultLimit)
        // 2^53: the largest offset a JSON number holds exactly.
        let since = args["since"] == nil ? nil : UInt64(try whole(args, "since", 0...(1 << 53), fallback: 0))
        let wait = try seconds(args, fallback: readTimeout)
        guard let path = s.transcriptPath, !path.isEmpty else {
            throw ControlError("\(s.title) has no transcript Prosper can read (not a Claude Code session dch mapped)")
        }
        return try await within(wait, "sessions.transcript",
                                late: "sessions.transcript: the transcript was not read within \(Int(wait.rounded(.up))) s (timeout)") {
            await offMain { readTranscript(path: path, since: since, limit: limit) }
        }
    }

    /// `read` on a detached task; cancelling the caller cancels it (a group's cancelAll never reaches a detached task).
    nonisolated static func offMain(_ read: @escaping @Sendable () -> Result<ControlJSON, ControlError>) async -> Result<ControlJSON, ControlError> {
        let t = Task.detached(priority: .userInitiated) { read() }
        return await withTaskCancellationHandler { await t.value } onCancel: { t.cancel() }
    }

    /// Off main. Bounded: the tail reads one page (plus at most one whole last line), a `since` read one chunk. A
    /// cancelled task reads nothing and stops decoding at the next line.
    nonisolated static func readTranscript(path: String, since: UInt64?, limit: Int) -> Result<ControlJSON, ControlError> {
        guard !Task.isCancelled else { return .failure(cancelled) }
        var tail = TranscriptTail(path: path, pageBytes: transcriptPage)
        tail.chunkBytes = transcriptChunk
        tail.maxLine = transcriptChunk
        let missing = ControlError("the transcript cannot be read")
        var lines: [LineBuffer.Line]
        var end: UInt64
        if let since {
            var sb = stat()
            guard stat(path, &sb) == 0 else { return .failure(missing) }
            let size = UInt64(max(0, sb.st_size))
            guard since <= size else { return .failure(ControlError("since is past the transcript's end (\(size) bytes)")) }
            var b = LineBuffer(at: since, maxLine: transcriptChunk)
            guard let d = tail.read(since..<min(size, since + UInt64(transcriptChunk))) else { return .failure(missing) }
            lines = b.feed(d, at: since)
            // shortcut: a line longer than one chunk is stepped over by bytes; its rest decodes as one unreadable entry.
            end = lines.isEmpty && d.count == transcriptChunk ? since + UInt64(d.count) : since
        } else {
            guard case .lines(let l, _) = tail.poll() else { return .failure(missing) }
            lines = l
            end = tail.earliestLoaded
        }
        var picked: [[ControlJSON]] = []
        var count = 0, chars = 0
        let ordered = since == nil ? Array(lines.reversed()) : lines
        for l in ordered {
            guard count < limit, chars < transcriptMaxChars else { break }
            guard !Task.isCancelled else { return .failure(cancelled) }
            let e = entries(l)
            picked.append(e)
            count += e.count
            for case .object(let o) in e { if case .string(let t)? = o["text"] { chars += t.count } }
            if since != nil { end = l.range.upperBound + 1 }
        }
        if since == nil {
            picked.reverse()
            end = lines.last.map { $0.range.upperBound + 1 } ?? end
        }
        var flat = Array(picked.joined())
        if since == nil, flat.count > limit { flat = Array(flat.suffix(limit)) }
        return .success(.object(["entries": .array(flat), "next": .number(Double(end))]))
    }

    /// One line's main-thread items as {at, kind, text?, error?}; subagent (sidechain) entries and hidden noise left out.
    nonisolated static func entries(_ l: LineBuffer.Line) -> [ControlJSON] {
        decoded.add()
        let d: DecodedEntry = switch l {
        case .line(let data, let r): TranscriptDecoder.decode(line: data, source: r, cap: entryChars)
        case .oversized: TranscriptDecoder.decode(l)
        }
        guard d.sidechain == nil else { return [] }
        let at = ControlJSON.number(Double(l.range.lowerBound))
        return d.items.compactMap { item -> ControlJSON? in
            guard let r = describe(item) else { return nil }
            var o: [String: ControlJSON] = ["at": at, "kind": .string(r.kind)]
            if let text = r.text { o["text"] = .string(String(text.prefix(entryChars))) }
            if r.error { o["error"] = .bool(true) }
            return .object(o)
        }
    }

    nonisolated static func describe(_ item: DecodedEntry.Item) -> (kind: String, text: String?, error: Bool)? {
        switch item {
        case .hidden: return nil
        case .toolUse(_, let name, _): return ("tool_use", name, false)
        case .toolResult(_, let r): return ("tool_result", r.text.text, r.isError)
        case .block(let body, _):
            switch body {
            case .user(let c): return ("user", c.text, false)
            case .assistant(let c): return ("assistant", c.text, false)
            case .thinking: return ("thinking", nil, false)
            case .image: return ("image", nil, false)
            case .bash(let command, _, let output, let isError):
                return ("bash", [command, output?.text].compactMap { $0 }.joined(separator: "\n"), isError)
            case .diff(let tool, let path, _, _, let isError): return ("edit", "\(tool) \(path)", isError)
            case .read(let path, _): return ("read", path, false)
            case .search(let tool, let pattern, _, _, _): return ("search", "\(tool) \(pattern)", false)
            case .compaction(_, _, let summary): return ("compaction", summary?.text, false)
            case .notice(let s): return ("notice", s, false)
            case .thread(_, let title): return ("subagent", title, false)
            case .command(let name, let args): return ("command", [name, args].compactMap { $0 }.joined(separator: " "), false)
            case .card(let title, _, let body, _, let isError): return ("tool", [title, body?.text].compactMap { $0 }.joined(separator: "\n"), isError)
            case .failed(let reason, _): return ("unreadable", reason, true)
            }
        }
    }
}

extension ControlRegistry {
    /// #1840: wired in ControlRegistry.standard().
    static func registerSessionsRead(_ r: inout ControlRegistry) {
        let name = ControlArg(type: "string", required: true, summary: "the session's dch name or shown title")
        // reply(to:) awaits runAsync; the synchronous run is never called for these (as registerXray's)
        let awaits: @MainActor @Sendable (ControlRegistry, [String: ControlJSON]) throws -> ControlJSON = { _, _ in
            throw ControlError("this command awaits its answer: send it through the control channel")
        }
        func timeout(_ d: Double) -> ControlArg { ControlArg(type: "number", summary: "seconds, 1 to 60, default \(Int(d))") }
        r.register(ControlCommand(name: "sessions.get",
                                  summary: "One session's full row: sessions.list's fields plus status, activity, model, pty, PRs, shells.",
                                  args: ["name": name], mutates: false) { _, a in try ControlSessionsRead.get(a) })
        r.register(ControlCommand(
            name: "sessions.wait",
            summary: "Wait until a session is idle, needs you, or ended: {reached, state}, {ended} when it ended first, an error on timeout. Pass changed:true right after sessions.say, or a still-idle session answers at once.",
            args: ["name": name,
                   "state": ControlArg(type: "string", allowed: ControlSessionsRead.states, summary: "idle when absent"),
                   "changed": ControlArg(type: "boolean", summary: "true: ignore the current state, answer only after a later change"),
                   "timeout": timeout(ControlSessionsRead.waitTimeout)],
            mutates: false, run: awaits, runAsync: { _, a in try await ControlSessionsRead.wait(a) }))
        r.register(ControlCommand(
            name: "sessions.screen",
            summary: "A session's visible terminal screen as text.",
            args: ["name": name, "lines": ControlArg(type: "number", summary: "last lines, 60 when absent (1-500)"),
                   "timeout": timeout(ControlSessionsRead.readTimeout)],
            mutates: false, run: awaits, runAsync: { _, a in try await ControlSessionsRead.screen(a) }))
        r.register(ControlCommand(
            name: "sessions.transcript",
            summary: "A Claude Code session's transcript entries.",
            args: ["name": name,
                   "since": ControlArg(type: "number", summary: "byte offset: an earlier reply's next; the last entries when absent"),
                   "limit": ControlArg(type: "number", summary: "entries, 50 when absent (1-200)"),
                   "timeout": timeout(ControlSessionsRead.readTimeout)],
            mutates: false, run: awaits, runAsync: { _, a in try await ControlSessionsRead.transcript(a) }))
    }
}

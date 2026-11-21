import Foundation

/// #1860: xray.chapters, xray.tasks, xray.memory and xray.recap, read-only, for a live session named by `session` or
/// `cwd`, through ControlXray's reader (the gate, the target, the drawer's runner), deadline (`timeout`) and caps. Each
/// answer is parsed by the drawer's own parser (XrayChapters, XrayTasks, XrayMemory, XrayRecap) off main, and only a
/// bounded page of it goes out: ControlXray.maxRows rows, each string capped (snippetCap). On demand only.
@MainActor
enum ControlXrayReads {
    /// The clock xray.recap's default `since` reads. Rows fix it.
    static var now: @Sendable () -> Date = { Date() }

    static let badSince = "since must be epoch seconds from 0 to 10000000000"
    static let defaultAway: TimeInterval = 24 * 60 * 60
    static let noTasks = "dch sent no task list"
    static let noMemory = "dch sent no memory list"
    static let noChapters = "dch sent no chapters (the session has no X-ray corpus, or dch does not know the form)"
    static let noRecap = "dch sent no recap"
    static let recapNeeds = "xray.recap needs dch \(DchCommand.versionString(XrayRecap.minimumDch))"
    static let cannotRead = "dch cannot read this session's X-ray"
    static let refused = "the host refused the read"
    static let tooLarge = "the answer was too large to read"

    /// One read: `args` (built from the target) runs through the drawer's runner under the deadline; exit 0's bytes are
    /// parsed off main by `parse` (nil: the answer did not read, `failed`). Other exits are takeChapters' and takeSearch's.
    static func read(_ cmd: String, _ args: [String: ControlJSON], failed: String, argv: (XrayTarget) -> [String],
                     parse: @escaping @Sendable (Data) -> ControlJSON?) async throws -> ControlJSON {
        let (t, dch, run) = try ControlXray.reader(args)
        let wait = try ControlXray.timeout(args)
        let a = argv(t), env = t.env, remote = t.dir == nil
        let work: @MainActor @Sendable () async -> Result<ControlJSON, ControlError> = {
            let r = await run(dch, a, env)
            if ControlXray.unreached(r.status, remote: remote) { return .failure(ControlError("host unreachable")) }
            switch r.status {
            case 0:
                let out = r.out
                let json = await Task.detached(priority: .userInitiated) { parse(out) }.value
                return json.map { .success($0) } ?? .failure(ControlError(failed))
            case 6: return .failure(ControlError(refused))
            case XrayPanels.overCap: return .failure(ControlError(tooLarge))
            default: return .failure(ControlError(cannotRead))
            }
        }
        // the deadline: one line, so a mutant can drop it (M-noDeadline)
        return try await ControlXray.within(wait, cmd, work)
    }

    nonisolated static func at(_ d: Date?) -> ControlJSON { d.map { .number($0.timeIntervalSince1970) } ?? .null }
    nonisolated static func str(_ s: String?, _ max: Int = ControlXray.snippetCap) -> ControlJSON {
        s.map { .string(OutsideText.shown($0, max: max)) } ?? .null
    }

    // MARK: xray.chapters

    static func chapters(_ args: [String: ControlJSON]) async throws -> ControlJSON {
        try await read("xray.chapters", args, failed: noChapters, argv: { $0.chaptersArgs }) { data in
            XrayChapters.parse(data).map(chaptersJSON)
        }
    }

    /// The newest maxRows chapters, oldest first as dch lists them; `total` is how many dch sent.
    nonisolated static func chaptersJSON(_ list: [TranscriptOutline.Chapter]) -> ControlJSON {
        let rows = list.suffix(ControlXray.maxRows).map { c -> ControlJSON in
            .object(["n": .number(Double(c.ordinal)), "title": str(c.title, 120), "kind": .string(c.kind == .compaction ? "compact" : "prompt"),
                     "auto": .bool(c.auto), "peer": str(c.peer, 120), "error": .bool(c.hasError),
                     "response": str(c.response), "tools": str(c.tools)])
        }
        return .object(["chapters": .array(rows), "total": .number(Double(list.count)), "more": .bool(list.count > ControlXray.maxRows)])
    }

    // MARK: xray.tasks

    static func tasks(_ args: [String: ControlJSON]) async throws -> ControlJSON {
        try await read("xray.tasks", args, failed: noTasks, argv: { $0.args("tasks") }) { data in
            let t = XrayTasks.parse(data)
            return t.schema == 1 ? tasksJSON(t) : nil
        }
    }

    /// In progress, Pending, Done, Dropped (the drawer's order), at most maxRows.
    nonisolated static func tasksJSON(_ t: XrayTasks) -> ControlJSON {
        let all = t.groups.flatMap(\.tasks)
        let rows = all.prefix(ControlXray.maxRows).map { k -> ControlJSON in
            .object(["id": str(k.id, 32), "title": str(k.title, 120), "status": .string(k.status.rawValue), "label": str(k.label, 40),
                     "active": str(k.active, 120), "note": str(k.note, 120), "group": str(k.group, 120),
                     "blocked_by": .array(k.blockedBy.prefix(ControlXray.maxRows).map { str($0, 32) }),
                     "created": at(k.created), "updated": at(k.updated)])
        }
        return .object(["tasks": .array(rows), "open": .number(Double(t.open)), "total": .number(Double(all.count)),
                        "dropped": .number(Double(t.droppedCount)), "more": .bool(all.count > ControlXray.maxRows),
                        "partial": .bool(t.partial)])
    }

    // MARK: xray.memory

    static func memory(_ args: [String: ControlJSON]) async throws -> ControlJSON {
        // XrayMemory has no schema; a read with no row and no done line is no answer
        try await read("xray.memory", args, failed: noMemory, argv: { $0.args("memory") }) { data in
            let m = XrayMemory.parse(data)
            return m.items.isEmpty && m.partial ? nil : memoryJSON(m)
        }
    }

    /// This session, Memories, Instructions (the drawer's order), at most maxRows; a body is its first snippetCap scalars.
    nonisolated static func memoryJSON(_ m: XrayMemory) -> ControlJSON {
        let all = m.groups.flatMap(\.items)
        let rows = all.prefix(ControlXray.maxRows).map { i -> ControlJSON in
            let body = i.body.map { String($0.unicodeScalars.prefix(ControlXray.snippetCap)) }
            return .object(["id": str(i.id, 64), "title": str(i.title, 120), "note": str(i.note, 120), "kind": str(i.kindWord, 40),
                            "scope": str(i.scopeWord, 40), "session": str(i.sessionWord, 40), "updated": at(i.updated),
                            "body": body.map { .string($0) } ?? .null,
                            "cut": .bool(i.cut || (i.body?.unicodeScalars.count ?? 0) > ControlXray.snippetCap)])
        }
        return .object(["items": .array(rows), "total": .number(Double(all.count)), "dropped": .number(Double(m.droppedCount)),
                        "more": .bool(all.count > ControlXray.maxRows), "partial": .bool(m.partial)])
    }

    // MARK: xray.recap

    /// `since` (epoch seconds, default 24 h ago); dch 1.113.0+ only (XrayRecap.supported), as the drawer's strip.
    static func sinceDate(_ args: [String: ControlJSON]) throws -> Date {
        guard case .number(let s)? = args["since"] else { return now().addingTimeInterval(-defaultAway) }
        guard s.isFinite, s >= 0, s <= 1e10 else { throw ControlError(badSince) }
        return Date(timeIntervalSince1970: s)
    }

    static func recap(_ args: [String: ControlJSON]) async throws -> ControlJSON {
        guard XrayRecap.supported(XrayPanels.probed?.version) else { throw ControlError(recapNeeds) }
        let since = try sinceDate(args)
        return try await read("xray.recap", args, failed: noRecap, argv: { $0.sinceArgs(since) }) { data in
            XrayRecap.parse(data).map(recapJSON)
        }
    }

    nonisolated static func recapJSON(_ r: XrayRecap) -> ControlJSON {
        let chapters = r.chapters.prefix(ControlXray.maxRows).map { c -> ControlJSON in
            .object(["anchor": str(c.anchor, XrayRecap.anchorCap), "title": str(c.title), "at": at(c.at)])
        }
        let refs = r.refs.prefix(ControlXray.maxRows).map { f -> ControlJSON in
            .object(["key": str(f.key), "shape": str(f.shape, XrayRecap.shapeCap), "text": str(f.text),
                     "count": .number(Double(f.count)), "last_at": at(f.lastAt)])
        }
        return .object(["since": at(r.since), "chapters": .array(chapters), "refs": .array(refs),
                        "more": .bool(r.more || r.chapters.count > ControlXray.maxRows || r.refs.count > ControlXray.maxRows),
                        "partial": .bool(r.partial)])
    }
}

extension ControlRegistry {
    static func registerXrayReads(_ r: inout ControlRegistry) {
        let target: [String: ControlArg] = [
            "session": ControlArg(type: "string", summary: "a live session's dch name or title (or give cwd)"),
            "cwd": ControlArg(type: "string", summary: "a project folder a live session works in (or give session)"),
            "timeout": ControlArg(type: "number", summary: "seconds to wait for dch, 1 to 60, default 20"),
        ]
        // reply(to:) awaits runAsync; the synchronous run is never called for these (as registerXray's)
        let awaits: @MainActor @Sendable (ControlRegistry, [String: ControlJSON]) throws -> ControlJSON = { _, _ in
            throw ControlError("this command awaits dch: send it through the control channel")
        }
        func add(_ name: String, _ summary: String, _ extra: [String: ControlArg] = [:],
                 _ go: @escaping @MainActor @Sendable ([String: ControlJSON]) async throws -> ControlJSON) {
            r.register(ControlCommand(name: name, summary: summary, args: target.merging(extra) { $1 },
                                      mutates: false, run: awaits, runAsync: { _, args in try await go(args) }))
        }
        add("xray.chapters", "A session's X-ray chapters (its prompts, newest 20: title, response snippet, tools), as the drawer's Prompts tab.") { try await ControlXrayReads.chapters($0) }
        add("xray.tasks", "A session's X-ray task list (in progress, pending, done: first 20), as the drawer's Tasks tab.") { try await ControlXrayReads.tasks($0) }
        add("xray.memory", "A session's memories and instruction files (first 20; a body is a snippet), as the drawer's Memory tab.") { try await ControlXrayReads.memory($0) }
        add("xray.recap", "What began in a session since a time (its new prompts and ticket/PR refs), as the 'since you were last here' strip. dch 1.113.0+.",
            ["since": ControlArg(type: "number", summary: "epoch seconds, 0 to 10000000000; default 24 hours ago")]) { try await ControlXrayReads.recap($0) }
    }
}

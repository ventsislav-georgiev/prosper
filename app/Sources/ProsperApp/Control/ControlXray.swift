import Foundation

/// #1834: xray.search and xray.ref, read-only, for a live session named by `session` (its dch name or title) or `cwd`
/// (a live session working in that folder), built the way the X-ray drawer builds its own: XrayRefLink.target for the
/// session, the gate's dch (XrayPanels.dch), the warm --requests runner for a remote (XrayPanels.shared.requests), the
/// ref card's argv (refCall: the GitHub setting, #1623's retry) and the Agents window's 30 s --ref cache. Each call awaits
/// dch's answer under a deadline (`timeout`); `fast` takes #1824's light answer when there is one. On demand only.
@MainActor
enum ControlXray {
    /// The window's --ref cache the drawer uses (XrayPanels.wire); nil while the Agents window was never opened or under
    /// XCTest (XrayRefResults.on): every ask reads. Rows put a private one.
    static var cache: @MainActor () -> XrayRefResults? = {
        XrayRefResults.on() ? AgentsWindow.shared.window.map { XrayRefResults.of($0) } : nil
    }
    /// The deadline's one-shot wait (no poll). Rows shorten it.
    static var sleep: @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }

    static let oneTarget = "give exactly one of session or cwd"
    static let badRef = "Not a ref dch can look up"
    static let badLine = "line must be a whole number from 1"
    static let badTimeout = "timeout must be from 1 to 60 seconds"
    static func noSession(in cwd: String) -> String { "no live session works in \(cwd) (sessions.list lists them)" }
    static func timedOut(_ cmd: String, _ s: Double) -> String {
        "\(cmd): dch did not answer within \(Int(s.rounded(.up))) s (timeout); ask again or pass a larger timeout"
    }
    static let defaultTimeout = 20.0
    static let maxTimeout = 60.0
    /// Caps on the reply: list rows and groups (each string is already capped by its parse or below).
    nonisolated static let maxRows = 20
    nonisolated static let maxGroups = 8
    nonisolated static let snippetCap = 240

    // MARK: the target

    /// The session's target, the gate's dch path and the drawer's runner, or the refusal the drawer would show.
    static func reader(_ args: [String: ControlJSON]) throws -> (target: XrayTarget, dch: String, run: XrayPanels.Run) {
        guard let dch = XrayPanels.dch() else {
            throw ControlError(XrayTabs.gate(XrayPanels.probed).refusal ?? "needs dch \(DchCommand.versionString(XrayTabs.minimumDch))")
        }
        let name = ControlSessions.string(args, "session"), cwd = ControlSessions.string(args, "cwd")
        guard (name == nil) != (cwd == nil) else { throw ControlError(oneTarget) }
        let st = try ControlSessions.store()
        let s = try name.map { try ControlSessions.session($0, in: st) } ?? working(in: cwd ?? "", st)
        guard let t = XrayRefLink.target(s.key) else { throw ControlError("\(s.name) has no X-ray (dch reads its name as a flag)") }
        return (t, dch, XrayPanels.shared.requests.run(for: t, cold: XrayPanels.run))
    }

    /// A live session whose cwd is `folder` (first in the store's order), else one working below it.
    /// shortcut: the first such session; with scope "project" (the default) any one answers for the whole project.
    static func working(in folder: String, _ st: AgentIslandStore) throws -> AgentSession {
        func std(_ p: String) -> String { p.isEmpty ? "" : (p as NSString).standardizingPath }
        let f = std(folder)
        let s = st.sessions.first { std($0.cwd) == f } ?? st.sessions.first { f != "/" && std($0.cwd).hasPrefix(f + "/") }
        guard let s, !f.isEmpty else { throw ControlError(noSession(in: folder)) }
        return s
    }

    static func timeout(_ args: [String: ControlJSON]) throws -> Double {
        guard case .number(let t)? = args["timeout"] else { return defaultTimeout }
        guard t.isFinite, t >= 1, t <= maxTimeout else { throw ControlError(badTimeout) }
        return t
    }

    /// XrayPanelModel.unreached without a panel: exit 4 or 7, or a remote read's -1 (timed out dialling).
    nonisolated static func unreached(_ status: Int32, remote: Bool) -> Bool { status == 4 || status == 7 || status == -1 && remote }

    /// `work`'s answer, or the timeout's error once `seconds` pass first. Both are children of one group: the loser
    /// is cancelled there (a read's cancel SIGTERMs its dch, XrayPanels.run).
    static func within(_ seconds: Double, _ cmd: String,
                       _ work: @escaping @MainActor @Sendable () async -> Result<ControlJSON, ControlError>) async throws -> ControlJSON {
        let sleep = Self.sleep
        let first = await withTaskGroup(of: Result<ControlJSON, ControlError>?.self) { g in
            g.addTask { await work() }
            g.addTask { await sleep(seconds); return nil }
            let r = await g.next() ?? nil
            g.cancelAll()
            return r
        }
        guard let first else { throw ControlError(timedOut(cmd, seconds)) }
        return try first.get()
    }

    // MARK: xray.search

    /// The drawer's runSearch: `--scope project` on dch 1.110.0+ (scope "session" asks without it), the text on stdin
    /// per viaStdin; a remote scoped read that exits 1 runs once more unscoped. Its answer as takeSearch reads it.
    static func search(_ args: [String: ControlJSON]) async throws -> ControlJSON {
        let (t, dch, run) = try reader(args)
        guard case .string(let query)? = args["query"], DchCtl.searchOK(query) else { throw ControlError(XraySearch.badQuery) }
        let wait = try timeout(args)
        let scoped = args["scope"] != .string("session") && XraySearch.scoped(XrayPanels.probed?.version)
        let env = t.env, (text, input) = t.viaStdin(query, version: XrayPanels.probed?.version)
        let a = t.searchArgs(text, scope: scoped ? "project" : nil), plain = t.searchArgs(text)
        let remote = t.dir == nil, scope = scoped ? "project" : "session"
        return try await within(wait, "xray.search") {
            var r = await XrayPanels.stdin.withValue(input) { await run(dch, a, env) }
            if scoped, remote, r.status == 1, !Task.isCancelled { r = await run(dch, plain, env) }
            let out = r.out
            let json = r.status == 0 ? await Task.detached(priority: .userInitiated) {
                XraySearch.parse(out).map { searchJSON($0, scope: scope) }
            }.value : nil
            return searchAnswer(r.status, json, unreached: unreached(r.status, remote: remote))
        }
    }

    /// takeSearch's reading of an answer (`json`: exit 0's, nil when it did not parse).
    static func searchAnswer(_ status: Int32, _ json: ControlJSON?, unreached: Bool) -> Result<ControlJSON, ControlError> {
        if unreached { return .failure(ControlError("host unreachable")) }
        switch status {
        case 1: return .failure(ControlError(XraySearch.cannotSearch))
        case 6: return .failure(ControlError(XraySearch.refused))
        case XrayPanels.overCap: return .failure(ControlError(XraySearch.tooLarge))
        default: return json.map { .success($0) } ?? .failure(ControlError("The search failed"))
        }
    }

    nonisolated static func searchJSON(_ s: XraySearch, scope: String) -> ControlJSON {
        func clean(_ t: String, _ max: Int) -> ControlJSON { .string(OutsideText.shown(t, max: max)) }
        func hit(_ h: XraySearch.Hit) -> ControlJSON {
            var o: [String: ControlJSON] = ["who": clean(h.who, XraySearch.wordCap),
                                            "snippet": clean(XraySearch.withoutLeadingEllipsis(h.snippet), snippetCap),
                                            "answer": .bool(h.answer)]
            if let t = h.tool { o["tool"] = clean(t, 40) }
            if let at = h.at { o["at"] = .number(at.timeIntervalSince1970) }
            return .object(o)
        }
        let groups = s.others.prefix(maxGroups).map { g -> ControlJSON in
            .object(["session": clean(g.session, 64), "hits": .array(g.hits.prefix(maxRows).map(hit)),
                     "more": .bool(g.more || g.hits.count > maxRows)])
        }
        var o: [String: ControlJSON] = [
            "scope": .string(scope), "hits": .array(s.hits.prefix(maxRows).map(hit)),
            "sessions": .array(groups), "more": .bool(s.more || s.hits.count > maxRows || s.others.count > maxGroups),
            "partial": .bool(s.partial),
        ]
        if let why = s.why { o["why"] = clean(why, XraySearch.wordCap) }
        return .object(o)
    }

    // MARK: xray.ref

    /// The ref card's read of `path` (":line" added). A full answer the window cached within 30 s answers at once.
    /// `fast`: a cached light answer, else #1824's light read (local only, as the pin's), whose exit-0 answer is the
    /// reply ("light": true, "more": true); no light answer: the full read. Else the full read, cached as runRef does.
    static func ref(_ args: [String: ControlJSON]) async throws -> ControlJSON {
        let (t, dch, run) = try reader(args)
        guard case .string(let path)? = args["path"] else { throw ControlError(badRef) }
        var line: Int?
        if case .number(let n)? = args["line"] {
            guard n.isFinite, n >= 1, n <= Double(Int32.max), n == n.rounded() else { throw ControlError(badLine) }
            line = Int(n)   // checked above: a whole number in Int32's range
        }
        let text = line.map { path + ":\($0)" } ?? path
        guard DchCtl.refOK(text), !text.hasPrefix("-") else { throw ControlError(badRef) }
        let version = XrayPanels.probed?.version, (arg, input) = t.viaStdin(text, version: version)
        guard (input?.count ?? 0) <= 256 else { throw ControlError(XrayPanelModel.refTooLong) }   // runRef's overStdin
        let wait = try timeout(args), fast = args["fast"] == .bool(true)
        let cache = cache(), key = XrayRefResults.Key(target: t, ref: text, light: false, scope: "project")
        let lightKey = XrayRefResults.Key(target: t, ref: text, light: true, scope: "project")
        let hit = cache?.get(key) ?? (fast ? cache?.get(lightKey) : nil)
        let lookups = Preferences.xrayGithubLookups, remote = t.dir == nil
        let light = fast && hit == nil && !remote && XrayPanels.lightFirst()
            ? t.refCall(t.lightArgs(arg, budget: XrayPanels.budget()), version: version, lookups: lookups) : nil
        let plain = t.refArgs(arg)
        let (a, env, flagged) = t.refCall(plain, version: version, lookups: lookups)
        return try await within(wait, "xray.ref") {
            func parse(_ out: Data) async -> XrayRefStream {
                await Task.detached(priority: .userInitiated) { XrayRefStream.parse(out) }.value
            }
            if let hit {
                let s: XrayRefStream
                if let p = hit.parsed { s = p } else { s = await parse(hit.out) }
                return .success(refJSON(s, light: hit.light, more: hit.light))
            }
            if let light {
                let l = await XrayPanels.stdin.withValue(input) { await run(dch, light.args, light.env) }
                if l.status == 0, !Task.isCancelled {
                    let s = await parse(l.out)
                    cache?.put(lightKey, l.out, parsed: s)
                    return .success(refJSON(s, light: true, more: true))
                }
            }
            var r = await XrayPanels.stdin.withValue(input) { await run(dch, a, env) }
            if flagged, r.status == 1, !Task.isCancelled {   // #1623, as runRef
                r = await XrayPanels.stdin.withValue(input) { await run(dch, plain, env) }
            }
            var json: ControlJSON?
            if r.status == 0, !Task.isCancelled {
                let s = await parse(r.out)
                cache?.put(key, r.out, parsed: s)
                json = refJSON(s, light: false, more: false)
            }
            return refAnswer(r.status, json, remote: remote, unreached: unreached(r.status, remote: remote))
        }
    }

    /// takeRef's reading of an answer (`json`: exit 0's).
    static func refAnswer(_ status: Int32, _ json: ControlJSON?, remote: Bool, unreached: Bool) -> Result<ControlJSON, ControlError> {
        switch status {
        case 0: return json.map { .success($0) } ?? .failure(ControlError(XrayPanelModel.refFailed))
        case 1: return .failure(ControlError(XrayPanelModel.refNoCorpus))
        case 2: return .failure(ControlError(XrayPanelModel.refNotARef))
        case 6 where remote: return .failure(ControlError(XrayPanelModel.refNoXray))
        case _ where unreached: return .failure(ControlError("host unreachable"))
        default: return .failure(ControlError(XrayPanelModel.refFailed))
        }
    }

    /// The card's data as JSON. The stream's strings are cleaned by its parse (OutsideText.shown, capped).
    nonisolated static func refJSON(_ s: XrayRefStream, light: Bool, more: Bool) -> ControlJSON {
        func at(_ d: Date?) -> ControlJSON { d.map { .number($0.timeIntervalSince1970) } ?? .null }
        let defs = s.definitions.prefix(maxRows).map { d -> ControlJSON in
            .object(["session": .string(d.session), "title": .string(d.title), "passage": .string(d.passage),
                     "rule": .string(d.rule), "at": at(d.at), "url": d.url.map { .string($0) } ?? .null])
        }
        let mentions = s.mentions.prefix(maxRows).map { x -> ControlJSON in
            let snippet = x.sentence.map { $0.before + $0.hit + $0.after } ?? x.line
            return .object(["session": .string(x.session), "snippet": .string(String(snippet.unicodeScalars.prefix(snippetCap))),
                            "turn": x.turn.map { .number(Double($0)) } ?? .null, "who": x.who.map { .string($0) } ?? .null,
                            "title": x.turnTitle.map { .string($0) } ?? .null, "at": at(x.at)])
        }
        var o: [String: ControlJSON] = [
            "light": .bool(light), "more": .bool(more), "partial": .bool(s.partial),
            "definitions": .array(defs), "mentions": .array(mentions),
            "truncated": .bool(s.definitions.count > maxRows || s.mentions.count > maxRows),
        ]
        if let f = s.first { o["ref"] = .object(["key": .string(f.key), "shape": .string(f.shape), "text": .string(f.text)]) }
        if let c = s.counts {
            o["counts"] = .object(["session": .number(Double(c.session)), "project": .number(Double(c.project)),
                                   "project_sessions": .number(Double(c.projectSessions))])
        }
        if let r = s.resolved {
            o["resolved"] = .object(["kind": .string(r.kind), "state": .string(r.state), "title": .string(r.title),
                                     "subtitle": .string(r.subtitle), "lines": .array(r.lines.map { .string($0) })])
        }
        return .object(o)
    }
}

extension ControlRegistry {
    static func registerXray(_ r: inout ControlRegistry) {
        let target: [String: ControlArg] = [
            "session": ControlArg(type: "string", summary: "a live session's dch name or title (or give cwd)"),
            "cwd": ControlArg(type: "string", summary: "a project folder a live session works in (or give session)"),
            "timeout": ControlArg(type: "number", summary: "seconds to wait for dch, 1 to 60, default 20"),
        ]
        // reply(to:) awaits runAsync; the synchronous run is never called for these
        let awaits: @MainActor @Sendable (ControlRegistry, [String: ControlJSON]) throws -> ControlJSON = { _, _ in
            throw ControlError("this command awaits dch: send it through the control channel")
        }
        r.register(ControlCommand(
            name: "xray.search",
            summary: "Search a session's X-ray history (its project's other sessions too on dch 1.110.0+), as the X-ray drawer does.",
            args: target.merging([
                "query": ControlArg(type: "string", required: true, summary: "2 to 200 bytes, no control character"),
                "scope": ControlArg(type: "string", allowed: ["project", "session"], summary: "default project"),
            ]) { $1 },
            mutates: false, run: awaits, runAsync: { _, args in try await ControlXray.search(args) }))
        r.register(ControlCommand(
            name: "xray.ref",
            summary: "What a session and its project said about a ref (a file path, issue, term): definitions and mentions, as the X-ray ref card shows them.",
            args: target.merging([
                "path": ControlArg(type: "string", required: true, summary: "the ref, e.g. a file path"),
                "line": ControlArg(type: "number", summary: "a line in that file, from 1"),
                "fast": ControlArg(type: "boolean", summary: "true: the quick light answer when there is one (\"light\": true)"),
            ]) { $1 },
            mutates: false, run: awaits, runAsync: { _, args in try await ControlXray.ref(args) }))
    }
}

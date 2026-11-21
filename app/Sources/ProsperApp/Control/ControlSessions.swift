import Foundation

/// #1809: Agent Sessions over the control channel: sessions.list/new/stop/restart/focus and layout.set. Every command
/// takes the window's own path (the agent window is the superset): Stop and Restart the confirm strip's gate check and
/// the model's `stopSession`/`restartSession` (the island controller's methods); New the New session form; Focus a
/// sidebar pick (#1846: the keys stay put); layout.set the Layouts "+" (newLayout), a pick, Split Right and a pick. Work runs on demand only: no
/// observer, no poll. Only structured commands with arguments live here: parameterless actions are #1818's.
@MainActor
enum ControlSessions {
    /// The Agent Sessions window's model; nil while the window was never opened (or was torn down).
    static var model: @MainActor () -> AgentWindowModel? = { AgentsWindow.shared.model }
    /// The island's store, for list/stop/restart with no window open; nil while Agent Island is off.
    static var islandStore: @MainActor () -> AgentIslandStore? = { AgentIslandController.shared.store }
    /// The window shown (the menu item's `show`, AgentsWindow.swift:102) and its model; nil (nothing shown) while the
    /// island is off. sessions.focus always; sessions.new and layout.set only while the window has no model yet.
    /// #1846 n133: quietly: an inactive Prosper is not activated (DockPolicy.presentQuietly).
    static var showWindow: @MainActor () -> AgentWindowModel? = {
        guard AgentIslandController.shared.store != nil else { return nil }
        AgentsWindow.shared.show(quietly: true)
        return AgentsWindow.shared.model
    }

    nonisolated static let agents = ["claude", "codex", "shell"]
    nonisolated static let layouts = ["side-by-side"]
    static let islandOff = "Agent Island is off: turn it on in Settings > Extensions"
    static let formOpen = "the New session form is open in Agent Sessions: finish or cancel it first"

    // MARK: - Lookup

    static func store() throws -> AgentIslandStore {
        guard let s = model()?.store ?? islandStore() else { throw ControlError(islandOff) }
        return s
    }

    /// A live local session by its dch name (exact), else by its shown title (case folded). Two matches: ambiguous.
    static func session(_ name: String, in st: AgentIslandStore) throws -> AgentSession {
        var hits = st.sessions.filter { $0.name == name }
        if hits.isEmpty { hits = st.sessions.filter { $0.title.lowercased() == name.lowercased() } }
        guard hits.count < 2 else { throw ControlError("\(hits.count) sessions are named \(name): rename one first") }
        guard let s = hits.first else { throw ControlError("no live session named \(name) (sessions.list lists them)") }
        return s
    }

    static func string(_ args: [String: ControlJSON], _ key: String) -> String? {
        guard case .string(let s)? = args[key] else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func required(_ args: [String: ControlJSON], _ key: String) throws -> String {
        guard let s = string(args, key) else { throw ControlError("argument '\(key)' is empty") }
        return s
    }

    /// #1809 (b): the window's model, the window opened through the menu's show path when it has none yet.
    static func window() throws -> (AgentWindowModel, AgentIslandStore) {
        guard let m = model() ?? showWindow(), let st = m.store else { throw ControlError(islandOff) }
        return (m, st)
    }

    // MARK: - sessions.list

    /// {"sessions": [{name, title, state, agent, cwd, pane, action}]}: the store's order; `pane` the 1-based pane
    /// of the window's active layout that shows it (null: none, or no window); `agent` "claude" when dch maps a Claude
    /// Code session, else dch's harness title, else null.
    static func list() throws -> ControlJSON {
        let st = try store(), layout = model()?.layout
        return .object(["sessions": .array(st.sessions.map { s -> ControlJSON in
            let pane = layout.flatMap { l in
                l.pane(showing: .session(dir: s.key.dir, name: s.name)).flatMap { l.order.firstIndex(of: $0) }
            }
            let agent = s.claudeSessionID?.isEmpty == false ? "claude" : (s.harness.isEmpty ? nil : s.harness)
            return .object([
                "name": .string(s.name), "title": .string(s.title), "state": .string(s.state.label),
                "agent": agent.map { .string($0) } ?? .null, "cwd": s.cwd.isEmpty ? .null : .string(s.cwd),
                "pane": pane.map { .number(Double($0 + 1)) } ?? .null,
                "action": st.actions[s.key].map { .string($0) } ?? .null,
            ])
        })])
    }

    // MARK: - sessions.stop / sessions.restart

    /// The confirm strip's answer without the question (AgentWindowModel.confirm): the menu's gate, then the model's
    /// seam (the island controller's restart/stop with sayBusy); no window: the controller itself, the seam's default.
    static func run(_ verb: AgentWindowVerb, _ args: [String: ControlJSON]) throws -> ControlChange {
        let st = try store(), s = try session(try required(args, "name"), in: st), m = model()
        if let why = AgentWindowControls.notRun(AgentWindowControls.menu(s, store: st), verb) { throw ControlError(why) }
        let restart = verb == .restart
        let started = if let m { restart ? m.restartSession(s) : m.stopSession(s) }
            else { restart ? AgentIslandController.shared.restart(s, sayBusy: true) : AgentIslandController.shared.stop(s, sayBusy: true) }
        guard started else { throw ControlError(st.actions[s.key] ?? "\(s.title) is busy: try again") }
        // Neither has an inverse: undo nil, so the notice shows no Undo.
        return ControlChange(summary: s.title, result: .string(s.name), verb: restart ? "restarted" : "stopped")
    }

    // MARK: - sessions.focus

    /// The window shown and the session selected in its sidebar, as a click picks it but the keys stay where they are
    /// (#1846 n133: the person may be typing in another app). An open New session form is refused (n135: a pick closes
    /// it). Undo selects the row selected before.
    static func focus(_ args: [String: ControlJSON]) throws -> ControlChange {
        let name = try required(args, "name")
        guard let m = showWindow(), let st = m.store else { throw ControlError(islandOff) }
        guard m.newSession == nil else { throw ControlError(formOpen) }
        let s = try session(name, in: st), before = m.selection
        m.select(.live(s.key))
        return ControlChange(summary: "focus \(s.title)", result: .string(s.name), verb: "focused", undo: { [weak m] in
            // A live row comes back only while its session is listed (the sidebar's rows may not be built yet).
            guard let before, let m else { return }
            if case .live(let k) = before, m.store?.sessions.contains(where: { $0.key == k }) != true { return }
            m.select(before)
        })
    }

    // MARK: - sessions.new

    /// The New session form, filled and started: what ⌘N, typing and Start do. A refusal closes the form (Cancel) and
    /// is the reply's error. Undo stops the new session once it is listed.
    static func new(_ args: [String: ControlJSON]) throws -> ControlChange {
        let (m, _) = try window()
        guard m.newSession == nil else { throw ControlError(formOpen) }
        let agent = try required(args, "agent"), prompt = string(args, "prompt")
        guard agent == "claude" || prompt == nil else { throw ControlError("a prompt needs agent claude") }
        m.openNewSession()
        guard let f = m.newSession else {
            throw ControlError(m.store?.resumeGate.refusal.map { "Controls \($0)" } ?? "New session is not available")
        }
        func refuse(_ why: String?) -> ControlError {
            m.cancelNewSession()
            return ControlError(why ?? "New session refused")
        }
        if let cwd = string(args, "cwd") { m.setNewSessionFolder(cwd) }
        // claude: the form's own command when it runs a Claude (the person's saved flags), else plain claude.
        switch agent {
        case "codex": m.setNewSessionCommand("codex")
        case "shell": m.setNewSessionCommand("")
        default: if !m.newSessionClaude { m.setNewSessionCommand("claude") }
        }
        let folder = AgentNewSession.expand(m.newSession?.folder ?? f.folder, home: m.home)
        m.setNewSessionName(string(args, "name")
            ?? AgentNewSession.autoName(folder: folder, taken: m.spawnTaken, dir: m.island().spawnDir()))
        // #1809 (a): the form's prompt only; the person's kept draft (lastPrompt) is never touched.
        m.setNewSessionPrompt(prompt ?? "", draft: false)
        guard m.canStartNewSession else {
            let e = m.newSessionErrors
            throw refuse(e.name ?? e.folder ?? m.newSessionStatus)
        }
        let name = m.newSessionName
        guard m.startNewSession(persist: false) else { throw refuse(m.newSession?.status) }
        return ControlChange(summary: name, result: .string(name), verb: "started a session", undo: { [weak m] in
            // shortcut: by name in the store as listed at undo time; a session not listed yet is not stopped.
            guard let m, let s = m.store?.sessions.first(where: { $0.name == name }) else { return }
            _ = m.stopSession(s)
        })
    }

    // MARK: - layout.set

    /// "side-by-side": a new layout (Layouts "+", Edit layout on), `left` picked into its pane, Split Right, `right`
    /// picked into the new pane, then Done (saved, locked). A refusal (the split gate off, 9 layouts, no room) deletes
    /// the layout it made, puts Edit layout back as it was (#1846 n134) and is the error. An open New session form is
    /// refused (n135: a pick closes it). Undo deletes it: the layout before comes back (the MRU's next).
    static func setLayout(_ args: [String: ControlJSON]) throws -> ControlChange {
        let (m, st) = try window()
        guard m.newSession == nil else { throw ControlError(formOpen) }
        let left = try session(try required(args, "left"), in: st), right = try session(try required(args, "right"), in: st)
        guard left.key != right.key else { throw ControlError("left and right are the same session") }
        guard AgentPaneLayout.splitsEnabled else { throw ControlError("split panes are off in this build") }
        let editing = m.layoutEditing
        if let r = m.newLayout() { throw ControlError(r.notice ?? "no new layout: \(r)") }
        let made = m.layout.id
        m.select(.live(left.key))
        let split = m.perform(.split(.columns))
        if split, m.layout.panes.count == 2 { m.select(.live(right.key)) }
        let shown = m.layout.panes.compactMap(\.target)
        guard shown == [.session(dir: left.key.dir, name: left.name), .session(dir: right.key.dir, name: right.name)] else {
            let why = m.paneRefusal?.notice
            m.deleteLayout(made)
            m.setLayoutEditing(editing)
            throw ControlError(why ?? "the two sessions could not be put side by side")
        }
        m.setLayoutEditing(false)
        return ControlChange(summary: "\(left.title) beside \(right.title)", result: .string(made.uuidString), verb: "set the layout", undo: { [weak m] in
            _ = m?.deleteLayout(made)
        })
    }
}

extension ControlRegistry {
    /// #1809: wired in ControlRegistry.standard().
    static func registerSessions(_ r: inout ControlRegistry) {
        let name = ControlArg(type: "string", required: true, summary: "the session's dch name or shown title")
        r.register(ControlCommand(name: "sessions.list",
                                  summary: "List live agent sessions: name, title, state, agent, cwd, pane, action.",
                                  args: [:], mutates: false) { _, _ in try ControlSessions.list() })
        r.register(.change(name: "sessions.new", summary: "Start a new agent session from Agent Sessions' New session form.", args: [
            "agent": ControlArg(type: "string", required: true, allowed: ControlSessions.agents, summary: "what runs in it"),
            "name": ControlArg(type: "string", summary: "its name; a free one from the folder when absent"),
            "cwd": ControlArg(type: "string", summary: "its folder; the form's default when absent"),
            "prompt": ControlArg(type: "string", summary: "the first message (claude only)"),
        ]) { _, a in try ControlSessions.new(a) })
        r.register(.change(name: "sessions.stop", summary: "Stop a session (Claude Code paused, the session ends; no undo).",
                           args: ["name": name]) { _, a in try ControlSessions.run(.stop, a) })
        r.register(.change(name: "sessions.restart", summary: "Restart a session's agent on the same conversation (no undo).",
                           args: ["name": name]) { _, a in try ControlSessions.run(.restart, a) })
        r.register(.change(name: "sessions.focus", summary: "Show Agent Sessions with this session selected (the keys stay where they are).",
                           args: ["name": name]) { _, a in try ControlSessions.focus(a) })
        r.register(.change(name: "layout.set", summary: "Arrange Agent Sessions: side-by-side puts two sessions in two panes.", args: [
            "layout": ControlArg(type: "string", required: true, allowed: ControlSessions.layouts),
            "left": name, "right": name,
        ]) { _, a in try ControlSessions.setLayout(a) })
    }
}

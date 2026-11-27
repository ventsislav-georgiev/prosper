import Foundation
import UniformTypeIdentifiers

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
    /// of the window's active layout that shows it (null: none, or no window); `agent` dch's --ls-json `agent` (#1996):
    /// "claude", "codex", or null when neither runs; from an older dch that sends none, "claude" when dch maps a Claude
    /// Code session, else dch's harness title, else null.
    static func list() throws -> ControlJSON {
        let st = try store(), layout = model()?.layout
        return .object(["sessions": .array(st.sessions.map { s -> ControlJSON in
            let pane = layout.flatMap { l in
                l.pane(showing: .session(dir: s.key.dir, name: s.name)).flatMap { l.order.firstIndex(of: $0) }
            }
            let agent: String? = if let a = s.agent { a.isEmpty ? nil : a }
                else { s.claudeSessionID?.isEmpty == false ? "claude" : (s.harness.isEmpty ? nil : s.harness) }
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

    /// #1864 n181: the person's keys are in (or headed for) the focused pane's terminal, so a retarget of that pane would
    /// swap in another session's view, which takes them (AgentTerminalHostSlot.hold).
    static let keysInPane = "no pane shows that session and the keys are in the focused pane: pick it yourself"

    /// The window shown and the session selected in its sidebar, as a click picks it but the keys stay where they are
    /// (#1846 n133: the person may be typing in another app; #1864: inside keepingKeys, as window.nextNeedsYou). An open
    /// New session form is refused (n135: a pick closes it), and so is a pick that would retarget the focused pane while
    /// the keys are in its terminal (n181: nothing changed). Undo selects the row selected before, skipped when that
    /// would retarget the focused pane while the keys are in it.
    static func focus(_ args: [String: ControlJSON]) throws -> ControlChange {
        let name = try required(args, "name")
        guard let m = showWindow(), let st = m.store else { throw ControlError(islandOff) }
        guard m.newSession == nil else { throw ControlError(formOpen) }
        let s = try session(name, in: st), before = m.selection
        guard !retargetsKeys(m, .live(s.key)) else { throw ControlError(keysInPane) }
        m.keepingKeys { m.select(.live(s.key)) }
        return ControlChange(summary: "focus \(s.title)", result: .string(s.name), verb: "focused", undo: { [weak m] in
            // A live row comes back only while its session is listed (the sidebar's rows may not be built yet).
            guard let before, let m, !retargetsKeys(m, before) else { return }
            if case .live(let k) = before, m.store?.sessions.contains(where: { $0.key == k }) != true { return }
            m.keepingKeys { m.select(before) }
        })
    }

    /// #1864: `select(id)` would put another target into the focused pane while its terminal has the keys or a focus
    /// pending (only a terminal view hands them on a swap; with no keys there a retarget moves none, so it stays allowed).
    static func retargetsKeys(_ m: AgentWindowModel, _ id: AgentSidebar.RowID) -> Bool {
        guard m.wouldRetargetFocusedPane(id) else { return false }
        return m.terminal.focusPending || m.terminal.view.map { $0.window?.firstResponder === $0 } == true
    }

    // MARK: - sessions.new

    /// #1863: the image files' writer, AgentPromptImages.store (off main, its result on main); rows run `write` in place.
    static var storeImages: @MainActor ([AgentPromptImages.Source], URL, @escaping @MainActor @Sendable (AgentPromptImages.Outcome) -> Void) -> Void = {
        AgentPromptImages.store($0, dir: $1, done: $2)
    }

    /// #1863: sessions.new's images: absolute paths whose extension is an image type, at most AgentPromptImages.maxImages,
    /// no control or hidden character. Checked here without touching the disk; the writer then refuses what is not a
    /// regular file, is past the paste's byte cap, is a link whose target is not named as an image (n173 a: resolved off
    /// main), is over its pixel cap or does not decode as an image (AgentPromptImages.write).
    static func imagePaths(_ args: [String: ControlJSON]) throws -> [URL] {
        guard let v = args["images"] else { return [] }
        guard case .array(let a) = v, !a.isEmpty else { throw ControlError("images is an empty list") }
        guard a.count <= AgentPromptImages.maxImages else { throw ControlError("at most \(AgentPromptImages.maxImages) images") }
        return try a.map { item in
            guard case .string(let p) = item, p.hasPrefix("/"), !ControlSessionsTalk.hasUnseen(p) else {
                throw ControlError("each image is an absolute file path with no control or hidden character")
            }
            let url = URL(fileURLWithPath: p)
            guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else {
                throw ControlError("\(OutsideText.shown(url.lastPathComponent, max: 80)) is not an image file (png, jpeg, heic, ...)")
            }
            return url
        }
    }

    /// The New session form, filled and started: what ⌘N, typing and Start do. A refusal closes the form (Cancel) and
    /// is the reply's error. Undo stops the new session once it is listed.
    /// #1863: `host` picks another Mac in the form's host picker (its remote start; no prompt or images there, no undo:
    /// its session is that Mac's). `images` go through the prompt's image paste path (written as PNGs, their paths
    /// after the prompt), then Start; that write runs off main, so a failure after the reply is a notice and the form
    /// is cancelled.
    static func new(_ args: [String: ControlJSON], changes: ControlChanges = .shared) throws -> ControlChange {
        let (m, _) = try window()
        guard m.newSession == nil else { throw ControlError(formOpen) }
        let agent = try required(args, "agent"), prompt = string(args, "prompt"), host = string(args, "host")
        // An agent's first message is outside text: the same cap and refusals as sessions.say, before anything opens.
        if prompt != nil { _ = try ControlSessionsTalk.text(args, key: "prompt") }
        let images = try imagePaths(args)
        guard agent == "claude" || agent == "codex" || prompt == nil else { throw ControlError("a prompt needs agent claude or codex") }
        // #1992: a Codex's first prompt is text only (the form pastes no images for it).
        guard agent == "claude" || images.isEmpty else { throw ControlError("images need agent claude") }
        guard host == nil || (prompt == nil && images.isEmpty) else { throw ControlError(AgentNewSessionView.notClaude(command: "", host: host)) }
        // The paths follow the prompt: alone, a leading "/" would read as a slash command.
        guard images.isEmpty || prompt != nil else { throw ControlError("images need a prompt") }
        if let host, !m.newSessionHosts.contains(host) {
            throw ControlError("no host \(OutsideText.shown(host, max: 80)) to start on (remote.list lists them)")
        }
        // n173 (d): another Mac's folder is argv there; the form checks only C0 and DEL (remoteFolderError), an agent's gets every unseen scalar refused.
        if host != nil, let cwd = string(args, "cwd"), ControlSessionsTalk.hasUnseen(cwd) {
            throw ControlError("cwd has a control or hidden character")
        }
        guard images.isEmpty || m.promptImagesDir != nil else { throw ControlError("images are not available here") }
        m.openNewSession()
        guard let f = m.newSession else {
            throw ControlError(m.store?.resumeGate.refusal.map { "Controls \($0)" } ?? "New session is not available")
        }
        func refuse(_ why: String?) -> ControlError {
            m.cancelNewSession()
            return ControlError(why ?? "New session refused")
        }
        if let host { m.setNewSessionHost(host) }
        if let cwd = string(args, "cwd") { m.setNewSessionFolder(cwd) }
        // claude: the form's own command when it runs a Claude (the person's saved flags), else plain claude.
        switch agent {
        case "codex": m.pickNewSessionAgent(.codex); if !m.newSessionCodex { m.setNewSessionCommand("codex") }   // #1997: the Codex command setting, else codex
        case "shell": m.pickNewSessionAgent(.shell)
        default: if !m.newSessionClaude { m.setNewSessionCommand("claude") }
        }
        let folder = AgentNewSession.expand(m.newSession?.folder ?? f.folder, home: m.home)
        // Another Mac's free name: from the names its list and History hold (the form's remoteTaken).
        let taken = host.map { h in Set(m.remoteSessions.filter { $0.host == h }.map(\.name)
                                        + m.remoteHistory.filter { $0.host == h }.map(\.record.name)) } ?? m.spawnTaken
        m.setNewSessionName(string(args, "name")
            ?? AgentNewSession.autoName(folder: folder, taken: taken, dir: m.island().spawnDir()))
        // #1809 (a): the form's prompt only; the person's kept draft (lastPrompt) is never touched.
        m.setNewSessionPrompt(prompt ?? "", draft: false)
        guard m.canStartNewSession else {
            let e = m.newSessionErrors
            throw refuse(e.name ?? e.folder ?? m.newSessionStatus)
        }
        let name = m.newSessionName
        if let dir = m.promptImagesDir, !images.isEmpty {
            m.beginNewSessionPromptPaste()   // Start waits for it, as for a paste
            storeImages(images.map(AgentPromptImages.Source.file), dir) { [weak m] out in
                guard let m, m.newSession != nil else { return }
                // Only into the form this call filled (its name): another one gets the paste's end and nothing else.
                guard m.newSession?.starting == nil, m.newSessionName == name, let text = m.newSession?.prompt else {
                    m.endNewSessionPromptPaste()   // n173 (c): nothing of this write reaches the form, its note included
                    return changes.present("Agent's new session \(OutsideText.shown(name, max: 60)) did not start: the New session form changed", nil)
                }
                m.setNewSessionPrompt(text + AgentPromptImages.insertion(out.made.map(\.path), after: text.last), draft: false)
                m.addNewSessionPromptImages(out)
                let why: String? = out.made.count < images.count ? out.note ?? "Could not add the images"
                    : m.startNewSession(persist: false) ? nil : m.newSession?.status ?? m.newSessionStatus ?? "New session refused"
                guard let why else { return }
                m.cancelNewSession()
                changes.present("Agent's new session \(OutsideText.shown(name, max: 60)) did not start: \(OutsideText.shown(why, max: 200))", nil)
            }
            return ControlChange(summary: name, result: .string(name), verb: "is starting a session", undo: undo(name, m))
        }
        guard m.startNewSession(persist: false) else { throw refuse(m.newSession?.status) }
        guard let host else { return ControlChange(summary: name, result: .string(name), verb: "started a session", undo: undo(name, m)) }
        return ControlChange(summary: "\(name) on \(host) (no undo on another Mac)", result: .string(name), verb: "started a session")
    }

    private static func undo(_ name: String, _ m: AgentWindowModel) -> @MainActor () -> Void {
        { [weak m] in
            // shortcut: by name in the store as listed at undo time; a session not listed yet is not stopped.
            guard let m, let s = m.store?.sessions.first(where: { $0.name == name }) else { return }
            _ = m.stopSession(s)
        }
    }

    // MARK: - layout.set

    /// "side-by-side": a new layout (Layouts "+"), `left` picked into its empty pane, Split Right, `right` picked into
    /// the new empty pane (#1895: an empty focused pane takes the pick; each step saved). A refusal (the split gate off,
    /// 9 layouts, no room) deletes the layout it made and is the error. An open New session form is
    /// refused (n135: a pick closes it). Undo deletes it: the layout before comes back (the MRU's next).
    static func setLayout(_ args: [String: ControlJSON]) throws -> ControlChange {
        let (m, st) = try window()
        guard m.newSession == nil else { throw ControlError(formOpen) }
        let left = try session(try required(args, "left"), in: st), right = try session(try required(args, "right"), in: st)
        guard left.key != right.key else { throw ControlError("left and right are the same session") }
        guard AgentPaneLayout.splitsEnabled else { throw ControlError("split panes are off in this build") }
        if let r = m.newLayout() { throw ControlError(r.notice ?? "no new layout: \(r)") }
        let made = m.layout.id
        m.select(.live(left.key))
        let split = m.perform(.split(.columns))
        if split, m.layout.panes.count == 2 { m.select(.live(right.key)) }
        let shown = m.layout.panes.compactMap(\.target)
        guard shown == [.session(dir: left.key.dir, name: left.name), .session(dir: right.key.dir, name: right.name)] else {
            let why = m.paneRefusal?.notice
            m.deleteLayout(made)
            throw ControlError(why ?? "the two sessions could not be put side by side")
        }
        return ControlChange(summary: "\(left.title) beside \(right.title)", result: .string(made.uuidString), verb: "set the layout", undo: { [weak m] in
            _ = m?.deleteLayout(made)
        })
    }

    // MARK: - sessions.history / sessions.resume (#1833)

    /// A History row's Resume: the island controller's own (the window's island when there is a window, its runner and
    /// gates); false when nothing started (busy). Tests replace it.
    static var resumeRecord: @MainActor (DchHistoryRecord, _ noMessage: Bool) -> Bool = {
        (ControlSessions.model()?.island() ?? AgentIslandController.shared).resume($0, noMessage: $1)
    }

    /// The History rows: this Mac's records (the store the window and the island read), then another Mac's records as
    /// the window's History lists them (its rows with a host; none without a window).
    static func records(_ st: AgentIslandStore) -> [DchHistoryRecord] {
        st.history + (model()?.rows.compactMap { $0.host == nil ? nil : $0.record } ?? [])
    }

    /// The id sessions.resume takes: the record's own (an aside record's file, else its name); "host:id" for another Mac's.
    static func recordID(_ r: DchHistoryRecord) -> String {
        AgentWindowModel.isRemote(r) ? "\(r.key.dir.dropFirst()):\(r.id.name)" : r.id.name
    }

    /// The History menu's answer for `verb` on `r` (AgentWindowControls.historyMenu + notRun, the confirm strip's check):
    /// nil when it runs, else its reason ("Not run: Resume (needs dch 1.23.0)"). Another Mac's record has Resume only
    /// (AgentWindowModel.act runs nothing else for it).
    static func historyRefusal(_ r: DchHistoryRecord, _ verb: AgentWindowVerb, in st: AgentIslandStore) -> String? {
        if verb == .resumeNoMessage, AgentWindowModel.isRemote(r) {
            return "Not run: " + AgentIsland.label(AgentIsland.resumeNoMessageLabel, needs: "this Mac's records only")
        }
        return AgentWindowControls.notRun(AgentWindowControls.historyMenu(r, store: st), verb,
                                          absent: AgentWindowControls.historyOff(verb, r, store: st))
    }

    /// {"history": [{id, name, title, cwd, ended, status, age, pinned, host, codex, action, resume, resumeWhyNot,
    /// resumeNoMessage, resumeNoMessageWhyNot}]}: read on demand from the store the window keeps (no dch call).
    /// #1990: `codex`, the Codex thread id dch 1.173.0 resumes for the record, else null.
    static func history() throws -> ControlJSON {
        let st = try store(), m = model(), now = m?.now() ?? Date().timeIntervalSince1970
        func str(_ s: String?) -> ControlJSON { s.map { .string($0) } ?? .null }
        return .object(["history": .array(records(st).map { r -> ControlJSON in
            let remote = AgentWindowModel.isRemote(r)
            let resume = historyRefusal(r, .resume, in: st), quiet = historyRefusal(r, .resumeNoMessage, in: st)
            return .object([
                "id": .string(recordID(r)), "name": .string(r.name), "title": .string(r.title),
                "cwd": r.cwd.isEmpty ? .null : .string(r.cwd), "ended": r.ended > 0 ? .number(r.ended) : .null,
                "status": .string(AgentIsland.endLabel(r.end)), "age": .string(r.lastSeen > 0 ? AgentIsland.age(now - r.lastSeen) : ""),
                "pinned": .bool(r.pinned), "host": remote ? .string(String(r.key.dir.dropFirst())) : .null,
                "codex": str(r.codex?.threadID),
                "action": str(remote ? m?.remoteResumeText[r.id] : st.historyActions[r.id]),
                "resume": .bool(resume == nil), "resumeWhyNot": str(resume),
                "resumeNoMessage": .bool(quiet == nil), "resumeNoMessageWhyNot": str(quiet),
            ])
        })])
    }

    /// A History row's Resume, or its Resume (no message): the History menu's gate, then the controller's resume (this
    /// Mac) or the window's resumeRemote (another Mac). `message`: resumed as Resume (no message), then the New session
    /// first prompt's path (sayFirst: it waits for the revived Claude's prompt); refused for a non-Claude record or another Mac's.
    /// #1992: a Codex record too (dch 1.173.0+ revives it with `codex resume`, then types the message like Claude's).
    /// No undo: a resume is not reversible. #1877: `said` gets the message's outcome on main, only when one was sent:
    /// nil when delivered, else the error naming the resume (ControlSessionsTalk.resume awaits it).
    static func resume(_ args: [String: ControlJSON], said: (@MainActor (_ failure: String?) -> Void)? = nil) throws -> ControlChange {
        let st = try store(), id = try required(args, "id")
        let hits = records(st).filter { recordID($0) == id }
        guard hits.count < 2 else { throw ControlError("\(hits.count) History records are \(id): resume it from Agent Sessions") }
        guard let r = hits.first else { throw ControlError("no History record \(id) (sessions.history lists them)") }
        let message = string(args, "message"), remote = AgentWindowModel.isRemote(r)
        if message != nil { _ = try ControlSessionsTalk.text(args, key: "message") }   // outside text, before anything resumes
        if message != nil {
            // The New session form's rule (newSessionTakesPrompt): a first message only to an interactive Claude or Codex on this Mac.
            guard !remote else { throw ControlError("a message goes only to a session on this Mac") }
            guard AgentIsland.isInteractiveClaude(r.argv) || AgentIsland.isInteractiveCodex(r.argv) else {
                throw ControlError("a message needs a Claude Code or Codex session")
            }
            // #1833 r1: the agent's message replaces dch's carry-on one: Resume (no message), on its own gate.
            guard args["noMessage"] != .bool(false) else { throw ControlError("message already resumes without dch's carry-on message") }
        }
        let noMessage = message != nil || args["noMessage"] == .bool(true)
        if let why = historyRefusal(r, noMessage ? .resumeNoMessage : .resume, in: st) { throw ControlError(why) }
        let busy = "\(r.title) is busy: try again"
        var name = r.name
        if remote {
            guard let m = model() else { throw ControlError(islandOff) }   // its record came from this model's rows
            guard m.remoteResumeText[r.id] != AgentIsland.resumingText else { throw ControlError(busy) }
            m.resumeRemote(r)
            // resumeRemote shows its running text only when the job started (busy: nothing ran, nothing shown).
            guard m.remoteResumeText[r.id] == AgentIsland.resumingText else { throw ControlError(busy) }
        } else {
            // The name it revives as, the controller's rule (resume: a name live now revives as the next free one).
            let live = Set(st.sessions.filter { $0.key.dir == r.key.dir }.map(\.name))
            let taken = Set(st.history.filter { $0.key.dir == r.key.dir && $0.key != r.key }.map(\.name))
            name = AgentIsland.reviveAs(r, live: live, records: taken) ?? r.name
            guard resumeRecord(r, noMessage) else { throw ControlError(busy) }
            if let message {
                let key = AgentSessionKey(dir: r.key.dir, name: name), title = r.title, revived = name
                let codex = !AgentIsland.isInteractiveClaude(r.argv)   // the guard above: else a Codex
                let then: @MainActor (String?) -> Void = { why in
                    said?(why.map { "\(title): resumed as \(revived), message not delivered: \(OutsideText.shown($0, max: 200))" })
                }
                if let m = model() { m.sayFirst(key, message, codex, then) }
                else { AgentIslandController.shared.sayFirst(key, message, codex: codex, then: then) }
            }
        }
        return ControlChange(summary: "\(r.title) (a resume has no undo)", result: .string(name), verb: "resumed")
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
            "prompt": ControlArg(type: "string", summary: "the first message (claude or codex)"),
            "host": ControlArg(type: "string", summary: "another Mac from remote.list (canStart) to start it on; this Mac when absent"),
            "images": ControlArg(type: "array", summary: "image file paths (absolute) added to the prompt, as a paste adds them (claude on this Mac, with a prompt)"),
        ]) { reg, a in try ControlSessions.new(a, changes: reg.changes) })
        r.register(.change(name: "sessions.stop", summary: "Stop a session (its agent is paused, the session ends; no undo).",
                           args: ["name": name]) { _, a in try ControlSessions.run(.stop, a) })
        r.register(.change(name: "sessions.restart", summary: "Restart a session's agent on the same conversation (no undo).",
                           args: ["name": name]) { _, a in try ControlSessions.run(.restart, a) })
        r.register(.change(name: "sessions.focus", summary: "Show Agent Sessions with this session selected (the keys stay where they are). Refused when no pane shows it and the keys are in the focused pane (it never swaps that pane's terminal under the person's keys).",
                           args: ["name": name]) { _, a in try ControlSessions.focus(a) })
        r.register(.change(name: "layout.set", summary: "Arrange Agent Sessions: side-by-side puts two sessions in two panes.", args: [
            "layout": ControlArg(type: "string", required: true, allowed: ControlSessions.layouts),
            "left": name, "right": name,
        ]) { _, a in try ControlSessions.setLayout(a) })
        // #1833: the History rows and their Resume.
        r.register(ControlCommand(name: "sessions.history",
                                  summary: "List History records: id, name, cwd, ended, status, age, pinned, host, codex thread, and whether Resume runs.",
                                  args: [:], mutates: false) { _, _ in try ControlSessions.history() })
        // #1877: awaited (reply(to:) calls runAsync) when it carries a message; ControlSessionsTalk.resume records the change.
        r.register(ControlCommand(name: "sessions.resume", summary: "Resume a History record, optionally without dch's message or with your own (no undo). Without a message the reply is the name it revives as; with one it waits (up to 60 s) for the message: {name, delivered: true}, an error naming the resume and why the message was not sent, or {name, delivered: \"unknown\", note}.", args: [
            "id": ControlArg(type: "string", required: true, summary: "the record's id from sessions.history"),
            "noMessage": ControlArg(type: "boolean", summary: "Resume (no message): dch types no carry-on message"),
            "message": ControlArg(type: "string", summary: "your first message once it is up, instead of dch's (a Claude or Codex session on this Mac only)"),
        ], mutates: true, run: { _, _ in throw ControlError("sessions.resume waits for its outcome: send it through the control channel") },
           runAsync: { reg, a in try await ControlSessionsTalk.resume(a, changes: reg.changes) }))
    }
}

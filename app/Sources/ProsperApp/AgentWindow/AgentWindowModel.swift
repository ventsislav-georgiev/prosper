import Combine
import Foundation

// #797 Agent window D1: the sidebar of every dch session and the one conversation
// model behind the detail pane. Fed only by Agent Island's store (its poller is
// the only dch fork); the transcript mapping rides on that same --ls-json read.

/// dch 1.30's per-row `claude_session_id` and `transcript_path` (design rule 6),
/// parsed from the same `--ls-json` bytes Agent Island already read.
enum AgentTranscriptMapping {
    struct Entry: Equatable {
        let sessionID: String
        let path: String
    }

    /// name → mapping. Tolerant (rule 2): a row without both, a non-UUID-shaped id or
    /// a path that is not an absolute `.jsonl` maps to nothing, so the session opens
    /// terminal-first (fail closed, never a guessed file).
    static func parse(_ data: Data) -> [String: Entry] {
        guard !data.isEmpty, let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [:] }
        var out: [String: Entry] = [:]
        for o in rows {
            guard let name = o["name"] as? String, !name.isEmpty,
                  let sid = (o["claude_session_id"] ?? o["claudeSessionId"]) as? String,
                  let path = (o["transcript_path"] ?? o["transcriptPath"]) as? String,
                  !sid.isEmpty, sid.count <= 64, sid.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "-") }),
                  path.hasPrefix("/"), path.hasSuffix(".jsonl"), path.utf8.count <= 4096,
                  !path.contains("\0"), !path.split(separator: "/").contains(".."),
                  // QA #626 INFO-5: dch names `<config>/projects/<dir>/<sessionId>.jsonl`, so the file is that id's.
                  (path as NSString).lastPathComponent == "\(sid).jsonl"
            else { continue }
            out[name] = Entry(sessionID: sid, path: path)
        }
        return out
    }
}

/// The sidebar's rows, built from the island store's values. Pure.
enum AgentSidebar {
    enum RowID: Hashable {
        case live(AgentSessionKey)
        /// A History record (its `id`): it can share a key with a live session (#580).
        case history(AgentSessionKey)
    }

    struct Row: Identifiable, Equatable {
        let id: RowID
        let title: String
        /// nil for a History row.
        let state: AgentState?
        /// "Needs input", "Working · 2 agents", "Ended · exit 1".
        let detail: String
        /// "4m"; "" for an unknown time.
        let age: String
        /// Open PR labels the island shows ("repo#12"), and "+N" past two.
        let prs: [String]
        /// Every open PR shown (the chips' fallback when they do not fit).
        var prCount = 0
        var session: AgentSession?
        var record: DchHistoryRecord?
    }

    struct Section: Identifiable, Equatable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    static let needsYouTitle = "Needs you"
    /// #828: the sections a header click folds away. Needs you never folds: it is the list of
    /// sessions waiting on the human.
    static let collapsible: Set<String> = ["Sessions", "Sidekicks", "History"]

    /// Waiting for the human: blocked on a prompt, or done (the turn is over and the
    /// next message is theirs). Working and idle sessions are not.
    static func needsYou(_ s: AgentSession) -> Bool { s.state == .blocked || s.state == .done }

    /// "Needs you" first (blocked before done, newest first), then the island's own
    /// Sessions / Sidekicks split in its sort order, then History. A session sits in
    /// one group only; empty groups are left out.
    /// #829 G0: `actions` are the island's row texts; a running one replaces the state word.
    static func sections(sessions: [AgentSession], history: [DchHistoryRecord], sort: AgentIslandSort,
                         sidekickPattern: String, details: AgentIslandRowDetails, now: TimeInterval,
                         actions: [AgentSessionKey: String] = [:]) -> [Section] {
        let needs = sessions.filter(needsYou).sorted {
            if $0.state != $1.state { return $0.state < $1.state }
            if $0.activity != $1.activity { return $0.activity > $1.activity }
            return ($0.key.name, $0.key.dir) < ($1.key.name, $1.key.dir)
        }
        let rest = AgentIsland.split(AgentIsland.sorted(sessions.filter { !needsYou($0) }, by: sort), pattern: sidekickPattern)
        var out: [Section] = []
        func add(_ title: String, _ rows: [Row]) { if !rows.isEmpty { out.append(Section(title: title, rows: rows)) } }
        let live = { (s: AgentSession) in row(s, details: details, now: now, action: actions[s.key]) }
        add(needsYouTitle, needs.map(live))
        add("Sessions", rest.primary.map(live))
        add("Sidekicks", rest.sidekicks.map(live))
        add("History", AgentIsland.cappedHistory(history).map { row($0, now: now) })
        return out
    }

    static func row(_ s: AgentSession, details: AgentIslandRowDetails, now: TimeInterval, action: String? = nil) -> Row {
        // #829 G0: "Stopping…", "Pausing…" while a Restart or Stop runs (from the island or the window).
        var parts = [AgentWindowControls.lock(action) ?? s.state.label]
        if details.agents, s.agents > 0 { parts.append(s.agents == 1 ? "1 agent" : "\(AgentIsland.count(s.agents)) agents") }
        if let merged = AgentIsland.mergedLabel(s.meta, show: details) { parts.append(merged) }
        let (chips, more) = AgentIsland.prChips(s.meta, show: details, budget: .infinity)
        let prs = chips.prefix(2).map(\.label) + (chips.count + more > 2 ? ["+\(chips.count + more - 2)"] : [])
        return Row(id: .live(s.key), title: s.title, state: s.state, detail: parts.joined(separator: " · "),
                   age: AgentIsland.age(of: s, now: now), prs: prs, prCount: chips.count + more, session: s)
    }

    static func row(_ r: DchHistoryRecord, now: TimeInterval) -> Row {
        Row(id: .history(r.id), title: r.title, state: nil, detail: "Ended · " + AgentIsland.endLabel(r.end),
            age: r.lastSeen > 0 ? AgentIsland.age(now - r.lastSeen) : "", prs: [], record: r)
    }

    /// The transcript model's input for a live session.
    static func source(_ s: AgentSession) -> AgentTranscriptSource {
        let state = switch s.state {
        case .blocked: "blocked"
        case .working: "working"
        case .done: "done"
        case .idle: "idle"
        }
        return AgentTranscriptSource(key: s.key, dchVersion: s.version, dchState: state,
                                     sessionId: s.claudeSessionID, transcriptPath: s.transcriptPath)
    }
}

/// The window's state: the sidebar, the selection and the one transcript model.
/// Energy (design "Energy"): nothing runs unless the window is open and visible.
/// While hidden the transcript is stopped and the age clock is off; `close` drops
/// the store subscription too.
@MainActor
final class AgentWindowModel: ObservableObject {
    @Published private(set) var sections: [AgentSidebar.Section] = []
    @Published private(set) var selection: AgentSidebar.RowID?
    /// False while the island is off (no store): the window says so.
    @Published private(set) var hasStore = false
    /// The only conversation model: rebound on each selection, stopped on deselect,
    /// hide and close.
    let transcript = AgentTranscriptModel()

    private(set) var store: AgentIslandStore?
    private(set) var visible = false
    private(set) var closed = false
    private var subscription: AnyCancellable?
    private(set) var clock: Timer?
    /// QA #626 INFO-4: the first row is picked once, on the window's first fill; a selected
    /// session that ends leaves nothing selected (the hint), never another conversation.
    private var filled = false
    /// #798: the input box, interrupt and prompt answers for the selected live session.
    let interaction = AgentWindowInteraction()
    /// #821: how much of the conversation shows: one level for the window, per Mac. A switch
    /// only re-projects the blocks already in memory (no read, no new file IO).
    @Published var verbosity = Preferences.agentWindowVerbosity {
        didSet { if verbosity != oldValue { Preferences.agentWindowVerbosity = verbosity } }
    }
    /// #828: the folded sidebar sections (titles), per Mac across window close and relaunch.
    /// Folding hides rows only: the selection, its transcript and Return stay as they were.
    @Published private(set) var collapsed = Preferences.agentWindowCollapsedSections {
        didSet { if collapsed != oldValue { Preferences.agentWindowCollapsedSections = collapsed } }
    }
    /// #822: the selected session's live terminal. One per window model, like `transcript`
    /// (a split pane brings its own model); attached only by `follow`.
    let terminal = AgentTerminalController()
    /// #822: a live session opens in Terminal (operator, 2026-11-10). These are the ones the human
    /// switched to Transcript ("<dir>\t<name>"), newest first, per Mac; a later session that reuses
    /// a name inherits the choice.
    @Published private(set) var transcriptKeys = Preferences.agentWindowTranscriptSessions {
        didSet { if transcriptKeys != oldValue { Preferences.agentWindowTranscriptSessions = transcriptKeys } }
    }

    // Seams.
    var now: () -> TimeInterval = { Date().timeIntervalSince1970 }
    /// Open in terminal: the island's row click (focus the attached terminal, else
    /// open one, else copy the attach command).
    var openSession: (AgentSession) -> Void = { AgentIslandController.shared.jump($0) }
    /// The island controller the History verbs go to (tests: one with a fake runner).
    var island: () -> AgentIslandController = { .shared }
    /// A History row's Resume: the island's.
    lazy var resume: (DchHistoryRecord) -> Void = { [weak self] in self?.island().resume($0) }
    /// #829 G6-G8: Resume (no message), Pin/Unpin and Remove from History: the island's.
    lazy var resumeNoMessage: (DchHistoryRecord) -> Void = { [weak self] in self?.island().resume($0, noMessage: true) }
    lazy var pinRecord: (DchHistoryRecord) -> Void = { [weak self] in self?.island().pin($0) }
    lazy var removeRecord: (DchHistoryRecord) -> Void = { [weak self] in self?.island().remove($0) }
    /// Told when the window shows or hides, so the island keeps the store current
    /// (it holds activity-only lists back while nothing shows them).
    var onVisible: (Bool) -> Void = { AgentIslandController.shared.windowWatching = $0 }
    var ageInterval: TimeInterval = 30
    /// #829: Restart agent, Stop and Kill: the island's controller methods (its gates, runner
    /// keys, busy refusal and row texts). True: the job started.
    var restartSession: (AgentSession) -> Bool = { AgentIslandController.shared.restart($0, sayBusy: true) }
    var stopSession: (AgentSession) -> Bool = { AgentIslandController.shared.stop($0, sayBusy: true) }
    var killSession: (AgentSession) -> Bool = { AgentIslandController.shared.kill($0) }
    /// #829 G4: Rename's `dch -m`, on the island's controller (its runner key and the row's dir env).
    var renameSession: (AgentSession, String) -> Bool = { AgentIslandController.shared.rename($0, alias: $1) }
    /// G4: the live session whose header title is a text field now. Dropped by a selection change,
    /// an ask, Return, Esc and the field losing focus. While set, the window's shortcuts stand down.
    @Published private(set) var renaming: AgentSessionKey?
    /// #829 (R5): the question the confirm strip shows; dropped by a selection change.
    @Published private(set) var confirming: AgentWindowConfirm?
    /// QA #665 INFO-6: an answer a gate refused since the question; dropped by a selection change or the next ask.
    @Published private(set) var refusal: AgentWindowRefusal?
    /// #829 G2: a Stop or Kill the window started: once its live row is gone and a History
    /// record of that key ended since, that row is selected. One-shot; any manual selection drops it.
    private(set) var following: (key: AgentSessionKey, at: TimeInterval)? {
        didSet { if following == nil { held = nil; heldSince = nil } }
    }
    /// QA #665 INFO-8: the followed session's last live row. Its row gone before its record lands,
    /// the selection stays on it (the pane keeps showing it) until the record lands or the bound passes.
    /// QA #668 F1: display only (nothing opens, sends or asks on it), and for `recordSlack` at most.
    private var held: AgentSidebar.Row?
    /// When the followed session's live row was first seen gone (the hold's start).
    private var heldSince: TimeInterval?
    /// dch writes a record each minute: a Stop or Kill's record has ended by then, with slack.
    static let recordSlack: TimeInterval = 65
    /// #829 G8: a record the window removed (its id): once its row is gone, the next History row
    /// is selected (else the previous, else none), never through nothing. A manual pick drops it.
    private(set) var removing: AgentSessionKey?
    /// Counts sidebar rebuilds (tests: nothing rebuilds after close).
    private(set) var refreshes = 0

    private var askSubscription: AnyCancellable?
    private var planSubscription: AnyCancellable?

    init() {
        terminal.isLive = { [weak self] key in self?.store?.sessions.contains { $0.key == key } ?? false }
        // #798: the transcript's pending AskUserQuestion is what a question form is checked against.
        askSubscription = transcript.$pendingAsk.sink { [weak self] ask in
            MainActor.assumeIsolated { self?.interaction.ask = ask }
        }
        // #802: and the pending ExitPlanMode is what a plan approval is checked against.
        planSubscription = transcript.$pendingPlan.sink { [weak self] plan in
            MainActor.assumeIsolated { self?.interaction.plan = plan }
        }
    }

    /// Follows `store` (nil: the island is off). Called on open and whenever the
    /// island rebuilds its store. The sidebar fills once the window is visible.
    func bind(_ store: AgentIslandStore?) {
        guard !closed else { return }
        self.store = store
        hasStore = store != nil
        subscription = nil
        guard let store else {
            sections = []
            select(nil, manual: false)
            return
        }
        // @Published sends on willSet with the new value, so the values are used as given.
        subscription = store.$sessions.combineLatest(store.$history, store.$sort, store.$sidekickPattern)
            .combineLatest(store.$details, store.$actions)
            .sink { [weak self] v, details, actions in
                MainActor.assumeIsolated {
                    self?.refresh(sessions: v.0, history: v.1, sort: v.2, pattern: v.3, details: details, actions: actions)
                }
            }
    }

    /// Rebuilds the sidebar from the store's current values (the age clock's tick).
    func refresh() {
        guard let s = store else { return }
        refresh(sessions: s.sessions, history: s.history, sort: s.sort, pattern: s.sidekickPattern, details: s.details,
                actions: s.actions)
    }

    private func refresh(sessions: [AgentSession], history: [DchHistoryRecord], sort: AgentIslandSort,
                         pattern: String, details: AgentIslandRowDetails, actions: [AgentSessionKey: String]) {
        // Hidden or closed: nothing is rebuilt; showing again reads the store afresh.
        guard visible, !closed else { return }
        refreshes += 1
        let new = AgentSidebar.sections(sessions: sessions, history: history, sort: sort, sidekickPattern: pattern,
                                        details: details, now: now(), actions: actions)
        let old = sections
        if let f = following, let r = new.lazy.flatMap(\.rows).first(where: { $0.id == .live(f.key) }) { held = r }
        if new != sections { sections = new }
        // The selected row gone (the session ended): nothing selected, nothing tailing; #829 G2:
        // unless it is followed to its History row (straight there, never through nothing; held
        // on the ended session until then). G8: a removed record's row hands on to its neighbour.
        if !followToHistory() {
            if case .history(let id)? = selection, id == removing, row(.history(id)) == nil {
                removing = nil
                select(Self.neighbour(of: id, old: old, new: new), manual: false)
            } else if selection != nil, selectedRow == nil {
                select(nil, manual: false)
            } else {
                follow()
            }
        }
        if confirming != nil, confirmingSession == nil, confirmingRecord == nil { confirming = nil }
        if let k = renaming, !sessions.contains(where: { $0.key == k }) { renaming = nil }   // it ended: no field
        // #828: the first shown row; every section folded leaves the hint, not a hidden pick.
        if !filled, !rows.isEmpty {
            filled = true
            if selection == nil, let first = navigableIDs.first { select(first, manual: false) }
        }
    }

    var rows: [AgentSidebar.Row] { sections.flatMap(\.rows) }
    func row(_ id: AgentSidebar.RowID) -> AgentSidebar.Row? { rows.first { $0.id == id } }
    /// QA #665 INFO-8: a followed session whose row left reads as its last row until its record lands.
    var selectedRow: AgentSidebar.Row? { selection.flatMap { row($0) ?? (held?.id == $0 ? held : nil) } }
    /// QA #668 F1: the selection resolves only through the hold: the session ended, so its pane is display-only.
    var selectionIsHeld: Bool { selection.map { row($0) == nil && held?.id == $0 } ?? false }

    /// G8: the History row after `id` in `old` that is still there, else the one before, else the
    /// first History row left; nil when History is empty.
    static func neighbour(of id: AgentSessionKey, old: [AgentSidebar.Section],
                          new: [AgentSidebar.Section]) -> AgentSidebar.RowID? {
        let was = old.first { $0.title == "History" }?.rows.map(\.id) ?? []
        let now = new.first { $0.title == "History" }?.rows.map(\.id) ?? []
        guard let i = was.firstIndex(of: .history(id)) else { return now.first }
        return was[(i + 1)...].first { now.contains($0) } ?? was[..<i].reversed().first { now.contains($0) } ?? now.first
    }

    func isCollapsed(_ title: String) -> Bool {
        AgentSidebar.collapsible.contains(title) && collapsed.contains(title)
    }

    /// Folds or unfolds `title` (a header click); a section that never folds is left alone.
    func setCollapsed(_ title: String, _ on: Bool) {
        guard AgentSidebar.collapsible.contains(title) else { return }
        if on { collapsed.insert(title) } else { collapsed.remove(title) }
    }

    func toggleCollapsed(_ title: String) { setCollapsed(title, !isCollapsed(title)) }

    /// Left / right arrows: fold or unfold the selected row's section.
    func collapseSelected(_ on: Bool) {
        guard let sel = selection, let s = sections.first(where: { $0.rows.contains { $0.id == sel } }) else {
            // QA #660 note 1: Right with nothing selected and nothing shown unfolds the first
            // folded section; then (or when rows show) it selects the first shown row.
            if !on, selection == nil {
                if navigableIDs.isEmpty, let s = sections.first(where: { isCollapsed($0.title) }) { setCollapsed(s.title, false) }
                move(1)
            }
            return
        }
        setCollapsed(s.title, on)
    }

    /// The rows up/down walk: the shown ones, plus the selection where it sits when its
    /// section is folded (so a move goes to its neighbour, never into a folded section).
    var navigableIDs: [AgentSidebar.RowID] {
        sections.flatMap { s in isCollapsed(s.title) ? s.rows.filter { $0.id == selection } : s.rows }.map(\.id)
    }

    /// `manual`: the human's pick (a click, a key, a menu); it drops a pending follow-to-History.
    /// Any change of row drops the confirm strip's question (R5).
    func select(_ id: AgentSidebar.RowID?, manual: Bool = true) {
        if manual { following = nil; removing = nil }
        if selection != id {
            selection = id
            confirming = nil
            refusal = nil
            renaming = nil
        }
        follow()
    }

    /// #845: the selection sits in a folded section (Right unfolds it before it moves in).
    var selectionFolded: Bool {
        sections.first { $0.rows.contains { $0.id == selection } }.map { isCollapsed($0.title) } ?? false
    }

    /// #845: a row click, Return, Right, ⌘T and the header toggle: the keyboard into the selected live session,
    /// its terminal (Terminal mode, once its client is live) or its input box (Transcript). False, and the focus
    /// stays where it is: nothing there takes input (History, an ended session's held row, none), or the rename
    /// field is editing. Only the human's actions call it, never a selection the model makes itself.
    @discardableResult
    func focusSelection() -> Bool {
        guard renaming == nil, !selectionIsHeld, selectedRow?.session != nil else { return false }
        if paneMode == .terminal { terminal.focus() } else { interaction.focusComposer() }
        return true
    }

    /// #845: a sidebar row's click: the human's pick, and the keyboard moves into it.
    func click(_ id: AgentSidebar.RowID) {
        select(id)
        focusSelection()
    }

    /// QA #694 INFO-2: the human took the keys elsewhere (a sidebar mouse-down, a rename) before a
    /// focus asked for landed (a terminal still attaching, an input box not built yet): it never lands.
    func dropPendingFocus() {
        terminal.dropPendingFocus()
        interaction.dropPendingFocus()
    }

    /// Up/down: the next or previous shown row across groups, clamped; from none, the first.
    func move(_ delta: Int) {
        let ids = navigableIDs
        guard !ids.isEmpty else { return }
        guard let sel = selection, let i = ids.firstIndex(of: sel) else { return select(ids[0]) }
        select(ids[min(max(i + delta, 0), ids.count - 1)])
    }

    /// The "Open in terminal" buttons: a live session only. False: nothing to open (a History
    /// row, none). QA #668 F1: nor an ended
    /// session's held row (`dch -n <name>` would start a new session of that name).
    @discardableResult
    func openSelected() -> Bool {
        guard !selectionIsHeld, let s = selectedRow?.session else { return false }
        openSession(s)
        return true
    }

    // MARK: #822 Transcript | Terminal

    nonisolated static func terminalKey(_ k: AgentSessionKey) -> String { "\(k.dir)\t\(k.name)" }

    func mode(_ s: AgentSession) -> AgentPaneMode {
        transcriptKeys.contains(Self.terminalKey(s.key)) ? .transcript : .terminal
    }

    /// The detail pane's mode: a row with nothing to attach (History, an ended session's held row,
    /// none) is Transcript and remembers nothing, so no terminal card shows where no terminal can be.
    var paneMode: AgentPaneMode {
        guard !selectionIsHeld, let s = selectedRow?.session else { return .transcript }
        return mode(s)
    }

    func setMode(_ m: AgentPaneMode, for s: AgentSession) {
        guard !(selectionIsHeld && selection == .live(s.key)) else { return }   // ended: nothing to remember
        let k = Self.terminalKey(s.key)
        var keys = transcriptKeys.filter { $0 != k }
        if m == .transcript { keys.insert(k, at: 0) }
        transcriptKeys = Array(keys.prefix(64))
        follow()
    }

    /// #845: the header's Transcript | Terminal toggle: the mode, then the keyboard into the shown mode's input.
    func switchMode(_ m: AgentPaneMode, for s: AgentSession) {
        setMode(m, for: s)
        focusSelection()
    }

    /// ⌘T and the header toggle: the selected live session's other mode. False: nothing to toggle.
    @discardableResult
    func toggleMode() -> Bool {
        guard !selectionIsHeld, let s = selectedRow?.session else { return false }
        setMode(mode(s) == .terminal ? .transcript : .terminal, for: s)
        return true
    }

    // MARK: #829 Restart agent, Stop, Kill (ask, then act)

    /// A header "⋯" or row context-menu item: selects the row first (R6), then asks.
    func ask(_ verb: AgentWindowVerb, _ s: AgentSession) {
        if selectionIsHeld, selection == .live(s.key) { return }   // QA #668 F1: it ended, nothing to ask
        select(.live(s.key))
        refusal = nil
        renaming = nil
        // G4: Rename edits the title in place and asks nothing; only a session still listed live.
        if verb == .rename {
            confirming = nil
            if store?.sessions.contains(where: { $0.key == s.key }) == true {
                renaming = s.key
                dropPendingFocus()   // QA #694 INFO-2: the field has the keys
            }
            return
        }
        confirming = AgentWindowConfirm(verb: verb, key: s.key)
    }

    /// G4: the title field's end, for the session `key` it was opened on. A key that is not the open
    /// field's (a replaced field's late end) changes nothing. `text` nil: Esc or the focus left, nothing
    /// runs. Else Return: the session is re-read by key (gone: nothing) and the controller runs `dch -m`
    /// unless the text is its alias already. An empty text clears the alias.
    func endRename(_ key: AgentSessionKey, _ text: String?) {
        guard renaming == key else { return }
        renaming = nil
        guard let text, let s = store?.sessions.first(where: { $0.key == key }),
              AgentIsland.renameArgs(s.name, text, current: s.alias) != nil else { return }
        _ = renameSession(s, text)
    }

    /// #829 G6-G8: a History row's context menu or detail button: selects the row first (R6).
    /// Resume, Resume (no message) and Pin/Unpin act at once (the island does not ask); Remove asks.
    func act(_ verb: AgentWindowVerb, _ r: DchHistoryRecord) {
        select(.history(r.id))
        refusal = nil
        switch verb {
        case .resume: resume(r)
        case .resumeNoMessage: resumeNoMessage(r)
        case .pin: pinRecord(r)
        case .remove: confirming = AgentWindowConfirm(verb: .remove, key: r.id)
        case .restart, .stop, .kill, .rename: break
        }
    }

    /// The asked session as it is now (nil: it ended).
    var confirmingSession: AgentSession? {
        confirming.flatMap { c in c.verb == .remove ? nil : store?.sessions.first { $0.key == c.key } }
    }

    /// The asked History record as it is now (nil: it went).
    var confirmingRecord: DchHistoryRecord? {
        confirming.flatMap { c in c.verb == .remove ? store?.history.first { $0.id == c.key } : nil }
    }

    /// The strip's answer. The session (or record) is re-resolved by key now: gone, nothing runs;
    /// QA #665 INFO-6: its gate closed since the question, nothing runs and the row says why.
    func confirm(_ yes: Bool) {
        guard let c = confirming, let store else { confirming = nil; return }
        let s = confirmingSession, r = confirmingRecord
        confirming = nil
        guard yes else { return }
        if let r {
            if let why = AgentWindowControls.notRun(AgentWindowControls.historyMenu(r, store: store), .remove,
                                                    absent: AgentWindowControls.historyOff(.remove, r, store: store)) {
                refusal = AgentWindowRefusal(id: .history(r.id), text: why)
                return
            }
            removing = r.id
            removeRecord(r)
            return
        }
        guard let s else { return }
        if let why = AgentWindowControls.notRun(AgentWindowControls.menu(s, store: store), c.verb) {
            refusal = AgentWindowRefusal(id: .live(s.key), text: why)
            return
        }
        switch c.verb {
        case .restart: _ = restartSession(s)
        case .stop: if stopSession(s) { startFollowing(s) }
        case .kill: if killSession(s) { startFollowing(s) }
        case .resume, .resumeNoMessage, .pin, .remove, .rename: break
        }
    }

    private func startFollowing(_ s: AgentSession) {
        following = (s.key, now())
        held = row(.live(s.key))
    }

    /// The refusal for the row `id`, if any.
    func refusalText(_ id: AgentSidebar.RowID) -> String? { refusal?.id == id ? refusal?.text : nil }

    /// G2: the followed session's live row is gone and a History record of its key ended
    /// since the Stop or Kill (dch writes a record each minute: 65 s of slack): select it.
    /// Dropped after the Stop's bound. QA #668 F1: no record `recordSlack` after the row left (history
    /// off, a failed record write): the hold lets go and nothing is selected.
    private func followToHistory() -> Bool {
        guard let f = following else { return false }
        if now() - f.at > DchActionRunner.restartBound { following = nil; return false }
        guard row(.live(f.key)) == nil else { return false }
        guard let h = rows.first(where: { $0.record?.key == f.key && ($0.record?.lastSeen ?? 0) >= f.at - Self.recordSlack })
        else {
            let since = heldSince ?? now()
            heldSince = since
            if now() - since > Self.recordSlack { following = nil }
            return false
        }
        following = nil
        select(h.id, manual: false)
        return true
    }

    func setVisible(_ v: Bool) {
        guard !closed, v != visible else { return }
        visible = v
        onVisible(v)
        clock?.invalidate()
        clock = nil
        if v {
            clock = Timer.scheduledTimer(withTimeInterval: ageInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            refresh()
        }
        follow()
    }

    /// The window closed: stop everything for good.
    func close() {
        guard !closed else { return }
        setVisible(false)
        closed = true
        subscription = nil
        askSubscription = nil
        transcript.stop()
        interaction.follow(nil)
        terminal.attach(nil)
    }

    /// The transcript model follows the selection: a visible live session runs, any
    /// other state is stopped (one model, so at most one transcript is ever tailed).
    /// #822: the terminal attaches to a visible, selected, live (not held) session in Terminal
    /// mode and detaches on anything else. The transcript runs in both modes: the header's cwd and
    /// todos come from it, so a toggle never changes the header.
    private func follow() {
        guard visible, !closed, let s = selectedRow?.session else {
            if transcript.running { transcript.stop() }
            interaction.follow(nil)
            terminal.attach(nil)
            return
        }
        transcript.update(AgentSidebar.source(s))
        transcript.start()
        interaction.ask = transcript.pendingAsk   // this session's, never the last one's
        interaction.plan = transcript.pendingPlan
        let terminalMode = paneMode == .terminal
        // QA #668 F1: an ended session takes no input; #822: Terminal mode has no input box (the terminal is the input).
        interaction.follow(selectionIsHeld || terminalMode ? nil : s)
        terminal.attach(terminalMode ? s.key : nil)   // paneMode is Transcript for a held row
    }
}

/// #822: the detail pane's two views of a live session.
enum AgentPaneMode: Equatable { case transcript, terminal }

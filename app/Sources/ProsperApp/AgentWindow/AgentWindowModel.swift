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

    /// Waiting for the human: blocked on a prompt, or done (the turn is over and the
    /// next message is theirs). Working and idle sessions are not.
    static func needsYou(_ s: AgentSession) -> Bool { s.state == .blocked || s.state == .done }

    /// "Needs you" first (blocked before done, newest first), then the island's own
    /// Sessions / Sidekicks split in its sort order, then History. A session sits in
    /// one group only; empty groups are left out.
    static func sections(sessions: [AgentSession], history: [DchHistoryRecord], sort: AgentIslandSort,
                         sidekickPattern: String, details: AgentIslandRowDetails, now: TimeInterval) -> [Section] {
        let needs = sessions.filter(needsYou).sorted {
            if $0.state != $1.state { return $0.state < $1.state }
            if $0.activity != $1.activity { return $0.activity > $1.activity }
            return ($0.key.name, $0.key.dir) < ($1.key.name, $1.key.dir)
        }
        let rest = AgentIsland.split(AgentIsland.sorted(sessions.filter { !needsYou($0) }, by: sort), pattern: sidekickPattern)
        var out: [Section] = []
        func add(_ title: String, _ rows: [Row]) { if !rows.isEmpty { out.append(Section(title: title, rows: rows)) } }
        add(needsYouTitle, needs.map { row($0, details: details, now: now) })
        add("Sessions", rest.primary.map { row($0, details: details, now: now) })
        add("Sidekicks", rest.sidekicks.map { row($0, details: details, now: now) })
        add("History", AgentIsland.cappedHistory(history).map { row($0, now: now) })
        return out
    }

    static func row(_ s: AgentSession, details: AgentIslandRowDetails, now: TimeInterval) -> Row {
        var parts = [s.state.label]
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

    // Seams.
    var now: () -> TimeInterval = { Date().timeIntervalSince1970 }
    /// Open in terminal: the island's row click (focus the attached terminal, else
    /// open one, else copy the attach command).
    var openSession: (AgentSession) -> Void = { AgentIslandController.shared.jump($0) }
    /// A History row's Resume: the island's.
    var resume: (DchHistoryRecord) -> Void = { AgentIslandController.shared.resume($0) }
    /// Told when the window shows or hides, so the island keeps the store current
    /// (it holds activity-only lists back while nothing shows them).
    var onVisible: (Bool) -> Void = { AgentIslandController.shared.windowWatching = $0 }
    var ageInterval: TimeInterval = 30
    /// Counts sidebar rebuilds (tests: nothing rebuilds after close).
    private(set) var refreshes = 0

    private var askSubscription: AnyCancellable?

    init() {
        // #798: the transcript's pending AskUserQuestion is what a question form is checked against.
        askSubscription = transcript.$pendingAsk.sink { [weak self] ask in
            MainActor.assumeIsolated { self?.interaction.ask = ask }
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
            select(nil)
            return
        }
        // @Published sends on willSet with the new value, so the values are used as given.
        subscription = store.$sessions.combineLatest(store.$history, store.$sort, store.$sidekickPattern)
            .combineLatest(store.$details)
            .sink { [weak self] v, details in
                MainActor.assumeIsolated {
                    self?.refresh(sessions: v.0, history: v.1, sort: v.2, pattern: v.3, details: details)
                }
            }
    }

    /// Rebuilds the sidebar from the store's current values (the age clock's tick).
    func refresh() {
        guard let s = store else { return }
        refresh(sessions: s.sessions, history: s.history, sort: s.sort, pattern: s.sidekickPattern, details: s.details)
    }

    private func refresh(sessions: [AgentSession], history: [DchHistoryRecord], sort: AgentIslandSort,
                         pattern: String, details: AgentIslandRowDetails) {
        // Hidden or closed: nothing is rebuilt; showing again reads the store afresh.
        guard visible, !closed else { return }
        refreshes += 1
        let new = AgentSidebar.sections(sessions: sessions, history: history, sort: sort, sidekickPattern: pattern,
                                        details: details, now: now())
        if new != sections { sections = new }
        // The selected row gone (the session ended): nothing selected, nothing tailing.
        if let sel = selection, row(sel) == nil { select(nil) } else { follow() }
        if !filled, let first = rows.first {
            filled = true
            if selection == nil { select(first.id) }
        }
    }

    var rows: [AgentSidebar.Row] { sections.flatMap(\.rows) }
    func row(_ id: AgentSidebar.RowID) -> AgentSidebar.Row? { rows.first { $0.id == id } }
    var selectedRow: AgentSidebar.Row? { selection.flatMap(row) }

    func select(_ id: AgentSidebar.RowID?) {
        if selection != id { selection = id }
        follow()
    }

    /// Up/down: the next or previous row across groups, clamped; from none, the first.
    func move(_ delta: Int) {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        guard let sel = selection, let i = ids.firstIndex(of: sel) else { return select(ids[0]) }
        select(ids[min(max(i + delta, 0), ids.count - 1)])
    }

    /// Return and the "Open in terminal" buttons: a live session only. False: nothing
    /// to open (a History row, none), so Return passes on (QA #626 INFO-2).
    @discardableResult
    func openSelected() -> Bool {
        guard let s = selectedRow?.session else { return false }
        openSession(s)
        return true
    }

    func resumeSelected() {
        guard let r = selectedRow?.record else { return }
        resume(r)
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
    }

    /// The transcript model follows the selection: a visible live session runs, any
    /// other state is stopped (one model, so at most one transcript is ever tailed).
    private func follow() {
        guard visible, !closed, let s = selectedRow?.session else {
            if transcript.running { transcript.stop() }
            interaction.follow(nil)
            return
        }
        transcript.update(AgentSidebar.source(s))
        transcript.start()
        interaction.ask = transcript.pendingAsk   // this session's, never the last one's
        interaction.follow(s)
    }
}

import AppKit
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

    /// #1135/#1291: dch 1.63's `claude_foreground` by row name, read outside `parse` because dch writes it for a
    /// row whose `transcript_path` is null. Only a real JSON boolean counts (a 1/0 number bridges to Bool through
    /// NSNumber); anything else, or the key left out, has no entry.
    static func foregrounds(_ data: Data) -> [String: Bool] {
        guard !data.isEmpty, let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [:] }
        var out: [String: Bool] = [:]
        for o in rows {
            guard let name = o["name"] as? String, !name.isEmpty, let n = o["claude_foreground"] as? NSNumber,
                  CFGetTypeID(n) == CFBooleanGetTypeID() else { continue }
            out[name] = n.boolValue
        }
        return out
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
        /// "Needs input", "Working", "Stopping…"; "Ended · exit 1" on a History row. #1115: the counts are fields.
        let detail: String
        /// "4m", "now" under a minute; "" for an unknown time and on a working row (#1114).
        let age: String
        /// Open PR labels the island shows ("repo#12"), and "+N" past two.
        let prs: [String]
        /// Every open PR shown (the chips' fallback when they do not fit).
        var prCount = 0
        /// #1289 (G5): the shown chips' values (label, help, allowlisted url); "+N" has none.
        var prLinks: [AgentIsland.PRChip] = []
        /// #1115: live subagents and merged PRs, drawn as symbol plus number; 0 (none, or the detail is off) draws nothing.
        var agents = 0
        var merged = 0
        var session: AgentSession?
        var record: DchHistoryRecord?
        /// #1203: a live Claude session's row (it has a transcript) keeps the model slot, with or without a value;
        /// Codex, shell and History rows have none.
        var modelSlot = false
        /// #1203: the short name of the last answer's model ("Opus 4.7") and its effort word; effort only with a model.
        var model: String?
        var effort: String?

        /// #1203: "Opus 4.7 · high", "Opus 4.7", or "" when the model is unknown.
        var modelText: String { model.map { m in effort.map { "\(m) · \($0)" } ?? m } ?? "" }
        /// #1203: "model Opus 4.7, effort high", "model Opus 4.7", or nil when unknown.
        var modelWords: String? { model.map { m in "model \(m)" + (effort.map { ", effort \($0)" } ?? "") } }

        /// #1115: the groups beside the state text, agents then merged; a count of 0 is left out.
        var counts: [(Count, Int)] { [(Count.agents, agents), (Count.merged, merged)].filter { $0.1 > 0 } }
        /// The counts in words for VoiceOver, the open PRs too (whether their chips or their count shows).
        var countWords: [String] { (counts + (prCount > 0 ? [(Count.open, prCount)] : [])).map { $0.0.words($0.1) } }
    }

    /// #1115: a count drawn as an SF Symbol plus a number (they follow the theme colour and the UI scale; an
    /// emoji does not); VoiceOver and the help read the words.
    enum Count: CaseIterable {
        case agents, merged, open

        var symbol: String {
            switch self {
            case .agents: "person.2"
            case .merged: "arrow.triangle.merge"
            case .open: "arrow.triangle.pull"
            }
        }

        /// "2 agents", "192 merged pull requests", "1 open pull request"; "99999+" above 99999, as drawn.
        func words(_ n: Int) -> String {
            let noun = switch self {
            case .agents: "agent"
            case .merged: "merged pull request"
            case .open: "open pull request"
            }
            return "\(AgentIsland.count(n)) \(noun)\(n == 1 ? "" : "s")"
        }
    }

    struct Section: Identifiable, Equatable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    static let needsYouTitle = "Needs you"
    /// #828: the sections a header click folds away. Needs you never folds: it is the list of
    /// sessions waiting on the human.
    static let collapsible: Set<String> = ["Sessions", "Sidekicks", "History", "Layouts"]   // #901 B3 step 4b: Layouts

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
        let (chips, more) = AgentIsland.prChips(s.meta, show: details, budget: .infinity)
        let prs = chips.prefix(2).map(\.label) + (chips.count + more > 2 ? ["+\(chips.count + more - 2)"] : [])
        // dch's agents is an unclamped Int (DchCommand.parseListJSON); merged is clamped by DchSessionMeta.count.
        // #1203: only a Claude session has a transcript (dch sets the path with a Claude only); the effort only with a model.
        // #1267: or a label carried over an answer with no mapping (display only).
        let claude = s.transcriptPath != nil || s.modelCarried > 0, model = claude ? s.model.map(AgentModelEffort.shortName) : nil
        return Row(id: .live(s.key), title: s.title, state: s.state, detail: AgentWindowControls.lock(action) ?? s.state.label,
                   age: AgentIsland.age(of: s, now: now), prs: prs, prCount: chips.count + more, prLinks: Array(chips.prefix(2)),
                   agents: details.agents ? max(0, s.agents) : 0, merged: details.merged ? max(0, s.meta?.merged ?? 0) : 0,
                   session: s, modelSlot: claude, model: model, effort: model == nil ? nil : s.effort)
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

/// #831 B1 step 2 (4.1a, rider R899-3): the lastLive map's home. The window's owner (`AgentsWindow`) keeps one for the
/// process and hands it to every model it builds, so a pane's last live sight outlives a window close; a model built
/// without one (tests) gets its own. B1 step 3 (R1193-3): pruned to the store's panes on load and on a layout delete.
@MainActor
final class AgentLastLiveHome {
    var map: AgentPaneLayout.LastLiveMap = [:]
}

/// #831 B1 step 2 (4.4, 11.2): one pane's runtime in the active layout: its own transcript model and its kept display
/// row. `ended` and `content` publish themselves (written only on a change), so a view of an UNFOCUSED pane is told of
/// an entry into or an exit from Ended, which changes no `selection` (step 1 review (a)).
@MainActor
final class AgentPaneRuntime: ObservableObject {
    let pane: UUID
    let transcript = AgentTranscriptModel()
    /// 4.4 M1: the session ended while this pane's transcript ran: its last live row, the blocks kept (suspended).
    @Published fileprivate(set) var ended: (target: PaneTarget, row: AgentSidebar.Row)?
    /// The pane's content as of the last resolve.
    @Published fileprivate(set) var content: PaneContent?
    /// The pane's live row as of the last resolve: what `ended` keeps when the session goes.
    fileprivate var liveRow: AgentSidebar.Row?

    init(pane: UUID) { self.pane = pane }
}

/// The window's state: the sidebar, the selection and one transcript model per pane of the active layout.
/// Energy (design "Energy"): nothing runs unless the window is open and visible.
/// While hidden the transcript is stopped and the age clock is off; `close` drops
/// the store subscription too.
@MainActor
final class AgentWindowModel: ObservableObject {
    @Published private(set) var sections: [AgentSidebar.Section] = []
    /// #831 B1 (spec 3.5): the focused pane's RESOLVED content as a row (`.live` -> .live(k), `.history` -> .history(id),
    /// anything else nil), written only by `settle()`. Stored so `$selection` publishes one change per change.
    @Published private(set) var selection: AgentSidebar.RowID?
    /// #831: the window's active layout. B1 step 3 (8.1): restored from the store on open (init, `layouts`), else a
    /// fresh one; every change is saved (`autosave`). Every selection change goes into its focused pane through the
    /// browse rule (`show`, 7.1). 15.0: a multi-pane layout keeps its whole tree here with the split gate off;
    /// `shownPanes` reduces it to the focused pane, and nothing saves that reduction.
    private(set) var layout = PaneLayout.single() {
        // #900 B2 step 5b (R900-5a-1): any writer but the drag's own move (perform, select, bind, the store refresh, a
        // pick, a nudge) ends a drag first: its live ratio is saved once, then this change by the didSet's rule.
        willSet { if dividerDrag != nil, !dragMoving { dragEnded() } }
        didSet {
            // 4.1a: a retarget or a closed pane loses its sight; a layout switch (another id) keeps every layout's.
            if oldValue.id == layout.id { lastLive = AgentPaneLayout.retargeted(lastLive, from: oldValue, to: layout) }
            syncRuntimes(switched: oldValue.id != layout.id)
            // #900 B2 step 4b (7.2): a new value settle() did not already tell (a zoom, a split, a close or focus move that
            // keeps the row) is published once, so the sidebar's "in view" glyphs redraw. Gate on only: nothing changes off.
            if !settle(), layout != oldValue, AgentPaneLayout.splitsEnabled { objectWillChange.send() }
            syncTier()   // R900-4b-1: a split or close moves the line too, so the stored tier never goes stale
            // #900 B2 step 6b2b (7.2): the focused pane moved, so its input box is built anew in the new pane (AgentPaneArea
            // draws the old one's as inert): forget the old box, so a focus asked for waits for the new one (pending).
            if AgentPaneLayout.splitsEnabled, layout.focused != oldValue.focused { interaction.composer = nil }
            if dividerDrag == nil { autosave() }   // #900 B2 step 5a (8.1): a divider drag saves once, at its end
            // R901-s4b-q2: another active layout ends an open inline rename (nothing written).
            if layoutRenaming != nil, layout.id != oldValue.id { layoutRenaming = nil }
        }
    }
    /// 8.1 / 8.2: where the layouts load from and save to: the owner passes the app's defaults, tests a private
    /// XCTestDefaults suite. nil: the model neither loads nor saves (every model built without one).
    private let layoutDefaults: UserDefaults?
    /// 8.1: the window's layouts as loaded and as last saved; nil without `layoutDefaults`.
    private(set) var layouts: PaneLayoutStore?
    /// Counts blob writes (tests: a change writes once, a publish that changes nothing writes nothing).
    private(set) var layoutWrites = 0
    /// #901 B3 step 2 (decision c): the pane bind(nil) emptied in memory and the target it had; nil while the island is on.
    private var offEmptied: (layout: UUID, pane: UUID, target: PaneTarget?)?
    /// R899-2: the browse rule's refusal of the last pick (select() kept the layout as it was); the next pick that
    /// lands drops it. The pane notice line (3.3) draws its `notice`.
    @Published private(set) var paneRefusal: PaneRefusal?
    /// #831 A2 (4.1a): the panes' last live sights, stamped by `stampLastLive` in the store's publish sink only.
    /// B1 step 2 (R899-3): kept by the window's owner (`lastLiveHome`), so it outlives this model.
    private(set) var lastLive: AgentPaneLayout.LastLiveMap {
        get { lastLiveHome.map }
        set { lastLiveHome.map = newValue }
    }
    let lastLiveHome: AgentLastLiveHome
    /// False while the island is off (no store): the window says so.
    @Published private(set) var hasStore = false
    /// #831 B1 step 2 (11.2): one runtime per pane of the active layout, keyed by pane id; freed by a close.
    private(set) var runtimes: [UUID: AgentPaneRuntime] = [:]
    var focusedRuntime: AgentPaneRuntime? { runtimes[layout.focused] }
    /// After `close()` (no runtime left): a model that never starts, for a late reader.
    private lazy var detachedTranscript = AgentTranscriptModel()
    /// The focused pane's conversation model (every existing reader, the view included, means that pane's). The same
    /// object across a row change in that pane (rewrite 11, restated per pane runtime); another pane's is another.
    var transcript: AgentTranscriptModel { focusedRuntime?.transcript ?? detachedTranscript }
    /// The shown panes (11.1) from frames in `paneArea`: with the split gate off, the focused pane alone (15.0).
    /// #900 B2 step 2 (7.4): zoomed, the zoomed pane (always the focused one) alone; the frames stay the tiling.
    var shownPanes: Set<UUID> {
        let tiled = Set(paneFrames(in: paneArea).keys)
        guard AgentPaneLayout.splitsEnabled, let z = layout.zoomed, tiled.contains(z) else { return tiled }
        return [z]
    }
    /// #900 B2 step 4b (7.2): the rows of the sessions shown in the active layout other than the focused pane's (the
    /// sidebar's "in view" glyph). From `shownPanes`, so a zoom or the too-small fallback (the focused pane alone) gives
    /// none. O(panes): one tiling walk and one resolved row per pane. Empty with the split gate off; the sidebar reads
    /// it once per section. shortcut: `paneArea` is not published, so a resize across the too-small line alone shows
    /// at the next model publish (as the band's chip, AgentWindowBand); publish it if that ever shows.
    var inViewRows: Set<AgentSidebar.RowID> {
        guard AgentPaneLayout.splitsEnabled else { return [] }
        let shown = shownPanes
        var rows = Set(layout.panes.compactMap { p in
            shown.contains(p.id) && p.id != layout.focused ? Self.resolvedRow(runtimes[p.id]?.content) : nil
        })
        if let selection { rows.remove(selection) }   // the focused pane's session keeps the selection bar alone
        return rows
    }
    /// 3.3 (#900 B2 step 2): the minimum pane, 300x200·s: the one value paneFrames tiles with and perform's split
    /// checks, so a split that passes its room check is always drawn tiled.
    var paneMinimum: CGSize { CGSize(width: sz(PaneLayout.minimumPane.width), height: sz(PaneLayout.minimumPane.height)) }
    /// #831 B1 step 4: the panes to draw in `area` and where (the view passes its own size, so a frame is never a
    /// layout pass behind): the layout's frames; too small (3.4): the focused pane alone at the whole area.
    func paneFrames(in area: CGRect) -> [UUID: CGRect] {
        switch layout.frames(in: area, minimum: paneMinimum, splitsEnabled: AgentPaneLayout.splitsEnabled) {
        case let .tiled(f): f
        case let .tooSmall(id): [id: area]
        }
    }
    /// The pane area's size: written by the view (AgentPaneArea, R1193-4) and by tests. `.zero`: the focused pane alone.
    /// Not @Published (the view draws from its own size); the same size again follows nothing.
    var paneArea: CGRect = .zero {
        didSet { if paneArea != oldValue { paneAreaChanges += 1; follow(); syncTier() } }
    }
    /// #900 B2 step 6b2e (R900-4b-1, 3.4): the too-small tier of `paneArea` for the active layout, published so a resize
    /// that only crosses the line redraws the sidebar's glyphs and the band's chip. Gate on only; written only on a
    /// change, from paneArea's didSet (the view's onAppear/onChange actions, after the body pass) and the layout's.
    @Published private(set) var paneTooSmall = false
    private func syncTier() {
        guard AgentPaneLayout.splitsEnabled else { return }   // gate off: nothing read, nothing written
        let t = if case .tooSmall = layout.frames(in: paneArea, minimum: paneMinimum, splitsEnabled: true) { true } else { false }
        if t != paneTooSmall { paneTooSmall = t }
    }
    /// Counts `paneArea` changes (tests: the same size twice is one change).
    private(set) var paneAreaChanges = 0
    /// 4.2 "Pick Another": the window gives the sidebar the keys (AgentsWindow wires it; tests count it).
    var focusSidebar: () -> Void = {}

    /// #831 7.2 (R6.1): which side takes plain arrows and Return; replaces the window's own Bool (`sidebarFocused` now
    /// reads and writes this). Set by a click (`mouseDown`), Tab, Pick Another and the pane focus actions; a publish, an
    /// autosave or an attention change never sets it (R6.9). Not @Published: nothing draws it.
    var keyFocus: PaneKeys.KeyFocus = .sidebar

    /// #900 B2 step 4 (7.2, R900-2): the sidebar hidden by ⌃⌘S; read from `Preferences.agentWindowSidebarHidden` (a
    /// Bool, nothing else) when the model is made and written on every toggle. Drawn only through `sidebarShown`.
    @Published private(set) var sidebarHidden = Preferences.agentWindowSidebarHidden
    /// The sidebar is drawn: always with the split gate off (15.0: the parent's window), else unless hidden. The root
    /// view, `sidebarFrame` and `paneAreaFrame` all read this one value.
    var sidebarShown: Bool { !(AgentPaneLayout.splitsEnabled && sidebarHidden) }

    /// ⌃⌘S (through `perform`) and the band's show-sidebar glyph: hides or shows the sidebar and saves the choice.
    /// Hidden, the panes take the keys (a hidden sidebar never holds them); shown again, the keys stay where they are.
    func toggleSidebar() {
        sidebarHidden.toggle()
        Preferences.agentWindowSidebarHidden = sidebarHidden
        if sidebarHidden { keyFocus = .pane }
    }

    /// 4.2 "Pick Another": focuses the pane and gives the sidebar the keys; starts nothing.
    func pickAnother(_ pane: UUID) {
        keyFocus = .sidebar   // before adopt: the sidebar keeps the keys (adopt's rule asks the pane's input only for .pane)
        if pane != layout.focused, case let .success(l) = layout.focus(pane) { adopt(l) }
        if !sidebarShown { toggleSidebar() }   // #900 B2 step 4: the pick is made in the sidebar, so it shows again
        focusSidebar()
    }

    /// 4.2 "Close Pane": the last pane is refused (7.3), so a one-pane window draws no Close Pane. 7.2: a close moves the
    /// keys to the panes.
    func closePane(_ pane: UUID) {
        if case let .success(l) = layout.close(pane) { keyFocus = .pane; adopt(l) }
    }

    /// #900 B2 step 1 (12.1, 7.3, 7.4): a tree key's action on the active layout; the window calls it only for
    /// `PaneKeys.treeAction` (the split gate on). True: it acted, so the window swallows the chord: the layout changed,
    /// or a refused split put its refusal in the pane notice line (R899-2's `paneRefusal`). False (an edge with no
    /// neighbour, an action this step does not route, the window closed): the chord goes on as before #831.
    /// Zoom: frames ignore it (the view still draws the tiling until step 3); shownPanes and follow() honour it (step
    /// 2), so a focus key while zoomed moves the zoom: one pane suspends, one starts (7.4).
    @discardableResult
    func perform(_ a: PaneAction, pane: UUID? = nil) -> Bool {
        guard !closed else { return false }
        // #900 B2 step 6b1 (R900-6a-1): `pane` (a header "⋯" item's) is focused in the result, so a choice writes once.
        let base = pane.flatMap { try? layout.focus($0).get() } ?? layout
        let next: Result<PaneLayout, PaneRefusal>
        switch a {
        case let .split(axis):
            next = splitting(axis, pane: pane)
        case .closePane:
            next = base.close(base.focused)
        case let .focus(d):
            // The tree's tiling in a fixed square: adjacency depends on the ratios only, never on the size or the minimum.
            let square = CGRect(x: 0, y: 0, width: 1000, height: 1000)
            guard case let .tiled(f) = base.frames(in: square, minimum: .zero, splitsEnabled: true),
                  let id = base.neighbour(of: base.focused, direction: d, frames: f) else { return false }
            next = base.focus(id)
        case let .cycle(step):
            next = base.focus(step < 0 ? base.previous : base.next)
        case .zoom:
            next = .success(base.toggleZoom())
        case .toggleSidebar:   // #900 B2 step 4: always acts, so ⌃⌘S is always swallowed (gate on)
            toggleSidebar()
            return true
        default:
            return false
        }
        switch next {
        case let .success(l):
            guard l != layout else { return false }
            if paneRefusal != nil { paneRefusal = nil }
            keyFocus = .pane   // 7.2: every pane focus action, split and close
            adopt(l)
            return true
        case let .failure(r):
            if base != layout { keyFocus = .pane; adopt(base) }   // the menu's pane is focused even when its action is refused
            guard case .split = a else { return false }
            paneRefusal = r
            return true
        }
    }

    /// #900 B2 step 6a: what Split answers for the focused pane, or for `pane` once focused (the header "⋯" of an
    /// unfocused pane focuses it first): perform's own call, so the menu and the key share one cap and one room rule.
    func splitting(_ axis: PaneNode.Axis, pane: UUID? = nil) -> Result<PaneLayout, PaneRefusal> {
        countDryRun()
        let l = pane.flatMap { try? layout.focus($0).get() } ?? layout
        // The same minimum paneFrames tiles with, so a split that passes here is drawn tiled.
        return l.split(axis: axis, minimum: paneMinimum, in: CGRect(origin: .zero, size: paneArea.size))
    }

    #if DEBUG
    /// Tests (R900-6b1-3): calls of `showing` and `splitting` (the menus' dry runs), read around one body pass.
    private(set) var dryRuns = 0
    #endif
    private func countDryRun() {
        #if DEBUG
        dryRuns += 1
        #endif
    }

    /// 7.6: the first click on an unfocused pane focuses it; the panes take the keys (7.2).
    func focusPane(_ pane: UUID) {
        keyFocus = .pane
        if pane != layout.focused, case let .success(l) = layout.focus(pane) { adopt(l) }
    }

    /// 7.2: the sidebar's frame in the root view's content of `size` (top-left origin; AgentWindowRootView.split: the
    /// sidebar sz(290) wide, a 1 pt line, the pane area). nil while no sidebar is drawn (the island off: one message;
    /// #900 B2 step 4: hidden by ⌃⌘S, so a click where it was is the pane area's).
    func sidebarFrame(in size: CGSize) -> CGRect? {
        hasStore && sidebarShown ? CGRect(x: 0, y: 0, width: sz(290), height: size.height) : nil
    }

    /// The pane area's frame in the same content: right of the sidebar and its line, under the band while it is shown
    /// (AgentWindowBand.shown; 9.1: a click on the band is in no pane), else the whole height; nil with no store.
    func paneAreaFrame(in size: CGSize) -> CGRect? {
        let band = AgentWindowBand.shown ? AgentWindowBand.height : 0
        let lead = sidebarShown ? sz(290) + 1 : 0   // #900 B2 step 4: hidden, the pane area starts at x = 0
        return hasStore ? CGRect(x: lead, y: band, width: max(0, size.width - lead),
                                 height: max(0, size.height - band)) : nil
    }

    /// 7.2 / 7.6: a left mouse-down at `p` in the content of `size` (top-left origin). Outside data: a point or size that
    /// is not finite changes nothing. In the sidebar: the sidebar takes the keys. In a pane frame: the panes do, and an
    /// unfocused pane is focused (`AgentsNSWindow.firstClick`). Elsewhere (the 1 pt line, the band): nothing changes.
    /// True: the click only focused a pane, so the window swallows it with its drags and its up.
    /// #900 B2 step 4b (7.4, N900-f): zoomed, the view draws the zoomed pane over the whole pane area and no other
    /// (AgentPaneArea.drawn), so a down anywhere in the area is that pane's: the panes take the keys and the click
    /// passes (never a hidden pane's tile). Checked after the finiteness guard, so it never reads a non-finite frame.
    func mouseDown(at p: CGPoint, in size: CGSize) -> Bool {
        guard p.x.isFinite, p.y.isFinite, size.width.isFinite, size.height.isFinite else { return false }
        if sidebarFrame(in: size)?.contains(p) == true { keyFocus = .sidebar; return false }
        guard let a = paneAreaFrame(in: size), a.contains(p) else { return false }
        let local = CGPoint(x: p.x - a.minX, y: p.y - a.minY), area = CGRect(origin: .zero, size: a.size)
        let frames = paneFrames(in: area), drawn = AgentPaneArea.drawn(self, in: area)
        if drawn.count < frames.count, let z = drawn.keys.first {
            focusPane(z)   // the focused pane: the layout stays as it is
            return false
        }
        guard frames.values.contains(where: { $0.contains(local) }) else { return false }
        keyFocus = .pane
        guard let id = AgentsNSWindow.firstClick(at: local, frames: frames, focused: layout.focused) else { return false }
        focusPane(id)
        return true
    }

    // MARK: 7.5 Dividers (#900 B2 step 5a; split gate on only)

    /// A divider in a pane area: the split at `path` (0 = first, 1 = second, from the root), its axis, its 1 pt line (the
    /// second side's leading edge, where AgentPaneArea.edge draws it) and the split's own rect.
    struct Divider: Equatable {
        let path: [Int]
        let axis: PaneNode.Axis
        let line: CGRect
        let split: CGRect
        /// R900-5b-q1: the split's identity: the pane ids of its first and of its second side, in tree order.
        let sides: [[UUID]]
        /// The line widened to 6·s across its axis, centred on it, clipped to the split's rect. Frames abut, so it overlaps
        /// both neighbours' edges: inside it the divider wins over the panes (checked before the first-click rule).
        @MainActor var hitArea: CGRect {
            let d = (1 - sz(6)) / 2
            return line.insetBy(dx: axis == .columns ? d : 0, dy: axis == .rows ? d : 0).intersection(split)
        }
    }

    /// 7.5: the dividers in a pane area of `size`, parents before children. None with the gate off, one pane, zoomed,
    /// too small (3.4: the focused pane alone) or a size that is not finite (refused before any use).
    func dividers(in size: CGSize) -> [Divider] {
        guard AgentPaneLayout.splitsEnabled, size.width.isFinite, size.height.isFinite, layout.zoomed == nil else { return [] }
        let area = CGRect(origin: .zero, size: size)
        guard case let .tiled(f) = layout.frames(in: area, minimum: paneMinimum, splitsEnabled: true), f.count > 1 else { return [] }
        var out: [Divider] = []
        func walk(_ n: PaneNode, _ r: CGRect, _ path: [Int]) {
            guard case let .split(axis, ratio, a, b) = n else { return }
            let (x, y) = PaneNode.divide(r, axis, ratio)
            out.append(Divider(path: path, axis: axis, line: axis == .columns
                ? CGRect(x: y.minX, y: r.minY, width: 1, height: r.height) : CGRect(x: r.minX, y: y.minY, width: r.width, height: 1),
                               split: r, sides: [a.panes.map(\.id), b.panes.map(\.id)]))
            walk(a, x, path + [0])
            walk(b, y, path + [1])
        }
        walk(layout.tree, area, [])
        return out
    }

    /// 7.5: the divider whose hit area holds `p` (pane-area coordinates, outside data: not finite is nil first); a parent
    /// before its children, so where a nested line meets its parent's the parent's is hit.
    func divider(at p: CGPoint, in size: CGSize) -> Divider? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        return dividers(in: size).first { $0.hitArea.contains(p) }
    }

    /// The divider drag under way: the divider, where it began along its axis, the split's ratio then, the area's size.
    private(set) var dividerDrag: (divider: Divider, start: CGFloat, ratio: Double, size: CGSize)?
    /// True only while dragMoved adopts its own move (the one writer of `layout` that keeps the drag).
    private var dragMoving = false
    /// R900-5a-1: the left button's down began a divider drag: the window's route swallows that button's drags and its
    /// up even after the drag was ended by something else (a key, a close, resign key). Reset by the up and the next down.
    var dividerHeld = false

    /// 7.5: a left mouse-down at `p` in a pane area of `size`: on a divider it begins that divider's drag (true). A
    /// double-click (`clicks` 2 or more) first equalizes that split alone (deep false), saved once by the didSet.
    /// Anywhere else false, nothing changes. A drag whose up never came is ended first.
    func dragBegan(at p: CGPoint, in size: CGSize, clicks: Int = 1) -> Bool {
        if dividerDrag != nil { dragEnded() }
        guard !closed, let d = divider(at: p, in: size) else { return false }
        if clicks >= 2, case let .success(l) = layout.equalize(path: d.path, deep: false), l != layout { adopt(l) }
        guard case let .split(_, ratio, _, _)? = layout.tree.locate(d.path[...], in: .zero)?.node else { return false }
        dividerDrag = (d, d.axis == .columns ? p.x : p.y, ratio, size)
        terminal.liveResizeStarted()   // 7.5: the terminal re-grids at the drag's end only (one setSize)
        return true
    }

    /// 7.5: the drag at `p`: ratio = the ratio at the start + the move along the axis / the split's length (compared
    /// first: at least 1 pt, so never a division by zero; p and the start are finite, so the ratio is), through setRatio
    /// (clamped at the minimum, 3.3), adopted live and NOT saved. An equal ratio (held at the clamp) adopts nothing.
    func dragMoved(to p: CGPoint) {
        guard let g = dividerDrag, p.x.isFinite, p.y.isFinite else { return }
        let length = g.divider.axis == .columns ? g.divider.split.width : g.divider.split.height
        guard length >= 1 else { return }
        let r = g.ratio + Double(((g.divider.axis == .columns ? p.x : p.y) - g.start) / length)
        guard case let .success(l) = layout.setRatio(path: g.divider.path, r, minimum: paneMinimum,
                                                     in: CGRect(origin: .zero, size: g.size)), l != layout else { return }
        dragMoving = true
        defer { dragMoving = false }
        adopt(l)
    }

    /// 7.5 / 8.1: the drag ends (its mouse-up): saved once, and only when the layout differs from the saved one (a drag
    /// back to its start writes nothing); the terminal pushes its grid once.
    func dragEnded() {
        guard dividerDrag != nil else { return }
        dividerDrag = nil
        terminal.liveResizeEnded()
        autosave()
    }

    /// 13: a divider's value: its split's ratio in whole percent, rounded. nil: no split at `path`, or a ratio (outside
    /// data: a saved blob) that is not finite or not in [0, 1], refused before the Int conversion.
    func dividerPercent(_ path: [Int]) -> Int? {
        guard case let .split(_, r, _, _)? = layout.tree.locate(path[...], in: .zero)?.node, r.isFinite, r >= 0, r <= 1
        else { return nil }
        return Int((r * 100).rounded())
    }

    /// 13: the divider's adjustable action: its first side grows (`up`) or shrinks by 5 percent through setRatio (clamped
    /// at the minimum and [0.1, 0.9] as a drag is), adopted only when the layout differs, so saved once by the didSet
    /// (a drag under way is ended first by the willSet). Nothing for a path with no divider: the gate off, zoomed, too
    /// small, one pane or a size that is not finite (dividers(in:) is empty); nothing at the clamp (no save, no publish).
    /// R900-5b-q1: `sides`, the drawn divider's identity (Divider.sides): nothing when the split now at `path` is another
    /// one (a tree change not yet drawn); nil compares none.
    func nudge(_ path: [Int], up: Bool, in size: CGSize, sides: [[UUID]]? = nil) {
        guard dividers(in: size).contains(where: { $0.path == path && (sides == nil || $0.sides == sides) }),
              case let .split(_, r, _, _)? = layout.tree.locate(path[...], in: .zero)?.node,
              case let .success(l) = layout.setRatio(path: path, r + (up ? 0.05 : -0.05), minimum: paneMinimum,
                                                     in: CGRect(origin: .zero, size: size)), l != layout else { return }
        adopt(l)
    }

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
    /// A pane runtime made after init (a new pane, a layout switch); tests give its transcript their seams. Called on the
    /// main actor, from the layout's didSet.
    var onNewRuntime: (AgentPaneRuntime) -> Void = { _ in }
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
    /// #897 (G9): "Agent Island Settings...": Settings on Agent Island's pane, through the extension host's one opener.
    var openIslandSettings: () -> Void = {
        LiveExtensionHostServices.shared.openSettings(extensionID: AgentWindowControls.islandExtensionID,
                                                      sectionID: AgentWindowControls.islandSectionID, anchor: nil)
    }

    /// #897 (G9): a sidebar "..." item: the island's own call on `island()`.
    func runSidebar(_ v: AgentSidebarVerb) {
        // R897-q1: Always allow ON asks first (the strip); nothing is written before its Turn on. OFF stays immediate.
        if v == .autoAllow, !Preferences.agentIslandAutoAllow { askingAlwaysAllow = true; return }
        AgentWindowControls.runSidebar(v, island: island(), openSettings: openIslandSettings)
    }

    /// R897-q1: the Always allow question is up in the sidebar (the store's question type cannot carry it: window state).
    @Published private(set) var askingAlwaysAllow = false

    /// R897-q1: the strip's answer. Turn on writes the setting as Settings does; Cancel (and Esc) writes nothing.
    func answerAlwaysAllow(_ yes: Bool) {
        guard askingAlwaysAllow else { return }
        askingAlwaysAllow = false
        if yes { AgentIslandPane.autoAllowToggled(true, island()) }
    }

    /// #897 (G9): the sidebar strip's answer to the store's question up now, through the island's confirm call.
    func answerStoreQuestion(_ yes: Bool) {
        guard let store, let q = AgentWindowControls.storeQuestion(store) else { return }
        AgentWindowControls.answer(q.kind, yes, island: island())
    }
    /// Told when the window shows or hides, so the island keeps the store current
    /// (it holds activity-only lists back while nothing shows them).
    var onVisible: (Bool) -> Void = { AgentIslandController.shared.windowWatching = $0 }
    /// The age clock: while visible the rows are rebuilt at least this often, so a row's age is never more than
    /// this behind (#1114: whole minutes, so at most one minute low, for at most this long past the minute).
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
    /// #853 (QA #693 INFO-1): the edit itself, its typed text included, so a field the header builds
    /// anew (a ViewThatFits variant swap) carries on with it.
    @Published private(set) var renameEdit: AgentRenameEdit?
    var renaming: AgentSessionKey? { renameEdit?.key }
    /// R901-s3-b (tests): the session rename field's state set without ask()'s select: no session verb, no attach.
    func openRenameField(_ edit: AgentRenameEdit) { renameEdit = edit }
    /// #901 B3 step 4b (8.1): the Layouts row whose name is an inline field now; nil: none. Set only with the gate on.
    @Published private(set) var layoutRenaming: UUID?
    /// #829 (R5): the question the confirm strip shows; dropped by a selection change.
    @Published private(set) var confirming: AgentWindowConfirm?
    /// QA #665 INFO-6: an answer a gate refused since the question; dropped by a selection change or the next ask.
    @Published private(set) var refusal: AgentWindowRefusal?
    /// #831 B1 (4.4 M1, replaces #829 G2's hold): the focused pane's session ended while its transcript ran: the pane
    /// keeps that session's last live row and its blocks (the transcript suspended), display only, until resolve
    /// first gives its own record (one swap), a new session takes the name, or the pane is retargeted or closed.
    /// B1 step 2: the focused pane's runtime's (each pane keeps its own).
    var ended: (target: PaneTarget, row: AgentSidebar.Row)? { focusedRuntime?.ended }
    /// The focused pane's content as of the last resolve.
    var content: PaneContent? { focusedRuntime?.content }
    /// The values of the publish being handled: the store's @Published still hold the old ones inside the sink.
    private var publishing: (sessions: [AgentSession], history: [DchHistoryRecord])?
    /// dch writes a record each minute: a Stop or Kill's record has ended by then, with slack.
    static let recordSlack: TimeInterval = AgentPaneLayout.recordSlack
    /// #829 G8: a record the window removed (its id): once its row is gone, the next History row
    /// is selected (else the previous, else none), never through nothing. A manual pick drops it.
    private(set) var removing: AgentSessionKey?
    /// Counts sidebar rebuilds (tests: nothing rebuilds after close).
    private(set) var refreshes = 0

    private var askSubscription: AnyCancellable?
    private var planSubscription: AnyCancellable?
    /// 5.2: what the ask and plan sinks are bound to: the focused pane, its model, its resolved row.
    private struct Bound: Equatable {
        let pane: UUID
        let row: AgentSidebar.RowID?
        let ended: Bool
    }
    private var bound: Bound?
    /// R1193-6: the bound model itself, compared with ===: a switch frees the old models before it makes the new
    /// ones, so a new model can take a freed one's address (an ObjectIdentifier would compare equal).
    private weak var boundModel: AgentTranscriptModel?

    init(lastLive home: AgentLastLiveHome = AgentLastLiveHome(), layouts d: UserDefaults? = nil) {
        lastLiveHome = home
        layoutDefaults = d
        // 8.1: the window loads the store when it opens, never at app launch. Nothing is written here: a repaired or
        // multi-pane blob (15.0) stays as stored until a change. R1193-3: sights of panes in no stored layout go; an
        // inactive layout's panes keep theirs (only temporarily absent).
        if let d {
            let s = Preferences.agentWindowLayouts(in: d)
            layouts = s
            lastLiveHome.map = AgentPaneLayout.pruned(home.map, keeping: s)
            if let l = s.activeLayout { layout = l }
        }
        for p in layout.panes { runtimes[p.id] = AgentPaneRuntime(pane: p.id) }
        if !sidebarShown { keyFocus = .pane }   // #900 B2 step 4: made hidden (the saved choice), the panes take the keys
        terminal.isLive = { [weak self] key in self?.store?.sessions.contains { $0.key == key } ?? false }
        // OQ-66: an OSC 52 write needs the session to be the focused pane's, live now (4.3: resolved at the write).
        terminal.isSelected = { [weak self] key in self?.focusedLive?.key == key }
        // #831 B1 (4.3): every interaction action re-resolves the focused pane (main actor: called from its actions).
        interaction.resolveFocused = { [weak self] in self?.focusedLive }
        rebind()
    }

    /// 5.2 (R6.2): the ask and plan sinks follow the focused pane's transcript model: re-subscribed on a change of
    /// focus, of that pane's model, or of its resolved content, so another pane's question never reaches the input.
    /// Subscribing delivers the model's current values at once (step 2 of 5.2). Both sinks run on the main actor:
    /// `pendingAsk` / `pendingPlan` are set by the @MainActor transcript model, and Published sends on the setter's thread.
    private func rebind() {
        let f = closed ? nil : focusedRuntime
        let now = f.map { Bound(pane: $0.pane, row: Self.resolvedRow($0.content), ended: $0.ended != nil) }
        guard now != bound || f?.transcript !== boundModel else { return }
        bound = now
        boundModel = f?.transcript
        // #798: the transcript's pending AskUserQuestion is what a question form is checked against.
        askSubscription = f?.transcript.$pendingAsk.sink { [weak self] ask in
            MainActor.assumeIsolated { self?.interaction.ask = ask }
        }
        // #802: and the pending ExitPlanMode is what a plan approval is checked against.
        planSubscription = f?.transcript.$pendingPlan.sink { [weak self] plan in
            MainActor.assumeIsolated { self?.interaction.plan = self?.withConfigDir(plan) }
        }
    }

    /// #1092: a plan kept in a file gets the focused live session's "config_dir" from dch's own live record (the
    /// controller's readLiveRecords seam, none under XCTest), never from the transcript or the screen. No record, no
    /// controller or "": the default <home>/.claude/plans. Read only while a plan file is pending (a few lstats).
    private func withConfigDir(_ p: AgentPlanInput?) -> AgentPlanInput? {
        guard var p, p.plan == nil, let s = focusedLive, let c = interaction.controller else { return p }
        p.configDir = c.readLiveRecords([s]).first { $0.key == s.key }?.agent?.configDir ?? ""
        return p
    }

    /// 11.2: a runtime per pane of the active layout. A layout switch frees every runtime of the old layout (stopped
    /// before any new one starts; pane ids are unique per layout only, so none is reused across layouts); within a
    /// layout a closed pane's runtime is stopped and freed, a new pane gets a fresh one.
    private func syncRuntimes(switched: Bool) {
        guard !closed else { return }
        let ids = Set(layout.order)
        for (id, r) in runtimes where switched || !ids.contains(id) {
            r.transcript.stop()
            runtimes[id] = nil
        }
        for id in layout.order where runtimes[id] == nil {
            let r = AgentPaneRuntime(pane: id)
            runtimes[id] = r
            onNewRuntime(r)
        }
    }

    /// The window's active layout replaced: a layout switch, or a focus or tree change (saved, 8.1). Only tests call it
    /// before B2/B3 route verbs, with multi-pane layouts built under the split gate (15.0).
    func adopt(_ l: PaneLayout) {
        guard !closed else { return }
        let moved = l.focused != layout.focused
        // #900 B2 step 6b2d (3.1 :224): a focus change or another set of panes drops the pane refusal. Gate on only, and a
        // write only when one is set: a gate-off person never sees a publish from here.
        if AgentPaneLayout.splitsEnabled, paneRefusal != nil, moved || l.order != layout.order { paneRefusal = nil }
        layout = l
        follow()
        // #900 B2 step 6b2b (7.2, R1196-1): the keys follow the focused pane: every pane focus action (a click, the pane
        // keys and menu, close pane) sets keyFocus .pane first. After follow(): the terminal's attach drops older asks.
        if moved, AgentPaneLayout.splitsEnabled, keyFocus == .pane { focusSelection() }
    }

    /// 8.1 Delete (B3 routes it): refused on the last layout, or with no store. R899-3: the deleted layout's sights go
    /// (the other layouts keep theirs); a deleted active layout hands over to the MRU's next, which is adopted.
    @discardableResult
    func deleteLayout(_ id: UUID) -> PaneRefusal? {
        dragEnded()   // R900-5a-1: before the store is read and replaced, so the drag's save cannot bring a deleted layout back
        guard !closed, let s = layouts else { return .noSuchLayout }
        switch s.deleting(id) {
        case let .failure(r):
            return r
        case let .success(out):
            autosave(out)
            if let r = layoutRenaming, !out.layouts.contains(where: { $0.id == r }) { layoutRenaming = nil }   // R901-s4b-q2
            lastLive = AgentPaneLayout.pruned(lastLive, keeping: out)
            if let next = out.activeLayout, next.id != layout.id { adopt(next) }
            return nil
        }
    }

    /// #901 B3 step 1, 8.1 New (B3 step 4 draws it): one empty pane, name nil (automatic), appended and made active.
    /// Refused as a value, nothing made or written: with the split gate off (.layoutsOff), at 9 layouts (.layoutCap,
    /// N1217-b: never made and dropped later), with no store loaded or the window closed (.noSuchLayout).
    @discardableResult
    func newLayout() -> PaneRefusal? { addLayout { _ in .single() } }

    /// 8.1 Duplicate: a copy of `id` with fresh layout and pane ids (`duplicated`), named by `duplicateName`, appended and
    /// made active. Refused as `newLayout`, and .noSuchLayout for an id the store does not hold.
    @discardableResult
    func duplicateLayout(_ id: UUID) -> PaneRefusal? {
        addLayout { s in s.layouts.first { $0.id == id }.map { $0.duplicated(name: s.duplicateName(of: $0.name)) } }
    }

    /// New and Duplicate: the whole store is written once (explicitly, so a layout made while the island is off is saved
    /// and the re-adopt in bind(store) keeps it), then the new layout is adopted (a switch: the old runtimes stop before
    /// the new pane's starts, 11.2); adopt's own autosave finds the store equal and writes nothing. Main actor; `make`
    /// runs synchronously here.
    private func addLayout(_ make: (PaneLayoutStore) -> PaneLayout?) -> PaneRefusal? {
        guard AgentPaneLayout.splitsEnabled else { return .layoutsOff }
        dragEnded()   // R900-5a-1: the drag's save lands before the store is read and replaced
        guard !closed, let s = layouts, let l = make(s) else { return .noSuchLayout }
        switch s.adding(l).flatMap({ $0.activate(l.id) }) {
        case let .failure(r):
            return r
        case let .success(out):
            autosave(out)
            adopt(l)
            return nil
        }
    }

    /// 8.1 Rename: the name cleaned and bounded (`PaneLayoutStore.cleanName`); empty returns to automatic. One write when
    /// the cleaned name differs, none when it does not. The active layout keeps its panes in memory (only the name
    /// changes there), so a rename while the island is off never brings back what bind(nil) emptied.
    @discardableResult
    func renameLayout(_ id: UUID, to raw: String?) -> PaneRefusal? {
        guard AgentPaneLayout.splitsEnabled else { return .layoutsOff }
        dragEnded()
        guard !closed, var s = layouts, let i = s.layouts.firstIndex(where: { $0.id == id }) else { return .noSuchLayout }
        let name = PaneLayoutStore.cleanName(raw)
        s.layouts[i].name = name
        autosave(s)
        if id == layout.id {
            var l = layout
            l.name = name
            adopt(l)
        }
        return nil
    }

    /// #901 B3 step 4b (8.1): a Layouts row's Rename opens its inline field. Gate off, or an id the store does not hold:
    /// nothing opens. Main actor (a menu entry's run).
    func beginLayoutRename(_ id: UUID) {
        guard AgentPaneLayout.splitsEnabled, layouts?.layouts.contains(where: { $0.id == id }) == true else { return }
        layoutRenaming = id
    }

    /// The inline field's end, once: `text` nil (Escape, the focus left) writes nothing; Return renames through
    /// renameLayout (the D1 cleaning there, one write, none when unchanged). Another row's late end changes nothing.
    func endLayoutRename(_ id: UUID, _ text: String?) {
        guard layoutRenaming == id else { return }
        layoutRenaming = nil
        if let text { renameLayout(id, to: text) }
    }

    /// #901 B3 step 2 (8.1, 11.2): a switch to layout `id` (step 3 routes the keys, step 4 the rows). Refused as a value
    /// before anything is read or written with the split gate off (.layoutsOff); .noSuchLayout with no store loaded, the
    /// window closed or an id the store does not hold. The active layout: nothing changes, nothing is written. Else the
    /// store from `activate` (the MRU updated) is written once, explicitly, so a switch while the island is off is saved
    /// and bind(store)'s re-adopt keeps it; then the saved layout is adopted with its focus and zoom: syncRuntimes stops
    /// every old runtime before a new one is made, follow() starts the focused pane first; adopt's autosave finds the
    /// store equal. Only the window's pane runtimes: no session is started, resumed, revived or attached (8.1 :619-621).
    /// #901 B3 step 6 (⌘J, 7.4): `pane` of that layout focused in the same write and adopt; zoomed, the zoom moves to it.
    @discardableResult
    func switchLayout(_ id: UUID, focus pane: UUID? = nil) -> PaneRefusal? {
        guard AgentPaneLayout.splitsEnabled else { return .layoutsOff }
        guard !closed, layouts != nil else { return .noSuchLayout }
        guard id != layout.id else { return nil }
        dragEnded()   // R900-5a-1: the drag's save lands before the store is read
        guard let s = layouts, case let .success(out) = s.activate(id), let saved = out.activeLayout else { return .noSuchLayout }
        let l = pane.flatMap { try? saved.focus($0).get() } ?? saved
        autosave(l == saved ? out : out.storing(l) ?? out)
        adopt(l)
        return nil
    }

    /// #901 B3 step 6 (section 10 :754-757, 7.1, 7.4): ⌘J. The Needs you rows (the sidebar's order: blocked before done,
    /// newest first) after the focused pane's session, wrapping, the focused one left out; the first blocked one, else
    /// the first done one. Shown in a pane of the active layout: that pane is focused. Else shown in a stored layout (the
    /// first in the stored order, the ⌃N numbers): switchLayout's own path, that pane focused. Else into the focused pane
    /// (7.1 rule 2: a row's click). Zoomed, the zoom moves with the focus (PaneLayout.focus). False, nothing read: the
    /// gate off or the window closed; false, nothing changed: no other session needs you. Never a session verb: only the
    /// window's pane runtimes stop and start. Main actor (the window's key route).
    /// R901-s6-q1: a refused stored-layout switch moves no keys and falls through to the focused pane (rule 2).
    /// `switching` (tests): the switch, nil = switchLayout(_:focus:); no refusal is reachable through the model's own store.
    @discardableResult
    func nextNeedsYou(switching: ((UUID, UUID) -> PaneRefusal?)? = nil) -> Bool {
        guard AgentPaneLayout.splitsEnabled, !closed else { return false }
        let rows = sections.first { $0.title == AgentSidebar.needsYouTitle }?.rows ?? []
        let mine = layout.panes.first { $0.id == layout.focused }?.target
        let after = rows.firstIndex { target($0.id) == mine }.map { Array(rows[($0 + 1)...] + rows[..<$0]) } ?? rows
        guard let next = after.first(where: { $0.state == .blocked }) ?? after.first, case .live = next.id else { return false }
        let t = target(next.id)
        func shown(_ l: PaneLayout) -> UUID? { l.panes.first { $0.target == t }?.id }   // a session, never a History pane
        if let p = shown(layout) {
            focusPane(p)
        } else if let other = layouts?.layouts.first(where: { $0.id != layout.id && shown($0) != nil }), let p = shown(other),
                  (switching ?? { self.switchLayout($0, focus: $1) })(other.id, p) == nil {
            // The keys move only once switched; adopt's own focusSelection ran only if they were the pane's already.
            if keyFocus != .pane { keyFocus = .pane; focusSelection() }
        } else {
            keyFocus = .pane
            select(next.id)
            focusSelection()
        }
        return true
    }

    /// 8.1: the layout numbered `n`, 1 to 9 in the list's order. `n` is outside data (a key): compared, never trapped on;
    /// a number with no layout is a no-op (.noSuchLayout): nothing made, switched or written.
    @discardableResult
    func switchLayout(number n: Int) -> PaneRefusal? {
        guard AgentPaneLayout.splitsEnabled else { return .layoutsOff }
        guard !closed, let s = layouts, n >= 1, n <= s.layouts.count else { return .noSuchLayout }
        return switchLayout(s.layouts[n - 1].id)
    }

    /// #901 B3 step 4a (8.1): one row of the sidebar's Layouts section. `name` is as drawn: the set name, else the
    /// automatic name of its panes' titles, through OutsideText.shown (outside data: never an id or a format string).
    struct LayoutRow: Identifiable, Equatable {
        let id: UUID
        /// 1...9, the stored order (the ⌃N key).
        let number: Int
        let name: String
        let active: Bool
        /// #901 B3 step 5 (section 10): blocked sessions in this layout's panes, an inactive layout only; 0 draws nothing.
        var blocked = 0
    }

    /// #901 B3 step 5 (section 10): what a session in a pane asks of the person: blocked outranks done (the sidebar's order).
    enum PaneNeed: Equatable { case blocked, done }

    /// Section 10's map: the active layout's panes whose session needs you, and per INACTIVE layout the count of its
    /// distinct blocked sessions (no entry for 0). Pure value.
    struct Attention: Equatable {
        var panes: [UUID: PaneNeed] = [:]
        var layouts: [UUID: Int] = [:]
    }

    /// Needs-you sessions by key, as of the last visible refresh (refresh(sessions:)); nil with the gate off or before
    /// the first visible refresh. Written only when it changes, so an equal refresh publishes nothing.
    @Published private(set) var needs: [AgentSessionKey: PaneNeed]?

    static func needing(_ sessions: [AgentSession]) -> [AgentSessionKey: PaneNeed] {
        var out: [AgentSessionKey: PaneNeed] = [:]
        for s in sessions where AgentSidebar.needsYou(s) { out[s.key] = s.state == .blocked ? .blocked : .done }
        return out
    }

    /// The map from `needs`, the active layout as it is now and the stored layouts: a pure read; nil with the gate off.
    var attention: Attention? {
        guard AgentPaneLayout.splitsEnabled, let n = needs else { return nil }
        return Self.attention(n, active: layout, stored: layouts?.layouts ?? [])
    }

    static func attention(_ needs: [AgentSessionKey: PaneNeed], active: PaneLayout, stored: [PaneLayout]) -> Attention {
        func key(_ t: PaneTarget?) -> AgentSessionKey? {
            if case let .session(d, n)? = t { AgentSessionKey(dir: d, name: n) } else { nil }   // history, remote: none
        }
        var a = Attention()
        for p in active.panes { if let k = key(p.target), let v = needs[k] { a.panes[p.id] = v } }
        for l in stored where l.id != active.id {
            let blocked = Set(l.panes.compactMap { key($0.target) }.filter { needs[$0] == .blocked })
            if !blocked.isEmpty { a.layouts[l.id] = blocked.count }
        }
        return a
    }

    /// Section 10's marks of pane `id`: nil for the focused pane (it never shows them) and for one that needs nothing.
    func paneNeed(_ id: UUID) -> PaneNeed? {
        guard id != layout.focused else { return nil }
        return attention?.panes[id]
    }

    /// #901 B3 step 4a (8.1 :625-627): the Layouts section's rows in the stored order; nil: the section is not built.
    /// Gate off: nil before anything is read (nothing drawn, routed or read aloud). Shown when the active layout has two or
    /// more panes or there are two or more layouts. A pure read of the state a user action changes (`layout`, `layouts`,
    /// `sections` for the titles): a refresh that changes none of them gives the same rows.
    var layoutRows: [LayoutRow]? {
        guard AgentPaneLayout.splitsEnabled, let s = layouts, layout.panes.count >= 2 || s.layouts.count >= 2 else { return nil }
        let counts = attention?.layouts ?? [:]   // step 5: inactive layouts only (the map skips the active one)
        return s.layouts.prefix(PaneLayoutStore.maxLayouts).enumerated().map { i, stored in
            let l = stored.id == layout.id ? layout : stored   // the active one as it is now (island off too)
            let name = l.name ?? PaneLayoutStore.automaticName(l.panes.map { layoutTitle($0.target) })
            return LayoutRow(id: l.id, number: i + 1, name: OutsideText.shown(name), active: l.id == layout.id,
                             blocked: counts[l.id] ?? 0)
        }
    }

    /// A pane's title for an automatic layout name: the sidebar row's title; a gone target the pane's own word for it
    /// (AgentPaneArea.title: its name); no target "Empty".
    private func layoutTitle(_ t: PaneTarget?) -> String {
        switch t {
        case let .session(d, n)?: row(.live(AgentSessionKey(dir: d, name: n)))?.title ?? n
        case let .history(d, id, _)?: row(.history(AgentSessionKey(dir: d, name: id)))?.title ?? id
        case let .remote(_, n)?: n
        case nil: "Empty"
        }
    }

    /// 8.1 ⌃Tab: the MRU pair, the layout active before this one. One layout: a no-op (.noSuchLayout), nothing written.
    @discardableResult
    func previousLayout() -> PaneRefusal? {
        guard AgentPaneLayout.splitsEnabled else { return .layoutsOff }
        guard !closed, let p = layouts?.previous else { return .noSuchLayout }
        return switchLayout(p)
    }

    /// #901 B3 step 2 (decision c): with the island off, the active layout as the person left it: the pane bind(nil)
    /// emptied (memory only, not their change) is saved with its target. nil, so skipped as before: the gate off, or
    /// nothing recorded, or a target the tree refuses back.
    private func islandOffLayout() -> PaneLayout? {
        guard AgentPaneLayout.splitsEnabled, let e = offEmptied else { return nil }
        guard e.layout == layout.id, layout.panes.contains(where: { $0.id == e.pane && $0.target == nil }) else { return layout }
        return try? layout.replace(e.pane, target: e.target).get()
    }

    /// 8.1: a change of the active layout (or `next`, a whole store) is written once; a call that changes nothing
    /// writes nothing. Runs on the main actor (the layout's didSet, deleteLayout). Causes of the early returns: no
    /// store loaded (`layoutDefaults` nil), the window closed; for a layout change also the island off (`store` nil:
    /// bind(nil) empties the pane, which is not the user's change; the blob keeps their target), the 9-layout cap
    /// (`storing` nil); and no change.
    /// shortcut: one write per committed change, not coalesced per run-loop turn (8.1); B2's divider (save at drag end)
    /// and B3's chained verbs are where coalescing pays.
    private func autosave(_ next: PaneLayoutStore? = nil) {
        guard let d = layoutDefaults, !closed, let s = layouts else { return }
        guard let n = next ?? (store == nil ? islandOffLayout().flatMap(s.storing) : s.storing(layout)), n != s else { return }
        layouts = n
        layoutWrites += 1
        Preferences.setAgentWindowLayouts(n, in: d)
    }

    /// Follows `store` (nil: the island is off). Called on open and whenever the
    /// island rebuilds its store. The sidebar fills once the window is visible.
    func bind(_ store: AgentIslandStore?) {
        guard !closed else { return }
        dragEnded()   // R900-5a-1: saved while the old store is still bound (bind(nil) makes autosave a no-op)
        self.store = store
        hasStore = store != nil
        subscription = nil
        guard let store else {
            // QA #713 INFO-4: the island's runner drops every answer once its store is gone.
            if let k = newSession?.starting {
                // R2 F5: answered and waiting for its row: it started, so the form goes; else no answer will come.
                if pendingSpawn?.key == k { newSession = nil } else {
                    newSession?.starting = nil; newSession?.status = "No answer for \(k.name): Agent Island is off"
                }
            }
            claimed = [:]
            sections = []
            // #901 B3 step 2 (decision c): the pane about to be emptied and its target, once per island-off spell.
            if offEmptied == nil, AgentPaneLayout.splitsEnabled {
                offEmptied = (layout.id, layout.focused, layout.panes.first { $0.id == layout.focused }?.target)
            }
            select(nil, manual: false)
            return
        }
        // R1194-2: the island back: the saved layout again (bind(nil) emptied its pane in memory only), before the first
        // refresh, so no first-row pick lands over the saved target and the autosave finds the store equal (no write).
        if let saved = layouts?.activeLayout, saved != layout { adopt(saved) }
        offEmptied = nil
        // @Published sends on willSet with the new value, so the values are used as given.
        subscription = store.$sessions.combineLatest(store.$history, store.$sort, store.$sidekickPattern)
            .combineLatest(store.$details, store.$actions)
            .sink { [weak self] v, details, actions in
                MainActor.assumeIsolated {
                    self?.refresh(sessions: v.0, history: v.1, sort: v.2, pattern: v.3, details: details, actions: actions)
                    self?.stampLastLive(v.0)   // after the refresh: a pane it just filled is stamped by this publish
                }
            }
    }

    /// #831 A2 (4.1a, entry 898 item a): a store publish stamps the shown panes whose session it lists live, at the
    /// publish's own time: the store has no poll time, and this sink runs as it publishes. The age tick never stamps
    /// (its values are the last publish's, so its clock would date a sight it never made); nor does a hidden window.
    private func stampLastLive(_ sessions: [AgentSession]) {
        guard visible, !closed else { return }
        // B1 step 2 (R899-3): every shown pane, from frames (the split gate off: the focused pane alone, 15.0).
        // #900 N900-d: with the gate on, every pane of the active layout (zoomed away and too-small hidden ones keep a
        // runtime, so a stale sight would bind them to an earlier instance's record).
        let stamped = AgentPaneLayout.splitsEnabled ? Set(layout.order) : shownPanes
        lastLive = AgentPaneLayout.stamp(lastLive, layout: layout.id, panes: layout.panes, visible: stamped,
                                         sessions: sessions, at: now())
    }

    /// 3.5, phase A: the RAW mapping of a pane target to its sidebar row, never through resolve. A remote pane has none.
    nonisolated static func rowID(_ t: PaneTarget?) -> AgentSidebar.RowID? {
        switch t {
        case let .session(dir, name)?: .live(AgentSessionKey(dir: dir, name: name))
        case let .history(dir, id, _)?: .history(AgentSessionKey(dir: dir, name: id))
        case .remote?, nil: nil
        }
    }

    /// The pane target of a sidebar row; a History row's carries the record's lastSeen as `seen` (3.1).
    private func target(_ id: AgentSidebar.RowID) -> PaneTarget {
        switch id {
        case let .live(k): .session(dir: k.dir, name: k.name)
        case let .history(k): .history(dir: k.dir, id: k.name, seen: row(id)?.record?.lastSeen)
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
        // #901 B3 step 5 (section 10): the attention source, on this visible refresh only; gate off: stays nil.
        let n = AgentPaneLayout.splitsEnabled ? Self.needing(sessions) : nil
        if n != needs { needs = n }
        let new = AgentSidebar.sections(sessions: sessions, history: history, sort: sort, sidekickPattern: pattern,
                                        details: details, now: now(), actions: actions)
        let old = sections
        publishing = (sessions, history)
        defer { publishing = nil }
        if new != sections { sections = new }
        // #831 B1 (4.3): the focused pane re-resolved on every publish. A session that ended stays Ended (4.4) and
        // swaps once to its own record (4.5: G2 subsumed). G8: a removed record's pane hands on to its neighbour
        // before the selection is written (never through nothing). `selection` is still the last resolve's here, so a
        // `.session` pane showing its own record (4.5) hands on too.
        if case .history(let id)? = selection, id == removing, row(.history(id)) == nil {
            removing = nil
            select(Self.neighbour(of: id, old: old, new: new), manual: false)
        } else {
            settle()
            follow()
        }
        if confirming != nil, confirmingSession == nil, confirmingRecord == nil { confirming = nil }
        if let k = renaming, !sessions.contains(where: { $0.key == k }) { renameEdit = nil }   // it ended: no field
        // #853 F1 (QA #699): a busy Return's refusal goes with the running text it was refused under,
        // so the row's outcome ("Restarted", a failure, the Stop's result) shows. Other refusals keep theirs.
        if let r = refusal, r.text == AgentIsland.renameBusyText, case .live(let k) = r.id,
           AgentWindowControls.lock(actions[k]) == nil { refusal = nil }
        // #948 F2, F3: before landSpawn, so no check here runs on this publish's values after a write it made.
        expireDirLine(sessions: sessions, actions: actions)
        endUnlisted(history)
        landSpawn()   // #847
        // #828: the first shown row; every section folded leaves the hint, not a hidden pick.
        if !filled, !rows.isEmpty {
            filled = true
            // B1 step 2: only into an empty focused pane; a pane with a target (an adopted layout's, its session gone)
            // keeps it and shows its placeholder (R3.4), never another conversation.
            if focusedTarget == nil, let first = navigableIDs.first { select(first, manual: false) }
        }
    }

    var rows: [AgentSidebar.Row] { sections.flatMap(\.rows) }
    func row(_ id: AgentSidebar.RowID) -> AgentSidebar.Row? { rows.first { $0.id == id } }
    /// The focused pane's row: its Ended session's last live row (4.4), else the selection's row.
    var selectedRow: AgentSidebar.Row? { ended?.row ?? selection.flatMap { row($0) } }
    /// #831 B1 (4.4): the focused pane is Ended (kept blocks, display only: nothing opens, sends or asks on it).
    var focusedEnded: Bool { ended != nil }

    var focusedTarget: PaneTarget? { layout.panes.first { $0.id == layout.focused }?.target }

    /// 4.1 on the focused pane, against the publish being handled, else the store as it is now. No store: nil.
    private func focusedContent() -> PaneContent? { resolvedContent(of: layout.focused, focusedTarget) }

    /// 4.1 on one pane of the active layout (its own slot of the lastLive map). No store or no target: nil.
    private func resolvedContent(of pane: UUID, _ target: PaneTarget?) -> PaneContent? {
        guard let t = target,
              let v = publishing ?? store.map({ (sessions: $0.sessions, history: $0.history) }) else { return nil }
        return AgentPaneLayout.resolve(t, sessions: v.sessions, history: v.history,
                                       lastLive: lastLive[AgentPaneLayout.PaneSlot(layout: layout.id, pane: pane)])
    }

    /// 4.3: the focused pane resolved now; its session only when `.live` (an ended, removed or empty pane: nil).
    var focusedLive: AgentSession? {
        guard !closed, case .live(let s)? = focusedContent() else { return nil }
        return s
    }

    /// 3.5 (B1): a content's sidebar row.
    nonisolated static func resolvedRow(_ c: PaneContent?) -> AgentSidebar.RowID? {
        switch c {
        case let .live(s)?: .live(s.key)
        case let .history(r)?: .history(r.id)
        case .notRunning?, .removed?, nil: nil
        }
    }

    /// #831 B1: re-resolves the focused pane and writes `content`, `ended` and `selection`. Ended (M1) is entered only
    /// on a `.live` -> `.notRunning` edge of the same target while the transcript runs (visible): a session that
    /// ended while hidden had its blocks freed, so it shows nothing kept. Any other content or target drops the kept
    /// blocks (`drop()`), so a name reuse never runs `start()` on them (4.4 (b)). No store: the raw mapping (3.5 A).
    /// B1 step 2: every pane of the active layout is settled (its own content and Ended state); `selection` stays the
    /// focused pane's.
    /// True when it published (a change of row, or of focusedEnded).
    @discardableResult
    private func settle() -> Bool {
        let wasEnded = focusedEnded
        for p in layout.panes { if let r = runtimes[p.id] { settle(r, target: p.target) } }
        let s = store == nil ? Self.rowID(focusedTarget) : Self.resolvedRow(content)
        // Any change of row drops the confirm strip's question, a refusal and the rename field (R5), as a
        // `select()` did before B1 for the publish-driven changes too (an end, the swap to History).
        if s != selection {
            selection = s
            confirming = nil
            refusal = nil
            renameEdit = nil
        } else if focusedEnded != wasEnded {
            objectWillChange.send()   // the view reads focusedEnded: told even when the row stays (an emptied pane)
        } else {
            return false
        }
        return true
    }

    /// One pane's runtime. Ended entry: a `.live` -> `.notRunning` edge of the same target while this pane's
    /// transcript runs (shown, visible window); exit: any other content or target (`drop()`).
    private func settle(_ r: AgentPaneRuntime, target t: PaneTarget?) {
        let was = r.content
        let c = store == nil ? nil : resolvedContent(of: r.pane, t)
        if case .live(let s)? = c { r.liveRow = row(.live(s.key)) }
        // #900 N900-e (4.4): a suspended pane (zoomed away, too-small hidden: gate on only) keeps its blocks: Ended too.
        if case .notRunning? = c, case .live? = was, r.ended == nil, visible,
           r.transcript.running || r.transcript.suspended,
           let t, let kept = r.liveRow, kept.id == Self.rowID(t) {
            r.ended = (t, kept)
        } else if let e = r.ended {
            var stays = false
            if case .notRunning? = c { stays = e.target == t }
            if !stays {
                r.ended = nil
                r.transcript.drop()   // the one swap, a name reuse, a retarget: the kept model goes (4.4 (b), (e))
            }
        }
        if r.content != c { r.content = c }   // published only on a change (one view update per change)
    }

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
    /// #847: a manual pick also closes the New session form and drops a pending spawn's selection.
    func select(_ id: AgentSidebar.RowID?, manual: Bool = true, placement: PaneLayout.Placement = .focused) {
        if manual { removing = nil; pendingSpawn = nil; newSession = nil }
        // #831 A2 (3.5): into the focused pane through the browse rule, never straight into the tree. One pane: the
        // pick replaces its target (or swaps it for the name's own record, #580); B1: `selection` is its resolve, and
        // `settle()` drops the strip's question on a change of row.
        let next = id.map { showing($0, placement: placement) } ?? layout.replace(layout.focused, target: nil)
        switch next {
        case let .success(l):
            if paneRefusal != nil { paneRefusal = nil }
            layout = l
        case let .failure(r):
            paneRefusal = r   // R899-2: kept for the pane notice line, never dropped silently
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
        // #887 (QA #747 INFO-4): the New session form covers the pane, so its session takes no input meanwhile.
        guard renaming == nil, newSession == nil, !focusedEnded, selectedRow?.session != nil else { return false }
        if paneMode == .terminal { terminal.focus() } else { interaction.focusComposer() }
        return true
    }

    /// #900 B2 step 6b1: the browse rule's answer for row `id` (select's own call; the row menu reads it). `.side` splits
    /// in the pane area at the minimum paneFrames tiles with; `.focused` never reads the area.
    func showing(_ id: AgentSidebar.RowID, placement: PaneLayout.Placement = .focused) -> Result<PaneLayout, PaneRefusal> {
        countDryRun()
        return layout.show(target(id), placement: placement, minimum: paneMinimum, in: CGRect(origin: .zero, size: paneArea.size),
                    splitsEnabled: AgentPaneLayout.splitsEnabled)
    }

    /// #845: a sidebar row's click: the human's pick, and the keyboard moves into it. #900 B2 step 6b1 (7.1, 15.0):
    /// `flags`, the click's event modifiers (outside data), are read only with the split gate on, and Option alone (no
    /// Command, Control or Shift) opens to the side; the gate off or any other set is today's click.
    func click(_ id: AgentSidebar.RowID, flags: @autoclosure () -> NSEvent.ModifierFlags = []) {
        if AgentPaneLayout.splitsEnabled, flags().intersection([.command, .option, .control, .shift]) == .option {
            return openToTheSide(id)
        }
        select(id)
        focusSelection()
    }

    /// R900-6b1-a: the flags a row Button's action may read: a plain SwiftUI Button runs its action on the left mouse up
    /// of the click it tracked (the down is the same click's), so only those two give their flags; a key (Full Keyboard
    /// Access), a flagsChanged, any other event or none (an accessibility press has no event of its own) gives [].
    static func clickFlags(_ e: NSEvent?) -> NSEvent.ModifierFlags {
        guard let e, e.type == .leftMouseUp || e.type == .leftMouseDown else { return [] }
        return e.modifierFlags
    }

    /// #900 B2 step 6b1 (7.1 rule 3, 3.3, 15.0): Option-click and the row menu's "Open to the Side". Gate off, a History
    /// row or an id no longer in the list: the plain click. Gate on: the layout's own show(.side) (rule 1 focuses a pane
    /// already showing it). A refusal (the cap, no room) is the key's refused split: the notice alone; layout,
    /// selection, the New session form and the keys stay.
    func openToTheSide(_ id: AgentSidebar.RowID) {
        guard AgentPaneLayout.splitsEnabled, case .live = id, row(id) != nil else { return click(id) }
        if case let .failure(r) = showing(id, placement: .side) { paneRefusal = r; return }
        select(id, placement: .side)
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
        // #900 B2 step 4 (7.1, OQ-1): with the gate on and several panes the step goes through PaneLayout.walk: a row
        // shown in another pane is skipped and the end is a no-op (no wrap). One pane or the gate off: today's walk.
        if AgentPaneLayout.splitsEnabled, layout.panes.count > 1 {
            if let t = layout.walk(ids.map { target($0) }, down: delta > 0), let id = Self.rowID(t) { select(id) }
            return
        }
        guard let sel = selection, let i = ids.firstIndex(of: sel) else { return select(ids[0]) }
        select(ids[min(max(i + delta, 0), ids.count - 1)])
    }

    /// #1110: the rows ⌘1…⌘9 select, from `sections` (the list the sidebar draws): the live rows it shows, top to bottom
    /// across its sections, the first nine. A folded section's rows are not shown, so not numbered; History never is.
    var numberedIDs: [AgentSidebar.RowID] {
        Array(sections.filter { !isCollapsed($0.title) }.flatMap(\.rows).filter { $0.session != nil }.map(\.id).prefix(9))
    }

    /// The sidebar row's chip: its 1-based number, nil for an unnumbered row.
    func number(_ id: AgentSidebar.RowID) -> Int? { numberedIDs.firstIndex(of: id).map { $0 + 1 } }

    /// ⌘<n>: the n-th numbered row, the human's pick, and the keyboard into its pane (as a click). False: no row there,
    /// nothing changes.
    @discardableResult
    func selectNumbered(_ n: Int) -> Bool {
        let ids = numberedIDs
        guard n >= 1, n <= ids.count else { return false }
        click(ids[n - 1])
        return true
    }

    /// The "Open in terminal" buttons: a live session only. False: nothing to open (a History
    /// row, none). QA #668 F1: nor an ended
    /// session's held row (`dch -n <name>` would start a new session of that name).
    @discardableResult
    func openSelected() -> Bool {
        guard let s = focusedLive else { return false }   // 4.3: resolved now; only `.live` opens (never `dch -n`)
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
        guard !focusedEnded, let s = selectedRow?.session else { return .transcript }
        return mode(s)
    }

    func setMode(_ m: AgentPaneMode, for s: AgentSession) {
        guard ended?.row.id != .live(s.key) else { return }   // ended: nothing to remember
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
        guard !focusedEnded, let s = selectedRow?.session else { return false }
        setMode(mode(s) == .terminal ? .transcript : .terminal, for: s)
        return true
    }

    // MARK: #847 New session

    /// The form in the detail pane; nil: not shown.
    @Published private(set) var newSession: AgentNewSessionForm?
    /// Bumped by every open: the form's Name field takes the keys (⌘N on an open form too).
    @Published private(set) var newSessionFocus = 0
    /// A session the window started: on the refresh its row shows, it is selected in Terminal with the keys.
    /// Dropped by a manual pick, the form reopening and after `spawnSlack`.
    /// #948 F3: `asked`, the request's time (a record that landed since is this start's).
    private(set) var pendingSpawn: (key: AgentSessionKey, at: TimeInterval, asked: TimeInterval)? {
        didSet {
            // #887 (QA #747 INFO-1): the slack has its own deadline, not the next refresh (the 30 s age clock).
            spawnDeadline?.invalidate()
            spawnDeadline = pendingSpawn == nil || closed ? nil
                : Timer.scheduledTimer(withTimeInterval: Self.spawnSlack + 0.5, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
        }
    }
    static let spawnSlack: TimeInterval = 15
    /// Fires once just past `spawnSlack` after the answer; a hidden window lands or expires the spawn when shown again.
    private(set) var spawnDeadline: Timer?
    /// QA #747 INFO-1: dch --spawn answers 0 for a session whose program already exited, the same as for one that runs.
    /// #948 F3: with the end of a record of that name that landed after the start ("exit 127"), in brackets.
    nonisolated static func notListedText(_ name: String, end: String = "") -> String {
        "\(name) ended at once or never started: check the command" + (end.isEmpty ? "" : " (\(end))")
    }
    /// #948 F3: a start that never listed, waiting for the one History read after its deadline.
    private(set) var unlisted: (key: AgentSessionKey, asked: TimeInterval)?
    /// QA #713 INFO-4: numbers every spawn; the form keeps its own (`request`), a quick shell has none.
    private var requests = 0
    /// QA #713 INFO-4 (d): the names this window spawned until the poll lists them: in flight (.infinity), then for
    /// `spawnSlack` after the answer. A second quick shell before the next poll takes the next free name.
    private var claimed: [String: TimeInterval] = [:]
    /// The island's one --spawn (its gate, runner key, env and failure line).
    lazy var spawnSession: (_ folder: String, _ command: [String], _ name: String?,
                            _ done: @escaping @MainActor @Sendable (AgentSessionKey?, String?) -> Void) -> AgentSessionKey? = {
        [weak self] in self?.island().spawn(in: $0, command: $1, name: $2, done: $3)
    }
    var folderExists: (String) -> Bool = { AgentIsland.isFolder($0) }
    var home = NSHomeDirectory()
    var shell = ProcessInfo.processInfo.environment["SHELL"]

    /// ⌘N, +, the empty state's pill: the form, prefilled (last folder > the selected session's cwd > ~,
    /// its free name, the island's command setting, else its inference). Open already: its Name field.
    func openNewSession(folder: String? = nil) {
        newSessionFocus += 1
        guard newSession == nil else { return }
        guard store?.resumeGate.isOK == true else {   // R2 F2: the one gate check for ⌘N, + and the pill
            store?.resumeGate.refusal.map { sayOnDirLine("Controls \($0)", until: .gate) }   // #887: Command-N says why too
            return
        }
        pendingSpawn = nil
        clearDirLine()   // #948 F2: the form says its own status
        let typed = Preferences.agentIslandNewSessionCommand
        newSessionTookKeys = sessionHasKeys
        newSession = AgentNewSessionForm(folder: AgentNewSession.abbreviate(folder ?? newSessionDefaultFolder, home: home),
                                         command: typed.isEmpty ? "claude" : typed)
        follow()   // P1b: the form covers the pane, so the terminal detaches (its view leaves the window)
        guard typed.isEmpty else { return }
        island().newSessionCommand { [weak self] argv in
            guard let self, var f = self.newSession, f.starting == nil, f.command == "claude" else { return }
            f.command = AgentIsland.shellLine(argv)
            self.newSession = f
        }
    }

    /// Cancel, Esc: the pane again, its terminal re-attached (a fresh client: dch redraws the screen), and the keys
    /// back in the session when the form took them from it.
    /// R2 F5: after a Start's answer (the form waits for the row), Cancel drops the pending selection too.
    func cancelNewSession() {
        if newSession?.starting != nil, pendingSpawn?.key == newSession?.starting { pendingSpawn = nil }
        newSession = nil
        follow()
        if newSessionTookKeys { focusSelection() }
    }

    /// P1b: the form opened while the keys were in the selected session (its terminal or input box) or asked for it.
    private var newSessionTookKeys = false
    private var sessionHasKeys: Bool {
        if terminal.focusPending || interaction.composerFocusPending { return true }
        let views: [NSView?] = [terminal.view, interaction.composer]
        return views.contains { v in v.map { $0.window?.firstResponder === $0 } ?? false }
    }

    var newSessionDefaultFolder: String {
        if let last = Preferences.agentWindowNewSessionFolder, folderExists(last) { return last }
        if !focusedEnded, selectedRow?.session != nil, let cwd = transcript.cwd, folderExists(cwd) { return cwd }
        return home
    }

    func setNewSessionFolder(_ s: String) { newSession?.folder = s }

    /// Typing pins the name; clearing it returns to the folder's free name.
    func setNewSessionName(_ s: String) {
        newSession?.name = s
        newSession?.nameEdited = !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setNewSessionCommand(_ s: String) { newSession?.command = s }

    func chooseNewSessionFolder() {
        island().chooseFolder { [weak self] path in
            guard let self, let path, self.newSession?.starting == nil else { return }
            self.setNewSessionFolder(AgentNewSession.abbreviate(path, home: self.home))
        }
    }

    /// The live sessions' and records' names in the spawn dir, from this window's store.
    var spawnTaken: Set<String> {
        guard let store else { return [] }
        let t = now(), own = newSession?.starting?.name.lowercased()
        // R2-1: the name the open form is starting is not taken for that form (its claim, or a poll listing it early).
        return AgentIsland.spawnTaken(dir: island().spawnDir(), sessions: store.sessions, history: store.history)
            .union(claimed.filter { t - $0.value <= Self.spawnSlack }.keys).filter { $0.lowercased() != own }
    }

    var newSessionAutoName: String {
        AgentNewSession.autoName(folder: AgentNewSession.expand(newSession?.folder ?? "", home: home), taken: spawnTaken,
                                 dir: island().spawnDir())
    }

    /// The name Start uses: the typed one, else the free name now (an untouched name taken since is re-picked).
    var newSessionName: String {
        guard let f = newSession, f.nameEdited else { return newSessionAutoName }
        return f.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var newSessionErrors: (folder: String?, name: String?) {
        guard let f = newSession else { return (nil, nil) }
        return (AgentNewSession.folderError(AgentNewSession.expand(f.folder, home: home), exists: folderExists),
                AgentNewSession.nameError(newSessionName, taken: spawnTaken, dir: island().spawnDir()))
    }

    /// #847 D7.4: the argv that runs, `--name` included.
    var newSessionRuns: String {
        let argv = AgentIsland.naming(AgentNewSession.argv(newSession?.command ?? "", shell: shell), name: newSessionName)
        return AgentIsland.shellLine(argv) + (AgentIsland.shellWords(newSession?.command ?? "").isEmpty ? " (your login shell)" : "")
    }

    var newSessionRecents: [String] {
        AgentNewSession.recents(last: Preferences.agentWindowNewSessionFolder, history: store?.history ?? [], exists: folderExists)
    }

    /// The status slot: starting, else the gate's refusal, else the last failure or busy text.
    var newSessionStatus: String? {
        guard let f = newSession else { return nil }
        if let k = f.starting { return "Starting \(k.name)…" }
        if let why = store?.resumeGate.refusal { return "Controls \(why)" }
        return f.status
    }

    /// Every check, against the store as it is now.
    var canStartNewSession: Bool {
        guard newSession?.starting == nil, store?.resumeGate.isOK == true else { return false }
        let e = newSessionErrors
        return e.folder == nil && e.name == nil
    }

    /// Start or Return: nothing runs unless every check passes now.
    @discardableResult
    func startNewSession() -> Bool {
        guard let f = newSession, canStartNewSession else { return false }
        return spawn(AgentNewSession.expand(f.folder, home: home), AgentNewSession.argv(f.command, shell: shell),
                     name: newSessionName, command: f.command)
    }

    /// ⇧⌘N, [>_] and the form's New shell: the login shell. With the form open, in its folder and name;
    /// else at once in ⌘N's folder with its free name.
    @discardableResult
    func startShell() -> Bool {
        let argv = [AgentNewSession.loginShell(shell), "-l"]
        if let f = newSession {
            guard canStartNewSession else { return false }
            return spawn(AgentNewSession.expand(f.folder, home: home), argv, name: newSessionName, command: nil)
        }
        guard store?.resumeGate.isOK == true else {
            store?.resumeGate.refusal.map { sayOnDirLine("Controls \($0)", until: .gate) }   // #887 (QA #747 INFO-3): Shift-Command-N says why
            return false
        }
        let folder = newSessionDefaultFolder
        return spawn(folder, argv, name: AgentNewSession.shellName(folder: folder, taken: spawnTaken, dir: island().spawnDir()),
                     command: nil)
    }

    private func spawn(_ folder: String, _ argv: [String], name: String, command: String?) -> Bool {
        requests += 1
        unlisted = nil
        let request = newSession == nil ? nil : requests, asked = now()   // nil: a quick shell, no form's
        guard let key = spawnSession(folder, argv, name, { [weak self] key, failure in
            self?.spawned(key, failure, name: name, folder: folder, command: command, request: request, asked: asked)
        }) else {
            let why = spawnRefusal(name)
            // never dropped silently; #948 F2: a gate refusal goes when the gate opens, a name or busy one with the form
            if newSession != nil {
                newSession?.status = why
            } else {
                sayOnDirLine(why, until: store?.resumeGate.isOK == false ? .gate : nil)
            }
            return false
        }
        claimed[name] = .infinity
        newSession?.starting = key
        newSession?.request = requests
        newSession?.status = nil
        return true
    }

    /// QA #736 INFO-3: why the island refused, re-checked in its own order: the gate, the name, then the runner.
    private func spawnRefusal(_ name: String) -> String {
        if let why = store?.resumeGate.refusal ?? (store == nil ? "Agent Island is off" : nil) { return "Controls \(why)" }
        return AgentNewSession.nameError(name, taken: [], dir: island().spawnDir()) ?? "\(name) is busy: try again"
    }

    /// With no form open: the spawn dir's dir-wide line, which the window draws in its sidebar strip
    /// (AgentDirStatusStrip) and the island on its own line; the runner's failures land there too.
    /// #948 F2: the one rule for a line this window wrote there: it goes when its cause is gone (`until`: the gate opens,
    /// a session of that name lists; nil: never by itself) or the form opens, in the same fixed slot. A line the island
    /// or a later action wrote over it is not the window's any more and is left alone.
    private func sayOnDirLine(_ text: String, until cause: DirLineCause? = nil) {
        guard let store else { return }
        let key = AgentSessionKey(dir: island().spawnDir(), name: "")
        dirLine = (key, text, cause)
        store.actions[key] = text
    }

    enum DirLineCause: Equatable { case gate, listed(String) }
    /// #948 F2: the window's own dir-wide line, while it is still the one up.
    private(set) var dirLine: (key: AgentSessionKey, text: String, cause: DirLineCause?)?

    private func clearDirLine() {
        guard let l = dirLine else { return }
        dirLine = nil
        if store?.actions[l.key] == l.text { store?.actions[l.key] = nil }
    }

    /// #948 F2, on every visible refresh (the values as published): replaced or cleared, it is forgotten; its cause
    /// gone, cleared. The gate is the store's (on a publish of `sessions` alone, one publish late).
    private func expireDirLine(sessions: [AgentSession], actions: [AgentSessionKey: String]) {
        guard let l = dirLine else { return }
        guard actions[l.key] == l.text else { dirLine = nil; return }
        let gone = switch l.cause {
        case .gate?: store?.resumeGate.isOK == true
        case .listed(let name)?: sessions.contains { $0.key == AgentSessionKey(dir: l.key.dir, name: name) }
        case nil: false
        }
        // Never inside an `actions` publish (its value lands after this sink and would put the line back): the next one.
        guard gone, let store, store.actions == actions else { return }
        dirLine = nil
        store.actions[l.key] = nil
    }

    /// #948 F3: the History read after the deadline answered: a record of that name that started since the request
    /// (whole seconds: 1 s of slack) puts its end in the sentence, where the sentence still is.
    private func endUnlisted(_ history: [DchHistoryRecord]) {
        guard let u = unlisted,
              let r = history.first(where: { $0.key == u.key && !$0.end.isEmpty && $0.started >= u.asked - 1 }) else { return }
        unlisted = nil
        let plain = Self.notListedText(u.key.name), said = Self.notListedText(u.key.name, end: r.end.hasPrefix("exit ") ? r.end : AgentIsland.endLabel(r.end))
        if newSession?.status == plain {
            newSession?.status = said
        } else if newSession == nil, let l = dirLine, l.text == plain, store?.actions[l.key] == plain {
            sayOnDirLine(said, until: l.cause)
        }
    }

    /// The runner's answer. Success keeps the folder and (OQ-3) a typed command as the one shared setting,
    /// selects the session once its row shows (R2 F5: the form stays "Starting…" over the pane until then);
    /// failure re-enables the form with dch's line.
    /// QA #713 INFO-4: an answer touches the form only when it answers the open form's own request.
    private func spawned(_ key: AgentSessionKey?, _ failure: String?, name: String, folder: String, command: String?,
                         request: Int?, asked: TimeInterval) {
        let mine = request != nil && newSession?.request == request && newSession?.starting != nil
        guard let key else {
            claimed[name] = nil
            if mine { newSession?.starting = nil; newSession?.status = failure }
            return
        }
        claimed[name] = now()
        Preferences.agentWindowNewSessionFolder = folder
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // #847 D7.2: a typed -n/--name would name every later session; else the text as typed.
            let words = AgentIsland.shellWords(command), kept = AgentIsland.strippingName(words)
            Preferences.agentIslandNewSessionCommand = kept == words ? command : AgentIsland.shellLine(kept)
        }
        if request != nil {
            guard mine else { return }   // closed or replaced meanwhile: the human moved on
            newSession?.starting = key   // R2 F5: the form stays "Starting…" over the pane until the row lands
        } else if newSession != nil {
            return   // a quick shell's answer under a form opened since: the form keeps the pane
        }
        pendingSpawn = (key, now(), asked)
        refresh()
    }

    /// The pending spawn's row is there: Terminal (a reused name's Transcript choice dropped), selected, the keys in.
    /// #887 (QA #747 INFO-2): the row first, so a window shown again past the slack still lands a row already listed.
    private func landSpawn() {
        guard let p = pendingSpawn else { return }
        guard let s = row(.live(p.key))?.session else {
            guard now() - p.at > Self.spawnSlack else { return }
            // QA #747 INFO-1: answered but never listed: the form stays, re-enabled, and says so; a quick shell, the dir line.
            pendingSpawn = nil
            let why = Self.notListedText(p.key.name)
            if newSession?.starting == p.key {
                newSession?.starting = nil
                newSession?.status = why
            } else if newSession == nil {
                sayOnDirLine(why, until: .listed(p.key.name))
            }
            // #948 F3: one History read when the sentence is up; its records (a refresh) may name how the command ended.
            if newSession?.status == why || dirLine?.text == why {
                unlisted = (p.key, p.asked)
                island().refreshHistory()
            }
            return
        }
        pendingSpawn = nil
        setMode(.terminal, for: s)
        select(.live(s.key))
        focusSelection()
    }

    // MARK: #829 Restart agent, Stop, Kill (ask, then act)

    /// #1289 (G5): a PR chip's way out; tests replace it (the island's seam opens nothing under XCTest).
    var openURL: @MainActor (URL) -> Void = { AgentIsland.openURL($0) }

    /// #1289 (G5): an allowlisted chip opens its URL; a chip with none opens nothing.
    func openPR(_ chip: AgentIsland.PRChip) {
        guard let url = chip.url else { return }
        openURL(url)
    }

    /// #1289 (G2/G8): Cmd-Backspace on the selected row only asks: Stop on a live session, Remove on a History record (the
    /// strip; confirm re-checks the gate and says why it runs nothing). No row selected: nothing.
    func askStopOrRemove() {
        guard let row = selectedRow else { return }
        if let s = row.session { ask(.stop, s) } else if let r = row.record { act(.remove, r) }
    }

    /// A header "⋯" or row context-menu item: selects the row first (R6), then asks.
    func ask(_ verb: AgentWindowVerb, _ s: AgentSession) {
        if ended?.row.id == .live(s.key) { return }   // QA #668 F1, 4.4 (d): it ended, nothing to ask
        select(.live(s.key))
        refusal = nil
        renameEdit = nil
        // G4: Rename edits the title in place and asks nothing; only a session still listed live.
        if verb == .rename {
            confirming = nil
            // QA #693 INFO-3: prefilled from the store, which holds a rename's alias before the poller lists it.
            if let live = store?.sessions.first(where: { $0.key == s.key }) {
                renameEdit = AgentRenameEdit(key: s.key, text: live.alias)
                dropPendingFocus()   // QA #694 INFO-2: the field has the keys
            }
            return
        }
        confirming = AgentWindowConfirm(verb: verb, key: s.key)
    }

    /// G4: the title field's end, for the edit it was opened with. An edit that is not the open one (a
    /// replaced field's late end, on another row or this one) changes nothing. `text` nil: Esc or the focus left, nothing
    /// runs. Else Return: the session is re-read by key (gone: nothing) and the controller runs `dch -m`
    /// unless the text is its alias already. An empty text clears the alias.
    /// #853 (QA #693 INFO-4): a Return the controller refused while another job runs on the row keeps
    /// the field open with the text, and the row's line says why over the running text ("Restarting…",
    /// which store.actions keeps for the input lock) until that text goes (refresh). True: the edit goes on.
    @discardableResult
    func endRename(_ edit: AgentRenameEdit, _ text: String?) -> Bool {
        guard renameEdit === edit else { return false }   // #853 r2: a replaced edit's late end, even on the same row
        let key = edit.key
        refusal = nil
        guard let text, let s = store?.sessions.first(where: { $0.key == key }),
              AgentIsland.renameArgs(s.name, text, current: s.alias) != nil else { renameEdit = nil; return false }
        // Past the checks above, a rename not run with a control dch there is a busy row.
        guard !renameSession(s, text), store?.controlDch != nil else { renameEdit = nil; return false }
        edit.text = text
        refusal = AgentWindowRefusal(id: .live(key), text: AgentIsland.renameBusyText)
        return true
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
        case .stop: _ = stopSession(s)   // #831 B1: the pane goes Ended, then its record by resolve (4.5)
        case .kill: _ = killSession(s)
        case .resume, .resumeNoMessage, .pin, .remove, .rename: break
        }
    }

    /// The refusal for the row `id`, if any.
    func refusalText(_ id: AgentSidebar.RowID) -> String? { refusal?.id == id ? refusal?.text : nil }

    func setVisible(_ v: Bool) {
        guard !closed, v != visible else { return }
        visible = v
        onVisible(v)
        clock?.invalidate()
        clock = nil
        if v {
            let t = Timer(timeInterval: ageInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            // R1115-1: common modes, so the ages keep ticking while a scroll or a drag is tracking.
            RunLoop.main.add(t, forMode: .common)
            clock = t
            refresh()
        }
        follow()
    }

    /// The window closed: stop everything for good.
    func close() {
        guard !closed else { return }
        dragEnded()   // R900-5a-1: a drag under way is saved once and the terminal's hold released, before saves stop
        setVisible(false)
        closed = true
        pendingSpawn = nil   // its deadline timer goes with it
        subscription = nil
        // 11.2 "window closed: runtime freed": every pane's model stopped, then released (no pane model outlives this).
        for r in runtimes.values { r.transcript.stop() }
        runtimes = [:]
        rebind()   // closed: the sinks go
        interaction.follow(nil)
        terminal.attach(nil)
    }

    /// 11.2 per pane runtime: a shown `.live` pane of a visible window runs; an Ended pane keeps its blocks suspended
    /// (4.4 (c): no IO, shown or not, hidden or not); anything else is stopped (a pane not shown holds no blocks
    /// unless Ended). Every stop and suspend comes before any start; the focused pane starts first.
    /// #900 B2 step 2 (R1193-5, 11.2, 7.4): with the split gate on, a `.live` pane of a visible window that is in the
    /// layout but not shown (zoomed away, too-small hidden) is suspended, not stopped: blocks and offset kept, one
    /// catch-up poll when shown again. A pane that left the layout was already stopped by syncRuntimes.
    /// #822: the terminal attaches to a visible, focused, live session in Terminal mode and detaches on anything else.
    /// The transcript runs in both modes: the header's cwd and todos come from it, so a toggle never changes the header.
    private func follow() {
        guard !closed else { return }
        let shown = visible ? shownPanes : []
        let keep = visible && AgentPaneLayout.splitsEnabled   // hidden or the gate off: stopped as before
        for r in runtimes.values {
            if r.ended != nil {
                r.transcript.suspend()
            } else if keep, !shown.contains(r.pane), Self.isLive(r.content) {
                r.transcript.suspend()
            } else if !shown.contains(r.pane) || !Self.isLive(r.content) {
                if r.transcript.running || r.transcript.suspended { r.transcript.stop() }
            }
        }
        for id in Self.focusedFirst(layout) where shown.contains(id) {
            guard let r = runtimes[id], r.ended == nil, case .live(let s)? = r.content else { continue }
            r.transcript.update(AgentSidebar.source(s))
            r.transcript.start()
        }
        rebind()
        guard visible, let f = focusedRuntime, f.ended == nil, case .live(let s)? = f.content else {
            interaction.follow(nil)   // 4.4 (d): nothing on an ended pane takes input; hidden or not live: nothing
            terminal.attach(nil)
            return
        }
        let transcript = f.transcript
        interaction.ask = transcript.pendingAsk   // this session's, never the last one's
        interaction.plan = withConfigDir(transcript.pendingPlan)
        let terminalMode = paneMode == .terminal
        // #822: Terminal mode has no input box (the terminal is the input).
        interaction.follow(terminalMode ? nil : s)
        // #847: the New session form covers the pane, so no terminal under it.
        terminal.attach(terminalMode && newSession == nil ? s.key : nil)
    }

    /// 11.2: the start order, the focused pane first, then the others in tree order.
    nonisolated static func focusedFirst(_ l: PaneLayout) -> [UUID] { [l.focused] + l.order.filter { $0 != l.focused } }

    nonisolated static func isLive(_ c: PaneContent?) -> Bool {
        if case .live? = c { return true }
        return false
    }
}

/// #822: the detail pane's two views of a live session.
enum AgentPaneMode: Equatable { case transcript, terminal }

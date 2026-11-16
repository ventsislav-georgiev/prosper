import AppKit
import Combine
import SwiftUI

// #1351 (#1346 P3a, design 3.1-3.9): the X-ray panel, a drawer over one pane (both modes; it overlays, so the terminal
// keeps its grid) with a tab strip in dch's order: Tasks and (#1352) Memory. Read when the panel opens; #1368's poller
// (XrayPoller.swift) re-reads Tasks while it is shown; Memory is read again on a switch to its tab (#1352) and every
// 30 s while it is shown (#1381).
// #1352: a task row and the memory card's "Read the prompt" jump to the prompt that last changed it (design 3.3).
// #1354 (P6 step A): Prompts and Responses from the pane's own chapters (Transcript mode), newest first; automatic rows
// hidden until shown, other sessions' messages marked and hideable (dch 1.78.0+, operator ruling Q1).
// #1389 (P6 step B): the same tabs for a Terminal-mode pane and a remote session, from `dch --xray <n> --json`'s chapters.

/// The tabs in dch's order (xview.c xv_ord); later phases put Refs and Search between Responses and Tasks.
enum XrayTab: String, CaseIterable { case prompts = "Prompts", responses = "Responses", tasks = "Tasks", memory = "Memory" }

/// The session a read names: a local one by name in its socket dir, a remote one as "host:name" (design 3.5).
struct XrayTarget: Equatable {
    let name: String
    /// The local session's socket dir; nil for a remote row (the default dir's dch dials the host).
    let dir: String?

    /// The selected row's session; nil for History, the empty pane, or a name dch would read as a flag.
    static func of(_ row: AgentSidebar.Row?) -> XrayTarget? {
        let t = row?.session.map { XrayTarget(name: $0.key.name, dir: $0.key.dir) }
            ?? row?.remote.map { XrayTarget(name: "\($0.host):\($0.name)", dir: nil) }
        guard let t, !t.name.isEmpty, !t.name.hasPrefix("-") else { return nil }
        return t
    }

    func args(_ form: String) -> [String] { ["--xray", name, "--\(form)", "--json"] }
    /// #1389: dch README "dch --xray <n> --json  # a session's chapters (prompts / commands) as one JSON object".
    var chaptersArgs: [String] { ["--xray", name, "--json"] }
    var env: [String: String] { AgentIsland.listEnv(dir: dir ?? DchCommand.defaultSocketDir) }
}

/// The open panels, by pane; the gate and the process seams.
@MainActor
final class XrayPanels: ObservableObject {
    static let shared = XrayPanels()
    @Published var open: [UUID: XrayPanelModel] = [:] {
        didSet {   // #1368: a panel that leaves stops polling and SIGTERMs its read; one that comes reads its pane's state
            for (k, m) in oldValue where open[k] !== m { m.stop() }
            for (k, m) in open where oldValue[k] !== m { m.paneState = { Self.paneState(k) }; wire(m, k) }
        }
    }

    func close(_ pane: UUID) { open[pane] = nil }

    /// #1352: the window that draws `pane` (its presenter shows the memory card); rows put theirs here.
    static var window: @MainActor (UUID) -> AgentsNSWindow? = { AgentsNSWindow.window(of: $0) }

    /// #1352, design 3.3: the transcript a jump lands in: the pane's own, in Transcript mode, for a local session; nil
    /// (Terminal mode, a remote row, another pane focused) means the card.
    static func transcript(_ pane: UUID, _ target: XrayTarget) -> AgentTranscriptModel? {
        guard target.dir != nil, let m = model(pane), m.layout.focused == pane, m.paneMode == .transcript else { return nil }
        return m.focusedRuntime?.transcript
    }

    /// #1389: the pane reads its Prompts and Responses from dch: a remote row, or a local one in Terminal mode (a
    /// Transcript-mode pane keeps its own chapters, never both). Off under XCTest as `run` is: rows put `fromDch` here.
    static var chaptersRead: @MainActor (UUID, XrayTarget) -> Bool = { NSClassFromString("XCTestCase") == nil && fromDch($0, $1) }

    /// The focused pane's mode through the window model (no model or another pane focused: no read).
    static func fromDch(_ pane: UUID, _ target: XrayTarget) -> Bool {
        guard let m = model(pane), m.layout.focused == pane else { return false }
        return target.dir == nil || m.paneMode != .transcript
    }

    /// #1352: the window's presenter, the transcript, the link opener and the cwd, for the panel that came to `pane`.
    private func wire(_ m: XrayPanelModel, _ pane: UUID) {
        let target = m.target
        m.present = { view, size in
            guard let w = Self.window(pane), let anchor = XrayCardAnchor.view(for: pane, in: w) ?? w.contentView else { return }
            w.cards.present(view, size: size, anchor: anchor) {}
        }
        m.dismiss = { Self.window(pane)?.cards.close() }
        m.transcript = { Self.transcript(pane, target) }
        m.fromDch = { Self.chaptersRead(pane, target) }
        m.openURL = { Self.model(pane)?.openURL($0) }
        m.cwd = { Self.model(pane)?.focusedRuntime?.transcript.cwd }
    }

    /// One dch run: (path, argv, env) -> (exit status, stdout); -1 when it never ran or timed out.
    typealias Run = @Sendable (_ path: String, _ args: [String], _ env: [String: String]) async -> (status: Int32, out: Data)

    /// The product's: the shared runCapturingBoth, bounded like a Remote Terminal call. Never under XCTest (rows put a
    /// fake here; no row runs a real dch).
    static var run: Run = { path, args, env in
        guard NSClassFromString("XCTestCase") == nil else { return (-1, Data()) }
        let child = XrayChild()   // #1368: a cancelled read (panel closed, session switched) SIGTERMs its dch
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                DispatchQueue.global(qos: .utility).async { c.resume(returning: runBounded(child, path, args, env)) }
            }
        } onCancel: { child.cancel() }
    }

    /// `run`'s blocking body, lifted so a row can drive it with a recorder child (R1380-s2): the exit is marked on the
    /// child (#1380) and on `bounded`, so neither a cancel nor the timeout signals a reaped dch's pid (R1380-s1).
    nonisolated static func runBounded(_ child: XrayChild, _ path: String, _ args: [String], _ env: [String: String],
                           timeout: TimeInterval = DchCommand.remoteTimeout,
                           terminate: @escaping @Sendable (pid_t) -> Void = DchCommand.sigkill) -> (status: Int32, out: Data) {
        let r = DchCommand.bounded(timeout, terminate: terminate) { onPid, onExit in
            DchCommand.runCapturingBoth(args: args, env: env, path: path, onPid: { onPid($0); child.started($0) },
                                        onExit: { onExit(); child.reaped() })
        }
        return r.map { ($0.status, $0.out) } ?? (-1, Data())
    }

    /// The dch path X-ray runs, when it passes XrayTabs.gate (1.78.0); nil below it: no item, no route, no process.
    static var dch: @MainActor () -> String? = { if case .ok(let path) = XrayTabs.gate(probed) { path } else { nil } }

    /// The bundled (else installed) dch's version, probed off main by `warm`; nil until then and under XCTest.
    private static var probed: DchCommand.Binary?

    /// shortcut: probed once per window open, so a dch upgrade shows on the next open; re-probe per toggle if needed.
    static func warm() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let path = DchCommand.dchPath
            let b = DchCommand.probedVersion(path).map { DchCommand.Binary(path: path, version: $0) }
            Task { @MainActor in probed = b }
        }
    }
}

/// One pane's panel: what the read found, the shown tab and the filter.
@MainActor
final class XrayPanelModel: ObservableObject {
    let target: XrayTarget
    /// nil: no Tasks tab (design 3.9: exit not 0, a schema other than 1, an empty list, a shell).
    @Published var tasks: XrayTasks?   // set here and by the poller (XrayPoller.swift)
    /// nil: no Memory tab (exit not 0, no row).
    @Published private(set) var memory: XrayMemory?
    /// #1389: Prompts and Responses from dch's chapters (Terminal mode, remote); nil: none (not read, exit not 0, bad JSON).
    @Published var dchChapters: [TranscriptOutline.Chapter]?
    /// #1389: this pane reads dch's chapters (XrayPanels.chaptersRead); false: never runs that read.
    var fromDch: () -> Bool = { false }
    @Published private(set) var loaded = false
    @Published var tab: XrayTab
    @Published var filter = ""
    @Published var filterFocused = false
    /// The task whose card was asked for last (the presenter shows it).
    @Published private(set) var card: XrayTasks.Task?
    /// #1352: the memory whose card was asked for last.
    @Published private(set) var memoryCard: XrayMemory.Item?
    var reading: Task<Void, Never>?   // the open read or a poll (XrayPoller.swift)
    /// #1368: the poller's state (XrayPoller.swift): the read's dch and runner, when the last read started, the dch
    /// path's mtime after a failed read (no retry until it moves), exit 4/7's "host unreachable", the ticker's stop.
    var dch: String?
    var run: XrayPanels.Run?
    var lastRead = Date.distantPast
    var failed = false
    var failedMtime: Date?
    @Published var unreachable = false
    var stopTicker: (() -> Void)?
    var stopped = false
    /// #1381 (R1352-i1): a switch to Memory came while another read ran; that read's end runs the Memory read, once.
    var pendingMemory = false
    /// #1368: the pane's window visible and its session live; XrayPanels.open wires it (default: hidden, no poll).
    var paneState: () -> (visible: Bool, live: Bool) = { (false, false) }
    /// #1368: the dch path's modification date (design 3.9's retry key).
    var mtime: (String) -> Date? = { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }

    var now: () -> Date = Date.init
    var close: () -> Void = {}
    var presentCard: (XrayTasks.Task) -> Void = { _ in }
    /// #1352 seams, wired by XrayPanels.open: any card through the window's presenter, its close, the pane's transcript
    /// (nil: no jump, the card), the link opener, the session's cwd (instruction paths are shown relative to it).
    var present: (AnyView, CGSize) -> Void = { _, _ in }
    var dismiss: () -> Void = {}
    var transcript: () -> AgentTranscriptModel? = { nil }
    var openURL: (URL) -> Void = { _ in }
    var cwd: () -> String? = { nil }
    var home = NSHomeDirectory()
    /// The Todos chip's: run instead of keeping the panel when the read finds no Tasks tab (Q3).
    var fallback: (() -> Void)?
    /// #1354: Prompts and Responses show the automatic rows (dch `n`, off at open) / hide other sessions' messages (`a`).
    @Published var showAuto = false
    @Published var hidePeer = false
    private weak var watched: AgentTranscriptModel?
    private var watch: AnyCancellable?
    /// R1351-i1: true while this panel is still the pane's open one and the pane still shows `target`; the fallback runs
    /// only then (chosen over cancelling the read: a panel hidden by a selection change stays open, so close never fires).
    var isCurrent: () -> Bool = { true }

    init(target: XrayTarget, tab: XrayTab) {
        self.target = target
        self.tab = tab
    }

    /// The one read on open: both forms, so the strip knows which tabs exist.
    func read(dch: String, run: @escaping XrayPanels.Run) {
        (self.dch, self.run) = (dch, run)
        if stopTicker == nil { stopTicker = XrayPanels.ticker { [weak self] in self?.tick() } }
        readBoth()
    }

    /// Both forms; again from the poller when a cancel left the panel unread (#1368).
    func readBoth() {
        guard let dch, let run else { return }
        lastRead = now()
        let env = target.env, a = target.args("tasks"), b = target.args("memory")
        let c = fromDch() ? target.chaptersArgs : nil   // #1389: the third read only for a dch-chapters pane
        let chapters: @Sendable () async -> (status: Int32, out: Data)? = {
            guard let c else { return nil }
            return await run(dch, c, env)
        }
        reading = Task { [weak self] in
            async let t = run(dch, a, env)
            async let m = run(dch, b, env)
            async let k = chapters()
            let (tr, mr, kr) = await (t, m, k)
            guard !Task.isCancelled else { return }   // #1368: closed or switched away: the SIGTERMed answer is not news
            self?.reading = nil
            self?.apply(tasks: tr, memory: mr, chapters: kr)
        }
    }

    func apply(tasks tr: (status: Int32, out: Data), memory mr: (status: Int32, out: Data),
               chapters kr: (status: Int32, out: Data)? = nil) {
        take(tr)
        takeMemory(mr)
        if let kr { takeChapters(kr) }
        loaded = true
        if let fallback, tasks == nil {
            if isCurrent() { close(); fallback() }   // another session now shown: the list never opens over it
            return
        }
        if !tabs.contains(tab), let first = tabs.first { tab = first }
    }

    func takeMemory(_ mr: (status: Int32, out: Data)) {
        memory = mr.status == 0 ? XrayMemory.parse(mr.out) : nil
        if memory?.count == 0 { memory = nil }
    }

    /// #1352: a tab chosen in the strip; Memory is read again then: at once, or (#1381, R1352-i1) when the read in
    /// flight ends. The 30 s Memory poll is the poller's (XrayPoller.swift).
    func select(_ t: XrayTab) {
        tab = t
        guard t == .memory, loaded else { return }
        if reading != nil { pendingMemory = true } else { readMemory() }
    }

    /// Design 3.9 and QA R1349-i2: a Tasks tab only for exit 0, header schema 1 and at least one task.
    static func tasksTab(_ r: (status: Int32, out: Data)) -> XrayTasks? {
        guard r.status == 0 else { return nil }
        let t = XrayTasks.parse(r.out)
        return t.schema == 1 && !t.tasks.isEmpty ? t : nil
    }

    /// #1354: Prompts and Responses while the pane's transcript is there (Transcript mode, a local session); #1389: or
    /// while dch's chapters read answered (Terminal mode, remote).
    var tabs: [XrayTab] {
        let prose = transcript() != nil || dchChapters != nil
        return XrayTab.allCases.filter {
            switch $0 {
            case .prompts, .responses: prose
            case .tasks: tasks != nil
            case .memory: memory != nil
            }
        }
    }

    /// Design 3.1: Prompts = rows listed; Responses = items shown without the automatic ones (dch README).
    func count(_ tab: XrayTab) -> Int {
        switch tab {
        case .prompts: shownPrompts.count
        case .responses: shownResponses.filter { !$0.auto }.count
        case .tasks: tasks?.open ?? 0
        case .memory: memory?.count ?? 0
        }
    }
    /// "Tasks 3" (open tasks), "Memory 2" (every row).
    func title(_ tab: XrayTab) -> String { "\(tab.rawValue) \(count(tab))" }
    /// VoiceOver: "Tasks, 3 open"; "Memory, 2".
    func spoken(_ tab: XrayTab) -> String { tab == .tasks ? "Tasks, \(count(tab)) open" : "\(tab.rawValue), \(count(tab))" }

    /// Design 3.2: case-insensitive, over id, title, note and label.
    static func matches(_ t: XrayTasks.Task, _ filter: String) -> Bool {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || [t.id, t.title, t.note ?? "", t.label].contains { $0.localizedCaseInsensitiveContains(q) }
    }

    /// The groups with the filter applied; an empty group goes, with or without a filter (#1381, as Memory's).
    var shownGroups: [XrayTasks.Group] {
        guard let tasks else { return [] }
        let q = filter.trimmingCharacters(in: .whitespaces)
        return tasks.groups.map { XrayTasks.Group(title: $0.title, tasks: $0.tasks.filter { Self.matches($0, q) }) }
            .filter { !$0.tasks.isEmpty }
    }

    /// "Tasks \u{00B7} <title>" for a command list; nil otherwise.
    var listTitle: String? {
        guard tasks?.source == "command", let t = tasks?.sessionTitle, !t.isEmpty else { return nil }
        return "Tasks \u{00B7} \(t)"
    }

    /// The faint footer: the warnings, "partial", "N not shown".
    var footer: [String] {
        guard let tasks else { return [] }
        var out = [tasks.headerWarn, tasks.doneWarn].compactMap { $0 }.filter { !$0.isEmpty }
        if tasks.partial { out.append("partial") }
        if tasks.droppedCount > 0 { out.append("\(tasks.droppedCount) not shown") }
        if unreachable { out.append("host unreachable") }   // #1368, design 3.5: exit 4/7 kept the rows
        return out
    }

    /// #1353 (R1381-i1): the Memory tab's footer: "host unreachable" when the last read did not reach the host; #1389:
    /// Prompts' and Responses' too.
    var memoryFooter: [String] { unreachable ? ["host unreachable"] : [] }

    /// Esc: clears the filter, then closes.
    func escape() {
        if filter.isEmpty { close() } else { filter = "" }
    }

    /// Command-F, or "/" outside the field, puts the keys in the filter.
    func key(_ chars: String, command: Bool) -> Bool {
        guard command ? chars.lowercased() == "f" : chars == "/" && !filterFocused else { return false }
        filterFocused = true
        return true
    }

    /// The task card.
    func openCard(_ t: XrayTasks.Task) {
        card = t
        presentCard(t)
    }

    /// #1352, design 3.3: "older than the loaded part", shown with the card when the prompt is above what can load.
    static let olderNote = "The prompt is older than the loaded part."

    /// Return or a click on a task row: the prompt that last changed it (`chapter`, never `created_chapter`); no
    /// chapter, no transcript (Terminal mode, remote) or a refused anchor: the card; too old: the card with the note.
    func activate(_ t: XrayTasks.Task) {
        go(t.chapter) { [weak self] older in
            guard let self else { return }
            guard older else { return self.openCard(t) }
            self.card = t
            self.present(AnyView(XrayTaskCard(task: t, now: self.now(), open: self.openURL, note: Self.olderNote)), XrayTaskCard.size)
        }
    }

    /// Return or a click on a memory row: its card.
    func openMemoryCard(_ m: XrayMemory.Item, note: String? = nil) {
        memoryCard = m
        let read: (() -> Void)? = XrayMemoryCard.canRead(m) ? { [weak self] in self?.readPrompt(m) } : nil
        present(AnyView(XrayMemoryCard(item: m, now: now(), note: note, readPrompt: read)), XrayMemoryCard.size)
    }

    /// The card's "Read the prompt": the card goes and the transcript jumps; else the card stays (with the note when old).
    func readPrompt(_ m: XrayMemory.Item) {
        guard XrayMemoryCard.canRead(m) else { return }
        go(m.chapter) { [weak self] older in if older { self?.openMemoryCard(m, note: Self.olderNote) } }
    }

    /// The jump; `card(older)` runs when it did not land.
    private func go(_ anchor: String?, card: @escaping @MainActor (Bool) -> Void) {
        guard let anchor, let tm = transcript() else { return card(false) }
        TranscriptJumper.of(tm).jump(anchor: anchor, in: tm) { [weak self] r in
            switch r {
            case .jumped: self?.dismiss()
            case .older: card(true)
            case .refused: card(false)
            }
        }
    }

    // MARK: #1354 Prompts and Responses

    /// The pane's chapters (#1389: without its transcript, dch's); a new poll or page redraws the panel.
    var chapters: [TranscriptOutline.Chapter] {
        guard let tm = transcript() else { return dchChapters ?? [] }
        if watched !== tm {
            watched = tm
            watch = tm.$chapters.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
        }
        return tm.chapters
    }

    /// dch xv_vis1 (xview.c:2283-2297): the filter (title, and the answer on Responses), then auto rows unless shown,
    /// then peer rows when hidden; newest first. Responses lists the chapters with an answer. `auto` / `peer`: true shows
    /// those rows whatever the toggles say (the footer's counts).
    func shown(_ tab: XrayTab, auto: Bool? = nil, peer: Bool? = nil) -> [TranscriptOutline.Chapter] {
        let (all, keepPeer) = (auto ?? self.showAuto, peer ?? !self.hidePeer)
        let q = filter.trimmingCharacters(in: .whitespaces)
        return chapters.reversed().filter { c in
            (tab != .responses || c.response != nil)
                && (q.isEmpty || c.title.localizedCaseInsensitiveContains(q)
                    || tab == .responses && (c.response ?? "").localizedCaseInsensitiveContains(q))
                && (all || !c.auto) && (keepPeer || c.from != .peer)
        }
    }
    var shownPrompts: [TranscriptOutline.Chapter] { shown(.prompts) }
    var shownResponses: [TranscriptOutline.Chapter] { shown(.responses) }

    /// The automatic rows and the other sessions' messages on `tab` (filter applied, shown or not): the footer's counts.
    func hidden(_ tab: XrayTab) -> (auto: Int, peer: Int) {
        let all = shown(tab, auto: true, peer: true)
        return (all.filter(\.auto).count, all.filter { $0.from == .peer }.count)
    }

    /// The footer's toggles (dch xview.c:3563-3575): "3 automatic hidden" + Show, or Hide; "2 agent messages hidden" + Show,
    /// or Hide; none when the tab has no such row.
    func promptFooter(_ tab: XrayTab) -> [(text: String?, button: String, toggle: () -> Void)] {
        let n = hidden(tab)
        var out: [(text: String?, button: String, toggle: () -> Void)] = []
        if n.auto > 0 {
            out.append((showAuto ? nil : "\(n.auto) automatic hidden", showAuto ? "Hide automatic" : "Show automatic",
                        { [weak self] in self?.showAuto.toggle() }))
        }
        if n.peer > 0 {
            out.append((hidePeer ? "\(n.peer) agent message\(n.peer == 1 ? "" : "s") hidden" : nil,
                        hidePeer ? "Show agent messages" : "Hide agent messages", { [weak self] in self?.hidePeer.toggle() }))
        }
        return out
    }

    /// Return or a click on a Prompts or Responses row: the pane's transcript jumps to that chapter (#1319's seam).
    func activate(_ c: TranscriptOutline.Chapter) {
        guard let tm = transcript() else { return }
        TranscriptJumper.of(tm).jump(to: c)
    }

    // MARK: #1352 Memory

    /// Design 3.2: case-insensitive, over id, title, note, kind, path and body.
    static func matches(_ m: XrayMemory.Item, _ filter: String) -> Bool {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || [m.id, m.title, m.note ?? "", m.kindWord ?? "", m.path, m.body ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(q) }
    }

    /// The memory groups with the filter applied; an emptied group goes.
    var shownMemory: [XrayMemory.Group] {
        guard let memory else { return [] }
        return memory.groups.map { XrayMemory.Group(title: $0.title, items: $0.items.filter { Self.matches($0, filter) }) }
            .filter { !$0.items.isEmpty }
    }
}

/// #1354: one Prompts or Responses row as drawn and spoken (design 3.2, 3.7, 3.8): the number, dch's mark (xview.c:2404
/// xv_mark: a robot and the sender for another session's message, an inbox and the name for a subagent's hand-back, a bell
/// for another automatic prompt), the title (faint for an automatic row); Responses adds the tools line and the answer.
struct XrayPromptRow: Equatable {
    let ordinal: String
    let mark: String?
    let title: String
    let faint: Bool
    let tools: String?
    let answer: String?
    /// The answer goes on past what the row shows (the transcript has it).
    let more: Bool
    let spoken: String

    /// dch README Responses: "the answer wrapped to the width, at most 8 lines".
    static let answerLines = 8
    static let lineCap = 240

    static func mark(_ c: TranscriptOutline.Chapter) -> String? {
        let symbol: String? = c.peer == nil ? (c.auto && c.kind != .compaction ? "\u{1F514}" : nil) : c.auto ? "\u{1F4E5}" : "\u{1F916}"
        guard let symbol else { return nil }
        let sender = OutsideText.shown(c.peer ?? "", max: 40)
        return sender.isEmpty ? symbol : symbol + " " + sender
    }

    init(_ c: TranscriptOutline.Chapter, response: Bool = false) {
        ordinal = "\(c.ordinal)"
        mark = Self.mark(c)
        title = OutsideText.shown(c.title, max: TranscriptOutline.titleCap)
        faint = c.auto
        tools = response ? c.tools.map { OutsideText.shown($0, max: 160) } : nil
        let lines = response ? (c.response ?? "").split(separator: "\n", omittingEmptySubsequences: false) : []
        answer = response ? lines.prefix(Self.answerLines).map { OutsideText.shown(String($0), max: Self.lineCap) }
            .joined(separator: "\n") : nil
        more = lines.count > Self.answerLines || lines.prefix(Self.answerLines).contains { $0.count > Self.lineCap }
        let sender = OutsideText.shown(c.peer ?? "", max: 40), who: String
        switch c.from {
        case .own: who = "Prompt \(c.ordinal)"
        case .auto where c.peer != nil: who = "Hand-back" + (sender.isEmpty ? "" : " from " + sender) + ", prompt \(c.ordinal)"
        case .auto: who = "Automatic prompt \(c.ordinal)"
        case .peer: who = "Message from " + (sender.isEmpty ? "another session" : sender) + ", prompt \(c.ordinal)"
        }
        let first = answer.flatMap { $0.split(separator: "\n").first.map(String.init) }
        let lead: String = response ? "Response to " + who.prefix(1).lowercased() + String(who.dropFirst()) : who
        let parts: [String?] = [lead, title, tools.map { "tools " + $0 }, first]
        spoken = parts.compactMap { $0 }.joined(separator: ", ")
    }
}

/// One memory row as drawn and spoken (design 3.2, 3.8): title; kind and note (an instruction file: its path) faint;
/// at the right "wrote"/"loaded" and the age.
struct XrayMemoryRow: Equatable {
    let title: String
    let detail: String
    let session: String?
    let age: String?
    let spoken: String

    /// Relative to the cwd (which wins when both hold), else ~ for the home dir; then the outside-text rule (160).
    static func shortPath(_ p: String, home: String, cwd: String?) -> String {
        var s = p
        if let cwd, !cwd.isEmpty, cwd != "/", p.hasPrefix(cwd + "/") { s = String(p.dropFirst(cwd.count + 1)) }
        else if !home.isEmpty, home != "/", p.hasPrefix(home + "/") { s = "~" + p.dropFirst(home.count) }
        return OutsideText.shown(s, max: 160)
    }

    init(_ m: XrayMemory.Item, now: Date, home: String, cwd: String?) {
        title = m.title
        let note = m.kind == .instructions ? Self.shortPath(m.path, home: home, cwd: cwd) : m.note
        detail = [m.kindWord, note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        session = m.sessionWord.flatMap { $0.isEmpty ? nil : $0 }
        let a = XrayTaskRow.age(m.updated, now: now)
        age = a?.short
        spoken = ([title, m.kindWord, note, session, a?.spoken].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: ", ")
    }
}

/// One task row as drawn and spoken (design 3.2, 3.8).
struct XrayTaskRow: Equatable {
    let mark: String
    let id: String
    let title: String
    let label: String?
    let blocked: String?
    let age: String?
    let spoken: String

    /// R1351-i2: the ids the row names; the card keeps the full list.
    static let blockedShown = 3

    static func statusName(_ s: XrayTasks.Status) -> String {
        switch s {
        case .active: "In progress"
        case .pending: "Pending"
        case .done: "Done"
        case .dropped: "Dropped"
        }
    }

    static func mark(_ s: XrayTasks.Status) -> String {
        switch s {
        case .active: "circle.dotted"
        case .pending: "circle"
        case .done: "checkmark.circle"
        case .dropped: "xmark.circle"
        }
    }

    /// The words that say no more than the status (dch shows a label only when it says more: a ledger's PARKED).
    static let statusWords: Set<String> = ["", "active", "in_progress", "pending", "done", "completed", "dropped", "deleted"]

    static func label(_ t: XrayTasks.Task) -> String? { statusWords.contains(t.label.lowercased()) ? nil : t.label }

    /// "5m", "3h", "2d" and "5 minutes ago"; from `updated`, else `created`.
    static func age(_ d: Date?, now: Date) -> (short: String, spoken: String)? {
        guard let d else { return nil }
        let s = max(0, min(now.timeIntervalSince(d), 1e10))   // bounded before Int: a far date from outside stays in range
        let m = Int(s / 60), h = m / 60, days = h / 24
        func say(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
        if h == 0 { return ("\(max(1, m))m", say(max(1, m), "minute")) }
        if days == 0 { return ("\(h)h", say(h, "hour")) }
        return ("\(days)d", say(days, "day"))
    }

    init(_ t: XrayTasks.Task, now: Date) {
        mark = Self.mark(t.status)
        id = t.id
        title = t.status == .active ? (t.active.flatMap { $0.isEmpty ? nil : $0 } ?? t.title) : t.title
        label = Self.label(t)
        blocked = t.blockedBy.isEmpty ? nil : "blocked by \(t.blockedBy.prefix(Self.blockedShown).joined(separator: ", "))"
            + (t.blockedBy.count > Self.blockedShown ? " +\(t.blockedBy.count - Self.blockedShown)" : "")
        let a = Self.age(t.updated ?? t.created, now: now)
        age = a?.short
        let blockedAll = t.blockedBy.isEmpty ? nil : "blocked by \(t.blockedBy.joined(separator: ", "))"
        spoken = (["\(Self.statusName(t.status)) task \(t.id)", title, label, blockedAll, a?.spoken].compactMap { $0 })
            .joined(separator: ", ")
    }
}

// MARK: - Views

/// The drawer over `pane`, drawn only while its panel is open for the session the pane shows.
struct XrayDrawer: View {
    @ObservedObject var panels = XrayPanels.shared
    let pane: UUID
    let target: XrayTarget?

    var body: some View {
        if let p = panels.open[pane], p.target == target {
            XrayPanelView(panel: p)
                .frame(maxWidth: sz(340))   // R1351-n1: min(340, the pane's width): the overlay is offered the pane's width
                .frame(maxHeight: .infinity)
                .modifier(AgentPaneProbe(kind: "xray"))   // tests only (nil probe: nothing)
                .background(Neon.card)
                .overlay(alignment: .leading) { Rectangle().fill(Neon.stroke).frame(width: 1) }
        }
    }
}

struct XrayPanelView: View {
    @ObservedObject var panel: XrayPanelModel
    @FocusState private var filterFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: sz(6)) {
                // Narrow: the counts go first, then the names scroll (design 3.1); capsule buttons ignore no UI scale.
                ViewThatFits(in: .horizontal) {
                    XrayTabStrip(panel: panel, counts: true)
                    XrayTabStrip(panel: panel, counts: false)
                    ScrollView(.horizontal, showsIndicators: false) { XrayTabStrip(panel: panel, counts: false) }
                }
                Spacer(minLength: 0)
                Button { panel.close() } label: {
                    Image(systemName: "xmark").font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
                }
                .buttonStyle(.plain).fixedSize()
                .help("Close X-Ray (Shift-Command-X)")
                .accessibilityLabel("Close X-Ray")
            }
            .padding(.horizontal, sz(10)).padding(.vertical, sz(6))
            Rectangle().fill(Neon.stroke).frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .focusable()
        .focusEffectDisabled()
        .onExitCommand { panel.escape() }
        .onKeyPress { k in panel.key(k.characters, command: k.modifiers.contains(.command)) ? .handled : .ignored }
        .onChange(of: panel.filterFocused) { _, v in filterFocus = v }
        .onChange(of: filterFocus) { _, v in panel.filterFocused = v }
    }

    @ViewBuilder var content: some View {
        if !panel.loaded {
            faint("Reading\u{2026}").padding(sz(10))
        } else if panel.tabs.isEmpty {
            faint("No tasks or memory for this session").padding(sz(10))
        } else if panel.tab == .memory {
            memoryTab
        } else if panel.tab == .prompts || panel.tab == .responses {
            promptsTab(panel.tab)
        } else {
            tasksTab
        }
    }

    var tasksTab: some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            TextField("Filter", text: $panel.filter)
                .textFieldStyle(.roundedBorder)
                .font(Neon.font(11))
                .focused($filterFocus)
                .accessibilityLabel("Filter tasks")
            if let t = panel.listTitle { Text(verbatim: t).font(Neon.font(11, weight: .semibold)).lineLimit(1) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(panel.shownGroups.enumerated()), id: \.offset) { _, g in
                        faint("\(g.title) \(g.tasks.count)").padding(.top, sz(6)).accessibilityAddTraits(.isHeader)
                        ForEach(Array(g.tasks.enumerated()), id: \.offset) { _, t in
                            XrayTaskRowView(row: XrayTaskRow(t, now: panel.now())) { panel.activate(t) }
                        }
                    }
                }
            }
            ForEach(panel.footer, id: \.self) { faint($0) }
        }
        .padding(sz(10))
    }

    /// #1354: Prompts or Responses, newest first; the footer's counts and toggles (design 1.3, 3.10).
    func promptsTab(_ tab: XrayTab) -> some View {
        let rows = panel.shown(tab)
        return VStack(alignment: .leading, spacing: sz(4)) {
            TextField("Filter", text: $panel.filter)
                .textFieldStyle(.roundedBorder)
                .font(Neon.font(11))
                .focused($filterFocus)
                .accessibilityLabel(tab == .prompts ? "Filter prompts" : "Filter responses")
            if rows.isEmpty { faint(tab == .prompts ? "No prompts shown" : "No responses yet") }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: sz(2)) {
                    ForEach(rows) { c in
                        XrayPromptRowView(row: XrayPromptRow(c, response: tab == .responses)) { panel.activate(c) }
                    }
                }
            }
            ForEach(Array(panel.promptFooter(tab).enumerated()), id: \.offset) { _, f in
                HStack(spacing: sz(6)) {
                    if let t = f.text { faint(t) }
                    Button(f.button, action: f.toggle).buttonStyle(.link).font(Neon.font(10, weight: .medium))
                }
            }
            ForEach(panel.memoryFooter, id: \.self) { faint($0) }   // #1389: "host unreachable"
        }
        .padding(sz(10))
    }

    var memoryTab: some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            TextField("Filter", text: $panel.filter)
                .textFieldStyle(.roundedBorder)
                .font(Neon.font(11))
                .focused($filterFocus)
                .accessibilityLabel("Filter memory")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(panel.shownMemory.enumerated()), id: \.offset) { _, g in
                        faint("\(g.title) \(g.items.count)").padding(.top, sz(6)).accessibilityAddTraits(.isHeader)
                        ForEach(Array(g.items.enumerated()), id: \.offset) { _, m in
                            XrayMemoryRowView(row: XrayMemoryRow(m, now: panel.now(), home: panel.home, cwd: panel.cwd())) {
                                panel.openMemoryCard(m)
                            }
                        }
                    }
                }
            }
            ForEach(panel.memoryFooter, id: \.self) { faint($0) }
        }
        .padding(sz(10))
    }

    func faint(_ s: String) -> some View {
        Text(verbatim: s).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary).lineLimit(1)
    }
}

/// The #821 capsule-button strip: only the tabs that exist, "Name N".
struct XrayTabStrip: View {
    @ObservedObject var panel: XrayPanelModel
    let counts: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(panel.tabs, id: \.self) { t in
                Button { panel.select(t) } label: {
                    Text(verbatim: counts ? panel.title(t) : t.rawValue)
                        .font(Neon.font(10.5, weight: .medium))
                        .foregroundStyle(t == panel.tab ? Neon.textPrimary : Neon.textSecondary)
                        .padding(.horizontal, sz(8)).padding(.vertical, sz(3))
                        .background(Capsule().fill(t == panel.tab ? Neon.blue.opacity(0.2) : .clear))
                        .contentShape(Capsule())
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(panel.spoken(t))
                .accessibilityAddTraits(t == panel.tab ? .isSelected : [])
            }
        }
        .padding(sz(2))
        .overlay(Capsule().stroke(Neon.stroke, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("X-Ray tabs")
    }
}

struct XrayTaskRowView: View {
    let row: XrayTaskRow
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: sz(6)) {
                Image(systemName: row.mark).foregroundStyle(Neon.textSecondary)
                Text(verbatim: row.id).foregroundStyle(Neon.textSecondary).fixedSize()
                Text(verbatim: row.title).foregroundStyle(Neon.textPrimary).lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1).modifier(AgentPaneProbe(kind: "xrayTitle"))   // tests only (nil probe: nothing)
                Spacer(minLength: sz(4))
                ForEach([row.label, row.age].compactMap { $0 }, id: \.self) {
                    Text(verbatim: $0).foregroundStyle(Neon.textSecondary).lineLimit(1).fixedSize()
                }
                // truncates under its own cap: a long id list never pushes the title out
                if let b = row.blocked {
                    Text(verbatim: b).foregroundStyle(Neon.textSecondary).lineLimit(1).truncationMode(.tail).frame(maxWidth: sz(120), alignment: .trailing)
                }
            }
            .font(Neon.font(11))
            .padding(.vertical, sz(2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.spoken)
    }
}

/// #1354: a Prompts or Responses row; a click (or Return / Space with VoiceOver) jumps to its chapter.
struct XrayPromptRowView: View {
    let row: XrayPromptRow
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: sz(1)) {
                HStack(spacing: sz(6)) {
                    Text(verbatim: row.ordinal).foregroundStyle(Neon.textSecondary).fixedSize()
                    if let m = row.mark { Text(verbatim: m).foregroundStyle(Neon.textSecondary).lineLimit(1) }
                    Text(verbatim: row.title).foregroundStyle(row.faint ? Neon.textSecondary : Neon.textPrimary)
                        .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                }
                if let t = row.tools { Text(verbatim: t).foregroundStyle(Neon.textSecondary).lineLimit(1) }
                if let a = row.answer {
                    Text(verbatim: a + (row.more ? "\u{2026}" : "")).foregroundStyle(row.faint ? Neon.textSecondary : Neon.textPrimary)
                        .lineLimit(XrayPromptRow.answerLines).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(Neon.font(11))
            .padding(.vertical, sz(2))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.spoken)
    }
}

struct XrayMemoryRowView: View {
    let row: XrayMemoryRow
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: sz(6)) {
                Text(verbatim: row.title).foregroundStyle(Neon.textPrimary).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                Text(verbatim: row.detail).foregroundStyle(Neon.textSecondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: sz(4))
                ForEach([row.session, row.age].compactMap { $0 }, id: \.self) {
                    Text(verbatim: $0).foregroundStyle(Neon.textSecondary).lineLimit(1).fixedSize()
                }
            }
            .font(Neon.font(11))
            .padding(.vertical, sz(2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.spoken)
    }
}

/// #1352, the memory card (design 3.2, 3.7): path, kind, scope, updated, then the body as plain text (never Markdown),
/// its combining marks capped (OutsideText.capMarks); the cut and unreadable notes; "Read the prompt" when the memory
/// was written or loaded in this session at a known prompt.
struct XrayMemoryCard: View {
    let item: XrayMemory.Item
    var now = Date()
    var note: String?
    let readPrompt: (() -> Void)?

    static let size = CGSize(width: 380, height: 360)

    static func canRead(_ m: XrayMemory.Item) -> Bool { m.sessionWord != nil && m.chapter != nil }

    static func fields(_ m: XrayMemory.Item, now: Date) -> [(label: String, value: String)] {
        let pairs: [(String, String?)] = [("Path", OutsideText.shown(m.path, max: 160)), ("Kind", m.kindWord), ("Scope", m.scopeWord),
                                          ("Updated", XrayTaskRow.age(m.updated, now: now)?.spoken)]
        return pairs.compactMap { p -> (label: String, value: String)? in
            guard let v = p.1, !v.isEmpty else { return nil }
            return (p.0, v)
        }
    }

    /// The body as drawn: marks capped again here (the item may not come from the parse); nil: "not readable".
    static func bodyText(_ m: XrayMemory.Item) -> String? { m.body.map { OutsideText.capMarks($0) } }

    /// The notes under the body.
    static func notes(_ m: XrayMemory.Item) -> [String] {
        (m.body == nil ? ["not readable"] : []) + (m.cut ? ["cut at 16 KB: see \(OutsideText.shown(m.path, max: 160))"] : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(8)) {
            Text(verbatim: item.title).font(Neon.font(12, weight: .semibold)).foregroundStyle(Neon.textPrimary).lineLimit(2)
            ForEach(Array(Self.fields(item, now: now).enumerated()), id: \.offset) { _, f in
                HStack(alignment: .firstTextBaseline, spacing: sz(6)) {
                    Text(verbatim: f.label).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
                    Text(verbatim: f.value).font(Neon.font(11)).foregroundStyle(Neon.textPrimary).lineLimit(1).truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(f.label): \(f.value)")
            }
            if let b = Self.bodyText(item) {
                ScrollView {
                    Text(verbatim: b).font(Neon.font(11)).foregroundStyle(Neon.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .accessibilityLabel("Body")
            }
            ForEach(Self.notes(item) + [note].compactMap { $0 }, id: \.self) {
                Text(verbatim: $0).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
            }
            if let readPrompt {
                Button("Read the prompt", action: readPrompt)
                    .keyboardShortcut(.defaultAction)   // Return in the card (design 3.2)
                    .accessibilityLabel("Read the prompt that changed this memory")
            }
        }
        .padding(sz(12))
    }
}

/// The task card (design 3.2): title in full, status and label, doing, note, times, blocked by, group, URL; Open
/// (http/https only, the raw url, and only when it is the shown one) and Copy (Pasteboard.swift).
struct XrayTaskCard: View {
    let task: XrayTasks.Task
    let now: Date
    let open: (URL) -> Void
    /// #1352: "older than the loaded part" when a jump could not reach the prompt.
    var note: String?

    static let size = CGSize(width: 360, height: 320)

    /// The labelled fields, in order; a field with no value is left out.
    static func fields(_ t: XrayTasks.Task, now: Date) -> [(label: String, value: String)] {
        let status = XrayTaskRow.statusName(t.status) + (XrayTaskRow.label(t).map { " (\($0))" } ?? "")
        let pairs: [(String, String?)] = [
            ("Title", t.title), ("Status", status), ("Doing", t.status == .active ? t.active : nil), ("Note", t.note),
            ("Created", XrayTaskRow.age(t.created, now: now)?.spoken), ("Updated", XrayTaskRow.age(t.updated, now: now)?.spoken),
            ("Blocked by", t.blockedBy.isEmpty ? nil : t.blockedBy.joined(separator: ", ")), ("Group", t.group), ("URL", t.url),
        ]
        return pairs.compactMap { p -> (label: String, value: String)? in
            guard let v = p.1, !v.isEmpty else { return nil }
            return (p.0, v)
        }
    }

    /// The raw url, re-checked: http or https with a host, else nil (shown as text only).
    static func openable(_ raw: String?) -> URL? {
        guard let raw, let u = URL(string: raw), let s = u.scheme?.lowercased(), s == "http" || s == "https",
              u.host?.isEmpty == false else { return nil }
        return u
    }

    static func copyText(_ t: XrayTasks.Task, now: Date) -> String {
        fields(t, now: now).map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }

    /// R1351-s1: Open only when the shown url is the raw one (cleaning dropped nothing and capped nothing); else text only.
    static func openURL(_ t: XrayTasks.Task) -> URL? { t.url == t.rawURL ? openable(t.rawURL) : nil }

    func openLink() { if let u = Self.openURL(task) { open(u) } }

    func copy() {
        Pasteboard.general.clearContents()
        Pasteboard.general.setString(Self.copyText(task, now: now), forType: .string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(8)) {
            ScrollView {
                VStack(alignment: .leading, spacing: sz(6)) {
                    ForEach(Array(Self.fields(task, now: now).enumerated()), id: \.offset) { _, f in
                        VStack(alignment: .leading, spacing: sz(1)) {
                            Text(verbatim: f.label).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
                            Text(verbatim: f.value).font(Neon.font(11.5)).foregroundStyle(Neon.textPrimary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(f.label): \(f.value)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let note { Text(verbatim: note).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary) }
            HStack(spacing: sz(8)) {
                if Self.openURL(task) != nil {
                    Button("Open", action: openLink).accessibilityLabel("Open the task's link")
                }
                Button("Copy", action: copy).accessibilityLabel("Copy the task")
            }
        }
        .padding(sz(12))
    }
}

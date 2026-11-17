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

/// The tabs in dch's order (xview.c xv_ord); #1415: Refs between Responses and Search.
enum XrayTab: String, CaseIterable {
    case prompts = "Prompts", responses = "Responses", refs = "Refs", search = "Search", tasks = "Tasks", memory = "Memory"
}

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
    /// #1355: dch README "dch --xray <n> --search <text> --json"; the text is checked by DchCtl.searchOK first.
    func searchArgs(_ text: String) -> [String] { ["--xray", name, "--search", text, "--json"] }
    /// #1472 b: dch.1 "dch --xray <n> --chapter <anchor> --json" (host:name for remote); the anchor is checked first.
    func chapterArgs(_ anchor: String) -> [String] { ["--xray", name, "--chapter", anchor, "--json"] }
    /// #1410: a local name takes the text on stdin ("-" in argv), so it never shows in ps; a remote one keeps
    /// it in argv (dch reads "-" there as the text itself; the serve path hides it). #1442: dch 1.84.0 reads stdin for
    /// every local name, one with ":" included. #1443: older dch (1.78 to 1.83) reads "-" as the text itself, so stdin
    /// only for a probed `version` at stdinMinimum or later; unknown (nil: no probe yet) goes in argv.
    func viaStdin(_ text: String, version: [Int]?) -> (arg: String, stdin: Data?) {
        dir == nil || !(version.map { DchCommand.isAtLeast($0, Self.stdinMinimum) } ?? false)
            ? (text, nil) : ("-", Data((text + "\n").utf8))
    }
    static let stdinMinimum = [1, 84, 0]
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

    /// #1416: the one --ref read in flight (XrayRefCard.swift runRef / closeRef); a new one or a card close cancels it.
    var refReading: Task<Void, Never>?

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

    /// #1463: a tab chosen in the strip is remembered (Preferences.xrayLastTab). Off under XCTest so no row leaks its
    /// choice into another row's default open; rows that pin it set it and restore it.
    static var rememberTab: @MainActor () -> Bool = { NSClassFromString("XCTestCase") == nil }

    /// #1355: a new panel has a Search tab. Off under XCTest so the existing rows keep their exact tab sets; rows set
    /// XrayPanelModel.searchable themselves.
    static var searchTab: @MainActor () -> Bool = { NSClassFromString("XCTestCase") == nil }

    /// #1415 (gate A): the Refs tab and its reads. #1417: on in the product (the ref card ships); off under XCTest as
    /// searchTab is, so the rows that pin exact tab sets and read counts keep them; rows set it and restore it.
    static let refsTabShips = true
    static var refsTab: @MainActor () -> Bool = { refsTabShips && NSClassFromString("XCTestCase") == nil }

    /// The focused pane's mode through the window model (no model or another pane focused: no read).
    static func fromDch(_ pane: UUID, _ target: XrayTarget) -> Bool {
        guard let m = model(pane), m.layout.focused == pane else { return false }
        return target.dir == nil || m.paneMode != .transcript
    }

    /// #1352: the window's presenter, the transcript, the link opener and the cwd, for the panel that came to `pane`.
    func wire(_ m: XrayPanelModel, _ pane: UUID) {   // #1418: and XrayRefLink.panel, for a transcript link's card
        let target = m.target
        // #1417: `closed` runs once when the card goes, whoever closed it (the ref card cancels its --ref read there)
        func show(_ view: AnyView, _ size: CGSize, _ closed: @escaping @MainActor () -> Void) {
            guard let w = Self.window(pane), let anchor = XrayCardAnchor.view(for: pane, in: w) ?? w.contentView else { return closed() }
            w.cards.present(view, size: size, anchor: anchor, closed: closed)
        }
        m.present = { show($0, $1) {} }
        m.presentRef = { show($0, $1, $2) }
        m.panels = self
        m.dismiss = { Self.window(pane)?.cards.close() }
        m.transcript = { Self.transcript(pane, target) }
        m.fromDch = { Self.chaptersRead(pane, target) }
        m.openURL = { Self.model(pane)?.openURL($0) }
        m.cwd = { Self.cwd(pane, target) }
    }

    /// #1475: the follows (XrayFollow.swift): one per target, shared by the panels showing it, kept in an LRU.
    let follows = XrayFollows()

    /// The transcript model's cwd; #1472: without one (Terminal mode, a remote row) dch's, from the row that shows
    /// `target` (AgentSession.cwd from dch's list, a remote row's cwd); "" (dch did not say) is none.
    static func cwd(_ pane: UUID, _ target: XrayTarget) -> String? {
        guard let m = model(pane) else { return nil }
        if let c = m.focusedRuntime?.transcript.cwd { return c }
        guard let r = m.selectedRow, XrayTarget.of(r) == target else { return nil }
        return [r.session?.cwd, r.remote?.cwd ?? nil].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// One dch run: (path, argv, env) -> (exit status, stdout); -1 when it never ran or timed out.
    typealias Run = @Sendable (_ path: String, _ args: [String], _ env: [String: String]) async -> (status: Int32, out: Data)

    /// #1410: the bytes `run` writes to the child's stdin, bound around one call (XrayTarget.viaStdin); nil: none.
    nonisolated static let stdin = TaskLocal<Data?>(wrappedValue: nil)

    /// The product's: the shared runCapturingBoth, bounded like a Remote Terminal call. Never under XCTest (rows put a
    /// fake here; no row runs a real dch).
    static var run: Run = { path, args, env in
        guard NSClassFromString("XCTestCase") == nil else { return (-1, Data()) }
        let child = XrayChild(), input = XrayPanels.stdin.get()   // #1368: a cancelled read (panel closed, session switched) SIGTERMs its dch
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                DispatchQueue.global(qos: .utility).async {
                    c.resume(returning: runBounded(child, path, args, env, outputLimit: maxReadBytes, stdin: input))
                }
            }
        } onCancel: { child.cancel() }
    }

    /// #1405: the most stdout one X-ray read keeps: the largest parser cap (XrayChapters' 16 MiB; Tasks and Memory cap
    /// lines and rows, not bytes). Past it the read stops, dch is ended and the answer is `overCap`.
    nonisolated static let maxReadBytes = XrayChapters.maxBytes

    /// #1407: the status of a read that went past maxReadBytes. Int32.min: a dch exit is 0...255 and the timeout (and a
    /// launch that failed) is -1, so no other answer shares it. The readers treat it as a refusal, never as unreachable.
    nonisolated static let overCap = Int32.min

    /// `run`'s blocking body, lifted so a row can drive it with a recorder child (R1380-s2): the exit is marked on the
    /// child (#1380) and on `bounded`, so neither a cancel nor the timeout signals a reaped dch's pid (R1380-s1).
    nonisolated static func runBounded(_ child: XrayChild, _ path: String, _ args: [String], _ env: [String: String],
                           timeout: TimeInterval = DchCommand.remoteTimeout, outputLimit: Int? = nil,
                           terminate: @escaping @Sendable (pid_t) -> Void = DchCommand.sigkill, stdin: Data? = nil) -> (status: Int32, out: Data) {
        let r = DchCommand.bounded(timeout, terminate: terminate) { onPid, onExit in
            DchCommand.runCapturingBoth(args: args, env: env, path: path, onPid: { onPid($0); child.started($0) },
                                        onExit: { onExit(); child.reaped() },
                                        outputLimit: outputLimit.map { ($0, terminate) }, stdin: stdin)
        }
        return r.map { ($0.status, $0.out) } ?? (-1, Data())
    }

    /// The dch path X-ray runs, when it passes XrayTabs.gate (1.78.0); nil below it: no item, no route, no process.
    static var dch: @MainActor () -> String? = { if case .ok(let path) = XrayTabs.gate(probed) { path } else { nil } }

    /// The bundled (else installed) dch's version, probed off main by `warm`; nil until then and under XCTest.
    static var probed: DchCommand.Binary?   // internal: rows set it (#1443)

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
    /// #1415: the refs of dch's `--json` read (gate A on only); nil: none read. "Show all kinds" (dch `a`).
    @Published var refs: XrayRefs?
    @Published var showAllRefs = false
    /// #1416: the ref card's data from the last --ref read (XrayPanels.runRef), or why it has none.
    @Published var refContext: XrayRefContext?
    @Published var refNote: String?
    /// #1417: the Refs row whose card was asked for last; the panels whose --ref read it runs (XrayPanels.open wires it).
    @Published private(set) var refCard: XrayRefs.Entry?
    weak var panels: XrayPanels?
    /// #1389: this pane reads dch's chapters (XrayPanels.chaptersRead); false: never runs that read.
    var fromDch: () -> Bool = { false }
    /// #1355: the Search tab is there (false once dch answered exit 1, does not know --search, or 6, refused); the
    /// query typed, the last answer's hits (nil before a search) and the line that says why nothing ran or came.
    @Published var searchable: Bool
    @Published var query = ""
    @Published var search: XraySearch?
    @Published var searchNote: String?
    /// #1355 (R1355-i1): why the Search tab went (exit 1 or 6), said where the strip lands; a new panel has none.
    @Published var searchGone: String?
    @Published private(set) var loaded = false
    @Published var tab: XrayTab
    @Published var filter = ""
    @Published var filterFocused = false
    /// The task whose card was asked for last (the presenter shows it).
    @Published private(set) var card: XrayTasks.Task?
    /// #1352: the memory whose card was asked for last.
    @Published private(set) var memoryCard: XrayMemory.Item?
    /// #1472: the chapter whose card was asked for last (no transcript: a Prompts or Responses row, Read the prompt).
    @Published private(set) var chapterCard: TranscriptOutline.Chapter?
    /// #1472 b: that card's --chapter read (XrayChapterRead), cancelled when the card closes.
    private(set) var chapterRead: XrayChapterRead?
    /// #1472: dch's chapter anchors to their `i` (ordinal); #1475: from every chapters read and the follow's state.
    var chapterAnchors: [String: Int] = [:]
    /// #1475: the follow this panel's chapters and refs come from (XrayFollow.swift); nil: today's reads and polls.
    var follow: XrayFollow?
    var followSinks: Set<AnyCancellable> = []
    /// #1475: when this panel attached its follow (now()); the first snapshot is bounded from here (XrayPoller tick).
    var followSince: Date?
    /// #1475: the open's Tasks and Memory reads answered; with a follow the open ends at its first snapshot too.
    var answered = false
    var reading: Task<Void, Never>?   // the open read or a poll (XrayPoller.swift)
    /// #1368: the poller's state (XrayPoller.swift): the read's dch and runner, when the last read started, the dch
    /// path's mtime after a failed read (no retry until it moves), exit 4/7's "host unreachable", the ticker's stop.
    var dch: String?
    var run: XrayPanels.Run?
    var lastRead = Date.distantPast
    var failed = false
    var failedMtime: Date?
    /// #1407: the Tasks read went past the byte limit (XrayPanels.overCap): not read again while this panel is open.
    var tasksRefused = false
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
    /// #1417: as present, with the presenter's `closed` (the ref card's --ref cancel).
    var presentRef: (AnyView, CGSize, @escaping @MainActor () -> Void) -> Void = { _, _, _ in }
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
        searchable = XrayPanels.searchTab()
        panels = XrayPanels.shared
    }

    /// The one read on open: both forms, so the strip knows which tabs exist.
    func read(dch: String, run: @escaping XrayPanels.Run) {
        (self.dch, self.run) = (dch, run)
        if stopTicker == nil { stopTicker = XrayPanels.ticker { [weak self] in self?.tick() } }
        attachFollow(dch)   // #1475: before readBoth, so the open's chapters come from the stream (cached: at once)
        readBoth()
    }

    /// Both forms; again from the poller when a cancel left the panel unread (#1368).
    func readBoth() {
        guard let dch, let run else { return }
        lastRead = now()
        let env = target.env, a = target.args("tasks"), b = target.args("memory")
        // #1389: the third read only for a dch-chapters pane; #1415: or, gate A on, for a Transcript pane's refs alone
        // #1475: a follow carries the chapters and refs: no chapters read beside it
        let refsOnly = !fromDch(), c = follow == nil && (!refsOnly || XrayPanels.refsTab()) ? target.chaptersArgs : nil
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
            self?.apply(tasks: tr, memory: mr, chapters: kr, refsOnly: refsOnly)
        }
    }

    func apply(tasks tr: (status: Int32, out: Data), memory mr: (status: Int32, out: Data),
               chapters kr: (status: Int32, out: Data)? = nil, refsOnly: Bool = false) {
        take(tr)
        takeMemory(mr)
        if let kr { if refsOnly { takeRefs(kr) } else { takeChapters(kr) } }
        answered = true
        if follow == nil || follow?.state != nil { finishOpen() }   // #1475: else the first snapshot finishes it
    }

    /// The open is done: the strip draws; the Todos chip's fallback when there is no Tasks tab.
    func finishOpen() {
        loaded = true
        if let fallback, tasks == nil {
            if isCurrent() { close(); fallback() }   // another session now shown: the list never opens over it
            return
        }
        if !tabs.contains(tab), let first = tabs.first { tab = first }
    }

    /// #1475: this panel reads its chapters and refs from the target's follow (XrayFollows.attach): a Terminal-mode or
    /// remote pane, or a Transcript pane's refs with the Refs tab on, as readBoth's chapters read; nil from attach (gate
    /// closed, no room) keeps today's reads. A state already there (a session read before) shows on this frame.
    func attachFollow(_ dch: String) {
        guard follow == nil, fromDch() || XrayPanels.refsTab(), let panels,
              let f = panels.follows.attach(target, dch: dch) else { return }
        follow = f
        followSince = now()
        f.$state.sink { [weak self] s in self?.takeFollow(s) }.store(in: &followSinks)
        f.$failed.sink { [weak self] gone in if gone { self?.followFailed() } }.store(in: &followSinks)
    }

    /// #1475: the follow's state: dch's chapters (a dch-chapters pane) and refs (the Refs tab on). The first one ends
    /// the open when Tasks and Memory answered; before them it draws the cached rows at once (no "Reading").
    func takeFollow(_ s: XrayFollow.State?) {
        guard let s, !stopped else { return }
        if fromDch() { (dchChapters, chapterAnchors) = (s.chapters, s.anchors) }
        if XrayPanels.refsTab() { refs = s.refs }
        // #1475 c: the stream's Tasks and Memory replace the reads' (a reset keeps the rows until its blocks come)
        if let t = s.tasks { tasks = Self.tasksTab(t) }
        if let m = s.memory { memory = m.count == 0 ? nil : m }
        if loaded, s.tasks != nil || s.memory != nil, !tabs.contains(tab), let first = tabs.first { tab = first }
        guard !loaded else { return }
        if answered { finishOpen() } else if fallback == nil { loaded = true }   // the chip's list waits for its Tasks
    }

    /// #1475: the follow ended before any snapshot (an older host's exit 2, no such session, unreachable): today's reads.
    func followFailed() {
        followSinks = []
        follow = nil
        guard !stopped else { return }
        cancel()
        answered = false
        readBoth()
    }

    /// #1475: no first snapshot within DchCommand.remoteTimeout of the attach (a hung ssh, a stalled dch), as today's
    /// chapters read is bounded by runBounded: that follow ends, leaves the LRU, and today's reads run (followFailed).
    func giveUpFollow() {
        if let follow { panels?.follows.drop(follow) }
        followFailed()
    }

    /// #1475: the panel leaves: the follow keeps running for the next open (the LRU ends it).
    func detachFollow() {
        followSinks = []
        if let follow { panels?.follows.detach(follow) }
        follow = nil
    }

    func takeMemory(_ mr: (status: Int32, out: Data)) {
        memory = mr.status == 0 ? XrayMemory.parse(mr.out) : nil
        if memory?.count == 0 { memory = nil }
    }

    /// #1352: a tab chosen in the strip; Memory is read again then: at once, or (#1381, R1352-i1) when the read in
    /// flight ends. The 30 s Memory poll is the poller's (XrayPoller.swift).
    func select(_ t: XrayTab) {
        tab = t
        if XrayPanels.rememberTab() { Preferences.xrayLastTab = t }   // #1463: only the person's choice, never a jump
        // #1415: a Transcript pane reads its refs again on a switch to Refs: at once, or at the next tick after the read
        if t == .refs, loaded, !fromDch(), follow == nil {   // #1475: a follow keeps the refs live
            if reading == nil, let dch, let run { readChapters(dch, run) } else { lastRead = .distantPast }
        }
        guard t == .memory, loaded, follow?.carriesTasks != true else { return }   // #1475 c: the stream keeps it
        if reading != nil { pendingMemory = true } else { readMemory() }
    }

    /// Design 3.9 and QA R1349-i2: a Tasks tab only for exit 0, header schema 1 and at least one task.
    static func tasksTab(_ r: (status: Int32, out: Data)) -> XrayTasks? {
        r.status == 0 ? tasksTab(XrayTasks.parse(r.out)) : nil
    }

    /// #1475 c: the same rule for a parse in hand (a follow's tasks block).
    static func tasksTab(_ t: XrayTasks) -> XrayTasks? { t.schema == 1 && !t.tasks.isEmpty ? t : nil }

    /// #1354: Prompts and Responses while the pane's transcript is there (Transcript mode, a local session); #1389: or
    /// while dch's chapters read answered (Terminal mode, remote).
    var tabs: [XrayTab] {
        let prose = transcript() != nil || dchChapters != nil
        return XrayTab.allCases.filter {
            switch $0 {
            case .prompts, .responses: prose
            case .refs: XrayPanels.refsTab() && refs?.entries.isEmpty == false
            case .search: searchable
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
        case .refs: refs?.entries.count ?? 0   // #1415: every ref, hidden kinds included (dch's rule)
        case .search: search?.hits.count ?? 0
        case .tasks: tasks?.open ?? 0
        case .memory: memory?.count ?? 0
        }
    }
    /// "Tasks 3" (open tasks), "Memory 2" (every row); #1355: "Search" before a search, "Search 50+" past dch's cap;
    /// #1415: "Refs \u{2265}3" while dch says its list is not complete.
    func title(_ tab: XrayTab) -> String {
        tab == .search && search == nil ? tab.rawValue
            : "\(tab.rawValue) \(tab == .refs && refs?.complete == false ? "\u{2265}" : "")\(count(tab))\(tab == .search && search?.more == true ? "+" : "")"
    }
    /// VoiceOver: "Tasks, 3 open"; "Memory, 2".
    func spoken(_ tab: XrayTab) -> String { tab == .tasks ? "Tasks, \(count(tab)) open" : title(tab).replacingOccurrences(of: " ", with: ", ") }

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
        if let g = searchGone { out.append(g) }   // R1355-i1
        return out
    }

    /// #1353 (R1381-i1): the Memory tab's footer: "host unreachable" when the last read did not reach the host; #1389:
    /// Prompts' and Responses' too.
    var memoryFooter: [String] { unreachable ? ["host unreachable"] : [] }

    /// R1355-i1: what the empty state draws: its text, then why Search went (an older dch usually lacks Tasks too).
    var emptyLines: [String] { ["No tasks or memory for this session"] + (searchGone.map { [$0] } ?? []) }

    /// R1355-i1: the footer of the tabs the strip lands on: memoryFooter, then why Search went.
    var goneFooter: [String] { memoryFooter + (searchGone.map { [$0] } ?? []) }

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
    /// #1472: Read the prompt with no transcript, for a prompt dch's chapters read does not hold (not read, newer, gone).
    static let notReadNote = "The prompt is not among the chapters read."

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
    /// #1472: without a transcript (Terminal mode, remote) the prompt's chapter card; a prompt not among the chapters
    /// read: the memory card again with the note, never nothing.
    func readPrompt(_ m: XrayMemory.Item) {
        guard XrayMemoryCard.canRead(m) else { return }
        guard transcript() != nil else {
            let i = m.chapter.flatMap { chapterAnchors[$0] }
            guard let c = dchChapters?.last(where: { $0.ordinal == i }) else { return openMemoryCard(m, note: Self.notReadNote) }
            return openChapterCard(c)
        }
        go(m.chapter) { [weak self] older in if older { self?.openMemoryCard(m, note: Self.olderNote) } }
    }

    /// The jump; `card(older)` runs when it did not land.
    func go(_ anchor: String?, card: @escaping @MainActor (Bool) -> Void) {
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

    /// Return or a click on a Prompts or Responses row: the pane's transcript jumps to that chapter (#1319's seam);
    /// #1472: no transcript (Terminal mode, remote): the chapter's card.
    func activate(_ c: TranscriptOutline.Chapter) {
        guard let tm = transcript() else { return openChapterCard(c) }
        TranscriptJumper.of(tm).jump(to: c)
    }

    /// #1472: the prompt and its response through the window's presenter, as the memory card. #1472 b: it opens with
    /// what dch's chapters gave and runs one --chapter read for the chapter's anchor (none known, or one that is not
    /// dch's shape: no read); the card's close, or the next card, cancels that read (the product runner SIGTERMs dch).
    func openChapterCard(_ c: TranscriptOutline.Chapter) {
        chapterCard = c
        chapterRead?.cancel()
        let read = XrayChapterRead()
        chapterRead = read
        if let anchor = chapterAnchors.filter({ $0.value == c.ordinal }).keys.min(), DchCtl.anchorOK(anchor),
           !anchor.hasPrefix("-"), let dch, let run {
            let a = target.chapterArgs(anchor), env = target.env
            read.reading = Task { [weak read] in
                let r = await run(dch, a, env)
                guard !Task.isCancelled, let read else { return }   // cancelled: the SIGTERMed answer is not news
                read.take(r)
            }
        }
        presentRef(AnyView(XrayChapterCard(chapter: c, read: read, refs: refs?.entries ?? [],
                                           link: { [weak self] in self?.openLink($0) ?? .discarded })),
                   XrayChapterCard.size) { [weak read] in read?.cancel() }
    }

    /// #1472: a link in the chapter card (XrayRefScope's rule for the transcript's): a ref of this panel's read opens
    /// its ref card; http/https go to the system; anything else is dropped.
    func openLink(_ url: URL) -> XrayRefLink.Outcome {
        XrayRefLink.open(url, refs: refs) { [weak self] in self?.openRef($0) }
    }

    /// #1472: dch's `anchor` -> `i` for each chapter, by XrayChapters.parse's rules (schema 1, the newest maxRows, `i`
    /// else the place in the list); empty for anything else.
    static func anchors(_ data: Data) -> [String: Int] {
        guard data.count <= XrayChapters.maxBytes, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return anchors(o)
    }

    /// #1475: the same of an object in hand (a follow's state, XrayFollow.swift).
    static func anchors(_ o: [String: Any]) -> [String: Int] {
        guard o["schema"] as? Int == 1, let list = o["chapters"] as? [Any] else { return [:] }
        var out: [String: Int] = [:]
        for (k, c) in list.suffix(XrayChapters.maxRows).compactMap({ $0 as? [String: Any] }).enumerated() {
            guard let a = c["anchor"] as? String else { continue }
            out[a] = (c["i"] as? Int).flatMap { (1...Int(Int32.max)).contains($0) ? $0 : nil } ?? k + 1
        }
        return out
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

    // MARK: #1415 Refs

    /// Case-insensitive, over the ref's text and its title.
    static func matches(_ e: XrayRefs.Entry, _ filter: String) -> Bool {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || e.text.localizedCaseInsensitiveContains(q) || e.title.localizedCaseInsensitiveContains(q)
    }

    /// The rows in dch's order with the filter applied; issues, pulls and tickets unless "Show all kinds".
    var shownRefs: [XrayRefs.Entry] {
        (refs?.ordered ?? []).filter { Self.matches($0, filter) && (showAllRefs || XrayRefs.byDefault($0)) }
    }

    /// The footer's toggle (dch `a`): "2 files, commits and links hidden" + Show all kinds, or Hide; none without such a row.
    var refsToggle: (text: String?, button: String)? {
        let n = (refs?.entries ?? []).filter { Self.matches($0, filter) && !XrayRefs.byDefault($0) }.count
        guard n > 0 else { return nil }
        return showAllRefs ? (nil, "Hide files, commits and links") : ("\(n) files, commits and links hidden", "Show all kinds")
    }

    /// R1415-i1 (b): a filter that leaves no row says so (a list of hidden kinds alone has the toggle's line instead).
    var refsEmpty: String? {
        shownRefs.isEmpty && !filter.trimmingCharacters(in: .whitespaces).isEmpty ? "No refs match" : nil
    }

    /// #1417: Return or a click on a Refs row: its card at once (header from the row), then the --ref read fills it. The
    /// card's close, however it goes (presenter closed, Esc, Search), cancels that read (XrayPanels.closeRef).
    func openRef(_ e: XrayRefs.Entry) {
        refCard = e
        (refContext, refNote) = (nil, nil)
        let panels = panels
        if panels?.runRef(e.text, for: self) != true { refNote = Self.refNotARef }   // refused: nothing runs
        let read = panels?.refReading
        presentRef(AnyView(XrayRefPopover(panel: self, entry: e, complete: refs?.complete ?? true)), XrayRefPopover.size) { [weak panels] in
            panels?.closeRef(started: read)
        }
    }

    /// "N more refs not indexed" (dch's dropped_keys), then "host unreachable" and why Search went.
    var refsFooter: [String] {
        let n = refs?.droppedKeys ?? 0
        return (n > 0 ? ["\(n) more refs not indexed"] : []) + goneFooter
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
            VStack(alignment: .leading, spacing: sz(4)) {
                ForEach(panel.emptyLines, id: \.self) { faint($0) }
            }.padding(sz(10))
        } else if panel.tab == .memory {
            memoryTab
        } else if panel.tab == .search {
            searchTab
        } else if panel.tab == .refs {
            refsTab
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
            ForEach(panel.goneFooter, id: \.self) { faint($0) }   // #1389: "host unreachable"
        }
        .padding(sz(10))
    }

    /// #1355: the query runs on Return (never per keystroke, never polled); a hit does nothing yet (P8/P9).
    var searchTab: some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            TextField("Search", text: $panel.query)
                .textFieldStyle(.roundedBorder)
                .font(Neon.font(11))
                .focused($filterFocus)
                .onSubmit { panel.runSearch() }
                .accessibilityLabel("Search this session")
            if let n = panel.searchNote { faint(n) }
            if let s = panel.search {
                if s.hits.isEmpty { faint("No hits") }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: sz(4)) {
                        ForEach(Array(s.hits.enumerated()), id: \.offset) { _, h in
                            XraySearchRowView(row: XraySearchRow(h, now: panel.now()))
                        }
                    }
                }
            }
            ForEach(panel.searchFooter, id: \.self) { faint($0) }
        }
        .padding(sz(10))
    }

    /// #1415: the Refs list; #1417: a row opens its card.
    var refsTab: some View {
        let complete = panel.refs?.complete ?? true
        return VStack(alignment: .leading, spacing: sz(4)) {
            TextField("Filter", text: $panel.filter)
                .textFieldStyle(.roundedBorder)
                .font(Neon.font(11))
                .focused($filterFocus)
                .accessibilityLabel("Filter refs")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(panel.shownRefs.enumerated()), id: \.offset) { _, e in
                        XrayRefRowView(row: XrayRefRow(e, complete: complete, home: panel.home, cwd: panel.cwd())) { panel.openRef(e) }
                    }
                }
            }
            if let n = panel.refsEmpty { faint(n) }
            if let f = panel.refsToggle {
                HStack(spacing: sz(6)) {
                    if let t = f.text { faint(t) }
                    Button(f.button) { panel.showAllRefs.toggle() }.buttonStyle(.link).font(Neon.font(10, weight: .medium))
                }
            }
            ForEach(panel.refsFooter, id: \.self) { faint($0) }
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
            ForEach(panel.goneFooter, id: \.self) { faint($0) }
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

/// #1354: a Prompts or Responses row; a click (or Return / Space with VoiceOver) jumps to its chapter (#1472: or,
/// with no transcript, opens its card).
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

/// #1355: one Search hit; not a button yet (P8/P9 open the hit's prompt).
struct XraySearchRowView: View {
    let row: XraySearchRow

    var body: some View {
        VStack(alignment: .leading, spacing: sz(1)) {
            HStack(spacing: sz(6)) {
                Text(verbatim: row.who).foregroundStyle(Neon.textSecondary).lineLimit(1)
                if let a = row.age { Text(verbatim: a).foregroundStyle(Neon.textSecondary).fixedSize() }
            }
            Text(verbatim: row.snippet).foregroundStyle(Neon.textPrimary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .font(Neon.font(11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.spoken)
    }
}

/// #1415: one Refs row: bold when defined or mentioned twice, the title faint, the count at the right.
struct XrayRefRowView: View {
    let row: XrayRefRow
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: sz(6)) {
                Text(verbatim: row.text).fontWeight(row.bold ? .semibold : .regular).foregroundStyle(Neon.textPrimary)
                    .lineLimit(1).truncationMode(.head).layoutPriority(1)
                if !row.title.isEmpty {
                    Text(verbatim: row.title).foregroundStyle(Neon.textSecondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: sz(4))
                Text(verbatim: row.count).foregroundStyle(Neon.textSecondary).fixedSize()
            }
            .font(Neon.font(11))
            .padding(.vertical, sz(2))
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

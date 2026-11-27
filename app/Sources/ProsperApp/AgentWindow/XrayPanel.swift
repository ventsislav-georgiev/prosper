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

/// The tabs in dch's order (xview.c xv_ord); #1415: Refs before Search. #1815 (operator 11-21): no Responses tab, a
/// prompt's card shows its answer. #1974: Questions (dch 1.171.0's `--questions`) after Tasks. #2014: Schedules last, as dch.
enum XrayTab: String, CaseIterable {
    case prompts = "Prompts", refs = "Refs", search = "Search", tasks = "Tasks", questions = "Questions", memory = "Memory"
    case schedules = "Schedules"
}

/// The session a read names: a local one by name in its socket dir, a remote one as "host:name" (design 3.5).
struct XrayTarget: Hashable {
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
    /// #1611: `scope` "project" (dch 1.110.0, #498) adds the other sessions' hits, grouped; nil: one session, as before.
    func searchArgs(_ text: String, scope: String? = nil) -> [String] {
        ["--xray", name, "--search", text] + (scope.map { ["--scope", $0] } ?? []) + ["--json"]
    }
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
    static let shared: XrayPanels = {   // #1561: its warm connections close on the Agents window's hide and close
        let p = XrayPanels()
        p.requests.observe(.default)
        return p
    }()
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

    /// #1389, #1471: the pane reads its Prompts and Responses from dch, a local row as a remote one. Off under XCTest as `run` is: rows put `fromDch` here.
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

    /// #1974: the open reads `--questions` too (an older dch refuses it: no tab). Off under XCTest as searchTab is, so the
    /// rows that pin read counts keep them; rows set it and restore it.
    static var questionsTab: @MainActor () -> Bool = { NSClassFromString("XCTestCase") == nil }

    /// #1471: every pane reads dch (Terminal is the only mode); no window model for `pane`: no read.
    static func fromDch(_ pane: UUID, _ target: XrayTarget) -> Bool { model(pane) != nil }

    /// #1352: the window's presenter, the transcript, the link opener and the cwd, for the panel that came to `pane`.
    func wire(_ m: XrayPanelModel, _ pane: UUID) {   // #1418: and XrayRefLink.panel, for a transcript link's card
        let target = m.target
        // #1417: `closed` runs once when the card goes, whoever closed it (the ref card cancels its --ref read there)
        func show(_ view: AnyView, _ size: CGSize, push: Bool = false, _ closed: @escaping @MainActor () -> Void) {
            guard let w = Self.window(pane), let anchor = XrayCardAnchor.view(for: pane, in: w) ?? w.contentView else { return closed() }
            if push { w.cards.push(view, size: size, anchor: anchor, closed: closed) } else { w.cards.present(view, size: size, anchor: anchor, closed: closed) }
        }
        m.present = { show($0, $1) {} }
        m.presentRef = { show($0, $1, $2) }
        m.pushRef = { show($0, $1, push: true, $2) }
        m.panels = self
        m.dismiss = { Self.window(pane)?.cards.close() }
        m.fromDch = { Self.chaptersRead(pane, target) }
        m.openURL = { Self.model(pane)?.openURL($0) }
        m.cwd = { Self.cwd(pane, target) }
        m.liveNames = { Self.liveNames(pane, target) }   // #2024
        m.refResults = { XrayRefResults.on() ? Self.window(pane).map { XrayRefResults.of($0) } : nil }   // #1567
        // #1611: a local panel's group opens its session to the side; a remote one's sessions are the host's: none
        m.openSession = { g in
            guard target.dir != nil, let w = Self.model(pane), let id = XraySearch.row(g, in: w.rows) else { return false }
            w.openToTheSide(id)
            return true
        }
    }

    /// #1475: the follows (XrayFollow.swift): one per target, shared by the panels showing it, kept in an LRU.
    let follows = XrayFollows()

    /// #1976: a closed panel's rows, for the next open of its target (a target with no follow, or whose follow has no
    /// Tasks and Memory, draws them on its first frame). The newest XrayFollows.limit targets; the oldest goes.
    struct Kept {
        var tasks: XrayTasks? = nil
        var questions: XrayTasks? = nil   // #1974
        var memory: XrayMemory? = nil
        var chapters: [TranscriptOutline.Chapter]? = nil
        var refs: XrayRefs? = nil
        var corpus: XrayChapters.Corpus? = nil
        var anchors: [String: Int]
    }
    private(set) var kept: [XrayTarget: Kept] = [:]
    private var keptOrder: [XrayTarget] = []
    func keep(_ t: XrayTarget, _ k: Kept) {
        keptOrder.removeAll { $0 == t }
        keptOrder.append(t)
        kept[t] = k
        if keptOrder.count > XrayFollows.limit { kept[keptOrder.removeFirst()] = nil }
    }
    /// #1976: off under XCTest as searchTab is, so no row's rows leak into another row's open; rows set it and restore it.
    static var keepRows: @MainActor () -> Bool = { NSClassFromString("XCTestCase") == nil }

    /// #1561: the warm `--requests` connections (XrayRequests.swift): a remote panel's request forms go through them.
    let requests = XrayRequests()

    /// #1471: the session's cwd, from the row that shows `target` (AgentSession.cwd from dch's list, a remote row's
    /// cwd); "" (dch did not say) is none, and then the cwd the session's transcript file names, as before #1471.
    static func cwd(_ pane: UUID, _ target: XrayTarget) -> String? {
        guard let m = model(pane) else { return nil }
        if let r = m.selectedRow, XrayTarget.of(r) == target,
           let c = [r.session?.cwd, r.remote?.cwd ?? nil].compactMap({ $0 }).first(where: { !$0.isEmpty }) { return c }
        return m.focusedRuntime?.transcript.cwd
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

    /// #1476 b: sets `probed` and tells the views that read the gate (the header X-ray buttons drew off before it).
    @MainActor static func publish(_ b: DchCommand.Binary?) {
        probed = b
        shared.objectWillChange.send()
    }

    /// shortcut: probed once per window open, so a dch upgrade shows on the next open; re-probe per toggle if needed.
    static func warm() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let path = DchCommand.dchPath
            let b = DchCommand.probedVersion(path).map { DchCommand.Binary(path: path, version: $0) }
            Task { @MainActor in publish(b) }
        }
    }
}

/// One pane's panel: what the read found, the shown tab and the filter.
@MainActor
final class XrayPanelModel: ObservableObject {
    let target: XrayTarget
    /// nil: no Tasks tab (design 3.9: exit not 0, a schema other than 1, an empty list, a shell).
    @Published var tasks: XrayTasks? {   // set here and by the poller (XrayPoller.swift)
        didSet { if tasks != oldValue { taskColsMemo = nil } }
    }
    /// #1974: nil: no Questions tab (Tasks' rule: exit not 0, a schema other than 1, no row; an older dch refuses the form).
    @Published var questions: XrayTasks? {   // set by the open read and the poller (XrayPoller.swift), never by the follow
        didSet { if questions != oldValue { questionColsMemo = nil } }
    }
    /// #2024 (XrayAnswer.swift): the Open question the answer editor is on (as it was when opened, so a row that moves or
    /// goes keeps the editor and its text), the text typed, the one status line and the clock time it goes (the poller's
    /// ticker clears it: no timer of its own), the Send in flight, and the live session names next to this drawer's.
    @Published var answerQuestion: XrayTasks.Task?
    @Published var answerText = ""
    @Published var answerLine: String?
    var answerLineUntil: Date?
    @Published var sending = false
    var answerTask: Task<Void, Never>?
    var liveNames: @MainActor () -> Set<String> = { [] }
    /// nil: no Memory tab (exit not 0, no row).
    @Published private(set) var memory: XrayMemory? {
        didSet { if memory != oldValue { memoryColsMemo = nil } }
    }
    /// #2014: the follow's schedules block (XraySchedules.swift); nil: no block (or a shell's). Never read on its own.
    @Published var schedules: XraySchedules?
    /// #2014: why the Schedules tab has no rows (the host refused `--follow --schedules`); nil: none.
    @Published var schedulesNote: String?
    /// #2014: the countdowns' clock last sent (schedulesTick) and the redraws it sent (the cost row counts them).
    var schedulesClock: Int?
    var schedulesRedraws = 0
    /// #1389: Prompts and Responses from dch's chapters (Terminal mode, remote); nil: none (not read, exit not 0, bad JSON).
    @Published var dchChapters: [TranscriptOutline.Chapter]?
    /// #1566: the corpus fields of the same read or snapshot (the header's second line); nil: none said.
    @Published var corpus: XrayChapters.Corpus?
    /// #1415: the refs of dch's `--json` read (gate A on only); nil: none read. "Show all kinds" (dch `a`).
    @Published var refs: XrayRefs? {
        didSet { if refs != oldValue { refCountMemo = nil } }
    }
    @Published var showAllRefs = false { didSet { if showAllRefs != oldValue { listChanged() } } }
    /// #1416: the ref card's data from the last --ref read (XrayPanels.runRef), or why it has none.
    @Published var refContext: XrayRefContext?
    @Published var refNote: String?
    /// #1417: the Refs row whose card was asked for last; the panels whose --ref read it runs (XrayPanels.open wires it).
    @Published private(set) var refCard: XrayRefs.Entry?
    weak var panels: XrayPanels?
    /// #1567: the window's --ref result cache (XrayPanels.wire); nil: none, every ask reads (rows set it).
    var refResults: @MainActor () -> XrayRefResults? = { nil }
    /// #1389: this pane reads dch's chapters (XrayPanels.chaptersRead); false: never runs that read.
    var fromDch: () -> Bool = { false }
    /// #1355: the Search tab is there (false once dch answered exit 1, does not know --search, or 6, refused); the
    /// query typed, the last answer's hits (nil before a search) and the line that says why nothing ran or came.
    @Published var searchable: Bool
    @Published var query = ""
    @Published var search: XraySearch?
    @Published var searchNote: String?
    /// #1611: this panel's remote host refused `--scope` once (exit 1): its later searches run unscoped (runSearch).
    var unscopedHost = false
    /// #1611: "open that session" for a Search group (XrayPanels.wire); rows put a recorder. false: no row matched.
    var openSession: @MainActor (XraySearch.Group) -> Bool = { _ in false }
    /// #1355 (R1355-i1): why the Search tab went (exit 1 or 6), said where the strip lands; a new panel has none.
    @Published var searchGone: String?
    @Published private(set) var loaded = false
    @Published var tab: XrayTab {
        didSet { if tab != oldValue { topRow = nil } }   // #1972: another tab's list starts at its top
    }
    /// #1972 (operator 2026-11-26, "Keep scroll anchored"): the id of the top row the person sees in the shown tab's list
    /// (#1979: the row at the top edge writes it while they scroll, XrayScrollRow; not published: a scroll redraws nothing).
    var topRow: String?
    /// #1979: the points scrolled past topRow's top (its row's geometry writes it, XrayScrollRow; unpublished as topRow).
    var topOffset: CGFloat = 0
    /// #1979 (QA n3): bumped by a filter keystroke or a chip toggle; XrayAnchoredScroll compares it to tell those
    /// (the list starts at its top) from a poll or follow update (the reader's row is kept).
    private(set) var listGen = 0
    /// #1979: the offset to add once the restored row lands flush at the top (XrayAnchoredScroll, settled(_:)).
    var settle: CGFloat?
    /// #1972 (QA f2): the clock minute the Tasks and Memory ages were last sent for (XrayPoller tick).
    var agesMinute: Int?
    @Published var filter = "" { didSet { if filter != oldValue { listChanged() } } }
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
    var quiet = XrayQuiet()   // #1636: the poller's idle backoff (XrayPoller.swift)
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
    /// #1352 seams, wired by XrayPanels.open: any card through the window's presenter, its close, the link opener, the
    /// session's cwd (instruction paths are shown relative to it). #1471: no transcript jump; a row opens its card.
    var present: (AnyView, CGSize) -> Void = { _, _ in }
    /// #1417: as present, with the presenter's `closed` (the ref card's --ref cancel).
    var presentRef: (AnyView, CGSize, @escaping @MainActor () -> Void) -> Void = { _, _, _ in }
    /// #1944: as presentRef, for a card opened from inside a card (the presenter's push: Back returns); nil: presentRef.
    var pushRef: ((AnyView, CGSize, @escaping @MainActor () -> Void) -> Void)?
    var dismiss: () -> Void = {}
    var openURL: (URL) -> Void = { _ in }
    var cwd: () -> String? = { nil }
    var home = NSHomeDirectory()
    /// The Todos chip's: run instead of keeping the panel when the read finds no Tasks tab (Q3).
    var fallback: (() -> Void)?
    /// #1354: Prompts shows the automatic rows (dch `n`, off at open) / hides other sessions' messages (`a`); #1815: the
    /// hide is the person's saved choice (Preferences.xrayHideAgentMessages, on unless set off), stored only behind the
    /// rememberTab seam as the last tab is.
    @Published var showAuto = false { didSet { if showAuto != oldValue { listChanged() } } }
    @Published var hidePeer = Preferences.xrayHideAgentMessages {
        didSet {
            if hidePeer != oldValue { listChanged() }   // #1979
            if XrayPanels.rememberTab() { Preferences.xrayHideAgentMessages = hidePeer }
        }
    }
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
        (self.dch, self.run) = (dch, panels?.requests.run(for: target, cold: run) ?? run)   // #1561: remote: warm
        if stopTicker == nil { stopTicker = XrayPanels.ticker { [weak self] in self?.tick() } }
        // #1976: the last rows, on this frame; #1974 n2: never for the Todos chip, whose Tasks answer alone decides (kept
        // rows and an unreachable host's kept-rows answer would skip its fallback and show stale rows)
        if !answered, fallback == nil, XrayPanels.keepRows(), let k = panels?.kept[target] { seed(k) }
        attachFollow(dch)   // #1475: before readBoth, so the open's chapters come from the stream (cached: at once)
        readBoth()
    }

    /// Both forms; again from the poller when a cancel left the panel unread (#1368).
    func readBoth() {
        guard let dch, let run else { return }
        lastRead = now()
        let env = target.env, a = target.args("tasks"), b = target.args("memory")
        let q = XrayPanels.questionsTab() ? target.args("questions") : nil   // #1974
        // #1389: the third read only for a dch-chapters pane; #1415: or, gate A on, for a Transcript pane's refs alone
        // #1475: a follow carries the chapters and refs: no chapters read beside it
        let refsOnly = !fromDch(), c = follow == nil && (!refsOnly || XrayPanels.refsTab()) ? target.chaptersArgs : nil
        let chapters: @Sendable () async -> (status: Int32, out: Data)? = {
            guard let c else { return nil }
            return await run(dch, c, env)
        }
        let questions: @Sendable () async -> (status: Int32, out: Data)? = {
            guard let q else { return nil }
            return await run(dch, q, env)
        }
        // #1976: each read is taken as it answers (the chapters read, 1.5 s on a big session, gates no tab)
        reading = Task { [weak self] in
            await withTaskGroup(of: (Int, (status: Int32, out: Data)?).self) { g in
                g.addTask { (0, await run(dch, a, env)) }
                g.addTask { (1, await run(dch, b, env)) }
                g.addTask { (2, await chapters()) }
                g.addTask { (3, await questions()) }
                for await (k, r) in g {
                    // #1368: closed or switched away: the SIGTERMed answer is not news; #1974: the reads still out end too
                    guard !Task.isCancelled, let self else { g.cancelAll(); return }
                    guard let r else { continue }
                    switch k {
                    case 0: self.take(r)
                    case 1: self.takeMemory(r)
                    case 3: self.takeQuestions(r)
                    default: self.takeChapters(r, refsOnly: refsOnly)
                    }
                    self.openStep(tasksIn: k == 0)
                }
            }
            guard !Task.isCancelled else { return }
            self?.reading = nil
            self?.answeredAll()
        }
    }

    func apply(tasks tr: (status: Int32, out: Data), memory mr: (status: Int32, out: Data),
               chapters kr: (status: Int32, out: Data)? = nil, refsOnly: Bool = false) {
        take(tr)
        takeMemory(mr)
        if let kr { takeChapters(kr, refsOnly: refsOnly) }
        answeredAll()
    }

    func takeChapters(_ r: (status: Int32, out: Data), refsOnly: Bool) { if refsOnly { takeRefs(r) } else { takeChapters(r) } }

    /// The open's reads all answered.
    func answeredAll() {
        answered = true
        if follow == nil || follow?.state != nil { finishOpen() }   // #1475: else the first snapshot finishes it
        // #1974 n1: an open drawn early whose answers removed the shown tab moves now, not at a snapshot that may not come
        else if loaded, !tabs.contains(tab), let first = tabs.first { tab = first }
    }

    /// #1976: one open read answered (or the kept rows were drawn): the shown tab draws once its rows are in, before
    /// the other reads; the Todos chip's list decides at the Tasks answer (never on kept rows or another read).
    func openStep(tasksIn: Bool) {
        guard !loaded else { return }
        if fallback != nil { if tasksIn { finishOpen() } } else if tabs.contains(tab) { loaded = true }
    }

    /// The open is done: the strip draws; the Todos chip's fallback when there is no Tasks tab.
    func finishOpen() {
        if !loaded { loaded = true }   // #1976: an open drawn early publishes nothing more when the rest answer unchanged
        if let fallback, tasks == nil {
            self.fallback = nil   // #1976: once (the Tasks answer decides; the end of the open does not again)
            if isCurrent() { close(); fallback() }   // another session now shown: the list never opens over it
            return
        }
        if !tabs.contains(tab), let first = tabs.first { tab = first }
    }

    /// #1976: the rows a closed panel for this target had; the fresh reads replace them through put (changes only).
    func seed(_ k: XrayPanels.Kept) {
        put(\.tasks, k.tasks); put(\.questions, k.questions); put(\.memory, k.memory); put(\.dchChapters, k.chapters); put(\.refs, k.refs); put(\.corpus, k.corpus)
        chapterAnchors = k.anchors
        openStep(tasksIn: false)
    }

    /// #1976: what a new panel for this target draws first (XrayPanels.keep, on stop).
    var keptRows: XrayPanels.Kept {
        XrayPanels.Kept(tasks: tasks, questions: questions, memory: memory, chapters: dchChapters, refs: refs, corpus: corpus, anchors: chapterAnchors)
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
        if fromDch() { put(\.dchChapters, s.chapters); chapterAnchors = s.anchors; put(\.corpus, s.corpus) }   // #1972: changes only
        if XrayPanels.refsTab() { put(\.refs, s.refs) }
        // #1475 c: the stream's Tasks and Memory replace the reads' (a reset keeps the rows until its blocks come)
        // #1972: the same rows as the open's reads publish nothing: the drawer does not redraw under the reader
        if let t = s.tasks { put(\.tasks, Self.tasksTab(t)) }
        if let m = s.memory { put(\.memory, m.count == 0 ? nil : m) }
        if let sc = s.schedules { put(\.schedules, Self.schedulesTab(sc)) }   // #2014
        // #2035: the note only for an agent session (the snapshot's corpus), never a shell
        if follow?.schedulesRefused == true, let c = s.corpus?.corpus, c == "claude" || c == "codex" {
            put(\.schedulesNote, "needs dch \(DchCommand.versionString(XrayFollow.schedulesDch))")   // #2014: the host's older dch
        }
        if loaded, s.tasks != nil || s.memory != nil || s.schedules != nil, !tabs.contains(tab), let first = tabs.first { tab = first }
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
        let m = mr.status == 0 ? XrayMemory.parse(mr.out) : nil
        put(\.memory, m?.count == 0 ? nil : m)   // #1972: one publish at most (it was two for an empty list), none when unchanged
    }

    /// #1972: sets a published value only when it changed (@Published sends on every set, an equal one too).
    func put<T: Equatable>(_ k: ReferenceWritableKeyPath<XrayPanelModel, T>, _ v: T) {
        if self[keyPath: k] != v { self[keyPath: k] = v }
    }

    /// #1972 (QA f2): put() leaves a quiet ledger's rows unsent, so the ticker sends one change when the clock minute
    /// turns while Tasks or Memory shows: their ages ("5m", "3h") are drawn from now() and move with it.
    func agesTick() {
        let m = minute()
        if m != agesMinute { agesMinute = m; objectWillChange.send() }
    }

    /// #1972: after the shown list's ids went from `old` to `new`: the row to put back at the top and (#1979) the points
    /// past its top, armed in `settle` (nil: leave the scroll).
    func restoreTop(old: [String], new: [String]) -> XrayScrollAnchor.Top? {
        settle = nil
        let r = XrayScrollAnchor.restore(old: old, new: new, anchor: topRow.map { .init(id: $0, offset: topOffset) })
        if let r { (topRow, topOffset, settle) = (r.id, r.offset, r.offset > 0 ? r.offset : nil) }
        return r
    }

    /// #1979 (QA n3): a filter or chip change: the shown list starts at its top.
    func listChanged() {
        listGen &+= 1
        (topRow, topOffset, settle) = (nil, 0, nil)
    }

    /// #1979: the shown list went from `old` to `new`: its top after a filter or chip change, else the reader's row.
    func shownChanged(old: XrayScrollAnchor.Shown, new: XrayScrollAnchor.Shown) -> XrayScrollAnchor.Move? {
        if old.gen != new.gen { (topRow, topOffset, settle) = (nil, 0, nil); return .top }
        return restoreTop(old: old.ids, new: new.ids).map { .row($0) }
    }

    /// #1979: a row straddling the list's top edge, `offset` points past its top (XrayScrollRow).
    func scrolled(_ id: String, offset: CGFloat) {
        (topRow, topOffset) = (id, offset)
    }

    /// #1979: the scroll's y once the restored row landed flush at the top: the y to scroll on to (its offset added), once.
    func settled(_ y: CGFloat) -> CGFloat? {
        defer { settle = nil }
        return settle.map { y + $0 }
    }

    /// #1352: a tab chosen in the strip; Memory is read again then: at once, or (#1381, R1352-i1) when the read in
    /// flight ends. The 30 s Memory poll is the poller's (XrayPoller.swift).
    func select(_ t: XrayTab) {
        tab = t
        quiet.reset()   // #1636
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

    /// #1354, #1389: Prompts while dch's chapters read answered.
    var tabs: [XrayTab] {
        let prose = dchChapters != nil
        return XrayTab.allCases.filter {
            switch $0 {
            case .prompts: prose
            case .refs: XrayPanels.refsTab() && refs?.entries.isEmpty == false
            case .search: searchable
            case .tasks: tasks != nil
            case .questions: questions != nil
            case .memory: memory != nil
            case .schedules: schedules != nil || schedulesNote != nil   // #2014: from the follow only
            }
        }
    }

    /// Design 3.1: Prompts = rows listed.
    func count(_ tab: XrayTab) -> Int {
        switch tab {
        case .prompts: shownPrompts.count
        case .refs: refs?.entries.count ?? 0   // #1415: every ref, hidden kinds included (dch's rule)
        case .search: search?.hits.count ?? 0
        case .tasks: tasks?.open ?? 0
        case .questions: questions?.open ?? 0   // #1974: open questions, as Tasks counts open tasks
        case .memory: memory?.count ?? 0
        case .schedules: schedules?.pendingCount ?? 0   // #2014: pending rows
        }
    }
    /// "Tasks 3" (open tasks), "Memory 2" (every row); #1355: "Search" before a search, "Search 50+" past dch's cap;
    /// #1415: "Refs \u{2265}3" while dch says its list is not complete.
    func title(_ tab: XrayTab) -> String {
        tab == .schedules && schedules?.loopActive == true ? "\(tab.rawValue) \(count(tab)) \u{21BB}"   // #2014: the /loop marker
            : tab == .search && search == nil ? tab.rawValue
            : "\(tab.rawValue) \(tab == .refs && refs?.complete == false ? "\u{2265}" : "")\(count(tab))\(tab == .search && search?.more == true ? "+" : "")"
    }
    /// VoiceOver: "Tasks, 3 open"; #1974 "Questions, 2 open"; "Memory, 2".
    func spoken(_ tab: XrayTab) -> String {
        tab == .schedules ? "Schedules, \(count(tab)) pending" + (schedules?.loopActive == true ? ", loop active" : "")
            : tab == .tasks || tab == .questions ? "\(tab.rawValue), \(count(tab)) open" : title(tab).replacingOccurrences(of: " ", with: ", ")
    }

    /// Design 3.2: case-insensitive, over id, title, note and label.
    static func matches(_ t: XrayTasks.Task, _ filter: String) -> Bool {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || [t.id, t.title, t.note ?? "", t.label].contains { $0.localizedCaseInsensitiveContains(q) }
    }

    /// The groups with the filter applied; an empty group goes, with or without a filter (#1381, as Memory's).
    var shownGroups: [XrayTasks.Group] { filtered(tasks?.groups ?? []) }

    /// #1974: the Questions tab's groups (Open, Answered, Dropped) with the filter applied, as shownGroups.
    var shownQuestionGroups: [XrayTasks.Group] { filtered(questions?.questionGroups ?? []) }

    private func filtered(_ groups: [XrayTasks.Group]) -> [XrayTasks.Group] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return groups.map { XrayTasks.Group(title: $0.title, tasks: $0.tasks.filter { Self.matches($0, q) }) }
            .filter { !$0.tasks.isEmpty }
    }

    /// #1815: shownGroups as the list draws it, one id per line ("g<i>" a header, "g<i>.<j>" its task). The view had a
    /// ForEach per group inside a LazyVStack, which flattens them: each group's ids were 0, 1, ... again, rows sharing an
    /// id went undrawn, and the operator saw an empty gap under "Pending" (op-1121-36).
    /// #1972: the ids are stable across polls ("h:" the group's title, "t:" the task's id; a repeat made unique), so a
    /// new task above keeps the reader's row (XrayAnchoredScroll).
    var taskLines: [XrayTaskLine] { Self.lines(shownGroups, row: "t:") }

    /// #1974: the Questions list as drawn: "h:" a group's header, "q:" a question's id (unique), as taskLines.
    var questionLines: [XrayTaskLine] { Self.lines(shownQuestionGroups, row: "q:") }

    private static func lines(_ groups: [XrayTasks.Group], row: String) -> [XrayTaskLine] {
        let lines = groups.flatMap { g in
            [XrayTaskLine(id: "h:" + g.title, header: "\(g.title) \(g.tasks.count)", task: nil)]
                + g.tasks.map { t in XrayTaskLine(id: row + t.id, header: nil, task: t) }
        }
        return zip(XrayScrollAnchor.unique(lines.map(\.id)), lines).map { XrayTaskLine(id: $0, header: $1.header, task: $1.task) }
    }

    /// #1972: each shown prompt under a stable id: its dch anchor (from the same read), else its block id.
    func promptLines(_ rows: [TranscriptOutline.Chapter]) -> [(id: String, c: TranscriptOutline.Chapter)] {
        let anchor = Dictionary(chapterAnchors.map { ($0.value, $0.key) }, uniquingKeysWith: min)   // as openChapterCard's
        return zip(XrayScrollAnchor.unique(rows.map { anchor[$0.ordinal].map { "a:" + $0 } ?? "c:\($0.id)" }), rows).map { (id: $0, c: $1) }
    }

    /// #1972: each shown ref under its text (unique).
    var refLines: [(id: String, e: XrayRefs.Entry)] {
        let rows = shownRefs
        return zip(XrayScrollAnchor.unique(rows.map { "r:" + $0.text }), rows).map { (id: $0, e: $1) }
    }

    /// #1972: the Memory list as drawn, one stable id per line: "h:" a group's header, "m:" a memory's id.
    var memoryLines: [(id: String, header: String?, item: XrayMemory.Item?)] {
        let lines = shownMemory.flatMap { g in
            [(id: "h:" + g.title, header: Optional("\(g.title) \(g.items.count)"), item: XrayMemory.Item?.none)]
                + g.items.map { (id: "m:" + $0.id, header: String?.none, item: Optional($0)) }
        }
        return zip(XrayScrollAnchor.unique(lines.map(\.id)), lines).map { (id: $0, header: $1.header, item: $1.item) }
    }

    // #1948: the list columns' widths over ALL items (so they hold while the filter types), computed from the source
    // fields, once per change of the data (and per clock minute for the ages), never per body.
    private var taskColsMemo: (minute: Int, cols: XrayTaskCols)?
    private var questionColsMemo: (minute: Int, cols: XrayTaskCols)?
    /// #1974: counts the Questions width computations (as colsBuilt).
    private(set) var questionColsBuilt = 0
    private var memoryColsMemo: (minute: Int, session: String, age: String)?
    private var refCountMemo: (complete: Bool, widest: String)?
    /// Counts the width computations (tests read it: N bodies, one computation).
    private(set) var colsBuilt = (tasks: 0, refs: 0, memory: 0)

    private func minute() -> Int { Int(max(-1e12, min(now().timeIntervalSince1970 / 60, 1e12)).rounded(.down)) }

    var taskCols: XrayTaskCols {
        let m = minute()
        if let c = taskColsMemo, c.minute == m { return c.cols }
        colsBuilt.tasks += 1
        let cols = XrayTaskCols(tasks: (tasks?.groups ?? []).flatMap(\.tasks), now: now())
        taskColsMemo = (m, cols)
        return cols
    }

    /// #1974: the Questions list's widths, as taskCols (over every question, once per change and clock minute).
    var questionCols: XrayTaskCols {
        let m = minute()
        if let c = questionColsMemo, c.minute == m { return c.cols }
        questionColsBuilt += 1
        let cols = XrayTaskCols(tasks: questions?.tasks ?? [], now: now())
        questionColsMemo = (m, cols)
        return cols
    }

    var memoryCols: (session: String, age: String) {
        let m = minute()
        if let c = memoryColsMemo, c.minute == m { return (c.session, c.age) }
        colsBuilt.memory += 1
        let items = (memory?.groups ?? []).flatMap(\.items), at = now()
        let s = XrayCol.widest(items.map { $0.sessionWord.flatMap { $0.isEmpty ? nil : $0 } })
        let a = XrayCol.widest(items.map { XrayTaskRow.age($0.updated, now: at)?.short })
        memoryColsMemo = (m, s, a)
        return (s, a)
    }

    /// The widest count of every ref, with the "\u{2265}" an incomplete read puts before it.
    var refCountWidest: String {
        let complete = refs?.complete ?? true
        if let c = refCountMemo, c.complete == complete { return c.widest }
        colsBuilt.refs += 1
        let w = XrayCol.widest((refs?.ordered ?? []).map { (complete ? "" : "\u{2265}") + "\($0.count)" })
        refCountMemo = (complete, w)
        return w
    }

    /// "Tasks \u{00B7} <title>" for a command list; nil otherwise.
    var listTitle: String? {
        guard tasks?.source == "command", let t = tasks?.sessionTitle, !t.isEmpty else { return nil }
        return "Tasks \u{00B7} \(t)"
    }

    /// #1566 (design 3.9, 5.5): the header's second line: dch's corpus label, then a shell's "counts in the last N
    /// rows" while dch read only part of its ring (why "range"); nil when dch's view shows none.
    var corpusLine: String? {
        let parts = [corpus?.label, corpus?.rangeNote].compactMap { $0 }
        return parts.isEmpty ? nil : OutsideText.shown(parts.joined(separator: XrayChapters.Corpus.dot), max: 240)
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
    /// Prompts' too.
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

    /// #1472: Read the prompt with no transcript, for a prompt dch's chapters read does not hold (not read, newer, gone).
    static let notReadNote = "The prompt is not among the prompts read."

    /// Return or a click on a task row: its card (#1471: no transcript jump).
    func activate(_ t: XrayTasks.Task) { openCard(t) }

    /// Return or a click on a memory row: its card.
    func openMemoryCard(_ m: XrayMemory.Item, note: String? = nil) {
        memoryCard = m
        let read: (() -> Void)? = XrayMemoryCard.canRead(m) ? { [weak self] in self?.readPrompt(m) } : nil
        present(AnyView(XrayMemoryCard(item: m, now: now(), note: note, readPrompt: read, match: filter)), XrayMemoryCard.size)
    }

    /// The card's "Read the prompt" (#1472, #1471: every pane): the prompt's chapter card; a prompt not among the
    /// chapters read: the memory card again with the note, never nothing.
    func readPrompt(_ m: XrayMemory.Item) {
        guard XrayMemoryCard.canRead(m) else { return }
        let i = m.chapter.flatMap { chapterAnchors[$0] }
        guard let c = dchChapters?.last(where: { $0.ordinal == i }) else { return openMemoryCard(m, note: Self.notReadNote) }
        openChapterCard(c, fromCard: true)
    }

    // MARK: #1354 Prompts

    /// The pane's chapters: dch's (#1389, #1471); a new poll or page redraws the panel.
    var chapters: [TranscriptOutline.Chapter] { dchChapters ?? [] }

    /// dch xv_vis1 (xview.c:2283-2297): the filter (title), then auto rows unless shown, then peer rows when hidden;
    /// newest first. `auto` / `peer`: true shows those rows whatever the toggles say (the footer's counts).
    func shown(_ tab: XrayTab, auto: Bool? = nil, peer: Bool? = nil) -> [TranscriptOutline.Chapter] {
        let (all, keepPeer) = (auto ?? self.showAuto, peer ?? !self.hidePeer)
        let q = filter.trimmingCharacters(in: .whitespaces)
        return chapters.reversed().filter { c in
            (q.isEmpty || c.title.localizedCaseInsensitiveContains(q))
                && (all || !c.auto) && (keepPeer || c.from != .peer)
        }
    }
    var shownPrompts: [TranscriptOutline.Chapter] { shown(.prompts) }

    /// The automatic rows and the other sessions' messages on `tab` (filter applied, shown or not): the footer's counts.
    func hidden(_ tab: XrayTab) -> (auto: Int, peer: Int) {
        let all = shown(tab, auto: true, peer: true)
        return (all.filter(\.auto).count, all.filter { $0.from == .peer }.count)
    }

    /// #1950: the filter bar's chips (dch xview.c:3563-3575's toggles): "Automatic" and "Agent messages", each with the
    /// number of such rows on the tab (filter applied, shown or hidden); none when the tab has no such row.
    func promptFooter(_ tab: XrayTab) -> [XrayFilterChip] {
        let n = hidden(tab)
        var out: [XrayFilterChip] = []
        if n.auto > 0 {
            out.append(XrayFilterChip(label: "Automatic", count: n.auto, shown: showAuto) { [weak self] in self?.showAuto.toggle() })
        }
        if n.peer > 0 {
            out.append(XrayFilterChip(label: "Agent messages", count: n.peer, shown: !hidePeer) { [weak self] in self?.hidePeer.toggle() })
        }
        return out
    }

    /// Return or a click on a Prompts or Responses row: the chapter's card (#1472; #1471: every pane).
    func activate(_ c: TranscriptOutline.Chapter) { openChapterCard(c) }

    /// #1472: the prompt and its response through the window's presenter, as the memory card. #1472 b: it opens with
    /// what dch's chapters gave and runs one --chapter read for the chapter's anchor (none known, or one that is not
    /// dch's shape: no read); the card's close, or the next card, cancels that read (the product runner SIGTERMs dch).
    /// #1944: `fromCard` (a ref card's arrow or turn, Read the prompt): pushed over that card, whose read goes on until it
    /// leaves the stack (its own `closed`).
    func openChapterCard(_ c: TranscriptOutline.Chapter, fromCard: Bool = false) {
        chapterCard = c
        if !fromCard { chapterRead?.cancel() }
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
        (fromCard ? pushRef ?? presentRef : presentRef)(AnyView(XrayChapterCard(chapter: c, read: read, refs: refs?.entries ?? [],
                                           link: { [weak self] in self?.openLink($0) ?? .discarded }, match: filter)),
                   XrayChapterCard.size) { [weak read] in read?.cancel() }
    }

    /// #1472: a link in the chapter card (XrayRefLink.open's rule): a ref of this panel's read opens
    /// its ref card; http, https and mailto: go to the system; anything else is dropped.
    func openLink(_ url: URL) -> XrayRefLink.Outcome {
        XrayRefLink.open(url, refs: refs) { [weak self] in self?.openRef($0, fromCard: true) }   // #1944: over the chapter card
    }

    /// #1472: dch's `anchor` -> `i` for each chapter, by XrayChapters.parse's rules (schema 1, the newest maxRows, `i`
    /// else the place in the list); empty for anything else.
    static func anchors(_ data: Data) -> [String: Int] {
        guard data.count <= XrayChapters.maxBytes, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return anchors(o)
    }

    /// #1475: the same of an object in hand (a follow's state, XrayFollow.swift).
    nonisolated static func anchors(_ o: [String: Any]) -> [String: Int] {   // #1631: a follow's build runs off main
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

    /// #1955: the filter bar's chip (dch `a`): "Files, commits and links" with the number of such refs (filter applied,
    /// shown or hidden); none without such a row.
    var refsChips: [XrayFilterChip] {
        let n = (refs?.entries ?? []).filter { Self.matches($0, filter) && !XrayRefs.byDefault($0) }.count
        guard n > 0 else { return [] }
        return [XrayFilterChip(label: "Files, commits and links", count: n, shown: showAllRefs) { [weak self] in self?.showAllRefs.toggle() }]
    }

    /// R1415-i1 (b): a filter that leaves no row says so (a list of hidden kinds alone has the toggle's line instead).
    var refsEmpty: String? {
        shownRefs.isEmpty && !filter.trimmingCharacters(in: .whitespaces).isEmpty ? "No refs match" : nil
    }

    /// #1417: Return or a click on a Refs row: its card at once (header from the row), then the --ref read fills it. The
    /// card's close, however it goes (presenter closed, Esc, Search), cancels that read (XrayPanels.closeRef).
    /// #1944: `fromCard` (a chapter card's link): pushed; the one --ref read is this card's now, so its close puts back
    /// the ref card state it replaced, for a ref card under it.
    func openRef(_ e: XrayRefs.Entry, fromCard: Bool = false) {
        // shortcut: a ref card under this one whose read had not landed comes back as it was (its read was cancelled);
        // re-read on Back if that shows up as stuck cards.
        let before = fromCard ? (refCard, refContext, refNote) : nil
        refCard = e
        (refContext, refNote) = (nil, nil)
        let panels = panels
        // #1489: dch keys a term by its bare text; --ref wants it in backticks (a text holding one is no ref).
        let sent = e.shape == .term ? (e.text.contains("`") ? "" : "`" + e.text + "`") : e.text
        if panels?.runRef(sent, shown: e.text, staged: true, for: self) != true {   // refused: nothing runs; #1824: light first
            refNote = panels?.refTooLong(sent, for: self) == true ? Self.refTooLong : Self.refNotARef
        }
        let read = panels?.refReading
        (fromCard ? pushRef ?? presentRef : presentRef)(AnyView(XrayRefPopover(panel: self, entry: e, complete: refs?.complete ?? true)),
                                                       XrayRefPopover.size) { [weak panels, weak self] in
            panels?.closeRef(started: read)
            if let before, let self { (self.refCard, self.refContext, self.refNote) = before }
        }
    }

    /// "N more refs not indexed" (dch's dropped_keys), then "host unreachable" and why Search went.
    var refsFooter: [String] {
        let n = refs?.droppedKeys ?? 0
        return (n > 0 ? ["\(n) more refs not indexed"] : []) + goneFooter
    }
}

/// #1354: one Prompts row as drawn and spoken (design 3.2, 3.7, 3.8): the number, dch's mark (xview.c:2404 xv_mark: a
/// robot and the sender for another session's message, an inbox and the name for a subagent's hand-back, a bell for
/// another automatic prompt), the title (faint for an automatic row). #1815: the answer is the card's (no Responses tab).
struct XrayPromptRow: Equatable {
    let ordinal: String
    let mark: String?
    /// #1546: a peer's message: the view draws RobotGlyph before `mark` (the sender; "" when it has none), not an emoji.
    let robot: Bool
    let title: String
    let faint: Bool
    let spoken: String

    static func mark(_ c: TranscriptOutline.Chapter) -> String? {
        let sender = OutsideText.shown(c.peer ?? "", max: 40)
        if isRobot(c) { return sender }
        let symbol: String? = c.peer == nil ? (c.auto && c.kind != .compaction ? "\u{1F514}" : nil) : "\u{1F4E5}"
        guard let symbol else { return nil }
        return sender.isEmpty ? symbol : symbol + " " + sender
    }
    static func isRobot(_ c: TranscriptOutline.Chapter) -> Bool { c.peer != nil && !c.auto }

    init(_ c: TranscriptOutline.Chapter) {
        ordinal = "\(c.ordinal)"
        mark = Self.mark(c)
        robot = Self.isRobot(c)
        title = OutsideText.shown(c.title, max: TranscriptOutline.titleCap)
        faint = c.auto
        let sender = OutsideText.shown(c.peer ?? "", max: 40), who: String
        switch c.from {
        case .own: who = "Prompt \(c.ordinal)"
        case .auto where c.peer != nil: who = "Hand-back" + (sender.isEmpty ? "" : " from " + sender) + ", prompt \(c.ordinal)"
        case .auto: who = "Automatic prompt \(c.ordinal)"
        case .peer: who = "Message from " + (sender.isEmpty ? "another session" : sender) + ", prompt \(c.ordinal)"
        }
        spoken = who + ", " + title
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
        blocked = t.blockedBy.isEmpty ? nil : "Blocked by \(t.blockedBy.joined(separator: ", "))"   // #1956: the tooltip; the row shows a link mark
        let a = Self.age(t.updated ?? t.created, now: now)
        age = a?.short
        spoken = (["\(Self.statusName(t.status)) task \(t.id)", title, label, t.blockedBy.isEmpty ? nil : "blocked by \(t.blockedBy.joined(separator: ", "))", a?.spoken].compactMap { $0 })
            .joined(separator: ", ")
    }
}

// MARK: - Views

/// #1473: the drawer's width, one for every pane and window, remembered per Mac (Preferences.xrayDrawerWidth) in points at
/// UI scale 1.0 and drawn times the scale. Dragging the drawer's leading edge resizes it; a double-click there resets it.
@MainActor
final class XrayDrawerWidth: ObservableObject {
    static let shared = XrayDrawerWidth()
    /// The default fits every tab's name at UI scale 0.7 to 1.0 (XrayDrawerWidthTests measures the strip); the narrowest
    /// usable width; the largest share of the space offered.
    static let standard: CGFloat = 420, minimum: CGFloat = 300, share: CGFloat = 0.6
    @Published private(set) var points: CGFloat = Preferences.xrayDrawerWidth.map { CGFloat($0) } ?? XrayDrawerWidth.standard
    /// The drawn width when the drag began; nil between drags.
    private var start: CGFloat?
    var dragging: Bool { start != nil }

    /// The drawn width: the stored points times the scale, at most `share` of `offered` but not under the minimum, and
    /// never past `offered` (R1351-n1: the overlay is offered the pane's width, or the pane area's in splits).
    static func width(stored: CGFloat, offered: CGFloat, scale: CGFloat = ThemeRuntime.scale) -> CGFloat {
        max(0, min(offered, max(minimum * scale, min(stored * scale, offered * share))))
    }

    /// The leading edge moved `dx` points since the drag began (left is negative: wider). Stored as drawn, clamped.
    func dragged(by dx: CGFloat, offered: CGFloat, scale: CGFloat = ThemeRuntime.scale) {
        let from = start ?? Self.width(stored: points, offered: offered, scale: scale)
        start = from
        points = Self.width(stored: (from - dx) / scale, offered: offered, scale: scale) / scale
    }

    /// The drag is over: the width is written once (while dragging only the in-memory value moves).
    func ended() {
        start = nil
        Preferences.xrayDrawerWidth = Double(points)
    }

    func reset() {
        start = nil
        points = Self.standard
        Preferences.xrayDrawerWidth = nil
    }
}

/// The drawer over `pane`, drawn only while its panel is open for the session the pane shows.
struct XrayDrawer: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var panels = XrayPanels.shared
    @ObservedObject var width = XrayDrawerWidth.shared
    let pane: UUID
    let target: XrayTarget?

    var body: some View {
        if let p = panels.open[pane], p.target == target {
            GeometryReader { g in
                XrayPanelView(panel: p)
                    .frame(width: XrayDrawerWidth.width(stored: width.points, offered: g.size.width))
                    .frame(maxHeight: .infinity)
                    .modifier(AgentPaneProbe(kind: "xray"))   // tests only (nil probe: nothing)
                    .background(Neon.card)
                    .background(XrayDrawerFrame())   // #1760: a card goes beside the drawer, never over it
                    .overlay(alignment: .leading) { Rectangle().fill(Neon.stroke).frame(width: 1) }
                    .overlay(alignment: .leading) { handle(offered: g.size.width) }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// #1473: a few points of hit area on the leading edge (the 1 pt line stays the visual). The cursor is set while the
    /// pointer moves over it, as the split dividers do (no push or pop to unbalance when the drawer closes under it).
    func handle(offered: CGFloat) -> some View {
        Color.clear.frame(width: sz(5)).contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { NSCursor.resizeLeftRight.set() } else if !width.dragging { NSCursor.arrow.set() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { width.dragged(by: $0.translation.width, offered: offered) }
                .onEnded { _ in
                    width.ended()
                    NSCursor.arrow.set()   // a drag can end off the handle: no later hover end to restore it
                })
            .onTapGesture(count: 2) { width.reset() }
            .accessibilityElement()
            .accessibilityLabel("X-ray width")
            // the drawn width (bounded by the space offered), never the stored value: that is outside data and Int( could trap
            .accessibilityValue("\(Int(XrayDrawerWidth.width(stored: width.points, offered: offered) / ThemeRuntime.scale)) points")
            .accessibilityAdjustableAction { d in
                width.dragged(by: d == .increment ? -sz(20) : sz(20), offered: offered)
                width.ended()
            }
    }
}

struct XrayPanelView: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
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
            if let l = panel.corpusLine {   // #1566: the corpus label, wrapped (a shell's carries the clear note)
                Text(verbatim: l).font(Neon.font(10, weight: .medium)).foregroundStyle(Neon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, sz(10)).padding(.bottom, sz(6))
            }
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
        } else if panel.tab == .prompts {
            promptsTab
        } else if panel.tab == .schedules {
            schedulesTab
        } else if panel.tab == .questions {
            taskList(panel.questionLines, cols: panel.questionCols, filterLabel: "Filter questions", title: nil, footer: panel.goneFooter,
                     questions: true)
        } else {
            tasksTab
        }
    }

    var tasksTab: some View {   // #1945, #1948: memoised on the model; one filter pass
        taskList(panel.taskLines, cols: panel.taskCols, filterLabel: "Filter tasks", title: panel.listTitle, footer: panel.footer)
    }

    /// The Tasks list; #1974: the Questions tab's too (its own lines, widths and filter label).
    /// #2024: the Questions list adds the Answer slot on every row (the button on Open rows) and the editor under the rows.
    func taskList(_ lines: [XrayTaskLine], cols: XrayTaskCols, filterLabel: String, title: String?, footer: [String],
                  questions: Bool = false) -> some View {
        let answers = questions && panel.answerShown
        return VStack(alignment: .leading, spacing: sz(4)) {
            TextField("Filter", text: $panel.filter)
                .textFieldStyle(.roundedBorder)
                .font(Neon.font(XrayText.row))
                .focused($filterFocus)
                .accessibilityLabel(filterLabel)
            if let t = title { Text(verbatim: t).font(Neon.font(XrayText.row, weight: .semibold)).lineLimit(1) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { l in
                        Group {
                            if let h = l.header {
                                faint(h).padding(.top, sz(6)).accessibilityAddTraits(.isHeader)
                            } else if let t = l.task {
                                XrayTaskRowView(row: XrayTaskRow(t, now: panel.now()), cols: cols,
                                                answer: answers && XrayPanelModel.isOpen(t) ? { panel.openAnswer(t) } : nil,
                                                answerSlot: answers) { panel.activate(t) }
                            }
                        }
                        .modifier(XrayScrollRow(panel: panel, id: l.id))   // #1979
                    }
                }
                .scrollTargetLayout()
            }
            // #2024: an inset, so opening the editor or a new status line moves no row (the list's bottom edge only)
            .safeAreaInset(edge: .bottom, spacing: 0) { if questions { XrayAnswerEditor(panel: panel) } }
            .modifier(XrayAnchoredScroll(panel: panel, shown: .init(gen: panel.listGen, ids: lines.map(\.id))))   // #1972, #1979
            ForEach(footer, id: \.self) { faint($0) }
        }
        .padding(sz(10))
    }

    /// #1354: Prompts, newest first; the footer's counts and toggles (design 1.3, 3.10).
    var promptsTab: some View {
        let rows = panel.shownPrompts, lines = panel.promptLines(rows)   // #1972: stable ids
        let ordinalW = XrayCol.widest(rows.map { "\($0.ordinal)" })   // #1945
        return VStack(alignment: .leading, spacing: sz(4)) {
            TextField("Filter", text: $panel.filter)
                .textFieldStyle(.roundedBorder)
                .font(Neon.font(XrayText.row))
                .focused($filterFocus)
                .accessibilityLabel("Filter prompts")
            if rows.isEmpty { faint("No prompts shown") }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: sz(2)) {
                    ForEach(lines, id: \.id) { l in
                        XrayPromptRowView(row: XrayPromptRow(l.c), ordinalWidest: ordinalW) { panel.activate(l.c) }
                            .modifier(XrayScrollRow(panel: panel, id: l.id))   // #1979
                    }
                }
                .scrollTargetLayout()
            }
            .modifier(XrayAnchoredScroll(panel: panel, shown: .init(gen: panel.listGen, ids: lines.map(\.id))))   // #1972, #1979
            filterBar(panel.promptFooter(.prompts))
            ForEach(panel.goneFooter, id: \.self) { faint($0) }   // #1389: "host unreachable"
        }
        .padding(sz(10))
    }

    /// #1950: a tab's filters (Prompts: Automatic / Agent messages; #1955 Refs: files, commits and links), a bar of
    /// its own under the list (hairline above, chips with their counts inside, so no number sits in the ordinal column).
    @ViewBuilder func filterBar(_ chips: [XrayFilterChip]) -> some View {
        if !chips.isEmpty {
            Divider().overlay(Neon.stroke)
            HStack(spacing: sz(6)) {
                faint("Show")
                ForEach(chips, id: \.label) { XrayFilterChipView(chip: $0) }
            }
            .padding(.top, sz(2))
        }
    }

    /// #1355: the query runs on Return (never per keystroke, never polled); a hit does nothing yet (P8/P9).
    var searchTab: some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            TextField("Search", text: $panel.query)
                .textFieldStyle(.roundedBorder)
                .font(Neon.font(XrayText.row))
                .focused($filterFocus)
                .onSubmit { panel.runSearch() }
                .accessibilityLabel(panel.searchFieldLabel)
            if let n = panel.searchNote { faint(n) }
            if let s = panel.search {
                if s.hits.isEmpty && s.others.isEmpty { faint("No hits") }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: sz(4)) {
                        ForEach(s.moments(now: panel.now()), id: \.self) { faint($0) }   // #1611: first mentioned, latest
                        // #1823: every lazy row's id is unique in the stack (XrayRefPopover.keyed, as #1816): hits part 0, groups part 1
                        ForEach(XrayRefPopover.keyed(s.hits, part: 0), id: \.id) { r in
                            XraySearchRowView(row: XraySearchRow(r.e, now: panel.now()))
                        }
                        // #1611: the other sessions' groups in dch's order, each under its "also discussed in" header
                        ForEach(XrayRefPopover.keyed(s.others, part: 1), id: \.id) { gr in
                            let (gi, g) = (gr.id.row, gr.e)
                            let head = XraySearch.header(g, now: panel.now())
                            Button { _ = panel.openSession(g) } label: {
                                Text(verbatim: head).font(Neon.font(XrayText.row, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, sz(4))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityLabel(head)
                            .accessibilityHint("Opens that session to the side")
                            ForEach(XrayRefPopover.keyed(g.hits, part: 1, block: gi), id: \.id) { h in
                                XraySearchRowView(row: XraySearchRow(h.e, now: panel.now()))
                            }
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
        let countW = panel.refCountWidest   // #1945, #1948
        let lines = panel.refLines   // #1972: keyed by the ref's text, not its place
        return VStack(alignment: .leading, spacing: sz(4)) {
            TextField("Filter", text: $panel.filter)
                .textFieldStyle(.roundedBorder)
                .font(Neon.font(XrayText.row))
                .focused($filterFocus)
                .accessibilityLabel("Filter refs")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines, id: \.id) { l in
                        XrayRefRowView(row: XrayRefRow(l.e, complete: complete, home: panel.home, cwd: panel.cwd()), countWidest: countW) { panel.openRef(l.e) }
                            .modifier(XrayScrollRow(panel: panel, id: l.id))   // #1979
                    }
                }
                .scrollTargetLayout()
            }
            .modifier(XrayAnchoredScroll(panel: panel, shown: .init(gen: panel.listGen, ids: lines.map(\.id))))   // #1972, #1979
            if let n = panel.refsEmpty { faint(n) }
            filterBar(panel.refsChips)
            ForEach(panel.refsFooter, id: \.self) { faint($0) }
        }
        .padding(sz(10))
    }

    var memoryTab: some View {
        let (sessionW, ageW) = panel.memoryCols   // #1945, #1948
        let lines = panel.memoryLines   // #1972: one flat list of stable ids (#1823: unique in the lazy stack)
        return VStack(alignment: .leading, spacing: sz(4)) {
            TextField("Filter", text: $panel.filter)
                .textFieldStyle(.roundedBorder)
                .font(Neon.font(XrayText.row))
                .focused($filterFocus)
                .accessibilityLabel("Filter memory")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines, id: \.id) { l in
                        Group {
                            if let h = l.header {
                                faint(h).padding(.top, sz(6)).accessibilityAddTraits(.isHeader)
                            } else if let m = l.item {
                                XrayMemoryRowView(row: XrayMemoryRow(m, now: panel.now(), home: panel.home, cwd: panel.cwd()),
                                                 sessionWidest: sessionW, ageWidest: ageW) {
                                    panel.openMemoryCard(m)
                                }
                            }
                        }
                        .modifier(XrayScrollRow(panel: panel, id: l.id))   // #1979
                    }
                }
                .scrollTargetLayout()
            }
            .modifier(XrayAnchoredScroll(panel: panel, shown: .init(gen: panel.listGen, ids: lines.map(\.id))))   // #1972, #1979
            ForEach(panel.goneFooter, id: \.self) { faint($0) }
        }
        .padding(sz(10))
    }

    func faint(_ s: String) -> some View {
        Text(verbatim: s).font(Neon.font(XrayText.small, weight: .medium)).foregroundStyle(Neon.textSecondary).lineLimit(1)
    }
}

/// #1972 (operator 2026-11-26, "Keep scroll anchored"): a drawer list whose rows carry stable ids. The top row the person
/// sees and (#1979) the points scrolled past its top are kept on the model as they scroll (XrayScrollRow); when a poll or
/// follow update changes the rows above it (a new prompt, ref or task sorting first), that row goes back to the top and
/// then down by its offset, so the line read stays where it was. At the very top nothing moves, so new rows there show.
/// #1979 (QA n3): a filter keystroke or a chip toggle (listGen) starts the list at its top.
struct XrayAnchoredScroll: ViewModifier {
    let panel: XrayPanelModel
    let shown: XrayScrollAnchor.Shown
    @State private var position = ScrollPosition(idType: String.self)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position, anchor: .top)
            .onChange(of: shown) { old, new in
                switch panel.shownChanged(old: old, new: new) {
                case .top: position.scrollTo(edge: .top)
                case .row(let t): position.scrollTo(id: t.id, anchor: .top)
                case nil: break
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                if let to = panel.settled(y) { position.scrollTo(y: to) }
            }
            .onScrollPhaseChange { _, p in if p == .tracking || p == .interacting { panel.settle = nil } }   // the person scrolls: no late nudge
    }
}

/// #1979: a drawer row: while it straddles the list's top edge it notes itself and the points scrolled past its top on
/// the model (unpublished: a scroll redraws nothing). Only that row's value changes as the list scrolls.
struct XrayScrollRow: ViewModifier {
    let panel: XrayPanelModel
    let id: String

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat?.self) { XrayScrollAnchor.past($0.frame(in: .scrollView)) } action: { _, off in
            if let off { panel.scrolled(id, offset: off) }
        }
    }
}

/// #1972: the pure part of XrayAnchoredScroll.
enum XrayScrollAnchor {
    /// #1979: the reader's top row and the points scrolled past its top.
    struct Top: Equatable {
        var id: String
        var offset: CGFloat = 0
    }

    /// #1979: what a drawer list shows: the filter and chip generation (XrayPanelModel.listGen) and its row ids.
    struct Shown: Equatable {
        var gen: Int
        var ids: [String]
    }

    /// #1979: where the list goes after it changed: its top (a filter or chip change) or back to the reader's row.
    enum Move: Equatable {
        case top
        case row(Top)
    }

    /// The row to put back at the top after the ids went from `old` to `new`, `anchor` the top row the person saw and
    /// the points past its top (kept with it; 0 for a row that stands in for it); nil: leave the scroll (no anchor, the
    /// very top: the first row, under a point into it, or nothing above it changed). An anchor that went: the next row
    /// of `old` still there, else the one before it.
    static func restore(old: [String], new: [String], anchor: Top?) -> Top? {
        guard let a = anchor, let i = old.firstIndex(of: a.id), i > 0 || a.offset >= 1 else { return nil }
        let now = Set(new)
        guard let keep = old[i...].first(where: now.contains) ?? old[..<i].last(where: now.contains),
              let j = new.firstIndex(of: keep) else { return nil }
        return old[..<i].elementsEqual(new[..<j]) ? nil : Top(id: keep, offset: keep == a.id ? a.offset : 0)
    }

    /// #1979: the points scrolled past a row's top while it straddles the scroll view's top edge (`frame` in its
    /// coordinates); nil for every other row.
    static func past(_ frame: CGRect) -> CGFloat? {
        frame.minY <= 0 && frame.maxY > 0 ? -frame.minY : nil
    }

    /// A repeated id gets "\u{1F}2", "\u{1F}3", ... (a lazy stack draws one row per id: #1815, #1823).
    static func unique(_ ids: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return ids.map { id in
            let n = seen[id, default: 0] + 1
            seen[id] = n
            return n == 1 ? id : "\(id)\u{1F}\(n)"
        }
    }
}

/// #1950: one filter chip of the Prompts tab: what it filters, how many such rows there are, whether they are listed.
struct XrayFilterChip {
    let label: String, count: Int, shown: Bool, toggle: () -> Void
    var spoken: String { "\(label), \(count) \(count == 1 ? "row" : "rows")" }
}

/// #1950: the chip: outlined capsule, count badge inside; on = Neon.blue tint + eye, off = outline + eye.slash.
struct XrayFilterChipView: View {
    let chip: XrayFilterChip

    var body: some View {
        Button(action: chip.toggle) {
            HStack(spacing: sz(4)) {
                Image(systemName: chip.shown ? "eye" : "eye.slash").font(Neon.font(XrayText.small - 1))
                Text(verbatim: chip.label).font(Neon.font(XrayText.small, weight: .medium))
                Text(verbatim: "\(chip.count)").font(Neon.font(XrayText.small - 1, weight: .medium).monospacedDigit())
                    .padding(.horizontal, sz(5))
                    .background(Capsule().fill(Neon.stroke))
            }
            .foregroundStyle(chip.shown ? Neon.textPrimary : Neon.textSecondary)
            .padding(.horizontal, sz(8)).padding(.vertical, sz(3))
            .background(Capsule().fill(chip.shown ? Neon.blue.opacity(0.2) : .clear))
            .overlay(Capsule().stroke(chip.shown ? Neon.blue.opacity(0.6) : Neon.stroke, lineWidth: 1))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chip.spoken)
        .accessibilityValue(chip.shown ? "shown" : "hidden")
        .accessibilityAddTraits(chip.shown ? .isSelected : [])
    }
}

/// The #821 capsule-button strip: only the tabs that exist, "Name N".
struct XrayTabStrip: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
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

/// #1945: the drawer list's text sizes (at UI scale 1.0, through Neon.font): rows and filters, the small headers and
/// footers, and the row's vertical padding.
enum XrayText {
    static let row: CGFloat = 12.5, small: CGFloat = 11.5, pad: CGFloat = 4
    /// #1956: every Tasks row is this tall (a 16 pt line for the 12.5 pt text, plus the padding), whatever it holds.
    static let rowHeight: CGFloat = 16 + 2 * pad
}

/// #1945: one column cell. The cell is as wide as `widest` (the list's longest value of the column, drawn hidden), so
/// every row's cell starts and ends at the same x; no per-row measuring. Digits are monospaced, so the longest string by
/// character count is the widest one for ids and ages. An empty `widest` (no row has the value) draws nothing.
struct XrayCol: View {
    let text: String?
    let widest: String
    var trailing = false

    var body: some View {
        if !widest.isEmpty {
            Text(verbatim: widest).monospacedDigit().lineLimit(1).fixedSize().hidden()
                .overlay(alignment: trailing ? .trailing : .leading) {
                    if let text { Text(verbatim: text).monospacedDigit().lineLimit(1).fixedSize() }
                }
        }
    }

    /// shortcut: the longest by character count; a proportional label (not digits) of equal length can differ by a few
    /// points, upgrade to a measured width if a status label ever needs it.
    static func widest(_ xs: [String?]) -> String { xs.reduce("") { m, x in (x?.count ?? 0) > m.count ? x! : m } }
    static func widest(_ xs: [String]) -> String { widest(xs.map { Optional($0) }) }
}

/// #1945: the Tasks list's column widths: the widest id, status label and age of the rows.
struct XrayTaskCols: Equatable {
    let id: String, label: String, age: String
    init(_ rows: [XrayTaskRow]) {
        id = XrayCol.widest(rows.map(\.id))
        label = XrayCol.widest(rows.map(\.label))
        age = XrayCol.widest(rows.map(\.age))
    }
    /// #1948: the same widths from the tasks' own fields, no row built (spoken join, blocked strings).
    init(tasks: [XrayTasks.Task], now: Date) {
        id = XrayCol.widest(tasks.map(\.id))
        label = XrayCol.widest(tasks.map { XrayTaskRow.label($0) })
        age = XrayCol.widest(tasks.map { XrayTaskRow.age($0.updated ?? $0.created, now: now)?.short })
    }
}

struct XrayTaskRowView: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let row: XrayTaskRow
    var cols: XrayTaskCols?   // nil: each cell fits its own text
    /// #2024: the Questions list's Answer (nil: none on this row); `answerSlot` keeps its width on every row of that list.
    var answer: (() -> Void)? = nil
    var answerSlot = false
    let open: () -> Void

    var body: some View {
        HStack(spacing: sz(6)) {
            rowButton
            if answerSlot {
                Button("Answer") { answer?() }
                    .buttonStyle(.plain)
                    .font(Neon.font(XrayText.small, weight: .medium))
                    .foregroundStyle(Neon.blue)
                    .opacity(answer == nil ? 0 : 1)   // drawn on every row so the columns stay put
                    .disabled(answer == nil)
                    .accessibilityHidden(answer == nil)
                    .accessibilityLabel("Answer question \(row.id)")
            }
        }
    }

    var rowButton: some View {
        Button(action: open) {
            HStack(spacing: sz(6)) {
                Image(systemName: row.mark).foregroundStyle(Neon.textSecondary)
                XrayCol(text: row.id, widest: cols?.id ?? row.id, trailing: true).foregroundStyle(Neon.textSecondary)
                // #1956: a fixed narrow column, drawn hidden when nothing blocks the task, so the titles stay aligned
                Image(systemName: "link").font(Neon.font(XrayText.small)).foregroundStyle(Neon.textSecondary).opacity(0.6)
                    .opacity(row.blocked == nil ? 0 : 1)
                    .modifier(AgentPaneProbe(kind: row.blocked == nil ? "xrayNotBlocked" : "xrayBlocked"))
                Text(verbatim: row.title).foregroundStyle(Neon.textPrimary).lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                    .modifier(AgentPaneProbe(kind: "xrayTitle"))   // tests only (nil probe: nothing)
                Spacer(minLength: sz(4))
                XrayCol(text: row.label, widest: cols?.label ?? row.label ?? "").foregroundStyle(Neon.textSecondary)
                    .modifier(AgentPaneProbe(kind: "xrayStatus"))
                XrayCol(text: row.age, widest: cols?.age ?? row.age ?? "", trailing: true).foregroundStyle(Neon.textSecondary)
                    .modifier(AgentPaneProbe(kind: "xrayAge"))
            }
            .font(Neon.font(XrayText.row))
            .frame(height: sz(XrayText.rowHeight))   // #1956: one height for every row, no measuring
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.blocked ?? "")
        .accessibilityLabel(row.spoken)
    }
}

/// #1354: a Prompts row; a click (or Return / Space with VoiceOver) jumps to its chapter (#1472: or,
/// with no transcript, opens its card).
struct XrayPromptRowView: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let row: XrayPromptRow
    var ordinalWidest: String?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: sz(6)) {
                XrayCol(text: row.ordinal, widest: ordinalWidest ?? row.ordinal, trailing: true).foregroundStyle(Neon.textSecondary)
                if row.robot { RobotGlyph(size: XrayText.row).foregroundStyle(Neon.textSecondary) }
                if let m = row.mark, !m.isEmpty { Text(verbatim: m).foregroundStyle(Neon.textSecondary).lineLimit(1) }
                Text(verbatim: row.title).foregroundStyle(row.faint ? Neon.textSecondary : Neon.textPrimary)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1).modifier(AgentPaneProbe(kind: "xrayTitle"))
            }
            .font(Neon.font(XrayText.row))
            .padding(.vertical, sz(XrayText.pad))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.spoken)
    }
}

/// #1355: one Search hit; not a button yet (P8/P9 open the hit's prompt).
struct XraySearchRowView: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let row: XraySearchRow

    var body: some View {
        VStack(alignment: .leading, spacing: sz(1)) {
            HStack(spacing: sz(6)) {
                Text(verbatim: row.who).foregroundStyle(Neon.textSecondary).lineLimit(1)
                if let a = row.age { Text(verbatim: a).foregroundStyle(Neon.textSecondary).fixedSize() }
                if row.answer { Text(verbatim: XraySearchRow.answerMark).foregroundStyle(Neon.blue).fixedSize() }   // #1611
            }
            Text(verbatim: row.snippet).foregroundStyle(Neon.textPrimary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .font(Neon.font(XrayText.row))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.spoken)
    }
}

/// #1415: one Refs row: bold when defined or mentioned twice, the title faint, the count at the right.
struct XrayRefRowView: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let row: XrayRefRow
    var countWidest: String?
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
                XrayCol(text: row.count, widest: countWidest ?? row.count, trailing: true).foregroundStyle(Neon.textSecondary)
                    .modifier(AgentPaneProbe(kind: "xrayAge"))
            }
            .font(Neon.font(XrayText.row))
            .padding(.vertical, sz(XrayText.pad))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.spoken)
    }
}

struct XrayMemoryRowView: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let row: XrayMemoryRow
    var sessionWidest: String?, ageWidest: String?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: sz(6)) {
                Text(verbatim: row.title).foregroundStyle(Neon.textPrimary).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                Text(verbatim: row.detail).foregroundStyle(Neon.textSecondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: sz(4))
                XrayCol(text: row.session, widest: sessionWidest ?? row.session ?? "").foregroundStyle(Neon.textSecondary)
                    .modifier(AgentPaneProbe(kind: "xrayStatus"))
                XrayCol(text: row.age, widest: ageWidest ?? row.age ?? "", trailing: true).foregroundStyle(Neon.textSecondary)
                    .modifier(AgentPaneProbe(kind: "xrayAge"))
            }
            .font(Neon.font(XrayText.row))
            .padding(.vertical, sz(XrayText.pad))
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
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let item: XrayMemory.Item
    var now = Date()
    var note: String?
    let readPrompt: (() -> Void)?
    /// #1814: the drawer's filter when the card opened, highlighted in the title and the body.
    var match = ""

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
            XrayRichBlock(text: item.title, size: 12, strong: true, match: match).lineLimit(2)
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
                    XrayRichBlock(text: b, size: 11, match: match)   // #1814: Markdown drawn, the filter highlighted
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
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
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

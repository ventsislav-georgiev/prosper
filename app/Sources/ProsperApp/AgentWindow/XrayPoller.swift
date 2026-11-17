import AppKit

// #1368 (#1346 P3b, design 3.4, 3.5, 3.9): the Tasks poller. While the drawer shows the Tasks tab for a live session in
// a visible window, `--tasks` is read again every 5 s (local) or 15 s (remote: each read dials the host). Never while
// hidden; one read in flight (a tick while it runs is skipped, never queued); closing the panel or switching the pane
// to another session cancels the read (the product runner SIGTERMs its dch); an ended session keeps its one open read.
// #1381 (design 2.2 / 3.4): the Memory tab the same way every 30 s, sharing the one read in flight with Tasks.
// #1389: Prompts and Responses from dch's chapters (`--xray <n> --json`) at the Tasks cadence, 5 s local, 15 s remote.
// #1415 (gate A): the Refs tab reads that same `--json` every 30 s (Memory's cadence) while it is shown and live; a
// Transcript pane keeps only its refs (its chapters are its own), a dch-chapters pane takes both.

extension XrayPanelModel {
    /// Design 3.4 / 3.5: Tasks (#1389: and dch's chapters) 5 s for a local session, 15 s for a remote one; Memory 30 s
    /// (#1381, design 2.2).
    var interval: TimeInterval { loaded && (tab == .memory || tab == .refs) ? 30 : target.dir == nil ? 15 : 5 }

    /// One tick (the product's ticker fires each second; rows call it with an injected clock).
    func tick() {
        guard !stopped else { return }
        // #1475: a follow goes on (hidden keeps it)
        guard isCurrent() else { return cancel() }   // hidden by a selection change: SIGTERM; read again on return
        // #1475: a follow with no snapshot past the bound: today's reads instead
        if let f = follow, f.state == nil, let t = followSince, now().timeIntervalSince(t) >= DchCommand.remoteTimeout { return giveUpFollow() }
        // #1475 a2 (QA r1436 s2): a follow that ended after its snapshot (a dropped link, a serve restart or eviction):
        // the rows stay and the polls resume (the next open follows again)
        if let f = follow, f.state != nil, !f.running { detachFollow() }
        let s = paneState()
        guard s.visible, reading == nil, let dch, let run else { return }
        // ended: the open read was its one read; a Memory tab gone (a failed read) is not polled again
        // #1389: Prompts/Responses poll dch only on a dch-chapters pane whose read answered (a Transcript pane never)
        // #1475: a follow keeps both live: no chapters or Refs poll beside it
        let prose = (tab == .prompts || tab == .responses) && dchChapters != nil && fromDch() && follow == nil
        let refsShown = tab == .refs && refs != nil && follow == nil   // #1415: only while Refs is the shown tab (gate A keeps it nil)
        guard !loaded || s.live && (tab == .tasks || tab == .memory && memory != nil || prose || refsShown) else { return }
        guard now().timeIntervalSince(lastRead) >= interval else { return }
        // design 3.9: no Tasks retry until the dch path's mtime moves
        if failed, tab == .tasks, mtime(dch) == failedMtime { return }
        if tab == .tasks, tasksRefused { return }
        if !loaded { if !answered { readBoth() } } else if tab == .memory { readMemory() } else if prose || refsShown { readChapters(dch, run) }
        else { readTasks(dch, run) }
    }

    private func readTasks(_ dch: String, _ run: @escaping XrayPanels.Run) {
        lastRead = now()
        let env = target.env, a = target.args("tasks")
        reading = Task { [weak self] in
            let r = await run(dch, a, env)
            guard !Task.isCancelled, let self else { return }
            self.reading = nil
            self.take(r)
            self.landed()
        }
    }

    /// #1389: one chapters read (`--xray <n> --json`), labelled as Tasks' (takeChapters); #1415: a Transcript pane's
    /// keeps the refs alone (takeRefs).
    func readChapters(_ dch: String, _ run: @escaping XrayPanels.Run) {
        lastRead = now()
        let env = target.env, a = target.chaptersArgs, refsOnly = !fromDch()
        reading = Task { [weak self] in
            let r = await run(dch, a, env)
            guard !Task.isCancelled, let self else { return }
            self.reading = nil
            if refsOnly { self.takeRefs(r) } else { self.takeChapters(r) }
            self.landed()
        }
    }

    /// #1407: an over-cap answer (XrayPanels.overCap) is a refusal here, as exit 6: no chapters, and no re-read.
    /// #1389, as take: exit 4 or 7 (or a remote -1) keeps the rows and says "host unreachable"; any other answer
    /// replaces them, so exit 1 (the host's dch does not know the form), 6 (refused) or bad JSON leaves no Prompts or
    /// Responses tab (nil), and with the tab gone the tick reads no more chapters.
    func takeChapters(_ r: (status: Int32, out: Data)) {
        if unreached(r.status) { unreachable = true; return }
        unreachable = false
        dchChapters = r.status == 0 ? XrayChapters.parse(r.out) : nil
        chapterAnchors = r.status == 0 ? Self.anchors(r.out) : [:]   // #1472, #1475: every read's, not the open's alone
        if XrayPanels.refsTab() { refs = r.status == 0 ? XrayRefs.parse(r.out) : nil }   // #1415: the same bytes
    }

    /// #1415: a Transcript pane's `--json` read: its refs only, by takeChapters' rules (4/7 keep the rows).
    func takeRefs(_ r: (status: Int32, out: Data)) {
        if unreached(r.status) { unreachable = true; return }
        unreachable = false
        refs = r.status == 0 ? XrayRefs.parse(r.out) : nil
    }

    /// #1381: one `--memory` read in `reading` (the tab switch's, the pending one, the 30 s poll). A host that did not
    /// answer (4, 7, a remote -1) keeps the rows and says "host unreachable", as Tasks; any other answer clears that line
    /// (#1353, R1381-i1: the host answered) and replaces the Memory tab (nil: none).
    func readMemory() {
        guard let dch, let run else { return }
        lastRead = now()
        let env = target.env, a = target.args("memory")
        reading = Task { [weak self] in
            let r = await run(dch, a, env)
            guard !Task.isCancelled, let self else { return }
            self.reading = nil
            self.unreachable = self.unreached(r.status)
            if !self.unreachable { self.takeMemory(r) }
            self.pendingMemory = false   // this read answered the switch
            self.landed()
        }
    }

    /// After a read: the strip moves to the tab left when its tab went; then R1352-i1's pending Memory read, once.
    func landed() {
        if !tabs.contains(tab), let first = tabs.first { tab = first }
        guard pendingMemory else { return }
        pendingMemory = false
        if tab == .memory, !stopped { readMemory() }
    }

    /// Design 3.5: exit 4 or 7, or a remote read's -1 (timed out dialling): the host did not answer.
    func unreached(_ status: Int32) -> Bool { status == 4 || status == 7 || status == -1 && target.dir == nil }

    /// Design 3.5 / 3.9: exit 4 or 7, or a remote read's -1 (timed out dialling), keeps the rows and says "host
    /// unreachable" (the poll goes on); any other answer replaces the Tasks tab (nil: none, so exit 6 or "does not know"
    /// removes it), an over-cap answer (#1407) is a refusal that is not read again while the panel is open, and a non-zero exit (a local -1 too) stops the reads until the mtime moves.
    func take(_ r: (status: Int32, out: Data)) {
        if unreached(r.status) { unreachable = true; return }
        unreachable = false
        tasks = Self.tasksTab(r)
        failed = r.status != 0
        if r.status == XrayPanels.overCap { tasksRefused = true }   // #1407: no Tasks read again until the panel is reopened
        if failed { failedMtime = dch.flatMap(mtime) }
    }

    /// The read in flight, if any, is cancelled (the product runner SIGTERMs its dch).
    func cancel() {
        reading?.cancel()
        reading = nil
        pendingMemory = false
    }

    /// The panel left XrayPanels.open: no tick reads again.
    func stop() {
        stopped = true
        detachFollow()   // #1475
        stopTicker?()
        stopTicker = nil
        cancel()
    }
}

extension XrayPanels {
    /// The window model that draws `pane` (read only); rows put theirs here.
    static var model: @MainActor (UUID) -> AgentWindowModel? = { AgentsNSWindow.window(of: $0)?.model }

    /// The poller's one-second ticker; the cadence is the model's. None under XCTest: rows call tick() themselves.
    static var ticker: @MainActor (_ fire: @escaping @MainActor @Sendable () -> Void) -> (() -> Void)? = { fire in
        guard NSClassFromString("XCTestCase") == nil else { return nil }
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { fire() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        return { t.invalidate() }
    }

    /// Design 3.4: the pane's window visible (AgentWindowModel.visible) and the pane focused (the drawer draws there
    /// only); live: a live or remote row that has not ended (an ended pane keeps its last row: `ended`).
    static func paneState(_ pane: UUID) -> (visible: Bool, live: Bool) {
        guard let m = model(pane), m.layout.focused == pane else { return (false, false) }
        let row = m.selectedRow
        return (m.visible, m.ended == nil && (row?.session != nil || row?.remote != nil))
    }
}

/// One read's dch child, for the SIGTERM a cancel sends (as DchActionRunner.signal). A cancel before the launch
/// signals at the launch; never once the child is reaped (its pid may be reused).
final class XrayChild: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var done = false
    private var cancelled = false
    private let signal: @Sendable (pid_t) -> Void

    init(signal: @escaping @Sendable (pid_t) -> Void = { _ = Darwin.kill($0, SIGTERM) }) { self.signal = signal }

    func started(_ p: pid_t) { lock.withLock { pid = p; if cancelled, !done { signal(p) } } }
    /// Called from runCapturingBoth's onExit (#1380), the termination handler, not after the call returns.
    func reaped() { lock.withLock { done = true } }
    func cancel() { lock.withLock { if !cancelled, !done, let p = pid { signal(p) }; cancelled = true } }
}

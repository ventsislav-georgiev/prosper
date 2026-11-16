import AppKit

// #1368 (#1346 P3b, design 3.4, 3.5, 3.9): the Tasks poller. While the drawer shows the Tasks tab for a live session in
// a visible window, `--tasks` is read again every 5 s (local) or 15 s (remote: each read dials the host). Never while
// hidden; one read in flight (a tick while it runs is skipped, never queued); closing the panel or switching the pane
// to another session cancels the read (the product runner SIGTERMs its dch); an ended session keeps its one open read.
// #1381 (design 2.2 / 3.4): the Memory tab the same way every 30 s, sharing the one read in flight with Tasks.

extension XrayPanelModel {
    /// Design 3.4 / 3.5: Tasks 5 s for a local session, 15 s for a remote one; Memory 30 s (#1381, design 2.2).
    var interval: TimeInterval { loaded && tab == .memory ? 30 : target.dir == nil ? 15 : 5 }

    /// One tick (the product's ticker fires each second; rows call it with an injected clock).
    func tick() {
        guard !stopped else { return }
        guard isCurrent() else { return cancel() }   // hidden by a selection change: SIGTERM; read again on return
        let s = paneState()
        guard s.visible, reading == nil, let dch, let run else { return }
        // ended: the open read was its one read; a Memory tab gone (a failed read) is not polled again
        guard !loaded || s.live && (tab == .tasks || tab == .memory && memory != nil) else { return }
        guard now().timeIntervalSince(lastRead) >= interval else { return }
        // design 3.9: no Tasks retry until the dch path's mtime moves
        if failed, tab == .tasks, mtime(dch) == failedMtime { return }
        if !loaded { readBoth() } else if tab == .memory { readMemory() } else { readTasks(dch, run) }
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

    /// #1381: one `--memory` read in `reading` (the tab switch's, the pending one, the 30 s poll). A host that did not
    /// answer (4, 7, a remote -1) keeps the rows, as Tasks; any other answer replaces the Memory tab (nil: none).
    func readMemory() {
        guard let dch, let run else { return }
        lastRead = now()
        let env = target.env, a = target.args("memory")
        reading = Task { [weak self] in
            let r = await run(dch, a, env)
            guard !Task.isCancelled, let self else { return }
            self.reading = nil
            if !self.unreached(r.status) { self.takeMemory(r) }
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
    /// removes it), and a non-zero exit (a local -1 too) stops the reads until the mtime moves.
    func take(_ r: (status: Int32, out: Data)) {
        if unreached(r.status) { unreachable = true; return }
        unreachable = false
        tasks = Self.tasksTab(r)
        failed = r.status != 0
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

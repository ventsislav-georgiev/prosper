// Owns Agent Island (#474) end to end: the borderless non-activating panel over
// the notch, the 1 s stat poll on a utility queue (dch is forked only when the
// gate in AgentIslandModel says so), expand/collapse, the row-click jump, and
// (#475) the prompt cards of blocked sessions and their answer clicks.
// Gated by the com.prosper.agentisland system extension (ships default-disabled)
// exactly like CalendarBarController: AppDelegate sets `extLive` at launch and
// on every extension toggle, and `reload()` builds or tears everything down — a
// disabled install has no panel, no timer and never forks dch.

import AppKit
import SwiftUI

/// Key only while expanded (Escape needs it); collapsed it never takes focus.
final class AgentIslandPanel: NSPanel {
    var keyable = false
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// The app is never active behind the island, so the first click must count.
private final class FirstClickHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AgentIslandController {
    static let shared = AgentIslandController()

    /// Whether the extension is enabled + trusted. Set by AppDelegate.
    var extLive = false

    var store: AgentIslandStore?
    private var panel: AgentIslandPanel?
    private(set) var timer: DispatchSourceTimer?
    private(set) var outsideClick: Any?
    private(set) var screenObserver: NSObjectProtocol?
    /// #581: layout()'s last decision (the panel shown or ordered out); tests read it.
    private(set) var shown = false
    /// #475: the activity each blocked session's screen was last read at, and a
    /// per-session generation (never reset) so a late read never revives an
    /// answered card.
    private var readAt: [AgentSessionKey: TimeInterval] = [:]
    private var cardGen: [AgentSessionKey: Int] = [:]
    /// Keys whose answer is still on the queue: no second send, no re-added card.
    private var inFlight: Set<AgentSessionKey> = []
    let queue = DispatchQueue(label: "eu.illegible.prosper.agentisland", qos: .utility)
    /// Test seams (#478, #475): the poller reload() starts, the dch IO, and
    /// showsPanel = false so layout() never builds or orders the panel.
    var makePoller: () -> AgentIslandPoller = { AgentIslandPoller() }
    var io = AgentPromptIO.live
    var showsPanel = true
    /// More seams (#477): the screen geometry, the center the screen observer
    /// lives on, the outside-click monitor (tests never install a real global
    /// one), the row-click walk, and the main-thread font warm-up.
    var currentGeometry: @MainActor () -> AgentIslandGeometry? = { AgentIslandGeometry.current() }
    var center = NotificationCenter.default
    var monitorClicks: (@escaping @MainActor () -> Void) -> Any? = { onClick in
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { onClick() }
        }
    }
    var removeMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }
    var jumpTarget: @MainActor (AgentSessionKey) -> AgentJumpTarget = { key in
        AgentIsland.jumpTarget(
            clients: AgentIsland.clientPIDs(key), info: AgentIsland.procInfo,
            isRegularApp: { NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular },
            ourPID: getpid())
    }
    var touchFonts: @MainActor () -> Void = { _ = AgentIslandGeometry.cardFonts }
    /// #500 seams: the click setting, the chosen terminal, and the launcher
    /// (tests record; no test starts a terminal).
    var clickAction: @MainActor () -> AgentIslandClick = { AgentIslandClick(raw: Preferences.agentIslandClick) }
    var terminal: @MainActor () -> AgentTerminal = {
        AgentTerminal.resolve(raw: Preferences.agentIslandTerminal, installed: AgentTerminal.isInstalled)
    }
    var launchTerminal: @MainActor (AgentTerminal, AgentTerminal.Launch, @escaping @Sendable (Bool) -> Void) -> Void
        = { AgentTerminalLauncher.launch($0, $1, done: $2) }
    /// The .app jump: raise the session's window, activate its app (AX and Launch Services).
    var focusApp: @MainActor (pid_t, [String]) -> Void = { pid, needles in
        AgentIslandController.raiseWindow(pid: pid, matching: needles)
        AgentIslandController.activate(pid)
    }
    /// #505 seam: send Ghostty's new-tab or new-window event; `done` gets noErr or the AE error.
    var sendGhostty: @MainActor (NSAppleEventDescriptor, @escaping @Sendable (OSStatus) -> Void) -> Void
        = { GhosttyEventSender.send($0, done: $1) }
    /// Automation denied (-1743): the rest of the run opens Ghostty by script.
    private(set) var ghosttyDenied = false
    /// Sessions whose terminal is still launching: a double click opens one window.
    private var opening: Set<AgentSessionKey> = []
    /// #523: every published list, on main, and nil when the island stops.
    /// LiveStatusPublisher listens (set by AppDelegate; tests leave it nil).
    var onSessions: (@MainActor ([AgentSession]?) -> Void)?
    /// #578 seams: the control binary (probed and cached), the history read
    /// with it, the dirs to read (the poller's), and the long-verb runner.
    /// Under XCTest the default finds no binary even unstubbed, so a test that
    /// expands a controller never runs a real dch (no history, Resume refused).
    var controlDch: @Sendable () -> DchCommand.Binary? = {
        NSClassFromString("XCTestCase") == nil ? DchCommand.controlDch() : nil
    }
    var readHistory: @Sendable (_ dch: String, _ dirs: [String]) -> [DchHistoryRecord] = { dch, dirs in
        AgentIsland.history(dirs: dirs) { DchCommand.runIsland(args: $0, env: $1, path: dch) }
    }
    var historyDirs: @MainActor () -> [String] = { AgentIsland.liveSocketDirs() }
    /// #606 seam: the live sessions' dch records, read off main. Under XCTest
    /// the default reads none, so no test reads the operator's records.
    var readLiveRecords: @Sendable ([AgentSession]) -> [DchHistoryRecord] = {
        NSClassFromString("XCTestCase") == nil ? AgentIsland.liveRecords($0) : []
    }
    /// A control verb's env for one dir, built on the runner's thread (QA #445 M1:
    /// the user's PATH, not launchd's). Under XCTest no login shell runs: the
    /// fallback dirs only.
    var controlEnv: @Sendable (_ dir: String) -> [String: String] = { dir in
        AgentIsland.controlEnv(dir: dir, login: NSClassFromString("XCTestCase") == nil ? LoginPath.read() : nil)
    }
    var runner = DchActionRunner.shared
    /// #579 seam: the folder chooser for New session (NSOpenPanel, directories
    /// only); `done` gets the path, nil when cancelled. Tests never show a real one.
    var chooseFolder: @MainActor (@escaping @MainActor (String?) -> Void) -> Void = { done in
        AgentIslandController.openFolderPanel(done)
    }
    /// #579 seam: shows the header "⋯" menu at the mouse. Tests record it; none
    /// opens a real menu.
    var popUpMenu: @MainActor (NSMenu) -> Void = { $0.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }

    init() {}

    /// Idempotent — launch, every extension toggle and every screen change.
    func reload() {
        touchFonts()   // build the card fonts on main, before any queue work
        guard extLive else { teardown(); return }
        // #477 L4: observe before the geometry guard, so a screen that appears
        // after a screenless reload still builds the island.
        if screenObserver == nil {
            screenObserver = center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload(); self?.layout() }
            }
        }
        guard timer == nil, let geometry = currentGeometry() else { return }
        store = AgentIslandStore(geometry: geometry, details: Preferences.agentIslandRowDetails,
                                 sort: Preferences.agentIslandSort, sidekickPattern: Self.sidekickPattern)
        let t = Self.makePollTimer(makePoller(), queue: queue) { [weak self] sessions in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(sessions) } }
        }
        t.resume()
        timer = t
        // #581: once per build, so the island can show with history and no live
        // session (after a reboot). A read only, never --revive.
        refreshHistory()
    }

    /// #478: nonisolated so the handler is too. Built in reload() it was inferred
    /// @MainActor (setEventHandler is not @Sendable) and its executor check
    /// trapped on the poll queue.
    nonisolated static func makePollTimer(_ poller: AgentIslandPoller, queue: DispatchQueue,
                                          onSessions: @escaping @Sendable ([AgentSession]) -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(250))
        t.setEventHandler {
            guard let sessions = poller.tick() else { return }
            onSessions(sessions)
        }
        return t
    }

    private func apply(_ sessions: [AgentSession]) {
        guard timer != nil, let store else { return }   // a tick that raced teardown
        let wasLive = !store.sessions.isEmpty
        store.sessions = sessions
        onSessions?(sessions)
        let live = Set(sessions.map(\.key))
        store.notices = store.notices.filter { live.contains($0.key) }
        // #580: a session that ended (a Stop) takes its row's text with it, so a
        // later session of that name starts clean.
        if store.actions.contains(where: { !$0.key.name.isEmpty && !live.contains($0.key) }) {
            store.actions = store.actions.filter { $0.key.name.isEmpty || live.contains($0.key) || runner.isBusy($0.key) }
        }
        // #581: the last session gone: one history read, so its record can keep the
        // island. On that edge only, never per tick.
        // ponytail: with no history yet the collapsed ear hides for the ~100 ms the
        // read takes, then shows; keep the island up meanwhile if that ever flickers.
        if wasLive, sessions.isEmpty { refreshHistory() }
        refreshCards()
        layout()
    }

    /// #534: a Settings row-detail toggle; #571: the sort, the sidekick tabs
    /// toggle or pattern. Redraws the island and resizes the panel at once (a
    /// row losing its PR line is 48 pt again, a tab change shows other rows);
    /// no animation.
    func rowDetailsChanged() {
        guard let store else { return }
        store.details = Preferences.agentIslandRowDetails
        store.sort = Preferences.agentIslandSort
        store.sidekickPattern = Self.sidekickPattern
        refreshCards()
        layout()
    }

    /// #571: the pattern the store splits by; "" while the tabs are off.
    private static var sidekickPattern: String {
        Preferences.agentIslandSidekickTabs ? Preferences.agentIslandSidekickPattern : ""
    }

    /// #571: a Sessions / Sidekicks tab click. Only the shown rows get cards.
    func showSidekicks(_ on: Bool) {
        guard let store else { return }
        store.historyTab = false
        store.sidekickTab = on
        refreshCards()
        layout()
    }

    /// #578: the History tab click.
    func showHistory() {
        guard let store, !store.history.isEmpty else { return }
        store.historyTab = true
        refreshCards()
        layout()
        refreshHistory()  // #585: count a session that ended while open
    }

    // MARK: - History and Resume (#578)

    /// Reads `--history --json` with the control binary: once when the island is
    /// built (#581), on open and after an action, never on the poll timer. A
    /// binary under 1.24.0 (#580) reads none (no tab).
    func refreshHistory() {
        guard store != nil else { return }
        let dirs = historyDirs(), probe = controlDch, read = readHistory
        queue.async { [weak self] in
            let dch = probe()
            let records = dch.map { DchCommand.isAtLeast($0.version, AgentIsland.controlMinimum) ? read($0.path, dirs) : [] } ?? []
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.setHistory(records, dch) } }
        }
    }

    private func setHistory(_ records: [DchHistoryRecord], _ dch: DchCommand.Binary?) {
        guard let store else { return }
        store.controlDch = dch
        store.history = records
        // A record gone (revived) takes its status with it; running ones, the --all
        // lines and #579's live rows (a Restart result) stay.
        let recordKeys = Set(records.map(\.key)), live = Set(store.sessions.map(\.key))
        store.historyActions = store.historyActions.filter { recordKeys.contains($0.key) || runner.isBusy($0.key) }
        store.actions = store.actions.filter { $0.key.name.isEmpty || live.contains($0.key) || runner.isBusy($0.key) }
        layout()
    }

    /// A History row's click. A name that is live now revives under the first
    /// free `<name>-N`. A busy row refuses (the runner never queues).
    func resume(_ r: DchHistoryRecord) {
        guard let store, case .ok(let dch) = store.resumeGate else { return }
        let live = Set(store.sessions.filter { $0.key.dir == r.key.dir }.map(\.name))
        let records = Set(store.history.filter { $0.key.dir == r.key.dir && $0.key != r.key }.map(\.name))
        let key = r.key
        run(key, dch: dch, args: AgentIsland.reviveArgs(r, live: live, records: records), running: AgentIsland.resumingText,
            history: true, onLine: { [weak self] in self?.rowLine($0, key: key, history: true) }) { [weak self] res in
            self?.store?.historyActions[key] = AgentIsland.rowText(res, name: key.name, .resume)
            self?.refreshHistory()
        }
    }

    /// The Resume interrupted button, and nothing else: `--revive --all` in each dir
    /// with history. Never on launch, a timer or a reconnect — after a reboot
    /// every session reads "vanished" and would qualify.
    func resumeCrashed() {
        guard let store, case .ok(let dch) = store.resumeGate else { return }
        for dir in Set(store.history.map(\.key.dir)).sorted() {
            let key = AgentSessionKey(dir: dir, name: "")
            run(key, dch: dch, args: AgentIsland.reviveAllArgs, running: AgentIsland.resumingText,
                onLine: { [weak self] in self?.dirLine($0, dir: dir, .resume) }) { [weak self] r in
                self?.dirDone(dir, AgentIsland.tally(r, .resume, title: "Resume", empty: "nothing to resume"))
                self?.refreshHistory()
            }
        }
    }

    /// One long verb on the runner with the control env (QA #445 M1), plus
    /// spawnEnv's strip for --spawn. `running` shows in the row meanwhile (a
    /// History row's with `history`); `onLine` and `done` run on main. A busy
    /// key refuses: false, nothing shown.
    @discardableResult
    private func run(_ key: AgentSessionKey, dch: String, args: [String], running: String?, cwd: String? = nil,
                     bound: TimeInterval? = nil, spawn: Bool = false, history: Bool = false,
                     onLine: (@MainActor @Sendable (String) -> Void)? = nil,
                     done: @escaping @MainActor @Sendable (DchActionResult) -> Void) -> Bool {
        let env = controlEnv
        var hook: (@Sendable (String) -> Void)?
        if let onLine { hook = { line in DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } } } }
        let started = runner.start(key, path: dch, args: args, cwd: cwd, bound: bound,
                                   env: { spawn ? AgentIsland.spawnEnv(env(key.dir)) : env(key.dir) },
                                   onLine: hook) { [weak self] r in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.store != nil else { return }
                    done(r)
                    self.layout()
                }
            }
        }
        guard started else { return false }
        if let running {
            if history { store?.historyActions[key] = running } else { store?.actions[key] = running }
        }
        layout()
        return true
    }

    // MARK: - --json progress (#580)

    /// A one-row job's line: a phase is the row's running text; the result
    /// comes with `done`. Both lists refresh after a Resume: the history in
    /// `done`, the sessions on the poller's next tick.
    private func rowLine(_ line: String, key: AgentSessionKey, history: Bool = false) {
        guard let store, let o = AgentIsland.jsonLine(line), o.name == key.name, let t = AgentIsland.phaseText(o) else { return }
        if history { store.historyActions[key] = t } else { store.actions[key] = t }
        layout()
    }

    /// A dir job's line, on its row (a live session; a record for Resume
    /// crashed): a phase is the running text; a result shows where a phase or
    /// the job's own running text is up, when it failed, or when dch 1.24.1
    /// skipped a claude typed into the shell (in_shell). The master pass is
    /// Restart all's summary only.
    private func dirLine(_ line: String, dir: String, _ verb: AgentIsland.Verb) {
        guard let store, let o = AgentIsland.jsonLine(line) else { return }
        let key = AgentSessionKey(dir: dir, name: o.name), history = verb == .resume
        guard history ? store.history.contains(where: { $0.key == key }) : store.sessions.contains(where: { $0.key == key })
        else { return }
        let now = history ? store.historyActions[key] : store.actions[key]
        let text: String
        if let t = AgentIsland.phaseText(o) {
            text = t
        } else if o.isFinal, o.failed || o.reason == "in_shell" || AgentIsland.runningTexts.contains(now ?? "") {
            text = AgentIsland.finalText(o, verb)
        } else { return }
        if history { store.historyActions[key] = text } else { store.actions[key] = text }
        layout()
    }

    /// A dir job's end: the summary on the dir line; a row left on a running
    /// text (dch paused it but never reported on it again) is cleared.
    private func dirDone(_ dir: String, _ summary: String) {
        guard let store else { return }
        store.actions[AgentSessionKey(dir: dir, name: "")] = summary
        let running = AgentIsland.runningTexts
        func stale(_ e: (key: AgentSessionKey, value: String)) -> Bool { e.key.dir == dir && running.contains(e.value) }
        store.actions = store.actions.filter { !stale($0) || $0.key.name.isEmpty }
        store.historyActions = store.historyActions.filter { !stale($0) }
    }

    // MARK: - Restart and New session (#579)

    /// A row's Restart agent: `--restart <name> --include-agents -f`, even when
    /// current. A busy row refuses. Its result (a skip included) is the row's text.
    func restart(_ s: AgentSession) {
        guard let store, case .ok(let dch) = store.restartGate else { return }
        let key = s.key
        run(key, dch: dch, args: AgentIsland.restartArgs(s.name), running: AgentIsland.restartingText,
            bound: DchActionRunner.restartBound, onLine: { [weak self] in self?.rowLine($0, key: key) }) { [weak self] r in
            self?.store?.actions[key] = AgentIsland.rowText(r, name: key.name, .restart)
        }
    }

    // MARK: - Stop (#580)

    /// A row's Stop: `--stop <name> --json`, only on a master at 1.24.0 or
    /// later. A busy row (or its dir under an "all" job) refuses. The ended
    /// session shows in History after one re-read.
    func stop(_ s: AgentSession) {
        guard let store, case .ok(let dch) = store.restartGate, AgentIsland.canStop(s) else { return }
        let key = s.key
        run(key, dch: dch, args: AgentIsland.stopArgs([s.name]), running: AgentIsland.stoppingText,
            bound: DchActionRunner.restartBound, onLine: { [weak self] in self?.rowLine($0, key: key) }) { [weak self] r in
            self?.store?.actions[key] = AgentIsland.rowText(r, name: key.name, .stop)
            self?.refreshHistory()
        }
    }

    /// The "⋯" menu's Stop all in <tab>: only asks (the inline line).
    func askStopAll() {
        guard let store, store.restartGate.isOK, !store.stopAllTargets.stop.isEmpty else { return }
        store.confirmingRestartAll = false
        store.confirmingStopAll = true
        layout()
    }

    /// The inline answer. Stop recounts the shown tab and runs; Cancel runs nothing.
    func confirmStopAll(_ yes: Bool) {
        guard let store, store.confirmingStopAll else { return }
        store.confirmingStopAll = false
        if yes { stopAll() } else { layout() }
    }

    /// The shown tab's stoppable sessions by name, never `--all`: one job per
    /// dir under the dir-wide key, like Restart all, so a dir with any job
    /// running is refused whole. Each row shows "Stopping…", then its result;
    /// the dir gets "N stopped, N failed, N skipped".
    private func stopAll() {
        guard let store, case .ok(let dch) = store.restartGate else { return }
        let byDir = Dictionary(grouping: store.stopAllTargets.stop, by: \.key.dir)
        for (dir, rows) in byDir.sorted(by: { $0.key < $1.key }) {
            let key = AgentSessionKey(dir: dir, name: "")
            let started = run(key, dch: dch, args: AgentIsland.stopArgs(rows.map(\.name)), running: AgentIsland.stoppingText,
                              bound: DchActionRunner.restartBound, onLine: { [weak self] in self?.dirLine($0, dir: dir, .stop) }) {
                [weak self] r in
                self?.dirDone(dir, AgentIsland.tally(r, .stop, title: "Stop all", empty: "nothing stopped"))
                self?.refreshHistory()
            }
            if started { for s in rows { store.actions[s.key] = AgentIsland.stoppingText } }
        }
        layout()
    }

    /// The header "⋯".
    func showControlsMenu() {
        guard store != nil else { return }
        popUpMenu(makeControlsMenu())
    }

    /// New session ▸ recent folders, Choose folder…; Restart all agents. Off,
    /// with the gate's reason under them, while the gate refuses.
    func makeControlsMenu() -> NSMenu {
        let m = store?.controlsMenu ?? .init(recent: [], refused: nil), on = m.refused == nil
        let menu = NSMenu(), sub = NSMenu()
        menu.autoenablesItems = false
        sub.autoenablesItems = false
        for f in m.recent {
            sub.addItem(AgentIslandMenuItem((f as NSString).abbreviatingWithTildeInPath) { [weak self] in self?.newSession(in: f) })
        }
        if !m.recent.isEmpty { sub.addItem(.separator()) }
        sub.addItem(AgentIslandMenuItem(AgentIsland.chooseFolderLabel) { [weak self] in self?.chooseNewSessionFolder() })
        let new = AgentIslandMenuItem(AgentIsland.newSessionLabel, enabled: on)
        new.submenu = sub
        menu.addItem(new)
        // Restart all only reaches live sessions: off with history only.
        // #580 addendum 2: both off under a 1.24.0 control dch, reading "(needs dch 1.24.1)".
        let live = !(store?.sessions.isEmpty ?? true), needs = store?.restartNeeds, risky = on && needs == nil
        menu.addItem(AgentIslandMenuItem(AgentIsland.label(AgentIsland.restartAllLabel, needs: needs), enabled: risky && live) {
            [weak self] in self?.askRestartAll()
        })
        // #580: the shown tab's sessions; off when none of them can stop.
        let tab = store?.sessionTab.label ?? "Sessions", stoppable = !(store?.stopAllTargets.stop.isEmpty ?? true)
        menu.addItem(AgentIslandMenuItem(AgentIsland.label(AgentIsland.stopAllLabel(tab: tab), needs: needs), enabled: risky && stoppable) {
            [weak self] in self?.askStopAll()
        })
        if let why = m.refused {
            menu.addItem(.separator())
            menu.addItem(AgentIslandMenuItem("Controls \(why)", enabled: false))
        }
        return menu
    }

    /// The "⋯" menu's Restart all agents: only asks (the inline line).
    func askRestartAll() {
        guard let store, store.restartGate.isOK, !store.sessions.isEmpty else { return }
        store.confirmingStopAll = false
        store.confirmingRestartAll = true
        layout()
    }

    /// The inline answer. Restart runs Restart all; Cancel runs nothing.
    func confirmRestartAll(_ yes: Bool) {
        guard let store, store.confirmingRestartAll else { return }
        store.confirmingRestartAll = false
        if yes { restartAll() } else { layout() }
    }

    /// `--restart --all --include-agents --json` (no -f: stale agents only), one
    /// job per dir with a live session under the dir-wide key. A row shows dch's
    /// phases once it reaches it ("Pausing…"), then its result; the dir gets the summary.
    private func restartAll() {
        guard let store, case .ok(let dch) = store.restartGate else { return }
        for dir in Set(store.sessions.map(\.key.dir)).sorted() {
            let key = AgentSessionKey(dir: dir, name: "")
            run(key, dch: dch, args: AgentIsland.restartAllArgs, running: AgentIsland.restartAllRunningText,
                bound: DchActionRunner.restartBound, onLine: { [weak self] in self?.dirLine($0, dir: dir, .restart) }) {
                [weak self] r in self?.dirDone(dir, AgentIsland.restartAllSummary(r))
            }
        }
    }

    /// New session in `folder`: `--spawn <name> <command>` with the Process cwd
    /// set to it, into the island's first socket dir (it shows on the next tick).
    /// #606: the command is the setting's, else inferred first (off main).
    func newSession(in folder: String) {
        guard store?.resumeGate.isOK == true else { return }
        newSessionCommand { [weak self] command in self?.spawn(in: folder, command) }
    }

    private func spawn(in folder: String, _ command: [String]) {
        guard let store, case .ok(let dch) = store.resumeGate else { return }
        let dir = historyDirs().first ?? DchCommand.defaultSocketDir
        let taken = Set(store.sessions.filter { $0.key.dir == dir }.map(\.name))
            .union(store.history.filter { $0.key.dir == dir }.map(\.name))
        let args = AgentIsland.newSessionArgs(folder: folder, command: command, taken: taken)
        let key = AgentSessionKey(dir: dir, name: args[1])
        run(key, dch: dch, args: args, running: nil, cwd: folder, spawn: true) { [weak self] r in
            guard let store = self?.store else { return }
            if let failed = AgentIsland.spawnText(r, name: key.name) { store.actions[AgentSessionKey(dir: dir, name: "")] = failed }
        }
    }

    /// #606: New session's command to `done`, on main: the setting as typed;
    /// unset, inferred off main from the live sessions' records and the history
    /// already read, and stored when a real source gave it. Nothing found: `claude`,
    /// not stored. Settings asks too, when its field appears.
    func newSessionCommand(_ done: @escaping @MainActor ([String]) -> Void) {
        let typed = AgentIsland.shellWords(Preferences.agentIslandNewSessionCommand)
        guard typed.isEmpty else { done(typed); return }
        let sessions = store?.sessions ?? [], history = store?.history ?? [], read = readLiveRecords
        queue.async {
            let inferred = AgentIsland.inferredCommand(live: read(sessions), history: history)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let inferred, Preferences.agentIslandNewSessionCommand.isEmpty {
                        Preferences.agentIslandNewSessionCommand = AgentIsland.shellLine(inferred)
                    }
                    done(inferred ?? ["claude"])
                }
            }
        }
    }

    /// "Choose folder…": the island collapses, then the chooser; a folder spawns.
    func chooseNewSessionFolder() {
        guard let store, store.resumeGate.isOK else { return }
        setExpanded(false)
        chooseFolder { [weak self] path in
            if let path { self?.newSession(in: path) }
        }
    }

    /// The live chooser: directories only, after activating the app (an
    /// LSUIElement app's panel would open behind the front app). Non-modal.
    private static func openFolderPanel(_ done: @escaping @MainActor (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "New session"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { resp in
            MainActor.assumeIsolated { done(resp == .OK ? panel.url?.path : nil) }
        }
    }

    /// Size the panel to the island so nothing outside it eats clicks. #581: an
    /// open island never closes itself (a Resume's re-read can land before the
    /// tick shows the revived session); a collapsed one hides with nothing to
    /// show: no session and no history.
    private func layout() {
        guard let store else { return }
        shown = store.expanded || store.showsIsland
        guard showsPanel else { return }
        if let g = currentGeometry(), g != store.geometry { store.geometry = g }
        guard shown else { panel?.orderOut(nil); return }
        let panel = self.panel ?? makePanel(store)
        panel.setFrame(store.geometry.frame(store.size), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel(_ store: AgentIslandStore) -> AgentIslandPanel {
        let p = AgentIslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        // Above the menu bar (24) and status items, below menus (101).
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.onEscape = { [weak self] in self?.setExpanded(false) }
        let host = FirstClickHostingView(rootView: AgentIslandView(
            store: store,
            onToggle: { [weak self] in self?.setExpanded(!(self?.store?.expanded ?? true)) },
            onRow: { [weak self] in self?.jump($0) },
            onAnswer: { [weak self] in self?.answer($0, $1, $2) },
            onTab: { [weak self] in self?.showSidekicks($0) },
            onHistory: { [weak self] in self?.showHistory() },
            onResume: { [weak self] in self?.resume($0) },
            onResumeAll: { [weak self] in self?.resumeCrashed() },
            onRestart: { [weak self] in self?.restart($0) },
            onControls: { [weak self] in self?.showControlsMenu() },
            onConfirmRestartAll: { [weak self] in self?.confirmRestartAll($0) },
            onStop: { [weak self] in self?.stop($0) },
            onConfirmStopAll: { [weak self] in self?.confirmStopAll($0) }))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }

    /// Only the panel's own view expands it, so a nil panel (tests) just skips the window work.
    func setExpanded(_ on: Bool) {
        guard let store, store.expanded != on, !on || store.showsIsland else { return }
        store.expanded = on
        // #581: nothing live: open on History.
        if on, store.sessions.isEmpty, !store.history.isEmpty { store.historyTab = true }
        if !on {
            store.notices = [:]; store.cards = [:]; readAt = [:]
            store.confirmingRestartAll = false
            store.confirmingStopAll = false
            store.actions = store.actions.filter { runner.isBusy($0.key) }   // a running one keeps its "Resuming…"
            store.historyActions = store.historyActions.filter { runner.isBusy($0.key) }
        }
        refreshCards()
        if on { refreshHistory() }
        panel?.keyable = on
        layout()
        if on {
            panel?.makeKey()
            outsideClick = monitorClicks { [weak self] in
                // macOS 27 reports clicks on our own windows here too: keep those.
                guard let self, let f = self.panel?.frame, !f.contains(NSEvent.mouseLocation) else { return }
                self.setExpanded(false)
            }
        } else {
            if let m = outsideClick { removeMonitor(m) }
            outsideClick = nil
            // Hand key focus back: out and straight back in, no animation.
            if let panel, panel.isKeyWindow { panel.orderOut(nil); layout() }
        }
    }

    // MARK: - Prompt cards (#475)

    /// While expanded, re-read a blocked session's screen whenever its output
    /// moved since the last read (activity is the .act mtime); drop the cards of
    /// rows that are no longer blocked. #571: shown rows only, so a session under
    /// the other tab is never read.
    func refreshCards() {
        guard let store, store.expanded else { return }
        let blocked = store.visible.filter { $0.state == .blocked }
        let keys = Set(blocked.map(\.key))
        store.cards = store.cards.filter { keys.contains($0.key) }
        for k in readAt.keys where !keys.contains(k) { _ = bump(k) }   // a read still queued is stale
        readAt = readAt.filter { keys.contains($0.key) }
        for s in blocked where readAt[s.key] != s.activity && !inFlight.contains(s.key) {
            readAt[s.key] = s.activity
            let key = s.key, gen = bump(key), io = io
            queue.async { [weak self] in
                let card = AgentPrompt.card(screen: io.read(key))
                _ = AgentIslandGeometry.cardHeight(card)   // measure here, main only hashes
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.setCard(card, key, gen) } }
            }
        }
    }

    /// The buttons go at once, so a second click can never queue a second key;
    /// the guard re-reads and sends at most the one digit; a key in flight sends nothing.
    func answer(_ s: AgentSession, _ p: AgentPrompt, _ o: AgentPromptOption) {
        guard let store, inFlight.insert(s.key).inserted else { return }
        store.cards[s.key] = nil
        let key = s.key, gen = bump(key), io = io
        layout()
        queue.async { [weak self] in
            let r = AgentPrompt.answer(key, digit: o.digit, expected: p, io: io)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.inFlight.remove(key)
                    // sent: the next poll shows the new state
                    if r == .changed { self?.setCard(.changed, key, gen) }
                }
            }
        }
    }

    private func setCard(_ card: AgentCard, _ key: AgentSessionKey, _ gen: Int) {
        guard cardGen[key] == gen, let store, store.expanded else { return }
        store.cards[key] = card
        layout()
    }

    private func bump(_ key: AgentSessionKey) -> Int {
        cardGen[key, default: 0] += 1
        return cardGen[key]!
    }

    // MARK: - Jump

    func jump(_ s: AgentSession) {
        guard let store else { return }
        switch jumpTarget(s.key) {
        case .app(let pid):
            setExpanded(false)
            focusApp(pid, [s.title, s.name])
        case _ where clickAction() == .open:
            // #500: no local terminal window, so open one attached to the session.
            open(s)
        case .attachedElsewhere where store.notices[s.key] == nil:
            // Not jumpable; say so instead of silently copying. A second click copies.
            store.notices[s.key] = "Attached in tmux/ssh, click to copy attach command"
        case .attachedElsewhere, .notAttached:
            copyAttach(s, notice: "Attach command copied")
        }
    }

    private func copyAttach(_ s: AgentSession, notice: String) {
        let pb = Pasteboard.general
        pb.clearContents()
        pb.setString(AgentIsland.attachCommand(s.key, defaultDir: DchCommand.defaultSocketDir), forType: .string)
        store?.notices[s.key] = notice
    }

    /// Collapses once the terminal is up; a failed open copies instead and says so.
    /// #505: Ghostty first gets its Apple Event (one Automation consent, no
    /// per-click prompt); a failure falls back to the script, which shows
    /// Ghostty's own prompt (a timeout copies, see openInGhostty).
    private func open(_ s: AgentSession) {
        guard opening.insert(s.key).inserted else { return }
        let t = terminal()
        guard t == .ghostty, !ghosttyDenied else { return launch(s, t) }
        openInGhostty(s, tab: true)
    }

    /// #527: a new tab first (Ghostty makes a window when it has none). Ghostty
    /// refusing the tab (non-native fullscreen: -10000) tries a new window. Not up
    /// in time (-600) or no handler (-1708) go to the script as before: a second
    /// event would wait again or fail the same way. #529: a timeout (-1712) may
    /// still have opened the tab, so it opens nothing more and copies instead.
    /// #545: a -1708 here is an undeclared command; the sender maps a declared one to noErr.
    private func openInGhostty(_ s: AgentSession, tab: Bool) {
        let dch = DchCommand.dchPath
        let event = tab ? AgentIsland.ghosttyNewTab(s.key, dch: dch) : AgentIsland.ghosttyNewWindow(s.key, dch: dch)
        sendGhostty(event) { [weak self] status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if status == noErr { return self.opened(s, .ghostty, ok: true) }
                    if status == errAEEventNotPermitted { self.ghosttyDenied = true }
                    // Torn down meanwhile: no fallback opens anything; opened() only clears `opening`.
                    guard self.store != nil else { return self.opened(s, .ghostty, ok: false) }
                    if status == errAETimeout {
                        self.opening.remove(s.key)
                        return self.copyAttach(s, notice: "Ghostty didn't answer, attach command copied")
                    }
                    let toScript = [errAEEventNotPermitted, procNotFound, errAEEventNotHandled]
                    if tab, !toScript.map(OSStatus.init).contains(status) { return self.openInGhostty(s, tab: false) }
                    self.launch(s, .ghostty)
                }
            }
        }
    }

    private func launch(_ s: AgentSession, _ t: AgentTerminal) {
        launchTerminal(t, t.launch(AgentIsland.attachArgv(s.key, dch: DchCommand.dchPath))) { [weak self] ok in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.opened(s, t, ok: ok) } }
        }
    }

    private func opened(_ s: AgentSession, _ t: AgentTerminal, ok: Bool) {
        opening.remove(s.key)
        guard store != nil else { return }   // torn down meanwhile
        if ok { setExpanded(false) } else {
            copyAttach(s, notice: "Couldn't open \(t.label), attach command copied")
        }
    }

    /// A non-activating panel's app is never active, and macOS 14+ cooperative
    /// activation ignores `activate()` from it; a Launch Services open does not.
    private static func activate(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        guard let url = app.bundleURL else { app.activate(); return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            if error != nil { DispatchQueue.main.async { app.activate() } }
        }
    }

    /// Best effort: terminals title windows after the program (Claude sets
    /// "✳ <task>"), so a miss just leaves the app's front window.
    private static func raiseWindow(pid: pid_t, matching needles: [String]) {
        guard AXIsProcessTrusted() else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return }
        let lowered = needles.filter { !$0.isEmpty }.map { $0.lowercased() }
        for w in windows {
            // #477 L1: the timeout is per element (the app's does not carry over to
            // its windows), and a timed-out read means a hung app: stop asking it.
            AXUIElementSetMessagingTimeout(w, 0.25)
            var t: CFTypeRef?
            let read = AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            if read == .cannotComplete { return }
            guard read == .success,
                  let title = (t as? String)?.lowercased(),
                  lowered.contains(where: title.contains) else { continue }
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            return
        }
    }

    private func teardown() {
        if timer != nil { onSessions?(nil) }
        timer?.cancel(); timer = nil
        if let m = outsideClick { removeMonitor(m) }
        outsideClick = nil
        if let o = screenObserver { center.removeObserver(o) }
        screenObserver = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        store = nil
        shown = false
    }
}

/// #579: a menu item that runs a closure (the "⋯" menu has no responder chain
/// to target). `enabled: false` is a plain line (the gate's reason).
final class AgentIslandMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, enabled: Bool = true, run: @escaping () -> Void = {}) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not from a nib") }

    @objc private func fire() { run() }
}

/// #500: the live launcher behind AgentIslandController.launchTerminal.
enum AgentTerminalLauncher {
    /// `done` runs on any thread. Nonisolated, so its closures are too (a
    /// main-inferred closure called off main traps under Swift 6).
    nonisolated static func launch(_ t: AgentTerminal, _ launch: AgentTerminal.Launch,
                                   done: @escaping @Sendable (Bool) -> Void) {
        // Belt and braces: a test that forgot the seam never starts a real terminal.
        guard NSClassFromString("XCTestCase") == nil,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: t.bundleID) else {
            done(false); return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        switch launch {
        case .arguments(let args):
            cfg.createsNewApplicationInstance = true
            cfg.arguments = args
            NSWorkspace.shared.openApplication(at: app, configuration: cfg) { @Sendable _, error in done(error == nil) }
        case .script(let text):
            // A subdir: the $TMPDIR root is huge and slow to create in.
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prosper-attach", isDirectory: true)
            let file = dir.appendingPathComponent("\(UUID().uuidString).command")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data(text.utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            } catch { done(false); return }
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: cfg) { @Sendable _, error in
                if error != nil { try? FileManager.default.removeItem(at: file) }
                done(error == nil)
            }
        }
    }
}

/// #505: the live sender behind AgentIslandController.sendGhostty.
enum GhosttyEventSender {
    /// `done` runs on a background queue: noErr once the window is up, else the
    /// AE error (-600 not running, -1743 denied, -1708 no dictionary, -1712 timeout).
    /// #545: -1708 for a command the installed sdef declares is noErr (see opened).
    nonisolated static func send(_ event: NSAppleEventDescriptor, done: @escaping @Sendable (OSStatus) -> Void) {
        // Belt and braces: a test that forgot the seam never sends a real Apple Event.
        guard NSClassFromString("XCTestCase") == nil else { done(OSStatus(procNotFound)); return }
        nonisolated(unsafe) let event = event   // built for this send, touched only on the queue
        DispatchQueue.global(qos: .userInitiated).async {
            let status = opened(deliver(attempt: { attempt(event) }, launch: activateGhostty,
                                        sleep: { Thread.sleep(forTimeInterval: $0) }),
                                declared: { declares(installedSdef(), event) })
            // Cooperative activation may ignore Ghostty's own activate: bring it
            // forward through Launch Services, as the script path does.
            if status == noErr { activateGhostty() }
            done(status)
        }
    }

    /// Ghostty not running (-600): launch it once, then retry every 0.5 s for up
    /// to 8 s while it is still starting (-600). #545: only -600, an undelivered
    /// event; any other status (-1708 included) was delivered, and a resend repeats
    /// its side effect (16 tabs). Pure over its seams (tests drive it).
    nonisolated static func deliver(attempt: () -> OSStatus, launch: () -> Void,
                                    sleep: (TimeInterval) -> Void) -> OSStatus {
        var status = attempt()
        guard status == procNotFound else { return status }
        launch()
        for _ in 0..<16 where status == procNotFound {
            sleep(0.5)
            status = attempt()
        }
        return status
    }

    /// #545: a -1708 to a command Ghostty's dictionary declares means the handler
    /// ran and then threw building its reply (the tab is open): treat it as noErr.
    /// `declared` is asked only for a -1708.
    nonisolated static func opened(_ status: OSStatus, declared: () -> Bool) -> OSStatus {
        status == errAEEventNotHandled && declared() ? noErr : status
    }

    /// #545: whether the sdef text declares the event's command (code="GhstNTab").
    nonisolated static func declares(_ sdef: String, _ event: NSAppleEventDescriptor) -> Bool {
        let code = [event.eventClass, event.eventID].map {
            String(decoding: withUnsafeBytes(of: $0.bigEndian) { Array($0) }, as: UTF8.self)
        }.joined()
        return sdef.contains("code=\"\(code)\"")
    }

    /// #545: the installed Ghostty's sdef (Info.plist OSAScriptingDefinition), or ""
    /// with none. Plain file reads, no Bundle cache, so an updated Ghostty counts.
    private nonisolated static func installedSdef() -> String {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentTerminal.ghostty.bundleID),
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let name = info["OSAScriptingDefinition"] as? String else { return "" }
        let url = app.appendingPathComponent("Contents/Resources").appendingPathComponent(name)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The one-time Automation consent alert blocks this queue (never main) until
    /// answered; the send itself is bounded.
    private nonisolated static func attempt(_ event: NSAppleEventDescriptor) -> OSStatus {
        let target = event.attributeDescriptor(forKeyword: keyAddressAttr)
        let status = AEDeterminePermissionToAutomateTarget(target?.aeDesc, event.eventClass, event.eventID, true)
        guard status == noErr else { return status }
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 5)
            return reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? noErr
        } catch { return OSStatus((error as NSError).code) }
    }

    /// Launches Ghostty (its own startup window included) or brings it forward:
    /// the running instance, no arguments, never `-e`.
    private nonisolated static func activateGhostty() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentTerminal.ghostty.bundleID) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: cfg, completionHandler: nil)
    }
}

extension AgentPromptIO {
    /// Every call runs with DCH_SOCKET_DIR = the session's own dir, never the
    /// Remote Terminal env. `--read` is the plain visible screen; `--send` types
    /// its text as raw bytes with no Enter. Each call is bounded (#477): a timed-out
    /// read or status is empty, so a card reads as changed and nothing is sent.
    static let live = live { DchCommand.runIsland(args: $0, env: $1) ?? Data() }

    /// `run` gets the argv and env; tests pass a recorder.
    static func live(run: @escaping @Sendable ([String], [String: String]) -> Data) -> AgentPromptIO {
        @Sendable func dch(_ args: [String], _ key: AgentSessionKey) -> String {
            String(decoding: run(args, AgentIsland.listEnv(dir: key.dir)), as: UTF8.self)
        }
        return AgentPromptIO(
            read: { dch(["--read", $0.name], $0) },
            status: { dch(["--status", $0.name], $0) },
            send: { _ = dch(["--send", $0.name, $1], $0) })
    }
}

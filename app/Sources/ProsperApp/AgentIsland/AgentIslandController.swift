// Owns Agent Island (#474) end to end: the borderless non-activating panel over
// the notch, the 1 s stat poll on a utility queue (dch is forked only when the
// gate in AgentIslandModel says so), expand/collapse, the row-click jump, and
// (#475) the prompt cards of blocked sessions and their answer clicks.
// Gated by the com.prosper.agentisland system extension (ships default-disabled)
// exactly like CalendarBarController: AppDelegate sets `extLive` at launch and
// on every extension toggle, and `reload()` builds or tears everything down — a
// disabled install has no panel, no timer and never forks dch.

import AppKit
import os
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
    /// Internal for #1112's tests, which set a never-shown panel after expanding; only makePanel sets it in the app.
    var panel: AgentIslandPanel?
    private(set) var timer: DispatchSourceTimer?
    private(set) var outsideClick: Any?
    /// #1112: while expanded, the local click monitor and the key-window and menu-tracking observers (on `center`).
    private(set) var ownClick: Any?
    private(set) var focusObservers: [NSObjectProtocol] = []
    /// #1112: menus tracking now (the "⋯" and row menus are NSMenus). Nothing new closes the island meanwhile.
    private(set) var menusTracking = 0
    private(set) var screenObserver: NSObjectProtocol?
    /// #768: display sleep and screen lock (the same notifications Stats pauses on).
    private var sleepObservers: [(NSObjectProtocol, NotificationCenter)] = []
    /// QA #607 INFO-4 seam: the center each screen event is observed on. Under XCTest
    /// a private one, so no test registers a real workspace or distributed observer.
    var screenCenter: @MainActor (ScreenGate.Event) -> NotificationCenter = { e in
        if NSClassFromString("XCTestCase") != nil { return AgentIslandController.testScreenCenter }
        return ScreenGate.center(for: e) == .distributed
            ? DistributedNotificationCenter.default() : NSWorkspace.shared.notificationCenter
    }
    static let testScreenCenter = NotificationCenter()
    private(set) var screen = ScreenGate()
    private var poller: AgentIslandPoller?
    /// #768: the newest list when only its activity moved while collapsed or
    /// unseen: published, but not in the store until the island opens or shows again.
    private(set) var deferred: [AgentSession]?
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
    /// The poll timer's period; tests set a long one, so only an explicit refresh ticks.
    var pollEvery: TimeInterval = 1
    var io = AgentPromptIO.live
    var showsPanel = true
    /// More seams (#477): the screen geometry, the center the screen observer
    /// lives on, the outside-click monitor (tests never install a real global
    /// one), the row-click walk, and the main-thread font warm-up.
    var currentGeometry: @MainActor () -> AgentIslandGeometry? = { AgentIslandGeometry.current() }
    var center = NotificationCenter.default
    var monitorClicks: (@escaping @MainActor () -> Void) -> Any? = { onClick in
        NSEvent.addGlobalMonitorForEvents(matching: AgentIslandController.clickMask) { _ in
            MainActor.assumeIsolated { onClick() }
        }
    }
    /// #1112: a global monitor is never sent this app's own events (NSEvent.h), so a click in Settings,
    /// Agent Sessions or any other Prosper window comes through a local one. The handler gets the
    /// clicked window and the click in screen points. Inert under XCTest: no test installs a real
    /// monitor; tests pass a fake and call the handler.
    var monitorOwnClicks: @MainActor (@escaping @MainActor (NSWindow?, NSPoint?) -> Void) -> Any? = { onClick in
        NSClassFromString("XCTestCase") != nil ? nil
            : NSEvent.addLocalMonitorForEvents(matching: AgentIslandController.clickMask,
                                               handler: AgentIslandController.passThrough(onClick))
    }
    var removeMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }
    /// Mouse downs only: a drag's dragged and up events never close the island.
    nonisolated static let clickMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
    /// #1112: the local monitor's block. It hands every event on unchanged: closing the island never
    /// swallows the click the other window was meant to get.
    static func passThrough(_ onClick: @escaping @MainActor (NSWindow?, NSPoint?) -> Void) -> (NSEvent) -> NSEvent? {
        { e in
            MainActor.assumeIsolated {
                let w = e.window
                onClick(w, w?.convertPoint(toScreen: e.locationInWindow))
            }
            return e
        }
    }
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
    /// #744 (QA #572 INFO-1): rows a Kill started on since their last other job: a
    /// Stop or Restart it cut through leaves the row's text to the Kill. #749 (QA #572
    /// INFO-R4): the value is that job's last text held back ("" none), for a Kill that fails.
    /// #750 (QA #576 INFO-4): from the row's running text when the Kill started.
    private(set) var killedRows: [AgentSessionKey: String] = [:]
    /// #523: every published list, on main, and nil when the island stops.
    /// LiveStatusPublisher listens (set by AppDelegate; tests leave it nil).
    var onSessions: (@MainActor ([AgentSession]?) -> Void)?
    /// #765: every rowDetailsChanged, a sidekick pattern edit or adopt among them (the watch stream).
    var onRowDetails: (@MainActor () -> Void)?
    /// #797: the Agents window is open and visible. It reads the store, so a list
    /// where only activity moved goes in as while expanded, not held back.
    /// #829 G0b: and one History read on the edge to visible, so the window never opens on a stale History.
    var windowWatching = false {
        didSet {
            if windowWatching { flushDeferred() }
            if windowWatching, !oldValue { refreshHistory() }
        }
    }
    /// #797: the store was built or dropped (the Agents window rebinds).
    var onStoreChanged: (@MainActor () -> Void)?
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
    /// #720 seams: the socket dirs whose live sessions seed the held Claude ids (none
    /// under XCTest), and their listing.
    var seedDirs: @Sendable () -> [String] = {
        NSClassFromString("XCTestCase") == nil ? AgentIsland.seedSocketDirs() : []
    }
    var listSessions: @Sendable ([String]) -> [AgentSession] = { AgentIsland.list(dirs: $0) }
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
        Preferences.removeRetiredRowDetailKeys()   // #762
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
        if sleepObservers.isEmpty {
            for (name, event) in ScreenGate.notifications {
                let c = screenCenter(event)
                sleepObservers.append((c.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.screenChanged(event) }
                }, c))
            }
        }
        guard timer == nil, let geometry = currentGeometry() else { return }
        store = AgentIslandStore(geometry: geometry, details: Preferences.agentIslandRowDetails,
                                 sort: Preferences.agentIslandSort, sidekickPattern: Self.sidekickPattern)
        onStoreChanged?()
        let poller = makePoller(), hidden = screen.hidden
        queue.async { poller.hidden = hidden }
        self.poller = poller
        let t = Self.makePollTimer(poller, queue: queue, every: pollEvery) { [weak self] sessions in
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
    nonisolated static func makePollTimer(_ poller: AgentIslandPoller, queue: DispatchQueue, every: TimeInterval = 1,
                                          onSessions: @escaping @Sendable ([AgentSession]) -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: every, leeway: .milliseconds(250))
        t.setEventHandler {
            guard let sessions = poller.tick() else { return }
            onSessions(sessions)
        }
        return t
    }

    /// #768: a display sleep, wake, lock or unlock. The poller backs off to the
    /// hidden backstop; a list held back while unseen goes in once the island shows.
    func screenChanged(_ e: ScreenGate.Event) {
        screen.apply(e)
        pushHidden()
        if !screen.hidden, store?.expanded == true { flushDeferred() }
    }

    private func pushHidden() {
        if let poller { let h = screen.hidden; queue.async { poller.hidden = h } }
    }

    private func flushDeferred() {
        guard let d = deferred, let store else { return }
        deferred = nil
        store.sessions = d
        refreshCards()
        layout()
    }

    private func apply(_ sessions: [AgentSession]) {
        guard timer != nil, let store else { return }   // a tick that raced teardown
        let sessions = withSent(sessions)
        // #768: only ages moved and nobody sees them (collapsed, or the display
        // asleep or locked): Live status and the watch stream still get the list,
        // the store, cards and panel do not.
        if !(store.expanded || windowWatching) || screen.hidden, AgentIsland.onlyActivityMoved(sessions, store.sessions) {
            deferred = sessions
            recheckHuman()   // #791: a print on a row left to the human is all that moved
            onSessions?(published(sessions))
            return
        }
        deferred = nil
        let was = Set(store.sessions.map(\.key))
        store.sessions = sessions
        checkAutoAllow()   // #751: decided before the list is published
        publish()
        let live = Set(sessions.map(\.key))
        store.notices = store.notices.filter { live.contains($0.key) }
        // #580: a session that ended (a Stop) takes its row's text with it, so a
        // later session of that name starts clean.
        if store.actions.contains(where: { !$0.key.name.isEmpty && !live.contains($0.key) }) {
            store.actions = store.actions.filter { $0.key.name.isEmpty || live.contains($0.key) || runner.isBusy($0.key) }
        }
        killedRows = killedRows.filter { live.contains($0.key) || runner.isBusy($0.key) }
        // #581: the last session gone: one history read, so its record can keep the
        // island. On that edge only, never per tick.
        // ponytail: with no history yet the collapsed ear hides for the ~100 ms the
        // read takes, then shows; keep the island up meanwhile if that ever flickers.
        // #829 G0b: while the window watches, any session leaving (it ended by itself, or a
        // terminal killed it) is that edge too, so its record reaches the window's History.
        if !was.isEmpty, sessions.isEmpty || windowWatching && !was.isSubset(of: live) { refreshHistory() }
        refreshCards()
        layout()
    }

    /// #534: a Settings row-detail toggle; #571: the sort, the sidekick tabs
    /// toggle or pattern. Redraws the island and resizes the panel at once (a
    /// row losing its PR line is 48 pt again, a tab change shows other rows);
    /// no animation.
    func rowDetailsChanged() {
        onRowDetails?()
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
        store.confirmingClear = false   // #605: History's question goes with its tab
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
        let live = readLiveRecords, sessions = store?.sessions ?? [], seed = seedDirs, list = listSessions
        queue.async { [weak self] in
            let dch = probe()
            let records = dch.map { DchCommand.isAtLeast($0.version, AgentIsland.controlMinimum) ? read($0.path, dirs) : [] } ?? []
            // #719: the Claude ids dch 1.28.2's --revive --all holds; never read below it.
            // #720 (QA #535 M-1): also the sessions of a socket dir the view does not list.
            let held = dch.map { DchCommand.isAtLeast($0.version, AgentIsland.reviveFileMinimum) } == true
                ? Set(live(sessions + list(seed().filter { !dirs.contains($0) })).compactMap { $0.agent?.sessionID }.filter { !$0.isEmpty })
                : []
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.setHistory(records, dch, held) } }
        }
    }

    private func setHistory(_ records: [DchHistoryRecord], _ dch: DchCommand.Binary?, _ held: Set<String>) {
        guard let store else { return }
        store.controlDch = dch
        store.liveSIDs = held
        store.history = records
        if store.unpinnedCount == 0 { store.confirmingClear = false }   // #627 I4: no "Clear 0 unpinned?"
        // A record gone (revived) takes its status with it; running ones, the --all
        // lines and #579's live rows (a Restart result) stay.
        let recordKeys = Set(records.map(\.id)), live = Set(store.sessions.map(\.key))
        store.historyActions = store.historyActions.filter { recordKeys.contains($0.key) || runner.isBusy($0.key) }
        store.actions = store.actions.filter { $0.key.name.isEmpty || live.contains($0.key) || runner.isBusy($0.key) }
        layout()
    }

    /// A History row's click. A name that is live now revives under the first
    /// free `<name>-N`. A busy row refuses (the runner never queues).
    /// #669: `noMessage` is the row's Resume (no message), on its own 1.27.0 gate.
    func resume(_ r: DchHistoryRecord, noMessage: Bool = false) {
        guard let store, case .ok(let dch) = noMessage ? store.reviveNoMessageGate : store.resumeGate else { return }
        let live = Set(store.sessions.filter { $0.key.dir == r.key.dir }.map(\.name))
        let records = Set(store.history.filter { $0.key.dir == r.key.dir && $0.key != r.key }.map(\.name))
        // #714: the row's own id (an aside record's is its file); dch's lines carry the name.
        let key = r.id, name = r.name, verb: AgentIsland.Verb = noMessage ? .resumeNoMessage : .resume
        // #719: `<file>.json` from dch 1.28.2.
        let exact = store.reviveFileGate.isOK, arg = r.editTarget(exact: exact)
        run(key, dch: dch, args: AgentIsland.reviveArgs(r, live: live, records: records, noMessage: noMessage, exact: exact),
            running: AgentIsland.resumingText,
            history: true, onLine: { [weak self] in self?.rowLine($0, key: key, name: name, history: true) }) { [weak self] res in
            // #716 L-3: dch names a no_history line after the argument (an aside file; #719 `<file>.json`).
            let text = AgentIsland.rowText(DchControlOps.renamed(res, arg, to: name), name: name, verb)
            self?.store?.historyActions[key] = AgentIsland.byHand(text, r)
            self?.refreshHistory()
        }
    }

    /// The Resume interrupted button, and nothing else: `--revive --all` in each dir
    /// with history. Never on launch, a timer or a reconnect — after a reboot
    /// every session reads "vanished" and would qualify. #669: `noMessage` is its "(no message)".
    func resumeCrashed(noMessage: Bool = false) {
        guard let store, case .ok(let dch) = noMessage ? store.reviveNoMessageGate : store.resumeGate else { return }
        let verb: AgentIsland.Verb = noMessage ? .resumeNoMessage : .resume
        for dir in Set(store.history.map(\.key.dir)).sorted() {
            let key = AgentSessionKey(dir: dir, name: "")
            run(key, dch: dch, args: noMessage ? AgentIsland.reviveAllNoMessageArgs : AgentIsland.reviveAllArgs,
                running: AgentIsland.resumingText,
                onLine: { [weak self] in self?.dirLine($0, dir: dir, verb) }) { [weak self] r in
                self?.dirDone(dir, AgentIsland.tally(r, verb, title: verb.rawValue, empty: "nothing to resume"))
                self?.refreshHistory()
            }
        }
    }

    // MARK: - Pin, Remove and Clear unpinned (#605)

    /// A History row's pin toggle: `--pin`, or `--unpin` on a pinned record.
    func pin(_ r: DchHistoryRecord) {
        edit(r, args: AgentIsland.pinArgs(editTargets(r, forget: false), pin: !r.pinned), r.pinned ? .unpin : .pin)
    }

    /// A History row's X: `--forget <name>` at once, no -f; a pinned row has none.
    func remove(_ r: DchHistoryRecord) {
        guard !r.pinned else { return }
        edit(r, args: AgentIsland.forgetArgs(editTargets(r, forget: true)), .remove)
    }

    /// #714: `<file>.json` (one record each) once the control dch is 1.28.1.
    /// #743: the row's record and every older one of its name it folds.
    private func editTargets(_ r: DchHistoryRecord, forget: Bool) -> [String] {
        AgentIsland.editTargets(r, older: AgentIsland.older(r, in: store?.history ?? []),
                                exact: store?.recordFileGate.isOK == true, forget: forget)
    }

    /// One edit in the record's dir on the row's key (a busy row refuses); a
    /// failure goes on the dir's status line, then History is re-read.
    private func edit(_ r: DchHistoryRecord, args: [String]?, _ verb: AgentIsland.Verb) {
        guard let store, case .ok(let dch) = store.historyEditGate else { return }
        let dir = r.key.dir, name = r.name, sid = r.agent?.sessionID ?? ""
        run(r.id, dch: dch, args: args, running: nil) { [weak self] res in
            if let failed = AgentIsland.editFailure(res, name: name, verb, sid: sid) {
                self?.store?.actions[AgentSessionKey(dir: dir, name: "")] = failed
            }
            self?.refreshHistory()
        }
    }

    /// The History header's Clear unpinned: only asks (the inline line).
    func askClearUnpinned() {
        guard let store, store.clearUnpinnedButton != nil else { return }
        store.dropQuestions()
        store.confirmingClear = true
        layout()
    }

    /// The inline answer. Clear runs `--forget --all` once per History dir; Cancel runs nothing.
    func confirmClearUnpinned(_ yes: Bool) {
        guard let store, store.confirmingClear else { return }
        store.confirmingClear = false
        guard yes, case .ok(let dch) = store.historyEditGate else { return layout() }
        for dir in Set(store.history.map(\.key.dir)).sorted() {
            run(AgentSessionKey(dir: dir, name: ""), dch: dch, args: AgentIsland.forgetAllArgs,
                running: AgentIsland.clearingText) { [weak self] r in
                self?.dirDone(dir, AgentIsland.tally(r, .clear, title: "Clear unpinned", empty: "nothing to clear"))
                self?.refreshHistory()
            }
        }
        layout()
    }

    /// One long verb on the runner with the control env (QA #445 M1), plus
    /// spawnEnv's strip for --spawn. `running` shows in the row meanwhile (a
    /// History row's with `history`); `onLine` and `done` run on main. A busy
    /// key refuses: false, nothing shown; so does nil args (#627: a name dch would read as a flag).
    /// #744: `yields` (a Stop or Restart) lets a `kill` run beside it; any other job
    /// starting hands its rows' text back from an earlier Kill.
    @discardableResult
    private func run(_ key: AgentSessionKey, dch: String, args: [String]?, running: String?, cwd: String? = nil,
                     bound: TimeInterval? = nil, spawn: Bool = false, history: Bool = false,
                     yields: Bool = false, kill: Bool = false,
                     onLine: (@MainActor @Sendable (String) -> Void)? = nil,
                     prepare: (@Sendable () -> (args: [String]?, out: Data))? = nil,
                     done: @escaping @MainActor @Sendable (DchActionResult) -> Void) -> Bool {
        guard let args else { return false }
        let env = controlEnv
        var hook: (@Sendable (String) -> Void)?
        if let onLine { hook = { line in DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } } } }
        let started = runner.start(key, path: dch, args: args, cwd: cwd, bound: bound, yields: yields, kill: kill,
                                   env: { spawn ? AgentIsland.spawnEnv(env(key.dir)) : env(key.dir) },
                                   onLine: hook, prepare: prepare) { [weak self] r in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.store != nil else { return }
                    done(r)
                    self.layout()
                }
            }
        }
        guard started else { return false }
        if kill {
            // #750 (QA #576 INFO-4): a running text up now is held, so a dir job's result for
            // the row (shown only over one, dirLine) is held as well.
            let now = store?.actions[key] ?? ""
            killedRows[key] = AgentIsland.runningTexts.contains(now) ? now : ""
        } else {
            killedRows = killedRows.filter { $0.key != key && !(key.name.isEmpty && $0.key.dir == key.dir) }
        }
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
    private func rowLine(_ line: String, key: AgentSessionKey, name: String? = nil, history: Bool = false) {
        guard let store, let o = AgentIsland.jsonLine(line), o.name == name ?? key.name, let t = AgentIsland.phaseText(o) else { return }
        if history { store.historyActions[key] = t } else { setRow(key, t) }
        layout()
    }

    /// A dir job's line, on its row (a live session; a record for Resume
    /// crashed): a phase is the running text; a result shows where a phase or
    /// the job's own running text is up, when it failed, or when dch 1.24.1
    /// skipped a claude typed into the shell (in_shell). The master pass is
    /// Restart all's summary only.
    /// #584: `only`, the names the job asked about; a line for any other is ignored.
    private func dirLine(_ line: String, dir: String, _ verb: AgentIsland.Verb, only: Set<String>? = nil) {
        guard let store, let o = AgentIsland.jsonLine(line), only?.contains(o.name) ?? true else { return }
        let history = verb == .resume || verb == .resumeNoMessage
        var key = AgentSessionKey(dir: dir, name: o.name), record: DchHistoryRecord?, named = false
        if history {
            // #719 L-1: dch 1.28.2 names a skip's record, "(record <file>)": that row, always shown.
            if let file = AgentIsland.recordFile(o), let r = store.history.first(where: { $0.key.dir == dir && $0.file == file }) {
                record = r
                named = true
            } else {
                // #714: a line names no aside file. #716 L-1: the row of the name's newest
                // record --all takes (dch skips a stopped one; #719 a held Claude id), else the name's newest.
                let mine = store.history.filter { $0.key == key }, taken = store.reviveAllTaken, sid = o.sessionID ?? ""
                // #720 (QA #535 L-4): a final names its Claude id (dch's rv_say); from 1.28.2 no two
                // taken records of a dir share one, so it lands on its own row, and shows there.
                if !sid.isEmpty, let r = mine.first(where: { taken.contains($0.id) && $0.agent?.sessionID == sid }) {
                    record = r
                    named = true
                } else {
                    record = mine.first { taken.contains($0.id) } ?? mine.first
                }
            }
            guard let r = record else { return }
            key = r.id
        } else {
            guard store.sessions.contains(where: { $0.key == key }) else { return }
        }
        let now = history ? store.historyActions[key] : killedRows[key] ?? store.actions[key]   // #750: under a Kill, the held text
        let text: String
        if let t = AgentIsland.phaseText(o) {
            text = t
        } else if o.isFinal, named || o.failed || o.reason == "in_shell" || AgentIsland.runningTexts.contains(now ?? "") {
            text = AgentIsland.byHand(AgentIsland.finalText(o, verb), record)
        } else { return }
        if history { store.historyActions[key] = text } else { setRow(key, text) }
        layout()
    }

    /// QA #572 INFO-1: a Stop's or Restart's row text, unless a Kill cut through it:
    /// then the row keeps the Kill's outcome, and the text is held for a Kill that fails.
    private func setRow(_ key: AgentSessionKey, _ text: String) {
        if killedRows[key] != nil { killedRows[key] = text } else { store?.actions[key] = text }
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
    /// #829: false when nothing started; with `sayBusy` (the window's call) a busy row says so
    /// (refuseBusy). The island's own call stays silent, as before.
    @discardableResult
    func restart(_ s: AgentSession, sayBusy: Bool = false) -> Bool {
        guard let store, case .ok(let dch) = store.restartGate, let args = AgentIsland.restartArgs(s.name) else { return false }
        let key = s.key
        let started = run(key, dch: dch, args: args, running: AgentIsland.restartingText,
                          bound: DchActionRunner.restartBound, yields: true, onLine: { [weak self] in self?.rowLine($0, key: key) }) {
            [weak self] r in
            self?.setRow(key, AgentIsland.rowText(r, name: key.name, .restart))
        }
        if !started, sayBusy { refuseBusy(key, AgentIsland.restartBusyText) }
        return started
    }

    /// #829: a Restart or Stop a busy row refused: the row says so, but only over nothing or
    /// another refusal. A running text says what runs (and the window's input lock reads it);
    /// an outcome ("Killed") outlives the refusal. Goes once the job that refused it ends.
    private func refuseBusy(_ key: AgentSessionKey, _ text: String) {
        if let now = store?.actions[key], ![AgentIsland.restartBusyText, AgentIsland.stopBusyText, AgentIsland.killBusyText,
                                            AgentIsland.renameBusyText, AgentIsland.messageBusyText].contains(now) {
            return
        }
        store?.actions[key] = text
        clearRefusal(key, text)
    }

    // MARK: - Stop (#580)

    /// A row's Stop: `--stop <name> --json`, only on a master at 1.24.0 or
    /// later. A busy row (or its dir under an "all" job) refuses. The ended
    /// session shows in History after one re-read.
    /// #829: false when nothing started; with `sayBusy` (the window's call) a busy row says so.
    @discardableResult
    func stop(_ s: AgentSession, sayBusy: Bool = false) -> Bool {
        guard let store, case .ok(let dch) = store.restartGate, AgentIsland.canStop(s),
              let args = AgentIsland.stopArgs([s.name]) else { return false }
        let key = s.key
        let started = run(key, dch: dch, args: args, running: AgentIsland.stoppingText,
                          bound: DchActionRunner.restartBound, yields: true, onLine: { [weak self] in self?.rowLine($0, key: key) }) {
            [weak self] r in
            self?.setRow(key, AgentIsland.rowText(r, name: key.name, .stop))
            self?.refreshHistory()
        }
        if !started, sayBusy { refuseBusy(key, AgentIsland.stopBusyText) }
        return started
    }

    // MARK: - Message (#584)

    /// A row's Message…: the composer in the control line, for this row (any other question goes).
    /// Only while open (the panel is key then), on the base gate, for a live row dch can name; a busy
    /// row (a job, or a window action in flight) refuses here and says so, before anything is typed.
    func askMessage(_ s: AgentSession) {
        guard let store, store.expanded, store.resumeGate.isOK, AgentIsland.passable(s.name),
              store.sessions.contains(where: { $0.key == s.key }) else { return }
        if runner.isBusy(s.key) || inFlight.contains(s.key) { return refuseBusy(s.key, AgentIsland.messageBusyText) }
        store.dropQuestions()
        store.ask([s], skipped: 0, global: true)
        store.messageDraft = ""
        layout()
    }

    /// The "⋯" menu's Message all in <tab>…: the composer for the shown tab's live rows, fixed now.
    func askMessageAll() {
        guard let store, store.expanded, store.resumeGate.isOK else { return }
        let t = store.messageAllTargets
        guard !t.rows.isEmpty else { return }
        store.dropQuestions()
        store.ask(t.rows, skipped: t.skipped, global: false)
        store.messageDraft = ""
        layout()
    }

    /// Cancel or Esc: the composer closes and its draft goes.
    func cancelMessage() {
        guard let store, store.messageDraft != nil else { return }
        store.dropQuestions()
        layout()
    }

    /// The panel's Esc: the composer first, else the island collapses.
    func escape() {
        if store?.messageDraft != nil { cancelMessage() } else { setExpanded(false) }
    }

    /// Send or Enter: `--say <names…> --json -- <text>` on the composer's rows still live, the text one argv
    /// element. A row's Message is a job on the row's key; Message all one job per dir under the dir-wide key,
    /// like Stop all, so a dir with any job running (or a row with a window action in flight) is refused whole
    /// and says so. The composer closes; the text goes nowhere but dch's argv.
    /// #584 r2: in the job, before the say, the window's screen guard reads each name (messageScreens): a
    /// refused one is left out of the say and reads as skipped in the window's words. The job's hold (its
    /// key in the runner, its running text, which the window's input lock reads) covers the reads and the say.
    /// A gate that fell while the composer was open closes it and says why on its rows' line.
    func sendMessage() {
        guard let store, let draft = store.messageDraft, let text = AgentIsland.messageText(draft) else { return }
        let rows = store.messageTargets, all = store.asked.tab != nil, io = io
        store.dropQuestions()
        guard case .ok(let dch) = store.resumeGate else {
            let why = "Controls \(store.resumeGate.refusal ?? "")"
            for s in rows { store.actions[all ? AgentSessionKey(dir: s.key.dir, name: "") : s.key] = why }
            return layout()
        }
        for (dir, group) in Dictionary(grouping: rows, by: \.key.dir).sorted(by: { $0.key < $1.key }) {
            let names = group.map(\.name), only = Set(names)
            let key = all ? AgentSessionKey(dir: dir, name: "") : group[0].key
            let line: (@MainActor @Sendable (String) -> Void)? = { [weak self] in self?.dirLine($0, dir: dir, .message, only: only) }
            let screens: @Sendable () -> (args: [String]?, out: Data) = {
                let g = AgentIsland.messageScreens(io, dir: dir, names: names)
                return (g.names.isEmpty ? nil : AgentIsland.messageArgs(g.names, text), g.out)
            }
            var started = false
            if !group.contains(where: { inFlight.contains($0.key) }) {
                started = run(key, dch: dch, args: AgentIsland.messageArgs(names, text), running: AgentIsland.sendingText,
                              bound: DchActionRunner.messageBound, onLine: all ? line : nil, prepare: screens) { [weak self] r in
                    if all { self?.dirDone(dir, AgentIsland.messageTally(r, names: names)) } else {
                        self?.setRow(key, AgentIsland.rowText(r, name: key.name, .message))
                    }
                }
            }
            if !started {
                if all { store.actions[key] = AgentIsland.messageBusyText } else { refuseBusy(key, AgentIsland.messageBusyText) }
            } else if all {
                for s in group { store.actions[s.key] = AgentIsland.sendingText }
            }
        }
        layout()
    }

    // MARK: - Rename (#829 G4)

    /// The window's Rename: `dch -m <name> <alias>` on the row's key with its dir's control env
    /// (never DchConnection.setAlias, which is pinned to Remote Terminal's dir). Live sessions
    /// only; no version gate (-m predates every supported dch). A failure is the row's text; the
    /// alias sidecar's new stamp makes the poller list the dir again. False: nothing ran
    /// (not live, no dch, the text unchanged, or a busy row, which says so).
    @discardableResult
    func rename(_ s: AgentSession, alias: String) -> Bool {
        guard let store, let dch = store.controlDch?.path,
              let live = store.sessions.first(where: { $0.key == s.key }),
              let args = AgentIsland.renameArgs(live.name, alias, current: live.alias) else { return false }
        let key = live.key, name = live.name, sent = args[2]
        let started = run(key, dch: dch, args: args, running: nil) { [weak self] r in
            guard let self, let store = self.store else { return }
            if let failed = AgentIsland.renameFailure(r, name: name) {
                store.actions[key] = failed
            } else {
                if store.actions[key]?.hasPrefix("Couldn't rename ") == true {
                    store.actions[key] = nil   // an earlier failure's line goes with the rename that worked
                }
                // QA #693 INFO-3: the title, the field's prefill and its unchanged check read the new alias now,
                // not after the poller's next list (up to the 2 s gate floor plus the list). `was`: the alias the
                // listing still shows (an earlier rename's, when one is still shown over it).
                guard let i = store.sessions.firstIndex(where: { $0.key == key }) else { return self.refreshList() }
                let was = self.sentAliases[key]?.was ?? store.sessions[i].alias
                self.sentAliases[key] = sent == was ? nil : AgentIsland.SentAlias(alias: sent, was: was)
                store.sessions[i].alias = sent
            }
            self.refreshList()
        }
        if !started { refuseBusy(key, AgentIsland.renameBusyText) }
        return started
    }

    /// QA #693 INFO-3: the aliases renames set, until the poller lists them (AgentIsland.overlaySent).
    private var sentAliases: [AgentSessionKey: AgentIsland.SentAlias] = [:]

    private func withSent(_ sessions: [AgentSession]) -> [AgentSession] {
        guard !sentAliases.isEmpty else { return sessions }
        let r = AgentIsland.overlaySent(sessions, sentAliases)
        sentAliases = r.sent
        return r.sessions
    }

    /// One poller tick now, not on the next second: the list (and the window's title) shows the
    /// new alias as soon as the poll gate lets it fetch.
    private func refreshList() {
        guard let poller else { return }
        queue.async { [weak self] in
            guard let sessions = poller.tick() else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(sessions) } }
        }
    }

    /// The "⋯" menu's Stop all in <tab>, or (#744 `global`) Stop all: only asks (the inline line).
    /// QA #572 F2: the rows are fixed now; the answer acts on no other row.
    func askStopAll(global: Bool = false) {
        guard let store, store.restartGate.isOK else { return }
        let t = store.stopTargets(global: global)
        guard !t.stop.isEmpty else { return }
        store.dropQuestions()
        store.ask(t.stop, skipped: t.skipped, dashed: t.dashed, global: global)
        store.confirmingStopAll = true
        layout()
    }

    /// The inline answer. Stop runs on the asked rows still live; Cancel runs nothing.
    func confirmStopAll(_ yes: Bool) {
        guard let store, store.confirmingStopAll else { return }
        store.confirmingStopAll = false
        if yes { stopAll() } else { layout() }
    }

    /// The asked rows (the shown tab's or, #744, every tab's stoppable ones) by name, never `--all`: one job per
    /// dir under the dir-wide key, like Restart all, so a dir with any job
    /// running is refused whole. Each row shows "Stopping…", then its result;
    /// the dir gets "N stopped, N failed, N skipped".
    private func stopAll() {
        guard let store, case .ok(let dch) = store.restartGate else { return }
        let byDir = Dictionary(grouping: store.stopAllTargets, by: \.key.dir)
        for (dir, rows) in byDir.sorted(by: { $0.key < $1.key }) {
            let key = AgentSessionKey(dir: dir, name: "")
            let started = run(key, dch: dch, args: AgentIsland.stopArgs(rows.map(\.name)), running: AgentIsland.stoppingText,
                              bound: DchActionRunner.restartBound, yields: true, onLine: { [weak self] in self?.dirLine($0, dir: dir, .stop) }) {
                [weak self] r in
                guard let self else { return }
                // #749 (QA #572 INFO-R5): a row a Kill cut through counts as killed, as the row reads.
                // #750 (QA #576 INFO-2): only a Kill that worked before this job ended (r.killed).
                self.dirDone(dir, AgentIsland.tally(r, .stop, title: "Stop all", empty: "nothing stopped"))
                self.refreshHistory()
            }
            if started { for s in rows { store.actions[s.key] = AgentIsland.stoppingText } }
        }
        layout()
    }

    // MARK: - Kill (#744)

    /// A row's Kill: only asks (the inline "Kill <name>?" line). Base gate only:
    /// dch -k needs no newer flag and works on any master.
    func askKill(_ s: AgentSession) {
        guard let store, store.resumeGate.isOK, AgentIsland.killArgs(s.name) != nil,
              store.sessions.contains(where: { $0.key == s.key }) else { return }
        store.dropQuestions()
        store.confirmingKill = s.key
        layout()
    }

    /// The inline answer: Kill runs `dch -k <name>` on the row, if still live; Cancel runs nothing.
    /// QA #572 INFO-1: it cuts through the row's Stop or Restart; any other job (or a Kill
    /// already running) refuses it, and the row says so unless it reads "Killing…".
    func confirmKill(_ yes: Bool) {
        guard let store, store.confirmingKill != nil else { return }
        let target = store.killTarget
        store.confirmingKill = nil
        guard yes, let target, store.resumeGate.isOK else { return layout() }
        kill(target)
    }

    /// #829 G3: one row's Kill with no question state of the island's (the window asks its
    /// own): `dch -k <name>` on the row if it is still live. It cuts through the row's Stop or
    /// Restart; any other job refuses it, and the row says so. False: nothing started.
    @discardableResult
    func kill(_ s: AgentSession) -> Bool {
        guard let store, case .ok(let dch) = store.resumeGate, AgentIsland.killArgs(s.name) != nil,
              let live = store.sessions.first(where: { $0.key == s.key }) else { return false }
        let started = killRow(live, dch: dch, done: { _ in })
        if !started { refuseKill(live.key) }
        layout()
        return started
    }

    /// A Kill a busy row refused: the row says so, unless it reads "Killing…" (a Kill
    /// already runs there).
    private func refuseKill(_ key: AgentSessionKey) {
        guard store?.actions[key] != AgentIsland.killingText else { return }
        store?.actions[key] = AgentIsland.killBusyText
        clearRefusal(key, AgentIsland.killBusyText)
    }

    /// #749 (QA #572 INFO-R2): the refusal goes once the job that refused it ended, which
    /// may be one the island does not show (the phone's, a History row's, a New session).
    /// Checked each second while the row still says it; jobs are bounded, so is this.
    /// #750 (QA #576 INFO-1): busy as a Kill sees it; a Stop or Restart since would not refuse one.
    /// #829: `text` is the refusal shown (a Kill's, or a Restart's or Stop's: busy as any job sees it).
    private func clearRefusal(_ key: AgentSessionKey, _ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let store = self.store, store.actions[key] == text else { return }
                let kill = text == AgentIsland.killBusyText
                if kill ? self.runner.isKillBusy(key) : self.runner.isBusy(key) { return self.clearRefusal(key, text) }   // #750 (QA #576 INFO-1)
                store.actions[key] = nil
                self.layout()
            }
        }
    }

    /// `dch -k <name>` with its dir's control env, on the row's key, beside a Stop or
    /// Restart there (else a busy row refuses: false). "Killing…", then "Killed" or why
    /// not, and (`refresh`) one History re-read; the row itself goes on the poller's
    /// next tick. `done` gets dch's result.
    @discardableResult
    private func killRow(_ s: AgentSession, dch: String, refresh: Bool = true,
                         done: @escaping @MainActor @Sendable (DchActionResult) -> Void) -> Bool {
        let key = s.key
        return run(key, dch: dch, args: AgentIsland.killArgs(s.name), running: AgentIsland.killingText, kill: true) { [weak self] r in
            guard let self else { return }
            let text = AgentIsland.killText(r)
            if AgentIsland.killed(r) || AgentIsland.killGone(r) {
                self.store?.actions[key] = text
            } else {
                // #749 (QA #572 INFO-R4): a failed or cancelled Kill hands the row back to the Stop
                // or Restart it cut through: a result of theirs held back shows first; a phase (or
                // none) leaves the Kill's text, until their next line.
                let held = self.killedRows.removeValue(forKey: key) ?? ""
                self.store?.actions[key] = held.isEmpty || AgentIsland.runningTexts.contains(held) ? text : "\(held); \(text)"
            }
            if refresh { self.refreshHistory() }
            done(r)
        }
    }

    /// The "⋯" menu's Kill all in <tab>, or Kill all (`global`): only asks.
    /// QA #572 F1: the rows are fixed now; the answer acts on no other row.
    func askKillAll(global: Bool = false) {
        guard let store, store.resumeGate.isOK else { return }
        let t = store.killTargets(global: global)
        guard !t.kill.isEmpty else { return }
        store.dropQuestions()
        store.ask(t.kill, skipped: t.skipped, global: global)
        store.confirmingKillAll = true
        layout()
    }

    /// The inline answer. Kill runs on the asked rows still live; Cancel runs nothing.
    func confirmKillAll(_ yes: Bool) {
        guard let store, store.confirmingKillAll else { return }
        store.confirmingKillAll = false
        if yes { killAll() } else { layout() }
    }

    /// The asked rows by name, never `-kl` (it kills every session in the dir, listed
    /// or not). dch -k takes one name, so one call per row on the row's key, with its
    /// dir's env; a row running a job Kill may not cut through is left alone (busy) and
    /// says so, as under its own Kill (#749).
    /// Each dir gets "N killed, N already ended, N failed, N busy" once its last call
    /// is back, unless a dir-wide job's text is up there (QA #572 INFO-2: the rows say
    /// their own). One History re-read once every call is back (INFO-3).
    private func killAll() {
        guard let store, case .ok(let dch) = store.resumeGate else { return }
        let all = KillTally(left: 0)
        for (dir, rows) in Dictionary(grouping: store.killAllTargets, by: \.key.dir).sorted(by: { $0.key < $1.key }) {
            let tally = KillTally(left: rows.count), dirKey = AgentSessionKey(dir: dir, name: "")
            let finish = { @MainActor @Sendable [weak self] in
                guard tally.left == 0, let self, !self.runner.hasJob(dirKey) else { return }
                self.store?.actions[dirKey] = tally.line
            }
            for s in rows {
                let started = killRow(s, dch: dch, refresh: false) { [weak self] r in
                    tally.count(r)
                    tally.left -= 1
                    finish()
                    all.left -= 1
                    if all.left == 0 { self?.refreshHistory() }
                }
                if started {
                    all.left += 1
                } else {
                    tally.busy += 1
                    tally.left -= 1
                    refuseKill(s.key)   // #749 (QA #572 INFO-R3): as the row's own Kill, under any job
                }
            }
            finish()
        }
        layout()
    }

    /// One Kill all dir's count (or every dir's calls left), on main.
    @MainActor private final class KillTally {
        var left: Int, killed = 0, gone = 0, failed = 0, busy = 0
        init(left: Int) { self.left = left }
        func count(_ r: DchActionResult) {
            if AgentIsland.killed(r) { killed += 1 } else if AgentIsland.killGone(r) { gone += 1 } else { failed += 1 }
        }
        var line: String { AgentIsland.killTally(killed: killed, gone: gone, failed: failed, busy: busy) }
    }

    /// The header "⋯".
    func showControlsMenu() {
        guard store != nil else { return }
        popUpMenu(makeControlsMenu())
    }

    /// New session ▸ recent folders, Choose folder…; Restart stale agents, Restart all agents (force);
    /// Stop all in <tab>, Stop all, Kill all in <tab>, Kill all (#744). Off,
    /// with the gate's reason under them, while the gate refuses.
    func makeControlsMenu() -> NSMenu {
        let store = self.store, m = store?.controlsMenu ?? .init(recent: [], refused: nil), on = m.refused == nil
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
        menu.addItem(AgentIslandMenuItem(AgentIsland.label(AgentIsland.restartAllForceLabel, needs: needs), enabled: risky && live) {
            [weak self] in self?.askRestartAll(force: true)
        })
        // #580: the shown tab's sessions; off when none of them can stop.
        let tab = store?.sessionTab.label ?? "Sessions"
        let stoppable = { (global: Bool) in !(store?.stopTargets(global: global).stop.isEmpty ?? true) }
        menu.addItem(AgentIslandMenuItem(AgentIsland.label(AgentIsland.stopAllLabel(tab: tab), needs: needs),
                                         enabled: risky && stoppable(false)) { [weak self] in self?.askStopAll() })
        // #744: every tab's; then the non-graceful Kill all, per tab and every tab (base gate only).
        menu.addItem(AgentIslandMenuItem(AgentIsland.label(AgentIsland.stopAllGlobalLabel, needs: needs),
                                         enabled: risky && stoppable(true)) { [weak self] in self?.askStopAll(global: true) })
        let killable = { (global: Bool) in !(store?.killTargets(global: global).kill.isEmpty ?? true) }
        menu.addItem(AgentIslandMenuItem(AgentIsland.killAllLabel(tab: tab), enabled: on && killable(false)) {
            [weak self] in self?.askKillAll()
        })
        menu.addItem(AgentIslandMenuItem(AgentIsland.killAllGlobalLabel, enabled: on && killable(true)) {
            [weak self] in self?.askKillAll(global: true)
        })
        // #584: the shown tab's live sessions, by name; the base gate only (dch answers an old master itself).
        menu.addItem(AgentIslandMenuItem(AgentIsland.messageAllLabel(tab: tab),
                                         enabled: on && !(store?.messageAllTargets.rows.isEmpty ?? true)) {
            [weak self] in self?.askMessageAll()
        })
        if let why = m.refused {
            menu.addItem(.separator())
            menu.addItem(AgentIslandMenuItem("Controls \(why)", enabled: false))
        }
        return menu
    }

    /// The "⋯" menu's Restart stale agents, or (#700) Restart all agents (force):
    /// only asks (the inline line); one restart question at a time.
    func askRestartAll(force: Bool = false) {
        guard let store, store.restartGate.isOK, !store.sessions.isEmpty else { return }
        store.dropQuestions()
        store.restartAllForce = force
        store.confirmingRestartAll = true
        layout()
    }

    /// The inline answer. Restart runs Restart all; Cancel runs nothing.
    func confirmRestartAll(_ yes: Bool) {
        guard let store, store.confirmingRestartAll else { return }
        store.confirmingRestartAll = false
        if yes { restartAll(force: store.restartAllForce) } else { layout() }
    }

    /// `--restart --all --include-agents --json` (no -f: stale agents only; #700:
    /// `force` adds -f), one job per dir with a live session under the dir-wide key.
    /// A row shows dch's phases once it reaches it ("Pausing…"), then its result;
    /// the dir gets the summary.
    private func restartAll(force: Bool) {
        guard let store, case .ok(let dch) = store.restartGate else { return }
        for dir in Set(store.sessions.map(\.key.dir)).sorted() {
            let key = AgentSessionKey(dir: dir, name: "")
            run(key, dch: dch, args: force ? AgentIsland.restartAllForceArgs : AgentIsland.restartAllArgs,
                running: force ? AgentIsland.restartAllForceRunningText : AgentIsland.restartAllRunningText,
                bound: DchActionRunner.restartBound, yields: true, onLine: { [weak self] in self?.dirLine($0, dir: dir, .restart) }) {
                [weak self] r in self?.dirDone(dir, AgentIsland.restartAllSummary(r))
            }
        }
    }

    /// New session in `folder`: `--spawn <name> <command>` with the Process cwd
    /// set to it, into the island's first socket dir (it shows on the next tick).
    /// #606: the command is the setting's, else inferred first (off main).
    func newSession(in folder: String) {
        guard store?.resumeGate.isOK == true else { return }
        newSessionCommand { [weak self] command in self?.spawn(in: folder, command: command) }
    }

    /// #847: the socket dir a new session goes to.
    func spawnDir() -> String { historyDirs().first ?? DchCommand.defaultSocketDir }

    /// The one --spawn (#847: the island's New session, the window's form and quick shell). `name` nil:
    /// the folder's free name; given, it must pass the form's shape rule. nil: nothing runs (the gate
    /// refuses, a bad name, the key busy); else the session's key, and `done` later gets the key on
    /// success or the failure text, which also goes to the dir-wide line.
    @discardableResult
    func spawn(in folder: String, command: [String], name: String? = nil,
               done: (@MainActor @Sendable (AgentSessionKey?, String?) -> Void)? = nil) -> AgentSessionKey? {
        guard let store, case .ok(let dch) = store.resumeGate else { return nil }
        let dir = spawnDir()
        if let name, name.isEmpty || name.contains(where: \.isWhitespace) || AgentNewSession.nameError(name, taken: [], dir: dir) != nil {
            return nil
        }
        let taken = AgentIsland.spawnTaken(dir: dir, sessions: store.sessions, history: store.history)
        // QA #713 INFO-3: the island's automatic name fits dch's room in `dir` too.
        let args = AgentIsland.newSessionArgs(folder: folder, command: command, taken: taken,
                                              name: name ?? AgentNewSession.autoName(folder: folder, taken: taken, dir: dir))
        let key = AgentSessionKey(dir: dir, name: args[1])
        let started = run(key, dch: dch, args: args, running: nil, cwd: folder, spawn: true) { [weak self] r in
            guard let store = self?.store else { return }
            let failed = AgentIsland.spawnText(r, name: key.name)
            if let failed { store.actions[AgentSessionKey(dir: dir, name: "")] = failed }
            done?(failed == nil ? key : nil, failed)
        }
        return started ? key : nil
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
        panel.prompt = "Choose"   // QA #747 INFO-7: the window's form only fills its Folder field with it
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
        p.onEscape = { [weak self] in self?.escape() }
        let host = FirstClickHostingView(rootView: AgentIslandView(
            store: store,
            onToggle: { [weak self] in self?.setExpanded(!(self?.store?.expanded ?? true)) },
            onRow: { [weak self] in self?.jump($0) },
            onAnswer: { [weak self] in self?.answer($0, $1, $2) },
            onTab: { [weak self] in self?.showSidekicks($0) },
            onHistory: { [weak self] in self?.showHistory() },
            onResume: { [weak self] in self?.resume($0) },
            onResumeAll: { [weak self] in self?.resumeCrashed() },
            onResumeNoMessage: { [weak self] in self?.resume($0, noMessage: true) },
            onResumeAllNoMessage: { [weak self] in self?.resumeCrashed(noMessage: true) },
            onRestart: { [weak self] in self?.restart($0) },
            onControls: { [weak self] in self?.showControlsMenu() },
            onAgentsWindow: { [weak self] in self?.setExpanded(false); AgentsWindow.shared.show() },
            onConfirmRestartAll: { [weak self] in self?.confirmRestartAll($0) },
            onStop: { [weak self] in self?.stop($0) },
            onConfirmStopAll: { [weak self] in self?.confirmStopAll($0) },
            onKill: { [weak self] in self?.askKill($0) },
            onConfirmKill: { [weak self] in self?.confirmKill($0) },
            onConfirmKillAll: { [weak self] in self?.confirmKillAll($0) },
            onPin: { [weak self] in self?.pin($0) },
            onRemove: { [weak self] in self?.remove($0) },
            onClearUnpinned: { [weak self] in self?.askClearUnpinned() },
            onConfirmClear: { [weak self] in self?.confirmClearUnpinned($0) },
            onMessage: { [weak self] in self?.askMessage($0) },
            onSendMessage: { [weak self] in self?.sendMessage() },
            onCancelMessage: { [weak self] in self?.cancelMessage() }))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }

    /// Only the panel's own view expands it, so a nil panel (tests) just skips the window work.
    func setExpanded(_ on: Bool) {
        guard let store, store.expanded != on, !on || store.showsIsland else { return }
        store.expanded = on
        // QA #607 INFO-1: only a lit, unlocked screen takes a click: a missed wake or
        // unlock clears here (Stats does the same on popover open).
        if on, screen.hidden { screen.apply(.popoverShown); pushHidden() }
        if on, let d = deferred { deferred = nil; store.sessions = d }   // #768
        // #581: nothing live: open on History.
        if on, store.sessions.isEmpty, !store.history.isEmpty { store.historyTab = true }
        if !on {
            store.notices = [:]; store.cards = [:]; readAt = [:]
            store.dropQuestions()
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
            watchOwnWindows()
        } else {
            unwatch()
            // Hand key focus back: out and straight back in, no animation.
            if let panel, panel.isKeyWindow { panel.orderOut(nil); layout() }
        }
    }

    /// #1112: the open island also closes when the user turns to another Prosper window: a mouse down in
    /// it (the local monitor) or it taking key (typing there). Armed after makeKey, so the panel taking
    /// key never counts, and the window it took key from only resigns (not observed).
    private func watchOwnWindows() {
        ownClick = monitorOwnClicks { [weak self] w, p in self?.turnedAway(to: w, at: p) }
        focusObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
                let w = n.object as? NSWindow
                MainActor.assumeIsolated { self?.keyTaken(by: w) }
            },
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menusTracking += 1 }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuEnded() }
            },
        ]
    }

    /// 584's draft: a window that takes key with no click (a hotkey panel, one that opens itself) never
    /// drops an unsent message; a click elsewhere still closes the island and drops it.
    private func keyTaken(by w: NSWindow?) {
        guard store?.messageDraft == nil else { return }
        turnedAway(to: w, at: nil)
    }

    private func menuEnded() { menusTracking = max(0, menusTracking - 1) }   // an end whose begin came before expand

    /// #1112: a mouse down at `p` (screen) in `window`, or `window` taking key (p nil). Closes the island
    /// unless a menu tracks, the window is the panel, or the click lands inside the panel's frame (a
    /// see-through corner of the island over the window below).
    func turnedAway(to window: NSWindow?, at p: NSPoint?) {
        guard menusTracking == 0, let window, window !== panel else { return }
        if let p, panel?.frame.contains(p) == true { return }
        setExpanded(false)
    }

    /// Every monitor and observer the open island holds, off (collapse and teardown).
    private func unwatch() {
        for m in [outsideClick, ownClick].compactMap({ $0 }) { removeMonitor(m) }
        outsideClick = nil
        ownClick = nil
        for o in focusObservers { center.removeObserver(o) }
        focusObservers = []
        menusTracking = 0
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
        guard let gen = beginHuman(s, p) else { return }
        let key = s.key, io = io, at = clickAt(key)
        queue.async { [weak self] in
            let r = AgentPrompt.answer(key, digit: o.digit, expected: p, io: io)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inFlight.remove(key)
                    // sent: the next poll shows the new state
                    guard r == .changed else { return }
                    self.setCard(.changed, key, gen)
                    if let at { self.recheckStaleClick(key, p, at) }
                }
            }
        }
    }

    /// The `at` of the hold beginHuman just left (nil: Always allow holds nothing here).
    private func clickAt(_ key: AgentSessionKey) -> Date? {
        if case .human(_, _, let at) = autoAllow[key] { return at }
        return nil
    }

    /// QA #622 INFO-2: a click on a stale card sent nothing (the screen no longer showed its
    /// prompt): the prompt printed before the click (C) went unread, as the click took the row's
    /// activity then as seen. Untouched since the click: read once more (after the poll floor);
    /// C gets its own full check, while the clicked prompt (a re-wrap too) or none stays the human's.
    private func recheckStaleClick(_ key: AgentSessionKey, _ p: AgentPrompt, _ at: Date) {
        guard case .human(let left, _, let t) = autoAllow[key], left == p, t == at else { return }
        autoAllow[key] = .human(left: p, seen: -1, at: at)   // -1: no row's activity, so it reads
        recheckHuman()
    }

    /// #798: the Agents window acting on a session (an answer, a key sequence, a message, an
    /// interrupt) is the human's click, on the island click's own path: one action per session
    /// at a time (none while an island click or an Always allow check holds it), the card goes,
    /// and a prompt it answers is left to the human (#791/#794). `run` gets the dch IO off main
    /// (never on the poll queue: a sequence may take seconds); `done` gets its result on main.
    /// False: something else holds the session (or the island is off), nothing ran.
    @discardableResult
    func humanAction<R: Sendable>(_ s: AgentSession, prompt: AgentPrompt?,
                                  run: @escaping @Sendable (AgentPromptIO) -> R,
                                  done: @escaping @MainActor @Sendable (R) -> Void) -> Bool {
        guard beginHuman(s, prompt) != nil else { return false }
        let key = s.key, io = io
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = run(io)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.inFlight.remove(key)
                    done(r)
                }
            }
        }
        return true
    }

    /// #798: an island click, a window action or an Always allow check holds the session, or
    /// Always allow is still deciding its prompt (checking, answered, left to dch): the window
    /// shows no buttons, as the island shows no card.
    func heldByAutoAllow(_ key: AgentSessionKey) -> Bool {
        if inFlight.contains(key) { return true }
        guard let a = autoAllow[key] else { return false }
        if case .human = a { return false }
        return true
    }

    /// The click's bookkeeping, on main; nil when the session is already in flight.
    private func beginHuman(_ s: AgentSession, _ p: AgentPrompt?) -> Int? {
        guard let store, inFlight.insert(s.key).inserted else { return nil }
        store.cards[s.key] = nil
        // QA #620 INFO-1: the prompt a human clicks is the human's: a re-read still seeing it (or one
        // in flight) never checks it, and the next prompt is a fresh check.
        // QA #620 INFO-2: from any state: a pending verify (.answered) or stand-down (.dch) timer
        // finds its state gone and does nothing, so it never types "1" after the human's answer;
        // the dropped hold goes out as Needs input now (what that timer did on finding the click).
        if let was = autoAllow[s.key] {
            autoAllow[s.key] = .human(left: p, seen: activity(s.key), at: now())
            if case .human = was {} else { publish() }
        }
        let gen = bump(s.key)
        layout()
        return gen
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

    // MARK: - Always allow (#751)

    /// #751 seams: the setting, the loop guard's clock, and the re-read timer.
    /// #754: Sendable, so the queue reads it again right before the send.
    var autoAllowOn: @Sendable () -> Bool = { Preferences.agentIslandAutoAllow }
    var now: @MainActor () -> Date = { Date() }
    var after: @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { delay, fire in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { fire() } }
    }
    static let autoAllowedText = "Allowed automatically"
    /// The same prompt back this soon after its answer is the human's (the loop guard).
    static let loopWindow: TimeInterval = 30
    /// An answered session still listed blocked has its screen read again this soon.
    static let verifyDelay: TimeInterval = 2
    /// #792: how long a prompt left to dch's own auto-allow waits for its answer before the
    /// normal Needs input goes out (a DCH_NO_DETECT master, a hook or ask prompt dch refuses, a
    /// non-permission prompt). dch answers at most 2 s (its AA_MAX_MS, = verifyDelay) into the
    /// prompt's output, which began before this check saw it blocked; the answer's output is
    /// then re-listed at most AgentPollGate.floor after the last list, on a 1 s tick.
    static let standDownWait: TimeInterval = verifyDelay + AgentPollGate.floor + 1
    private static let log = Logger(subsystem: "eu.illegible.prosper", category: "agentisland")

    /// #792: a `--build` that timed out is asked again only this long after (QA #614 INFO-3: each
    /// ask holds the poll queue up to DchCommand.islandTimeout); meanwhile Prosper answers.
    static let dchBuildRetry: TimeInterval = 300

    /// `dch`: left to dch's auto-allow (#792), with the row's `auto_allowed` when it was.
    /// `human` (#791): the prompt it was left with (nil: none read), the row's activity at that read
    /// and when the read began; a different prompt on a later read gets a check of its own.
    private enum AutoAllowState: Equatable {
        case checking, answered, dch(DchAutoAllowed?)
        case human(left: AgentPrompt?, seen: TimeInterval, at: Date)
    }
    /// One blocked stretch of a session; dropped once the row is not blocked.
    private var autoAllow: [AgentSessionKey: AutoAllowState] = [:]
    /// The prompt last answered per session, and when: the loop guard.
    private var allowed: [AgentSessionKey: (prompt: AgentPrompt, at: Date)] = [:]
    /// QA #581 INFO-3: the live re-read timer per session; an older one is a no-op.
    private var rereadGen: [AgentSessionKey: Int] = [:]
    /// #755: the keys whose inFlight is an Always allow check, not an island click;
    /// true once an off-toggle orphaned it and an on-toggle took it back.
    private var checks: [AgentSessionKey: Bool] = [:]
    /// #792: each session's dch `auto_allowed` at the last check, so a new one shows once.
    private var dchSeen: [AgentSessionKey: DchAutoAllowed?] = [:]
    /// #792 seam: one call of the installed dch (`--build`, `--config`); nil = timed out. Only
    /// reached through controlDch, which finds no binary under XCTest.
    var runDch: @Sendable (_ path: String, _ args: [String], _ env: [String: String]) -> Data? = {
        DchCommand.runIsland(args: $1, env: $2, path: $0)
    }
    /// #792: `--build` per installed binary and version ("<path>@1.29.2": "full"), nil = timed out at `at`.
    private let dchBuilds = OSAllocatedUnfairLock<[String: (build: String?, at: Date)]>(initialState: [:])
    /// #791: the rows left to the human whose screen is being read again.
    private var rereading: Set<AgentSessionKey> = []
    /// #935: the rows dch names one live Claude Code in (`claude_session_id`, the Agents window's
    /// transcript mapping), from the newest list; the queue reads it again right before a send.
    private let claudeKeys = OSAllocatedUnfairLock<Set<AgentSessionKey>>(initialState: [])

    /// Every list change, before it is published: a session that just went blocked
    /// gets one check, any tab, expanded or not. Off: nothing is read or held.
    func checkAutoAllow() {
        guard let store else { return }
        // #935: no id (another program, two Claudes, an older dch, no list yet) is not Claude Code.
        let claude = Set(store.sessions.filter { $0.claudeSessionID?.isEmpty == false }.map(\.key))
        // QA #849 INFO-5: before the setting's guard, so a check an off-toggle orphaned reads a fresh set at its
        // send when the setting is back on before autoAllowChanged runs here.
        claudeKeys.withLock { $0 = claude }
        guard autoAllowOn() else { autoAllow = [:]; dchSeen = [:]; return }   // nothing held: published as is
        showDchAnswers(store.sessions)
        let blocked = Set(store.sessions.filter { $0.state == .blocked }.map(\.key))
        autoAllow = autoAllow.filter { blocked.contains($0.key) }
        for key in blocked where autoAllow[key] == nil { startAutoAllow(key, answered: false) }   // #935: it asks claudeKeys
        recheckHuman()
    }

    /// #791: a row left to the human that printed since its last read (its activity moved: a
    /// queued prompt replacing the one left, or a countdown tick) has its screen read once more,
    /// at most once per poll floor (a timer covers a print inside it), never while a read, a check
    /// or a click is in flight. A row that does not print costs no fork.
    func recheckHuman() {
        guard autoAllowOn() else { return }
        for s in deferred ?? store?.sessions ?? [] where s.state == .blocked {
            guard case .human(_, let seen, let at) = autoAllow[s.key], s.activity != seen,
                  !inFlight.contains(s.key), !rereading.contains(s.key) else { continue }
            let wait = AgentPollGate.floor - now().timeIntervalSince(at)
            if wait > 0 { after(wait) { [weak self] in self?.recheckHuman() }; continue }
            let key = s.key, io = io, was = autoAllow[key], act = s.activity, t = now()
            rereading.insert(key)
            queue.async { [weak self] in
                let screen = io.read(key)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.reread(key, was, screen, act, t) } }
            }
        }
    }

    /// The re-read, on main. The prompt left to the human stays the human's (its countdown ticking,
    /// or the same prompt re-wrapped at another width: sameIdentity, QA #620 F1), as does no prompt,
    /// and any prompt while none was read before
    /// (left by a stand-down or a click): fail safe, nothing more is forked. A different prompt gets
    /// the full check on this screen (gate, #790 refusals, loop guard, the #475 re-read).
    private func reread(_ key: AgentSessionKey, _ was: AutoAllowState?, _ screen: String, _ act: TimeInterval, _ t: Date) {
        rereading.remove(key)
        guard autoAllow[key] == was, case .human(let left, _, _) = was, !inFlight.contains(key) else { return }
        let p = AgentPrompt.parse(screen)
        guard let p, let left, !p.sameIdentity(left) else {
            autoAllow[key] = .human(left: left ?? p, seen: act, at: t)
            return recheckHuman()   // printed again meanwhile
        }
        startAutoAllow(key, answered: false, screen: (screen, act))
    }

    /// #792: a row whose dch `auto_allowed` moved since the last check: dch answered its
    /// prompt, so it reads "Allowed automatically". A row first seen shows nothing.
    private func showDchAnswers(_ sessions: [AgentSession]) {
        for s in sessions {
            guard let a = s.autoAllowed, let was = dchSeen[s.key], was != a else { continue }
            Self.log.info("dch auto-allow answered in \(s.key.name, privacy: .public): \(a.title, privacy: .private)")
            if !runner.isBusy(s.key) { store?.actions[s.key] = Self.autoAllowedText }
        }
        dchSeen = Dictionary(sessions.map { ($0.key, $0.autoAllowed) }, uniquingKeysWith: { a, _ in a })
    }

    /// QA #581 F3: the setting toggled (Settings): off drops every hold and
    /// publishes at once; on checks the sessions blocked now.
    /// #755 INFO-2: a dropped hold shows its card at once.
    func autoAllowChanged() {
        checkAutoAllow()
        publish()
        refreshCards()
        layout()
    }

    /// The row's activity now (the held-back list's when collapsed).
    private func activity(_ key: AgentSessionKey) -> TimeInterval {
        (deferred ?? store?.sessions)?.first { $0.key == key }?.activity ?? 0
    }

    /// `screen`: #791's re-read, the screen this check decides on and the row's activity then.
    private func startAutoAllow(_ key: AgentSessionKey, answered: Bool, screen: (text: String, act: TimeInterval)? = nil) {
        guard autoAllowOn() else { return autoAllowChanged() }   // QA #581 F3: switched off meanwhile
        // #935 (QA #849 INFO-2): every way in asks first. A session the newest list names no Claude Code in is
        // never checked or held: its card and Needs input, as with the setting off; one held until now
        // (a re-read, the verify, a stand-down, a taken-back re-run) is left to the human.
        guard claudeKeys.withLock({ $0.contains(key) }) else {
            guard autoAllow[key] != nil else { return }
            autoAllow[key] = .human(left: nil, seen: activity(key), at: now())
            publish()
            refreshCards()
            return layout()
        }
        // An island click is answering it: the human's.
        guard inFlight.insert(key).inserted else {
            // #755 INFO-1: our own check, orphaned by an off-toggle: held again, its result counts.
            if checks[key] != nil { checks[key] = true; autoAllow[key] = .checking; return }
            autoAllow[key] = .human(left: nil, seen: activity(key), at: now())
            if answered { publish() }
            return
        }
        autoAllow[key] = .checking
        checks[key] = false
        // QA #620 INFO-1: no card, and no click, while the check holds the row: one drawn for a
        // replacing prompt goes, a card read in flight is dropped; refreshCards reads it again after.
        store?.cards[key] = nil
        readAt[key] = nil
        _ = bump(key)
        let io = io, t = now(), on = autoAllowOn, claude = claudeKeys, act = screen?.act ?? activity(key), retry = Self.dchBuildRetry
        // #935: every automatic send (a fresh check, a re-read, the verify) asks this last, right before the key:
        // a session whose newest list no longer names a Claude Code is left to the human.
        let isOn: @Sendable () -> Bool = { on() && claude.withLock { $0.contains(key) } }
        let last = allowed[key].flatMap { t.timeIntervalSince($0.at) < Self.loopWindow ? $0.prompt : nil }
        // #792: a fresh blocked stretch only; the re-read after Prosper's own answer stays Prosper's.
        let master = answered ? "" : store?.sessions.first { $0.key == key }?.version ?? ""
        let probe = controlDch, run = runDch, builds = dchBuilds
        queue.async { [weak self] in
            let env = AgentIsland.listEnv(dir: key.dir)
            let dch = DchAutoAllowGate.answers(master: master, dch: probe, build: { bin in
                let k = "\(bin.path)@\(DchCommand.versionString(bin.version))"
                // QA #614 INFO-3: a timeout is kept `retry` s, so a hung dch stalls the poll once per window.
                if let hit = builds.withLock({ $0[k] }), hit.build != nil || t.timeIntervalSince(hit.at) < retry {
                    return hit.build
                }
                let b = run(bin.path, ["--build"], env).map {
                    String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                builds.withLock { $0[k] = (b, t) }
                return b
            }, config: { bin in run(bin.path, ["--config"], env).map { String(decoding: $0, as: UTF8.self) } })
            let s = dch ? nil : screen?.text ?? io.read(key), read = s.flatMap(AgentPrompt.parse)
            let r = s.map { AgentPrompt.autoAllow(key, io: io, notAgain: last, answered: answered, isOn: isOn, screen: $0) } ?? .dch
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.autoAllowed(key, r, read, act, t) } }
        }
    }

    /// The check's result, on main. Answered: held, and read again after
    /// `verifyDelay` while still listed blocked. Anything else: the normal Needs
    /// input goes out now. `read`, `act`, `t`: the prompt it read, the row's activity and the
    /// time when it began (#791: what a later re-read compares against).
    private func autoAllowed(_ key: AgentSessionKey, _ r: AgentAutoAllow, _ read: AgentPrompt?,
                             _ act: TimeInterval, _ t: Date) {
        inFlight.remove(key)
        // #755 INFO-1: a taken-back check may have read the setting while it was off: check again.
        if checks.removeValue(forKey: key) == true, r == .human, autoAllow[key] == .checking {
            return startAutoAllow(key, answered: false)
        }
        if case .allowed(let p) = r {
            allowed[key] = (p, now())
            // QA #581 INFO-1: with the head off the screen the title is a command line.
            Self.log.info("Always allow answered Yes in \(key.name, privacy: .public): \(p.title, privacy: .private)")
            if !runner.isBusy(key) { store?.actions[key] = Self.autoAllowedText }
        }
        // QA #581 F2: the check held the key, so refreshCards skipped it; read the card now.
        // #754 INFO-R2: also when the hold is already gone (switched off meanwhile).
        // #755 INFO-2: and after a Yes whose hold is gone: it may not have taken.
        if r == .human || r == .gone || autoAllow[key] != .checking { refreshCards() }
        guard autoAllow[key] == .checking else { return layout() }   // not blocked any more
        if r == .human {
            autoAllow[key] = .human(left: read, seen: act, at: t)
            publish()
            recheckHuman()   // #791: printed while it was checked
        } else if r == .dch {
            standDown(key)
        } else {
            autoAllow[key] = .answered
            rereadGen[key, default: 0] += 1
            let gen = rereadGen[key]
            after(Self.verifyDelay) { [weak self] in
                guard let self, self.rereadGen[key] == gen, self.autoAllow[key] == .answered else { return }
                self.startAutoAllow(key, answered: true)
            }
        }
        layout()
    }

    /// #792: dch answers this prompt, Prosper sends nothing. Held (no Needs input) until the
    /// row leaves blocked (checkAutoAllow drops the hold) or `standDownWait` runs out: with
    /// dch's `auto_allowed` moved (it answered, and a new prompt is up) the next one is
    /// checked; with no answer from dch, the normal Needs input goes out.
    private func standDown(_ key: AgentSessionKey) {
        let seen = store?.sessions.first { $0.key == key }?.autoAllowed
        autoAllow[key] = .dch(seen)
        rereadGen[key, default: 0] += 1
        let gen = rereadGen[key]
        after(Self.standDownWait) { [weak self] in
            guard let self, self.rereadGen[key] == gen, self.autoAllow[key] == .dch(seen) else { return }
            if self.store?.sessions.first(where: { $0.key == key })?.autoAllowed != seen {
                return self.startAutoAllow(key, answered: false)
            }
            self.autoAllow[key] = .human(left: nil, seen: self.activity(key), at: self.now())
            self.publish()
            self.refreshCards()
            self.layout()
        }
    }

    /// The list for the phone (LiveStatusPublisher): a session being checked or
    /// answered reads working, so its Needs input never posts.
    func published(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.map { s in
            guard s.state == .blocked, let a = autoAllow[s.key] else { return s }
            if case .human = a { return s }
            return AgentSession(key: s.key, alias: s.alias, activity: s.activity, state: .working,
                                agents: s.agents, meta: s.meta, version: s.version, metaEpoch: s.metaEpoch,
                                autoAllowed: s.autoAllowed, claudeSessionID: s.claudeSessionID, transcriptPath: s.transcriptPath,
                                cwd: s.cwd)
        }
    }

    private func publish() {
        if let store { onSessions?(published(deferred ?? store.sessions)) }
        onHoldChanged?()
    }

    /// #798: told whenever a hold may have changed (publish), so the Agents window reads a
    /// prompt once Always allow leaves it to the human.
    var onHoldChanged: (@MainActor () -> Void)?

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
        unwatch()
        if let o = screenObserver { center.removeObserver(o) }
        screenObserver = nil
        for (o, c) in sleepObservers { c.removeObserver(o) }
        sleepObservers = []
        poller = nil
        deferred = nil
        screen = ScreenGate()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        let had = store != nil
        store = nil
        if had { onStoreChanged?() }
        autoAllow = [:]
        dchSeen = [:]
        sentAliases = [:]   // QA #699 INFO-3
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
    /// its text as raw bytes with no Enter, after "--" (QA #629 F1: else dch parses a
    /// leading "-" as its own flag, and "-kl" kills every session). Each call is bounded
    /// (#477): a timed-out read or status is empty, so a card reads as changed and nothing is sent.
    static let live = live { DchCommand.runIsland(args: $0, env: $1) ?? Data() }

    /// `run` gets the argv and env; tests pass a recorder.
    static func live(run: @escaping @Sendable ([String], [String: String]) -> Data,
                     say: @escaping @Sendable ([String], [String: String]) -> Data = liveSay,
                     noMirror: @escaping @Sendable ([String], [String: String]) -> Bool = liveNoMirror) -> AgentPromptIO {
        @Sendable func dch(_ args: [String], _ key: AgentSessionKey) -> String {
            String(decoding: run(args, AgentIsland.listEnv(dir: key.dir)), as: UTF8.self)
        }
        return AgentPromptIO(
            read: { dch(["--read", $0.name], $0) },
            status: { dch(["--status", $0.name], $0) },
            send: { _ = dch(["--send", $0.name, "--", $1], $0) },
            keys: { _ = dch(["--keys", $0.name] + $1, $0) },
            say: { key, text in
                String(decoding: say(["--say", key.name, "--json", "--", text], AgentIsland.listEnv(dir: key.dir)),
                       as: UTF8.self)
            },
            noMirror: { noMirror(["--read", $0.name], AgentIsland.listEnv(dir: $0.dir)) })
    }

    /// QA #651 INFO-2: dch's `--read` exits 3 when the session has no terminal mirror; a
    /// timed-out or failed call is not that (the caller then fails closed as unconfirmed).
    static func liveNoMirror(_ args: [String], _ env: [String: String]) -> Bool {
        let path = DchCommand.dchPath   // on the caller's thread
        return DchCommand.bounded(DchCommand.islandTimeout) { onPid in
            Data(DchCommand.runCapturingBoth(args: args, env: env, path: path, onPid: onPid).status == 3 ? [1] : [])
        } == Data([1])
    }

    /// #798: `--say` waits up to 30 s for the paste to land, then re-presses Enter up to 5 times
    /// 5 s apart (dch's DCH_AGENT_LAND_MS and retry), so it gets more than the island's 4 s.
    static let sayTimeout: TimeInterval = 70

    static func liveSay(_ args: [String], _ env: [String: String]) -> Data {
        let path = DchCommand.dchPath   // on the caller's thread
        return DchCommand.bounded(sayTimeout) { onPid in
            DchCommand.runCapturingBoth(args: args, env: env, path: path, onPid: onPid).out
        } ?? Data()
    }
}

/// #792: whether dch's own auto-allow answers a row's prompts, so Always allow stands down.
/// Only when dch clearly does: the row's master at 1.29.0+ (older ones never auto-allow;
/// standing down on one that cannot leaves the prompt to the human after the wait, never two
/// engines), the installed dch at 1.29.2+ (its normalised `--config` listing is the verified
/// one), the installed build "full" (lite never auto-allows; asked only past the version,
/// since older dch exits 1 on --build), and that listing has exactly "auto_allow = true".
/// Anything else (off, unreadable, timed out, an older or lite dch, none): Prosper answers.
enum DchAutoAllowGate {
    static let masterMinimum = [1, 29, 0]
    static let installedMinimum = [1, 29, 2]

    static func answers(master: String, dch: () -> DchCommand.Binary?, build: (DchCommand.Binary) -> String?,
                        config: (DchCommand.Binary) -> String?) -> Bool {
        guard DchCommand.isAtLeast(DchCommand.masterVersion(master), masterMinimum), let bin = dch(),
              DchCommand.isAtLeast(bin.version, installedMinimum), build(bin) == "full", let text = config(bin) else { return false }
        // Line 1 is the config's path; bools are normalised to true/false (never the raw "yes").
        return text.split(separator: "\n").dropFirst().contains("auto_allow = true")
    }
}

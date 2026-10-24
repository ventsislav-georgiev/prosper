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
        store = AgentIslandStore(geometry: geometry, details: Preferences.agentIslandRowDetails)
        let t = Self.makePollTimer(makePoller(), queue: queue) { [weak self] sessions in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(sessions) } }
        }
        t.resume()
        timer = t
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
        store.sessions = sessions
        onSessions?(sessions)
        let live = Set(sessions.map(\.key))
        store.notices = store.notices.filter { live.contains($0.key) }
        if sessions.isEmpty { setExpanded(false) }
        refreshCards()
        layout()
    }

    /// #534: a Settings row-detail toggle. Redraws the island and resizes the
    /// panel at once (a row losing its PR line is 48 pt again); no animation.
    func rowDetailsChanged() {
        guard let store else { return }
        store.details = Preferences.agentIslandRowDetails
        layout()
    }

    /// Size the panel to the island so nothing outside it eats clicks; hide it
    /// with no sessions.
    private func layout() {
        guard showsPanel, let store else { return }
        if let g = currentGeometry(), g != store.geometry { store.geometry = g }
        guard !store.sessions.isEmpty else { panel?.orderOut(nil); return }
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
            onAnswer: { [weak self] in self?.answer($0, $1, $2) }))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }

    /// Only the panel's own view expands it, so a nil panel (tests) just skips the window work.
    func setExpanded(_ on: Bool) {
        guard let store, store.expanded != on else { return }
        store.expanded = on
        if !on { store.notices = [:]; store.cards = [:]; readAt = [:] }
        refreshCards()
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
    /// rows that are no longer blocked.
    func refreshCards() {
        guard let store, store.expanded else { return }
        let blocked = store.sessions.filter { $0.state == .blocked }
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
    }
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
    nonisolated static func send(_ event: NSAppleEventDescriptor, done: @escaping @Sendable (OSStatus) -> Void) {
        // Belt and braces: a test that forgot the seam never sends a real Apple Event.
        guard NSClassFromString("XCTestCase") == nil else { done(OSStatus(procNotFound)); return }
        nonisolated(unsafe) let event = event   // built for this send, touched only on the queue
        DispatchQueue.global(qos: .userInitiated).async {
            let status = deliver(attempt: { attempt(event) }, launch: activateGhostty,
                                 sleep: { Thread.sleep(forTimeInterval: $0) })
            // Cooperative activation may ignore Ghostty's own activate: bring it
            // forward through Launch Services, as the script path does.
            if status == noErr { activateGhostty() }
            done(status)
        }
    }

    /// Ghostty not running (-600): launch it once, then retry every 0.5 s for up
    /// to 8 s while it is still starting (-600) or its handler is not ready (-1708).
    /// Any other status ends it. Pure over its seams (tests drive it).
    nonisolated static func deliver(attempt: () -> OSStatus, launch: () -> Void,
                                    sleep: (TimeInterval) -> Void) -> OSStatus {
        var status = attempt()
        guard status == procNotFound else { return status }
        launch()
        for _ in 0..<16 where status == procNotFound || status == errAEEventNotHandled {
            sleep(0.5)
            status = attempt()
        }
        return status
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

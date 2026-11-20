import AppKit
import GhosttyTerminal
import SwiftUI
import UniformTypeIdentifiers

// #822 P1: the Agent Sessions window's live terminal. Prosper runs the same dch client
// Ghostty runs (`dch -E -a <name>`) in its own pty (PtyChild) and draws it with libghostty
// (GhosttyTerminal's AppTerminalView over the host-managed InMemoryTerminalSession). The
// renderer sits behind AgentTerminalScreen so SwiftTerm (plan B) can replace it. One
// controller per detail pane (no window-wide singleton), so a split pane hosts its own.

// MARK: - Seams

/// What the controller runs: a PtyChild in the app; tests hand in /bin/cat or a fake.
protocol AgentTerminalChild: AnyObject, Sendable {
    func run()
    func write(_ bytes: [UInt8])
    func resize(cols: Int, rows: Int)
    func redraw()
    func terminate()
}

extension PtyChild: AgentTerminalChild {}

/// One attach's command line.
struct AgentTerminalSpawn: Equatable {
    let exe: String
    let args: [String]
    let env: [String: String]
    let cols: Int
    let rows: Int

    /// `-E -a <name>`: attach only (never create or resurrect), no detach key. The key's dir always
    /// goes in DCH_SOCKET_DIR, so an isolated session is never confused with a same-named default one.
    static func local(_ key: AgentSessionKey, cols: Int, rows: Int, dch: String = DchCommand.dchPath,
                      env: [String: String] = DchCommand.childEnv()) -> AgentTerminalSpawn {
        var env = env
        env["DCH_SOCKET_DIR"] = key.dir
        return AgentTerminalSpawn(exe: dch, args: ["-E", "-a", key.name], env: env, cols: cols, rows: rows)
    }

    /// #836: a remote session's terminal key: its host behind "@" in the dir slot (AgentPaneLayout.resolve's own form),
    /// never an absolute path, so no local socket dir can be one.
    static func remoteKey(host: String, name: String) -> AgentSessionKey { AgentSessionKey(dir: "@" + host, name: name) }

    /// The host of a remote key; nil for a local one.
    static func remoteHost(_ key: AgentSessionKey) -> String? { key.dir.hasPrefix("@") ? String(key.dir.dropFirst()) : nil }

    /// #836 (b): `-E --host <host> -a <name>`: attach only, no detach key, on that host (dch's README "Remote hosts" at
    /// v1.74.0: `--host` is the unambiguous form; `-a host:name` would attach a local session of that exact name).
    /// No DCH_SOCKET_DIR: no local socket is involved.
    static func remote(host: String, name: String, cols: Int, rows: Int, dch: String = DchCommand.dchPath,
                       env: [String: String] = DchCommand.childEnv()) -> AgentTerminalSpawn {
        AgentTerminalSpawn(exe: dch, args: ["-E", "--host", host, "-a", name], env: env, cols: cols, rows: rows)
    }

    /// The attach for `key`: remote for a remote key, else local.
    static func attach(_ key: AgentSessionKey, cols: Int, rows: Int, dch: String = DchCommand.dchPath,
                       env: [String: String] = DchCommand.childEnv()) -> AgentTerminalSpawn {
        if let h = remoteHost(key) { return remote(host: h, name: key.name, cols: cols, rows: rows, dch: dch, env: env) }
        return local(key, cols: cols, rows: rows, dch: dch, env: env)
    }

    /// `--scrollback n` after the attach arguments (nil: unchanged). dch >= 1.40.0 then sends up to n rows
    /// of history before the screen; an older master ignores it without a word, an older client would not know it.
    func scrollback(_ n: Int?) -> AgentTerminalSpawn {
        guard let n else { return self }
        return AgentTerminalSpawn(exe: exe, args: args + ["--scrollback", String(n)], env: env, cols: cols, rows: rows)
    }
}

/// The child's callbacks; both run on its pump thread.
struct AgentTerminalIO: Sendable {
    let output: @Sendable ([UInt8]) -> Void
    let exit: @Sendable (Int32) -> Void
}

/// The renderer's callbacks. Any thread: libghostty calls write off main.
struct AgentTerminalScreenEvents: Sendable {
    let write: @Sendable (Data) -> Void
    /// The grid the renderer now parses at; the client starts once it is the view's.
    let resize: @Sendable (_ cols: Int, _ rows: Int) -> Void
    let backlog: @Sendable (Bool) -> Void
}

/// The renderer seam (libghostty today, SwiftTerm as plan B): bytes in, one screen per attach.
@MainActor
protocol AgentTerminalScreen: AnyObject {
    func feed(_ bytes: [UInt8])
}

/// libghostty's host-managed backend. Its parser runs on its own queue; past 4 MiB unparsed it
/// reports a backlog and the controller stops draining until it falls to 1 MiB.
@MainActor
final class AgentGhosttyScreen: AgentTerminalScreen {
    let session: InMemoryTerminalSession
    /// #1615: the surfaces this screen went into. A second is a fresh, empty grid on a session the first one parsed.
    var mounts = 0

    init(_ events: AgentTerminalScreenEvents) {
        session = InMemoryTerminalSession(write: events.write,
                                          resize: { events.resize(Int($0.columns), Int($0.rows)) })
        session.setOutputBacklogHandler(highWater: 4 << 20, lowWater: 1 << 20, events.backlog)
    }

    func feed(_ bytes: [UInt8]) { session.receive(Data(bytes)) }
}

// MARK: - Output and input plumbing

/// The pump-to-main hand-off: the pump appends, main drains everything at once with at most one
/// drain block in flight. Past `cap` unfed bytes the pump waits, so the pty stops being read, the
/// dch client blocks and the master (OUT_CAP) is the bound. `close` wakes a waiting pump for good.
final class AgentTerminalInbox: @unchecked Sendable {
    static let cap = 1 << 20
    private let cond = NSCondition()
    private var buffer: [UInt8] = []
    private var scheduled = false
    private var closed = false

    /// True when the caller must schedule a drain (none in flight).
    func put(_ bytes: [UInt8]) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        while !closed, buffer.count >= Self.cap { cond.wait() }
        guard !closed else { return false }
        buffer += bytes
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func take() -> [UInt8] {
        cond.lock()
        defer { cond.unlock() }
        let out = buffer
        buffer = []
        scheduled = false
        cond.broadcast()
        return out
    }

    /// The drain left the bytes (the renderer is backlogged); the next put or the backlog's end drains.
    func unschedule() { cond.withLock { scheduled = false } }

    func close() {
        cond.lock()
        closed = true
        buffer = []
        cond.broadcast()
        cond.unlock()
    }

    var count: Int { cond.withLock { buffer.count } }
}

/// The pty write path. libghostty's write callback arrives off main and paste arrives on main, so
/// every write goes through one serial queue (PtyChild.write itself is unlocked).
final class AgentTerminalWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var current: AgentTerminalChild?
    private let queue = DispatchQueue(label: "eu.illegible.prosper.agent-terminal.write")

    var child: AgentTerminalChild? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async { self.child?.write(bytes) }
    }

    /// Waits for every queued write (tests).
    func flush() { queue.sync {} }
}

// MARK: - The controller

/// One pane's terminal: attach conditions come from the window model (`attach`), the grid size
/// from the view (`gridChanged`). Never spawns anything under XCTest unless a test hands in `spawn`.
@MainActor
final class AgentTerminalController: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// A fresh screen; the client starts once the grid size is known.
        case attaching
        case live
        /// The session is gone.
        case ended
        /// The client left while the session lives on (a detach-all, the master's OUT_CAP drop).
        case detached(String)
        case failed(String)
    }

    @Published private(set) var phase = Phase.idle
    /// The current attach's screen; nil while nothing is attached.
    @Published private(set) var screen: AgentTerminalScreen?
    /// False from an attach until its first bytes are fed (or `revealAfter`): the pane shows only
    /// the background meanwhile, never a half-drawn frame.
    @Published private(set) var revealed = false
    /// "Reattached", for a moment.
    @Published private(set) var notice: String?
    /// The find bar (⌘F).
    @Published private(set) var findOpen = false
    @Published var findText = ""
    @Published private(set) var findTotal: Int?
    @Published private(set) var findSelected: Int?

    private(set) var key: AgentSessionKey?
    /// #836: the attached session is on another machine.
    var remoteHost: String? { key.flatMap(AgentTerminalSpawn.remoteHost) }
    /// #1330 (R836-q1): a remote attach takes the session from the device holding it (dch exit 5 there), so one starts
    /// only for the key the human armed (a click, a key, Attach); Reconnect is retry() on it. Any other attach or a
    /// detach (hide, the row gone, the New session form) drops it.
    private(set) var armed: AgentSessionKey?
    /// #1330: a remote session shown but not attached: its card offers Attach.
    @Published private(set) var held: AgentSessionKey?
    static let heldText = "Attaching takes this session over from the other device using it"
    /// The view's grid, and the size the pty last got.
    private(set) var grid: (cols: Int, rows: Int)?
    private(set) var sentSize: (cols: Int, rows: Int)?
    /// The grid the current screen last reported from its parser (libghostty's IO thread runs the
    /// resize just after it reports). The client starts only once this equals `grid`, so dch's attach
    /// replay is parsed at the size it was drawn for.
    private(set) var screenGrid: (cols: Int, rows: Int)?
    /// `screenWait` ran out on this screen: start at the view's grid without its report.
    private var screenWaitOver = false
    private var child: AgentTerminalChild?
    private var inbox: AgentTerminalInbox?
    let writer = AgentTerminalWriter()
    /// One automatic reattach per attach (an exit 0 while the session is live).
    private var reattached = false
    /// #896 (dch ask 4): automatic reconnects of a remote attach since the human's last pick or Reconnect, or since an
    /// attach that settled; at most `reconnectBackoff.count`.
    private var reconnects = 0
    /// #896: a reconnect is scheduled (the card says so).
    @Published private(set) var reconnecting = false
    /// #896 (dch ask 1): the session's pty size and attached clients from the store's `--ls-json`; the window model feeds it.
    @Published var sessionPty: AgentSessionPty?
    private(set) var generation = 0
    private var resizeGeneration = 0
    private var backlogged = false
    /// The view is in a live resize: the size goes out once, at its end.
    var liveResizing = false
    /// The dch client re-sends its size on focus-in itself (DEC 1004, dch >= 1.39.0); older clients
    /// need the rows-1 jiggle. Off until the client's version is known.
    private(set) var focusJiggle = false
    /// This attach's client version: probed (`versionKnown`, the answer may be nil) or not yet.
    private var version: [Int]?
    private var versionKnown = false
    /// A byte of this attach reached the screen (no quiet-attach redraw then).
    private var fed = false
    weak var view: AgentTerminalHostView?

    static let resizeDebounce: TimeInterval = 0.15
    static let revealAfter: TimeInterval = 0.3
    /// The longest the client waits for the screen to report the view's grid; then it starts anyway.
    static let screenWait: TimeInterval = 0.5
    static let noticeFor: TimeInterval = 2
    static let focusResizeDch = [1, 39, 0]
    /// `dch -a <name> --scrollback N`: client flag and master side since dch 1.40.0 (one commit).
    static let scrollbackDch = [1, 40, 0]
    static let scrollbackRows = 2000
    /// An attach that fed no byte by then gets one redraw (a quiet program repaints).
    static let quietRedrawAfter: TimeInterval = 0.7
    /// #896 (dch ask 4): the delays before each automatic reconnect after a lost link; past the last, the card's Reconnect.
    static let reconnectBackoff: [TimeInterval] = [1, 2, 4, 8, 16]
    /// #896: a remote attach that stays up this long starts the backoff over.
    static let reconnectSettled: TimeInterval = 30
    static let sizedElsewhereText = "Sized for another window"

    // Seams.
    var spawn: (AgentTerminalSpawn, AgentTerminalIO) throws -> AgentTerminalChild = AgentTerminalController.realSpawn
    var makeScreen: (AgentTerminalScreenEvents) -> AgentTerminalScreen = { AgentGhosttyScreen($0) }
    var request: (AgentSessionKey, Int, Int) -> AgentTerminalSpawn = { AgentTerminalSpawn.attach($0, cols: $1, rows: $2) }
    /// The store still lists the session (an exit 0 then means it was detached, not ended).
    var isLive: (AgentSessionKey) -> Bool = { _ in false }
    var after: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
    }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// #1480: a file link opens in the Text Viewer (the intake), relative to the session's folder.
    var cwd: (AgentSessionKey) -> String? = { _ in nil }
    var homeDirectory: () -> String = { NSHomeDirectory() }
    var showFile: @MainActor (URL) -> Void = { TextViewerIntake.shared.receive($0) }
    /// #1719: where a file link's disk check runs: off main, so a stat that blocks (a first look into a TCC-guarded
    /// folder waits for the consent answer, an iCloud folder for its download) holds a utility thread, never the UI.
    /// Rows run it inline.
    var fileCheck: (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
    /// #1357 (P9): a prosper-xray link (OSC 8) to the window's ref card, the key checked against this session's refs.
    var openRefLink: @MainActor (URL, NSWindow?, AgentSessionKey?) -> Void = {
        XrayRefLink.openTerminalLink($0, $1 as? AgentsNSWindow, key: $2)
    }
    /// The client binary's version, probed off main (cached per path and mtime). Nil under XCTest: the
    /// probe runs before the spawn now, and a row never runs a real `dch --version`.
    var clientVersion: @Sendable (String) -> [Int]? = {
        NSClassFromString("XCTestCase") == nil ? DchCommand.probedVersion($0) : nil
    }
    /// Where that probe runs: off main in the app (a cache miss runs `dch --version`, up to 4 s); under
    /// XCTest on main at once, so a fake's answer is in before the grid. A row that wants it late sets this.
    var probeOffMain = NSClassFromString("XCTestCase") == nil
    /// QA #681 INFO-4: the session's socket is on disk. dch's master unlinks it at exit (atexit(unlink_socket), master.c:4234 at dch v1.49.0, :4333 at v1.58.0, the bundled tag)
    /// before its clients read EOF, so an exit 0 with the socket gone is an end even while the store (polled
    /// about once a second) still lists the session.
    var socketExists: (AgentSessionKey) -> Bool = {
        FileManager.default.fileExists(atPath: ($0.dir as NSString).appendingPathComponent($0.name + ".sock"))
    }
    /// OQ-66: the session is the window's selection (the window model answers; until it does, none is).
    var isSelected: (AgentSessionKey) -> Bool = { _ in false }
    /// OQ-66: the pane's window as it is now; nil with no window (closed, or the view not in one).
    var windowState: @MainActor (NSWindow?) -> AgentTerminalWindowState? = { $0.map(AgentTerminalWindowState.init) }
    /// OQ-66: Settings › Agent Island › "Let sessions set the clipboard while you're viewing them".
    var clipboardWrites: () -> Bool = { Preferences.agentWindowClipboardWrites }
    /// #895: a font binding action for the surface, the call find makes (rows record it). Runs on main.
    var fontAction: @MainActor (AgentTerminalHostView?, String) -> Void = { _ = $0?.surface?.performBindingAction($1) }
    /// #1566: Command-K's local clear: libghostty's own clear_screen action (`keybind = clear` dropped its super+k).
    /// Rows record it. Runs on main.
    var clearAction: @MainActor (AgentTerminalHostView?) -> Void = { _ = $0?.surface?.performBindingAction("clear_screen") }
    /// #1477 (7.6): this terminal is its window's focused pane (the window model answers for a pane's; the window's is).
    var paneFocused: () -> Bool = { true }
    /// #1656 rows: every focus the wrapper hands libghostty for this terminal's surface (core.setFocus tells the view).
    var focusSent: ((Bool) -> Void)?
    /// #1559 (X-T a): the window's focused pane's follow for `target` (nil: none held); rows hand in a fake.
    var focusFollow: @MainActor (XrayTarget?, ObjectIdentifier) -> XrayFollow? = {
        XrayPanels.shared.follows.focus($0, window: $1, dch: $0 == nil ? nil : XrayPanels.dch())
    }
    /// #1559: the terminal that holds each window's pane focus (its marks go when another takes it).
    private struct FocusHolder { weak var terminal: AgentTerminalController? }
    private static var focusHolders: [ObjectIdentifier: FocusHolder] = [:]

    enum SpawnError: Error, CustomStringConvertible {
        case underTests
        var description: String { "no real dch under XCTest" }
    }

    nonisolated static func realSpawn(_ r: AgentTerminalSpawn, _ io: AgentTerminalIO) throws -> AgentTerminalChild {
        // Tests never run a real dch: a test that wants a pty hands in its own spawn.
        guard NSClassFromString("XCTestCase") == nil else { throw SpawnError.underTests }
        return try PtyChild(exe: r.exe, args: r.args, env: r.env, cols: r.cols, rows: r.rows,
                            onOutput: io.output, onExit: io.exit)
    }

    /// Attach to `key`, or detach (nil). The window model calls this from follow(): visible, a live
    /// session selected, and its mode Terminal. The same key again changes nothing.
    func attach(_ key: AgentSessionKey?) {
        defer { followFocus() }   // #1559: the same key too (another pane's focus may have come back to this one)
        if held != nil { held = nil }
        if key != armed { armed = nil }
        guard key != self.key else { return }
        focusPending = false   // #845: a focus asked for on another session never lands on this one
        detach()
        self.key = key
        reattached = false
        reconnects = 0
        sessionPty = nil   // #896: the last session's size never shows on this one
        closeFind(refocus: false)   // QA #694 INFO-1: the find bar goes with the session, the keys stay put
        guard key != nil else { phase = .idle; return }
        begin()
    }

    /// #1559 (X-T a): pane focus. The window's focused pane holds its session's follow (XrayFollows.focus), whose
    /// refs mark the grid and answer a Cmd-click; no session or gate B off holds none (the window's follow is detached).
    /// #1568 (X-R a): a remote session's too, keyed "host:name" (XrayRefLink.target). The terminal that held the window's focus before loses its marks (blur). An unfocused pane changes
    /// nothing: its attach after the rest must not take the focused pane's follow. No view or window yet: nothing
    /// (viewDidMoveToWindow asks again).
    func followFocus() {
        guard paneFocused(), let view, let w = view.window else { return }
        let id = ObjectIdentifier(w)
        let target = XrayRefLink.decorate() ? key.flatMap(XrayRefLink.target) : nil
        if let old = Self.focusHolders[id]?.terminal, old !== self { old.view?.marks.follow = nil }
        Self.focusHolders[id] = FocusHolder(terminal: self)
        view.marks.follow = focusFollow(target, id)
    }

    /// #1330: the human's pick of remote `key`: the next attach to it starts.
    func arm(_ key: AgentSessionKey) { armed = key }

    /// #1330: remote `key` focused but not armed: nothing attached, the card with Attach.
    func hold(_ key: AgentSessionKey) {
        if self.key != nil { attach(nil) }
        armed = nil
        if held != key { held = key }
    }

    /// #1330: the card's Attach.
    func attachHeld() {
        guard let k = held else { return }
        arm(k)
        attach(k)
    }

    /// Retry or Reattach from the overlay.
    func retry() {
        guard key != nil, child == nil else { return }
        reattached = false
        reconnects = 0
        begin()
    }

    /// A fresh screen; the client starts once it parses at the view's grid (see gridChanged).
    private func begin() {
        generation += 1
        let gen = generation
        reconnecting = false
        backlogged = false
        sentSize = nil
        screenGrid = nil
        screenWaitOver = false
        version = nil
        versionKnown = false
        fed = false
        let events = AgentTerminalScreenEvents(
            write: { [writer] in writer.send([UInt8]($0)) },
            resize: { [weak self] cols, rows in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.gridChanged(cols: cols, rows: rows, generation: gen) } }
            },
            backlog: { [weak self] on in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.backlogChanged(on, generation: gen) } }
            })
        screen = makeScreen(events)
        phase = .attaching
        revealed = false
        after(Self.revealAfter) { [weak self] in if self?.generation == gen { self?.revealed = true } }
        // A report that never comes, or never matches (rounding, a grid that kept moving), must not
        // leave the pane on "attaching".
        after(Self.screenWait) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.screenWaitOver = true
            self.start()
        }
        // The client's version decides the scrollback flag; the attach waits for it at most screenWait.
        let probe = clientVersion, path = DchCommand.dchPath
        if probeOffMain {
            // Runs on a utility queue; the answer runs on main and is dropped for a later attach.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let v = probe(path)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.versionProbed(v, generation: gen) } }
            }
        } else {
            versionProbed(probe(path), generation: gen)
        }
        if grid != nil { start() }
    }

    private func versionProbed(_ v: [Int]?, generation gen: Int) {
        guard gen == generation else { return }
        version = v
        versionKnown = true
        focusJiggle = v.map { !DchCommand.isAtLeast($0, Self.focusResizeDch) } ?? false
        start()
    }

    private func start() {
        guard let key, let grid, child == nil, phase == .attaching,
              screenWaitOver || (versionKnown && screenGrid.map({ $0 == grid }) == true) else { return }
        let box = AgentTerminalInbox()
        inbox = box
        // Every attach asks again, a re-attach too: it always has a fresh screen (no history kept to repeat).
        let asks = version.map { DchCommand.isAtLeast($0, Self.scrollbackDch) } ?? false
        let req = request(key, grid.cols, grid.rows).scrollback(asks ? Self.scrollbackRows : nil)
        do {
            let c = try spawn(req, Self.io(box, owner: self))
            child = c
            writer.child = c
            sentSize = grid
            phase = .live
            c.run()
            if focusPending { focus() }   // #845: a click while it attached lands now
            let gen = generation
            // Runs on main (the `after` seam); only this attach's child, only if it fed nothing.
            after(Self.quietRedrawAfter) { [weak self] in
                guard let self, self.generation == gen, !self.fed else { return }
                self.child?.redraw()
            }
            if remoteHost != nil {
                after(Self.reconnectSettled) { [weak self] in
                    guard let self, self.generation == gen, self.child != nil else { return }
                    self.reconnects = 0
                }
            }
        } catch {
            inbox = nil
            box.close()
            phase = .failed(Self.failure(error))
        }
    }

    /// QA #681 INFO-7: a spawn error as a sentence (it read "Couldn't open the terminal: forkFailed").
    nonisolated static func failure(_ error: Error) -> String {
        error is PtyChild.PtyError
            ? "Couldn't open the terminal: the Mac couldn't start a new process. Close some apps and retry."
            : "Couldn't open the terminal."
    }

    /// Built outside the main actor: these closures run on the pump thread (a closure formed in
    /// @MainActor code would be main-isolated and trap there).
    nonisolated static func io(_ box: AgentTerminalInbox, owner: AgentTerminalController) -> AgentTerminalIO {
        AgentTerminalIO(
            output: { [weak owner] bytes in
                guard box.put(bytes) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { owner?.drain(box) } }
            },
            exit: { [weak owner] code in
                DispatchQueue.main.async { MainActor.assumeIsolated { owner?.childExited(code, box) } }
            })
    }

    /// Feeds everything the pump has handed over, unless the renderer is backlogged.
    func drain(_ box: AgentTerminalInbox) {
        guard box === inbox, let screen else { _ = box.take(); return }
        if backlogged { return box.unschedule() }
        let bytes = box.take()
        guard !bytes.isEmpty else { return }
        screen.feed(bytes)
        view?.marks.output()   // #1559, #1628: marks whose text changed off now, all placed again once output rests
        fed = true
        revealed = true
    }

    private func backlogChanged(_ on: Bool, generation gen: Int) {
        guard gen == generation else { return }
        backlogged = on
        if !on, let inbox { drain(inbox) }
    }

    /// The view's grid (cols x rows, `gen` nil) or the screen's report of the grid its parser now runs
    /// at (`gen`). The client starts once the two agree, or `screenWait` after the screen began.
    /// #844: dch adopts the spawn size at attach and replays its screen drawn for it (dch v1.57.0: the client's
    /// MSG_ATTACH + MSG_REDRAW, attach.c:883-893; the master's MSG_REDRAW resizes, then queue_replay, master.c:3953-3982,
    /// :2418-2443); parsed at the new surface's creation grid (46x16 for
    /// 720x420 pt on 2x) that replay came out wrapped and torn.
    /// The screen's report never sizes the pty: it trails the view's (46x16 after 101x26).
    /// Later view grids reach the pty after a 150 ms trailing debounce, or once at the end of a live
    /// resize (one WINCH, one re-render).
    func gridChanged(cols: Int, rows: Int, generation gen: Int? = nil) {
        guard cols > 0, rows > 0, gen.map({ $0 == generation }) ?? true else { return }
        guard gen == nil else {
            screenGrid = (cols, rows)
            return start()
        }
        grid = (cols, rows)
        guard child != nil else { return start() }
        resizeGeneration += 1
        guard !liveResizing else { return }
        let rg = resizeGeneration
        after(Self.resizeDebounce) { [weak self] in
            guard let self, self.resizeGeneration == rg else { return }
            self.pushSize()
        }
    }

    func liveResizeStarted() { liveResizing = true }

    func liveResizeEnded() {
        liveResizing = false
        resizeGeneration += 1
        pushSize()
    }

    private func pushSize() {
        guard let child, let grid, sentSize.map({ $0 != grid }) ?? true else { return }
        sentSize = grid
        child.resize(cols: grid.cols, rows: grid.rows)
    }

    /// The terminal became first responder in the key window: the session takes this pane's size
    /// again. A >= 1.39 client does it itself on the focus event; an older one gets the jiggle.
    func focusIn() {
        guard let child, focusJiggle else { return }
        child.redraw()
    }

    /// #896 (dch ask 1): "Sized for another window": a local session another client holds at a size other than this pane's.
    var sizedElsewhere: Bool {
        guard remoteHost == nil, phase == .live, child != nil, let grid, let p = sessionPty, p.clients > 1 else { return false }
        return p.cols != grid.cols || p.rows != grid.rows
    }

    /// #896: Fit here. The session takes this pane's size by the focus-in path: the jiggle makes the dch client re-send
    /// its winsize (a same-size TIOCSWINSZ sends no SIGWINCH). The chip hides until the next list says otherwise.
    func fitHere() {
        guard sizedElsewhere, let child else { return }
        sessionPty = nil
        child.redraw()
    }

    /// Raw bytes to the program (an image-only paste's ^V).
    func input(_ bytes: [UInt8]) {
        guard child != nil else { return }
        writer.send(bytes)
    }

    private func childExited(_ code: Int32, _ box: AgentTerminalInbox) {
        guard box === inbox, let key else { return }
        child = nil
        writer.child = nil
        inbox = nil
        // dch's `-a host:name` exit codes (remote.h:47-53 at v1.99.0): 0 ended or detached, 1 lost, 4 refused, 5 taken.
        if let host = remoteHost {
            switch code {
            case 0: phase = .ended
            case 4: phase = .failed("\(OutsideText.shown(host)) refused the attach")   // #1330 (R836-q2)
            case 5: phase = .detached("Opened on another device")
            default: phase = .failed("Lost the connection to \(OutsideText.shown(host))")
            }
            revealed = true
            // #896 (dch ask 4): only a lost link retries by itself ("a retry may work"); refused, taken, ended and
            // detached never do, nor any other code.
            if code == 1 { reconnectLater() }
            return
        }
        // INFO-4: the store's list trails the socket, so a stale "live" never flashes "Couldn't attach".
        let live = isLive(key) && socketExists(key)
        switch code {
        case 0 where live && !reattached:
            reattached = true
            show("Reattached")
            return begin()   // a fresh screen: background until its first bytes
        case 0:
            phase = live ? .detached("Detached elsewhere") : .ended
        case 4:
            phase = .failed("dch refused the attach")
        case 5:
            phase = .detached("Opened on another device")
        default:
            phase = live ? .failed("Couldn't attach (dch exited \(code))") : .ended
        }
        revealed = true   // the card shows over the background
    }

    /// #896: the next automatic reconnect after its backoff, unless the cap is spent. A pick, Reconnect, a detach or
    /// another attach in between moves `generation` and drops it.
    private func reconnectLater() {
        guard reconnects < Self.reconnectBackoff.count else { return }
        let gen = generation, k = key
        let delay = Self.reconnectBackoff[reconnects]
        reconnects += 1
        reconnecting = true
        after(delay) { [weak self] in
            guard let self, self.generation == gen, self.key == k, self.child == nil else { return }
            self.begin()
        }
    }

    private func show(_ text: String) {
        notice = text
        after(Self.noticeFor) { [weak self] in if self?.notice == text { self?.notice = nil } }
    }

    /// Hidden, deselected, switched to Transcript, closed: the client goes (SIGHUP, then SIGKILL).
    func detach() {
        generation += 1
        reconnecting = false
        inbox?.close()
        inbox = nil
        child?.terminate()
        child = nil
        writer.child = nil
        screen = nil
        sentSize = nil
        if phase != .idle { phase = .idle }
    }

    /// #1615: `s` went into a second surface: SwiftUI remade the pane's view (a focus switch between two layout panes
    /// swaps each pane's branch, AgentPaneArea.pane), and the new surface's grid starts empty while dch sends only new
    /// output, so both panes drew nothing but the cursor. A fresh attach has dch replay the screen and scrollback into a
    /// fresh screen. Only a screen that was fed (an unfed one lost nothing, and two views over one fresh screen never loop),
    /// on the next main turn (the call comes from inside a view update), and only while `s` is still this attach's
    /// screen with its client running: a parked or ended pane has no client to replay.
    func remount(_ s: AgentTerminalScreen) {
        guard fed else { return }
        after(0) { [weak self] in
            guard let self, self.key != nil, self.screen === s, self.child != nil else { return }
            self.detach()
            self.begin()
        }
    }

    /// #1477 (11.2 "detached, last frame kept"): zoomed away, too small, over the cap of attached clients or the same
    /// session's second pane: the client goes as in a detach, the screen (its last frame) stays; the next attach
    /// replaces it with a fresh one.
    func park() {
        guard key != nil else { return }
        let kept = screen
        attach(nil)
        screen = kept
    }

    /// OQ-66 (operator, 2026-11-10): a program sets the clipboard (OSC 52) only while someone is looking
    /// at this session: the pane attached, the session selected, and its window on screen, not minimized
    /// and not fully covered (occlusionState has .visible). Off in Settings: never.
    func clipboardWriteAllowed() -> Bool {
        guard clipboardWrites(), phase == .live, let key, isSelected(key),
              let w = windowState(view?.window) else { return false }
        return w.onScreen && !w.miniaturized && w.occlusionVisible
    }

    // MARK: Links and find

    /// ⌘-click on a URL or an OSC 8 link: web and mail links to openURL; a text file to the Text Viewer
    /// (#1719: its disk check off main, fileCheck);
    /// #1357: a prosper-xray link to the ref card (a local session's only); never any other file or an app.
    func open(_ link: String) {
        if let url = URL(string: link), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            openURL(url)
            return
        }
        if let url = URL(string: link), url.scheme?.lowercased() == XrayRefLink.scheme {
            if remoteHost == nil { openRefLink(url, view?.window, key) }
            return
        }
        // A remote row's paths are another machine's: never open one here, not even an absolute one (same-named local file).
        guard remoteHost == nil,
              let file = AgentTerminalFileLink.resolve(link, cwd: key.flatMap(cwd), home: homeDirectory()) else { return }
        fileCheck { [weak self] in
            guard AgentTerminalFileLink.isViewable(file) else { return }
            let show: @Sendable () -> Void = { MainActor.assumeIsolated { self?.showFile(file) } }
            if Thread.isMainThread { show() } else { DispatchQueue.main.async(execute: show) }   // inline: rows
        }
    }

    func openFind() {
        guard screen != nil else { return }
        findOpen = true
        focusPending = false   // QA #694 INFO-2: the find field has the keys; going live takes none
        if !findText.isEmpty { search(findText) }
    }

    func search(_ text: String) {
        let needle = text.replacingOccurrences(of: "\n", with: " ")
        _ = view?.surface?.performBindingAction(needle.isEmpty ? "end_search" : "search:\(needle)")
        if needle.isEmpty { findTotal = nil; findSelected = nil }
    }

    func findNext(_ forward: Bool = true) {
        guard findOpen else { return openFind() }
        _ = view?.surface?.performBindingAction(forward ? "navigate_search:next" : "navigate_search:previous")
    }

    func closeFind(refocus: Bool = true) {
        guard findOpen else { return }
        findOpen = false
        findTotal = nil
        findSelected = nil
        _ = view?.surface?.performBindingAction("end_search")
        if refocus { focus() }
    }

    /// #895: the size a new surface is shown with: the stored one (checked and clamped by Preferences), else today's.
    static var fontSize: Double { Preferences.agentWindowTerminalFontSize ?? Double(12 * ThemeRuntime.scale) }

    /// #895: Command-plus (+1), Command-minus (-1), Command-0 (0, back to today's size: the key is removed). One write
    /// and one action, or nothing at a limit or with nothing to reset. "set_font_size", not "reset_font_size": Ghostty
    /// resets to its config's size, not to the size the surface was made with.
    func zoomFont(_ step: Int) {
        let range = Preferences.agentWindowTerminalFontRange
        let now = Self.fontSize
        if step == 0 {
            let had = Preferences.agentWindowTerminalFontSize != nil
            Preferences.agentWindowTerminalFontSize = nil   // a garbage value (read as unset) goes too
            guard had else { return }   // the surface is at today's size already
        } else {
            let next = min(max(now + Double(step.signum()), range.lowerBound), range.upperBound)
            guard next != now else { return }
            Preferences.agentWindowTerminalFontSize = next
        }
        fontAction(view, "set_font_size:\(Float(Self.fontSize))")
    }

    /// #1566 (spec 5.7, dch README v1.99.0:1527-1552): Command-K. The local clear always; then, for a live attach
    /// only, one `dch --xray <n> --clear --json` through XrayPanels.run, never a byte to the pty (dch clears its ring
    /// and mirror over the control socket). Local: <n> is the session_id of the focused pane's follow snapshot when
    /// it is this session's, else the name (dch matches a live ring's session_id first, then a name). Remote: the
    /// clear is a request on the warm host:name connection (XrayRequests; busy or a failed dial runs it cold). An
    /// ended, detached, failed or History pane, or no X-ray gate: the local clear alone.
    func commandK() {
        clearAction(view)
        guard phase == .live, child != nil, let key, !key.name.isEmpty, !key.name.hasPrefix("-"), let dch = XrayPanels.dch() else { return }
        let target: XrayTarget
        if let h = remoteHost {
            target = XrayTarget(name: "\(h):\(key.name)", dir: nil)
        } else {
            let own = XrayTarget(name: key.name, dir: key.dir), f = view?.marks.follow
            target = XrayTarget(name: (f?.target == own ? f?.state?.corpus?.sessionID : nil) ?? key.name, dir: key.dir)
        }
        let run = XrayPanels.shared.requests.run(for: target, cold: XrayPanels.run), args = target.args("clear"), env = target.env
        Task { _ = await run(dch, args, env) }
    }

    func searchTotal(_ n: Int?) { findTotal = n }
    func searchSelected(_ n: Int?) { findSelected = n }

    /// A focus asked for before the view was in a window (a toggle builds it on the next pass), or
    /// (#845) before the client was live. Dropped by an attach to another session, and (QA #694
    /// INFO-2) when the human takes the keys elsewhere first (dropPendingFocus, ⌘F).
    private(set) var focusPending = false

    func dropPendingFocus() { focusPending = false }

    /// Moves the keyboard into the terminal (⌘T, the toggle, a row click, Return or Right on a sidebar row,
    /// closing find). Only the first responder within this window: it never orders a window front or makes
    /// it key. #845: only a live client takes input; until then the keys stay where they are.
    func focus() {
        guard phase == .live, let view, view.window != nil else { focusPending = true; return }
        focusPending = false
        AgentsNSWindow.focus(view)
    }

    /// Paste text with the phone's rules (TerminalMath.pasteBytes): TAB, LF, CR and printable text
    /// only. Every ESC goes, so a copied ESC[201~ cannot end a bracketed paste early; other C0 and
    /// the C1 controls go too. DEL goes as well (the phone keeps it): a program reads it as Backspace.
    /// libghostty adds the bracketed-paste marks when the program set 2004.
    nonisolated static func pasteText(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter {
            ($0.value >= 0x20 && $0.value != 0x7f && !(0x80...0x9f).contains($0.value)) || $0 == "\t" || $0 == "\n" || $0 == "\r"
        }))
    }
}

/// OQ-66: the pane's window, read when an OSC 52 write arrives.
struct AgentTerminalWindowState: Equatable {
    /// Ordered in (closed or ordered out: false).
    var onScreen: Bool
    var miniaturized: Bool
    /// occlusionState contains .visible: some of it shows (another window, Space or a hidden app: false).
    var occlusionVisible: Bool

    init(onScreen: Bool, miniaturized: Bool, occlusionVisible: Bool) {
        self.onScreen = onScreen
        self.miniaturized = miniaturized
        self.occlusionVisible = occlusionVisible
    }

    @MainActor init(_ w: NSWindow) {
        self.init(onScreen: w.isVisible, miniaturized: w.isMiniaturized, occlusionVisible: w.occlusionState.contains(.visible))
    }
}

// MARK: - The view

/// libghostty's clipboard confirmation (its init is internal), as the host view uses it.
@MainActor protocol AgentClipboardRequest {
    var kind: TerminalClipboardRequestKind { get }
    var contents: String { get }
    func respond(allow: Bool)
}
extension TerminalClipboardConfirmationRequest: AgentClipboardRequest {}

/// GhosttyTerminal's AppKit view with Prosper's seams: copy, paste and OSC 52 through the
/// Pasteboard seam (libghostty's own clipboard paths are turned off in `AgentTerminalLook`), links
/// through the controller's openURL, find, focus and live resize to the controller.
final class AgentTerminalHostView: AppTerminalView, TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceClipboardConfirmationDelegate, TerminalSurfaceOpenURLDelegate, TerminalSurfaceSearchDelegate,
    TerminalSurfaceGridResizeDelegate, TerminalSurfaceFocusDelegate {
    weak var owner: AgentTerminalController?
    /// Public only through the lifecycle delegate.
    private(set) var surface: TerminalSurface?
    var pasteboard: () -> NSPasteboard = { Pasteboard.general }
    /// The ghostty app; tests hand in their own and drop it (its config file goes with it).
    var look: () -> TerminalController = { AgentTerminalLook.controller }
    private weak var installed: AgentGhosttyScreen?
    private var wanted: AgentGhosttyScreen?

    override init(frame: NSRect) {
        super.init(frame: frame)
        delegate = self
        registerForDraggedTypes(registeredDraggedTypes + [.agentRow])   // #1492: libghostty's own types and a row's
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal")
        marks.frame = bounds   // #1559: over the whole grid, hitTest nil; it never sizes the view or the pty
        marks.host = self
        addSubview(marks)
    }

    /// #1559 (X-T a): the ref marks over the grid (XrayGridMarks.swift).
    let marks = XrayGridMarksView(frame: .zero)

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `screen` (a new attach rebuilds the surface: a fresh grid). Waits for a window, so a view
    /// rendered without one (an offscreen hosting view) never starts libghostty.
    func show(_ screen: AgentGhosttyScreen?) {
        wanted = screen
        guard window != nil, let screen, screen !== installed else { return }
        AgentTerminalLook.refresh(look())
        installed = screen
        screen.mounts += 1
        viewportText = { [weak screen] in screen?.session.readViewportText() }
        // The backend first: a controller set while the options still name `.exec` (the default)
        // would build a surface that runs a login shell.
        fontShown = AgentTerminalController.fontSize
        configuration = TerminalSurfaceOptions(backend: .inMemory(screen.session),
                                               fontSize: Float(AgentTerminalController.fontSize), context: .window)
        if controller !== look() { controller = look() }
        if screen.mounts > 1 { owner?.remount(screen) }
    }

    /// #891: the theme generation and the font size this view last took (nil before its first update).
    private var themed: Int?
    private(set) var fontShown: Double?

    /// #891: a theme, accent, appearance or UI-size change on the open window, from updateNSView. The surface stays (no
    /// new configuration, no attach, no detach): an installed one re-takes the look's colours (the reconfigure show
    /// runs), and a changed font size (12 x scale unless the user zoomed) goes as one "set_font_size", the action
    /// Command-plus sends, so libghostty resizes the grid through its normal resize path, once. The first call only
    /// records; nothing installed: no colours (the next show reads them).
    func retheme(_ generation: Int = ThemeStore.shared.generation) {
        defer { themed = generation }
        if fontShown == nil { fontShown = AgentTerminalController.fontSize }
        guard let last = themed, last != generation else { return }
        if installed != nil { AgentTerminalLook.refresh(look()) }
        let size = AgentTerminalController.fontSize
        guard size != fontShown else { return }
        fontShown = size
        owner?.fontAction(self, "set_font_size:\(Float(size))")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // #1559: the focused pane's follow starts with its terminal in a window, so refs are there before the first
        // Cmd-click (it replaces #1357's ref cache read, which needed the session's transcript)
        owner?.followFocus()
        show(wanted)
        if owner?.focusPending == true { owner?.focus() }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()   // the wrapper hands libghostty focus true here, key window or not
        if ok, window?.isKeyWindow == true { owner?.focusIn() }
        if !libghosttyFocus(responder: ok) { unfocusSurface() }   // #1656: a window that is not key, or not the focused pane
        return ok
    }

    /// #1656 (operator 2026-11-19): libghostty focus (a solid blinking cursor; without it Ghostty's hollow, steady box)
    /// exactly while the window is key, this is its focused pane and this view is the first responder. The wrapper sends
    /// it on first responder in and out and on the window's key change (AppTerminalView+Lifecycle.swift); this view adds
    /// the two it misses: a first responder in a window that is not key, and a new surface (libghostty starts focused).
    private func libghosttyFocus(responder: Bool) -> Bool {
        responder && window?.isKeyWindow == true && owner?.paneFocused() != false
    }

    /// #1656: focus false through the wrapper's own call (its resign hook runs core.setFocus(false); NSView's answers yes
    /// and changes nothing): the responder chain, the grid and the pty stay as they are.
    /// Hosted through the wrapper's TerminalViewRepresentable instead, this would also flip its FocusState (QA R1656 n3).
    private func unfocusSurface() { _ = super.resignFirstResponder() }

    func terminalDidChangeFocus(_ focused: Bool) { owner?.focusSent?(focused) }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        owner?.liveResizeStarted()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        owner?.liveResizeEnded()
    }

    /// #1477: the mouse path a pane's wheel takes (libghostty's `sendMouseScroll`); rows record it.
    var mouseWheel: ((NSEvent) -> Void)?

    /// #1644 (operator 2026-11-19): the wheel scrolls the pane under the pointer, focused or not, and never moves focus
    /// (was #1477 7.6: an unfocused pane's became scroll_page_lines, which left a program's own scrolling still). Its
    /// point goes to libghostty first: an unfocused pane's moves never reach it (mouseMoved below), so after a focus
    /// switch the wheel went to a stale point and did nothing until the mouse moved. In ?1002/?1003 that move also
    /// writes one motion report at the wheel point (the operator's rule: the wheel reports to that program).
    override func scrollWheel(with event: NSEvent) {
        super.mouseMoved(with: event)
        if let mouseWheel { mouseWheel(event) } else { super.scrollWheel(with: event) }
    }

    /// R1477b-m1 (7.6): an unfocused pane's buttons, motion and exit never reach libghostty: GhosttyTerminal's
    /// AppTerminalView+Input.swift sends a mouse report (?1000-?1003) and its right and other downs make the view first
    /// responder. The window's first-click rule (AgentsNSWindow.sendEvent) already swallows a focusing down; this is the
    /// second guard. No owner, or the focused pane: libghostty as before.
    private var unfocused: Bool { owner?.paneFocused() == false }
    override func rightMouseDown(with event: NSEvent) { if !unfocused { super.rightMouseDown(with: event) } }
    override func rightMouseUp(with event: NSEvent) { if !unfocused { super.rightMouseUp(with: event) } }
    override func rightMouseDragged(with event: NSEvent) { if !unfocused { super.rightMouseDragged(with: event) } }
    override func otherMouseDown(with event: NSEvent) { if !unfocused { super.otherMouseDown(with: event) } }
    override func otherMouseUp(with event: NSEvent) { if !unfocused { super.otherMouseUp(with: event) } }
    override func otherMouseDragged(with event: NSEvent) { if !unfocused { super.otherMouseDragged(with: event) } }
    override func mouseMoved(with event: NSEvent) { if !unfocused { super.mouseMoved(with: event) } }
    override func mouseDragged(with event: NSEvent) { if !unfocused, !pinnedDown { super.mouseDragged(with: event) } }
    override func mouseExited(with event: NSEvent) { if !unfocused { super.mouseExited(with: event) } }

    /// #1566 (spec 5.7): Command-K in the focused pane (the window's first responder: a key equivalent visits every
    /// view) is the owner's clear; every other key equivalent goes to libghostty as before.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self, let owner,
           event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command],
           AgentsNSWindow.chordLetter(event) == "k" {
            owner.commandK()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// #1568: a plain Esc while a card is up closes it (XrayGridMarksView.escape) and goes no further; with no card it
    /// goes on to libghostty and the pty as before.
    override func keyDown(with event: NSEvent) {
        XrayRecaps.shared.dismiss()   // #1625/#1630: any keystroke into the terminal ends the recap strip, an Esc that closes a card too
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, marks.escape() {
            return
        }
        passedKey?(event)
        super.keyDown(with: event)
    }

    /// Tests: each key handed on to libghostty (keyDown); nil in the product.
    var passedKey: ((NSEvent) -> Void)?

    // MARK: #1357 (P9): a Cmd-click on a ref on the grid

    /// The grid as libghostty last laid it out (terminalDidResize): a click's cell.
    var gridMetrics: TerminalGridMetrics?
    /// The viewport's text, one line per row (rows hand in their own).
    var viewportText: () -> String? = { nil }
    /// The card for the ref at a cell; rows record it.
    var openRef: @MainActor (NSWindow?, AgentSessionKey, String, Int) -> Bool = {
        XrayRefLink.openOnGrid($0 as? AgentsNSWindow, key: $1, line: $2, column: $3)
    }
    /// The padding the pane's config applies (window-padding-x and -y, points; padding balance off): the grid's top-left
    /// when the surface cannot say (no surface yet, and the marks' underlines).
    static let gridOrigin = CGPoint(x: AgentTerminalLook.paddingX, y: AgentTerminalLook.paddingY)
    /// Tests: the cell under a top-left point instead of the surface's; nil in the product (#1682).
    var cellAt: ((CGPoint) -> (col: Int, row: Int)?)?

    /// #1682: the cell under a top-left point as libghostty's surface maps it (its own padding, whatever the config
    /// said); nil before the surface has a first frame. viewportCell flips y itself (surface top-left from view y).
    func surfaceCell(at p: CGPoint) -> (col: Int, row: Int)? {
        guard p.x.isFinite, p.y.isFinite, bounds.height.isFinite,
              let c = viewportCell(at: NSPoint(x: p.x, y: bounds.height - p.y)) else { return nil }
        return (c.column, c.row)
    }

    /// The cell (column, row) under a top-left point, nil off the grid. Every value is checked before Int() (an event's).
    static func cell(at p: CGPoint, _ g: TerminalGridMetrics, scale: CGFloat,
                     origin: CGPoint = gridOrigin) -> (col: Int, row: Int)? {
        guard scale > 0, g.cellWidthPixels > 0, g.cellHeightPixels > 0 else { return nil }
        let x = (p.x - origin.x) / (CGFloat(g.cellWidthPixels) / scale)
        let y = (p.y - origin.y) / (CGFloat(g.cellHeightPixels) / scale)
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < CGFloat(g.columns), y < CGFloat(g.rows) else { return nil }
        return (Int(x), Int(y))
    }

    /// A Cmd-click on the focused pane: the ref under it opens its card. The click still goes on to libghostty and the
    /// program (operator 2026-11-10, spec X-T mutant 10: Prosper takes no click); an unfocused pane's down never gets here.
    /// #1701 (operator 2026-11-20: "when i use cmd, you know it is intentional, so clicking will keep the xray window
    /// open, instead of opening me a link"): a Cmd-down on a mark pins its card and goes no further, nor does its up or
    /// drag, so libghostty opens no link (it opens on the up) and the program gets no click. Elsewhere as before.
    /// #1724 (operator 2026-11-20): while the program reports the mouse (Claude Code) libghostty gives a Cmd click to the
    /// program and links only with Shift; a Cmd-down (no Shift) on a link Prosper sees (capturedLink) opens it here and
    /// goes no further, the same as a pin. Cmd+Shift and every other click go on as before.
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), !unfocused {
            let p = convert(event.locationInWindow, from: nil)
            let q = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
            if let k = marks.mark(at: q)?.key, marks.hover.click(k) {
                pinnedDown = true
                return
            }
            if !event.modifierFlags.contains(.shift), let link = capturedLink(at: q) {
                pinnedDown = true
                owner?.open(link.text)
                return
            }
            refClick(at: q)
        }
        passedClick?(event)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if pinnedDown { pinnedDown = false; return }
        passedClick?(event)
        super.mouseUp(with: event)
    }

    /// #1701: the down pinned a card (#1724: or opened a link); its up and drags stop here.
    private(set) var pinnedDown = false
    /// Tests: each left down and up handed on to libghostty; nil in the product.
    var passedClick: ((NSEvent) -> Void)?

    /// #1701: Command pressed or released over the focused pane (the first responder gets flagsChanged): the hover
    /// follows it. Then libghostty as before.
    override func flagsChanged(with event: NSEvent) {
        marks.command(event.modifierFlags.contains(.command))
        super.flagsChanged(with: event)
    }

    /// #1724: the program has mouse reporting on (libghostty's surface); rows hand in their own.
    lazy var mouseCaptured: @MainActor () -> Bool = { [weak self] in self?.surface?.isMouseCaptured ?? false }
    /// #1724: viewport reads for a link (counted by rows: one per cell the Command pointer enters, never one per move).
    private(set) var linkReads = 0

    /// #1724: the link-shaped token under a top-left point while the program reports the mouse; nil otherwise (no
    /// capture, the unfocused pane, no grid, or no link there), so libghostty's own links stay as they are. By shape only:
    /// a path is checked on disk only when clicked (open, off main). A remote session's path is never a link here.
    func capturedLink(at p: CGPoint) -> AgentTerminalFileLink.Token? {
        guard !unfocused, mouseCaptured(), let c = gridCell(at: p) else { return nil }
        linkReads += 1
        let lines = (viewportText() ?? "").components(separatedBy: "\n")
        guard c.row < lines.count, let t = AgentTerminalFileLink.token(atColumn: c.col, in: lines[c.row]) else { return nil }
        let web = ["http://", "https://", "mailto:"].contains { t.text.lowercased().hasPrefix($0) }
        return web || owner?.remoteHost == nil ? t : nil
    }

    /// The grid cell under a top-left point: the rows' seam, else libghostty's surface (#1682), else the config padding.
    func gridCell(at p: CGPoint) -> (col: Int, row: Int)? {
        guard let g = gridMetrics else { return nil }
        if let cellAt { return cellAt(p) }
        return surfaceCell(at: p) ?? Self.cell(at: p, g, scale: window?.backingScaleFactor ?? 2)
    }

    /// The ref under top-left point `p` of the session's grid opens its card (#1568: a remote row's too). False: gate B
    /// off, no grid yet, off the grid, or no ref there.
    @discardableResult
    func refClick(at p: CGPoint) -> Bool {
        guard XrayRefLink.decorate(), let owner, let key = owner.key, let c = gridCell(at: p) else { return false }
        let lines = (viewportText() ?? "").components(separatedBy: "\n")
        guard c.row < lines.count else { return false }
        return openRef(window, key, lines[c.row], c.col)
    }

    // MARK: #1492 (QA m1): a sidebar row dragged over the terminal

    /// The window model and pane this terminal is drawn in (AgentPaneArea's environment); nil outside a pane.
    weak var dropModel: AgentWindowModel?
    var dropPane: UUID?
    /// Tests: each drop handed on to libghostty's own drop (it pastes); nil in the product.
    var pastedDrop: ((any NSDraggingInfo) -> Void)?

    /// A row's drag over a terminal in a pane: the model, the pane and the point in the terminal's top-left space. Nil
    /// (any other drag, or no pane): libghostty's drop as before (files, links, text and images paste).
    private func rowDrop(_ s: any NSDraggingInfo) -> (AgentWindowModel, UUID, CGPoint)? {
        guard let m = dropModel, let pane = dropPane, s.draggingPasteboard.availableType(from: [.agentRow]) != nil
        else { return nil }
        let p = convert(s.draggingLocation, from: nil)
        return (m, pane, CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard case let (m, pane, p)? = rowDrop(sender) else { return super.draggingEntered(sender) }
        m.dropOver(pane, at: p, in: bounds.size)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard case let (m, pane, p)? = rowDrop(sender) else { return super.draggingUpdated(sender) }
        m.dropOver(pane, at: p, in: bounds.size)
        return .copy
    }

    /// Only this pane's indicator goes. No super: libghostty keeps no drag state and NSView need not implement it.
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if let dropPane { dropModel?.dropExit(dropPane) }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if case let (m, pane, p)? = rowDrop(sender) {
            let token = sender.draggingPasteboard.data(forType: .agentRow).map { String(decoding: $0, as: UTF8.self) }
            return m.drop(token ?? "", into: pane, at: p, in: bounds.size)
        }
        pastedDrop?(sender)
        return super.performDragOperation(sender)
    }

    // MARK: Pasteboard (⌘C/⌘V/⌘A arrive through the Edit menu)

    @IBAction override func copy(_ sender: Any?) {
        guard let text = surface?.readSelection(), !text.isEmpty else { return }
        let pb = pasteboard()
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Text goes in sanitized (bracketed when the program asked); an image with no text sends ^V,
    /// so a local Claude Code reads the Mac clipboard itself, as it does under Ghostty.
    /// QA #681 INFO-6 (decided: left as is): no multi-line paste confirm. Ghostty asks before a paste with a
    /// new line into a program without bracketed paste; Prosper's terminal hosts Claude Code and login
    /// shells, which set 2004, so `surface.paste(text:)` sends without libghostty's paste protection.
    @IBAction override func paste(_ sender: Any?) {
        let pb = pasteboard()
        if let text = pb.string(forType: .string) {
            let clean = AgentTerminalController.pasteText(text)
            if !clean.isEmpty { surface?.paste(text: clean) }
        } else if pb.canReadItem(withDataConformingToTypes: [UTType.image.identifier]) {
            owner?.input([0x16])
        }
    }

    // MARK: Delegates

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        self.surface = surface
        surfaceStarted()
    }

    /// #1656: a new surface starts focused (beta.31's never-focused split pane drew the solid cursor): off unless the rule
    /// holds. Window rows on fake clients get no surface, so they call this where the wrapper's attach would.
    func surfaceStarted() {
        if !libghosttyFocus(responder: window?.firstResponder === self) { unfocusSurface() }
    }
    func terminalDidDetachSurface() { surface = nil }

    /// The grid as laid out, on main right after the surface took its pixel size: the only size the pty
    /// gets. The in-memory session's own report (IO thread) trails it on every new surface (720x420 pt
    /// on 2x: 46x16, then 101x26 ~25 ms later); the client starts once that report reaches this grid.
    func terminalDidResize(_ size: TerminalGridMetrics) {
        gridMetrics = size
        marks.output(resized: true)   // #1559: new cells: the marks go and settle again
        owner?.gridChanged(cols: Int(size.columns), rows: Int(size.rows))
    }

    /// clipboard-write = ask routes every OSC 52 write here: it lands on the Pasteboard seam and the
    /// library is told no, so it never writes the system pasteboard itself. Reads are denied, and so is
    /// a paste-protection request (`.paste`; Prosper's own paste never asks, see paste(_:)).
    /// OQ-66: a write lands only while the controller says the session is being viewed.
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        confirmClipboard(request)
    }

    /// The answer to every clipboard request, behind a protocol so a test can hand in a recorder.
    func confirmClipboard(_ request: some AgentClipboardRequest) {
        if request.kind == .osc52Write, !request.contents.isEmpty, owner?.clipboardWriteAllowed() == true {
            let pb = pasteboard()
            pb.clearContents()
            pb.setString(request.contents, forType: .string)
        }
        request.respond(allow: false)
    }

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) { owner?.open(url) }

    func terminalDidStartSearch(needle: String?) {}
    func terminalDidEndSearch() {}
    func terminalDidUpdateSearchTotal(_ total: Int?) { owner?.searchTotal(total) }
    func terminalDidUpdateSearchSelected(_ selected: Int?) { owner?.searchSelected(selected) }

    // MARK: VoiceOver (parity row 26: the visible screen as the value)

    override func accessibilityValue() -> Any? { installed?.session.readViewportText() }
}

/// The ghostty app and its config: Prosper's background and text colours, libghostty's own palette
/// and font (what Ghostty draws), no key bindings inside libghostty but Ghostty's macOS text ones (the window owns Cmd
/// keys, the view's Edit-menu actions own Cmd-C/V/A), OSC 52 reads denied and writes asked (see the view).
@MainActor
enum AgentTerminalLook {
    static let controller: TerminalController = make()

    /// #1376: Ghostty's macOS default keybinds that only send text to the program (line kill, line start and end, word
    /// back and forward), kept after `keybind = clear`; its others (copy, paste, new window...) would bypass the window.
    static let textKeybinds = [
        "super+backspace=text:\\x15", "super+arrow_left=text:\\x01", "super+arrow_right=text:\\x05",
        "alt+arrow_left=esc:b", "alt+arrow_right=esc:f",
    ]

    /// A ghostty app on Prosper's config, its generated config file already gone (QA #681 INFO-10).
    /// #1456: `colours` nil reads the Settings choice (and the user's file); a row hands in its own.
    static func make(colours: [(key: String, value: String)]? = nil) -> TerminalController {
        let c = TerminalController(configuration: configuration, theme: theme())
        dropConfigFile(c)
        refresh(c, colours: colours)
        return c
    }

    /// #1456 (OQ-153): Settings' "Terminal colours": none for Prosper, else the colour lines kept from the user's own
    /// Ghostty config (GhosttyUserColours: colours only, checked). Read in the app at each make and refresh.
    /// QA r1418 m1: a `theme` is resolved here (user themes folder, then Ghostty.app's), never handed to libghostty;
    /// light:A,dark:B follows Prosper's own theme appearance, as the terminal does.
    static func userColours(choice: String = Preferences.agentTerminalColours,
                            files: @autoclosure () -> [URL] = GhosttyUserColours.files(
                                home: FileManager.default.homeDirectoryForCurrentUser,
                                xdgConfigHome: ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]),
                            themeDirs: @autoclosure () -> [URL] = GhosttyUserColours.themeDirs(
                                home: FileManager.default.homeDirectoryForCurrentUser,
                                xdgConfigHome: ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]),
                            appearance: @autoclosure () -> ThemeAppearance = ThemeStore.shared.appearance) -> [(key: String, value: String)] {
        choice == "ghostty" ? GhosttyUserColours.read(files(), themeDirs: themeDirs(), appearance: appearance()) : []
    }

    /// window-padding-x and -y in points: the fallback grid origin of a Cmd-click (#1682) and the marks' origin.
    static let paddingX = 4, paddingY = 2

    static var configuration: TerminalConfiguration { configuration(colours: []) }

    static func configuration(colours: [(key: String, value: String)]) -> TerminalConfiguration {
        TerminalConfiguration(startingFrom: .default) {
            // #1456: the user's colour lines first, so every Prosper line below comes later and wins.
            for c in colours { $0.withCustom(c.key, c.value) }
            $0.withCustom("keybind", "clear")
            for bind in textKeybinds { $0.withCustom("keybind", bind) }
            $0.withCustom("clipboard-read", "deny")
            $0.withCustom("clipboard-write", "ask")
            // QA #681 INFO-2: the default primary-paste reads the system pasteboard straight through
            // GhosttyTerminal (its selection clipboard is the general one), past the Pasteboard seam.
            $0.withCustom("middle-click-action", "ignore")
            $0.withCustom("copy-on-select", "false")
            $0.withCustom("macos-option-as-alt", "false")
            // Ghostty.app doubles precise (trackpad) deltas in its own view; the package passes them at 1x. Discrete wheels keep the default 3.
            $0.withCustom("mouse-scroll-multiplier", "precision:2")
            $0.withWindowPaddingX(paddingX)
            $0.withWindowPaddingY(paddingY)
        }
    }

    /// Prosper's palette follows its own theme, not the system appearance: both variants are the same.
    /// #1456: with the user's colour lines there is no theme, so Prosper's background and text never cover them.
    static func theme(colours: [(key: String, value: String)] = []) -> TerminalTheme {
        guard colours.isEmpty else { return TerminalTheme() }
        let colours = TerminalConfiguration {
            $0.withBackground(hex(Neon.bgBottom))
            $0.withForeground(hex(Neon.textPrimary))
        }
        return TerminalTheme(light: colours, dark: colours)
    }

    /// A theme switch (or a "Terminal colours" change) since the last attach: a reconfigure, no rebuild; each load's
    /// new config file is dropped before the next one is written.
    /// #1456: Prosper's own config stays the base; the user's colours ride on an overlay with Prosper's lines repeated after
    /// them. A line libghostty refuses rolls the whole overlay back (TerminalController: any diagnostic fails a load), and
    /// the theme then keeps Prosper's colours: never a config without Prosper's keys and clipboard rules.
    static func refresh(_ c: TerminalController, colours: [(key: String, value: String)]? = nil) {
        let colours = colours ?? userColours()
        let overlay = colours.isEmpty ? TerminalConfiguration() : configuration(colours: colours)
        if c.setTerminalConfiguration(overlay) { dropConfigFile(c) }
        if c.setTheme(theme(colours: c.terminalConfiguration == overlay ? colours : [])) { dropConfigFile(c) }
    }

    /// QA #681 INFO-10: GhosttyTerminal writes each config it loads to $TMPDIR/<bundle id>/ghostty-config-
    /// <uuid>.conf and removes it only when the controller goes, which the app's never does.
    /// ghostty_config_load_file has parsed it by now (TerminalController+Config.swift prepareConfig), and
    /// a later reconfigure writes a fresh one, so it goes at once. Only this controller's own file, found
    /// by its stored property: nil when a GhosttyTerminal bump renames it (the INFO-10 test then fails).
    @discardableResult
    static func dropConfigFile(_ c: TerminalController) -> URL? {
        let url = Mirror(reflecting: c).children.first { $0.label == "managedConfigURL" }?.value as? URL
        if let url { try? FileManager.default.removeItem(at: url) }
        return url
    }

    static func hex(_ c: Color) -> String {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
        let v = [n.redComponent, n.greenComponent, n.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02x%02x%02x", v[0], v[1], v[2])
    }
}

// MARK: - SwiftUI

struct AgentTerminalRepresentable: NSViewRepresentable {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let controller: AgentTerminalController
    let screen: AgentTerminalScreen?

    func makeNSView(context: Context) -> AgentTerminalHostView {
        let v = AgentTerminalHostView(frame: .zero)
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: AgentTerminalHostView, context: Context) {
        v.owner = controller
        controller.view = v
        v.dropModel = context.environment.agentPaneModel   // #1492
        v.dropPane = context.environment.agentPaneID
        v.show(screen as? AgentGhosttyScreen)
        v.retheme()   // #891: no rebuild on a theme change: the live surface re-themes here
    }
}

/// The Terminal mode's pane: the terminal to the window's bottom, with the state over it (never
/// beside or under it, so its frame changes only with the window or the mode).
struct AgentTerminalPane: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var controller: AgentTerminalController
    let open: () -> Void

    var body: some View {
        AgentTerminalRepresentable(controller: controller, screen: controller.screen)
            .background(Neon.bgBottom)
            .overlay { if !controller.revealed || controller.screen == nil { Neon.bgBottom.allowsHitTesting(false) } }
            .overlay { card }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: sz(6)) {
                    if controller.findOpen { AgentTerminalFindBar(controller: controller) }
                    if controller.sizedElsewhere {   // #896 (dch ask 1)
                        HStack(spacing: sz(6)) {
                            Text(AgentTerminalController.sizedElsewhereText).foregroundStyle(Neon.textSecondary)
                            Button("Fit here") { controller.fitHere() }.buttonStyle(.plain).foregroundStyle(Neon.blue)
                                .help("Resize the session to this pane")
                        }
                        .font(Neon.font(10.5, weight: .medium))
                        .padding(.horizontal, sz(8)).padding(.vertical, sz(3))
                        .background(Capsule().fill(Neon.card))
                    }
                    if let n = controller.notice {
                        Text(n).font(Neon.font(10.5, weight: .medium)).foregroundStyle(Neon.textSecondary)
                            .padding(.horizontal, sz(8)).padding(.vertical, sz(3))
                            .background(Capsule().fill(Neon.card))
                    }
                }
                .padding(sz(8))
            }
    }

    /// Why nothing is attached, with the way out. (A held row never gets here: it shows Transcript.)
    @ViewBuilder var card: some View {
        switch controller.phase {
        case .idle where controller.held != nil:
            AgentTerminalCard(icon: "desktopcomputer", text: AgentTerminalController.heldText) {
                AgentPillButton(title: "Attach", icon: "arrow.right.circle", tint: Neon.blue) { controller.attachHeld() }
            }
        case .idle, .attaching, .live:
            EmptyView()
        case .ended:
            AgentTerminalCard(icon: "stop.circle", text: "Session ended")
        case .detached(let why):
            AgentTerminalCard(icon: "rectangle.portrait.and.arrow.right", text: why) {
                // #902 (R6.11, 9.3): a remote exit 5 (taken by another device) is the one remote .detached: Take back
                AgentPillButton(title: controller.remoteHost != nil ? "Take back" : "Reattach", icon: "arrow.clockwise",
                                tint: Neon.blue) { controller.retry() }
            }
        case .failed(let why) where controller.remoteHost != nil:
            // #896: a lost link retries by itself a few times (the card says so); Reconnect is now. No Open in terminal:
            // there is no local session.
            AgentTerminalCard(icon: "exclamationmark.triangle.fill", text: controller.reconnecting ? why + ". Reconnecting…" : why) {
                AgentPillButton(title: "Reconnect", icon: "arrow.clockwise", tint: Neon.blue) { controller.retry() }
            }
        case .failed(let why):
            AgentTerminalCard(icon: "exclamationmark.triangle.fill", text: why) {
                AgentPillButton(title: "Retry", icon: "arrow.clockwise", tint: Neon.blue) { controller.retry() }
                OpenInTerminalButton(action: open, compact: true)
            }
        }
    }
}

struct AgentTerminalCard<Buttons: View>: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let icon: String
    let text: String
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: sz(10)) {
            Image(systemName: icon).font(Neon.font(20)).foregroundStyle(Neon.textSecondary)
            Text(text).font(Neon.font(12.5, weight: .medium)).foregroundStyle(Neon.textPrimary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: sz(8)) { buttons }
        }
        .padding(sz(18))
        .background(RoundedRectangle(cornerRadius: sz(10)).fill(Neon.card))
        .overlay(RoundedRectangle(cornerRadius: sz(10)).stroke(Neon.stroke, lineWidth: 1))
    }
}

extension AgentTerminalCard where Buttons == EmptyView {
    init(icon: String, text: String) { self.init(icon: icon, text: text) { EmptyView() } }
}

/// ⌘F: the needle, the match count, previous / next (⇧⌘G / ⌘G, Return) and close (Esc).
struct AgentTerminalFindBar: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var controller: AgentTerminalController

    var count: String {
        guard !controller.findText.isEmpty, let total = controller.findTotal else { return " " }
        guard total > 0 else { return "No matches" }
        return controller.findSelected.map { "\($0 + 1) of \(total)" } ?? "\(total)"
    }

    var body: some View {
        HStack(spacing: sz(6)) {
            Image(systemName: "magnifyingglass").font(Neon.font(10.5)).foregroundStyle(Neon.textSecondary)
            // #1450: our own field (a SwiftUI TextField could keep the last UI scale's height).
            ScaledTextField(placeholder: "Find", text: $controller.findText, onSubmit: { controller.findNext() },
                            fontSize: 11.5, plain: true, focusOnAppear: true, onCancel: { controller.closeFind() })
                .frame(width: sz(160))
                .accessibilityLabel("Find")
                .onChange(of: controller.findText) { _, t in controller.search(t) }
            ZStack(alignment: .trailing) {   // the widest count's slot, so a count never moves the buttons
                Text("No matches").hidden()
                Text(count).foregroundStyle(Neon.textSecondary)
            }
            .font(Neon.font(10.5).monospacedDigit()).fixedSize()
            Button { controller.findNext(false) } label: { Image(systemName: "chevron.up") }
                .help("Previous (⇧⌘G)").accessibilityLabel("Previous match")   // QA #681 INFO-7: not "Go Up"
            Button { controller.findNext() } label: { Image(systemName: "chevron.down") }
                .help("Next (⌘G)").accessibilityLabel("Next match")
            Button { controller.closeFind() } label: { Image(systemName: "xmark") }
                .help("Close (Esc)").accessibilityLabel("Close find")
        }
        .buttonStyle(.plain).font(Neon.font(10.5, weight: .semibold)).foregroundStyle(Neon.textPrimary)
        .padding(.horizontal, sz(8)).padding(.vertical, sz(5))
        .background(RoundedRectangle(cornerRadius: sz(7)).fill(Neon.card))
        .overlay(RoundedRectangle(cornerRadius: sz(7)).stroke(Neon.stroke, lineWidth: 1))
    }
}

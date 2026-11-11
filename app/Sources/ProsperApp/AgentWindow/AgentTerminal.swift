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
    private(set) var generation = 0
    private var resizeGeneration = 0
    private var backlogged = false
    /// The view is in a live resize: the size goes out once, at its end.
    var liveResizing = false
    /// The dch client re-sends its size on focus-in itself (DEC 1004, dch >= 1.39.0); older clients
    /// need the rows-1 jiggle. Off until the client's version is known.
    private(set) var focusJiggle = false
    weak var view: AgentTerminalHostView?

    static let resizeDebounce: TimeInterval = 0.15
    static let revealAfter: TimeInterval = 0.3
    /// The longest the client waits for the screen to report the view's grid; then it starts anyway.
    static let screenWait: TimeInterval = 0.5
    static let noticeFor: TimeInterval = 2
    static let focusResizeDch = [1, 39, 0]

    // Seams.
    var spawn: (AgentTerminalSpawn, AgentTerminalIO) throws -> AgentTerminalChild = AgentTerminalController.realSpawn
    var makeScreen: (AgentTerminalScreenEvents) -> AgentTerminalScreen = { AgentGhosttyScreen($0) }
    var request: (AgentSessionKey, Int, Int) -> AgentTerminalSpawn = { AgentTerminalSpawn.local($0, cols: $1, rows: $2) }
    /// The store still lists the session (an exit 0 then means it was detached, not ended).
    var isLive: (AgentSessionKey) -> Bool = { _ in false }
    var after: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
    }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The client binary's version, probed off main (cached per path and mtime).
    var clientVersion: @Sendable (String) -> [Int]? = { DchCommand.probedVersion($0) }

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
        guard key != self.key else { return }
        focusPending = false   // #845: a focus asked for on another session never lands on this one
        detach()
        self.key = key
        reattached = false
        closeFind(refocus: false)   // QA #694 INFO-1: the find bar goes with the session, the keys stay put
        guard key != nil else { phase = .idle; return }
        begin()
    }

    /// Retry or Reattach from the overlay.
    func retry() {
        guard key != nil, child == nil else { return }
        reattached = false
        begin()
    }

    /// A fresh screen; the client starts once it parses at the view's grid (see gridChanged).
    private func begin() {
        generation += 1
        let gen = generation
        backlogged = false
        sentSize = nil
        screenGrid = nil
        screenWaitOver = false
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
        if grid != nil { start() }
    }

    private func start() {
        guard let key, let grid, child == nil, phase == .attaching,
              screenWaitOver || screenGrid.map({ $0 == grid }) == true else { return }
        let box = AgentTerminalInbox()
        inbox = box
        let req = request(key, grid.cols, grid.rows)
        do {
            let c = try spawn(req, Self.io(box, owner: self))
            child = c
            writer.child = c
            sentSize = grid
            phase = .live
            c.run()
            if focusPending { focus() }   // #845: a click while it attached lands now
            let probe = clientVersion, path = req.exe, gen = generation
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let v = probe(path)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == gen else { return }
                        self.focusJiggle = v.map { !DchCommand.isAtLeast($0, Self.focusResizeDch) } ?? false
                    }
                }
            }
        } catch {
            inbox = nil
            box.close()
            phase = .failed("Couldn't open the terminal: \(error)")
        }
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
        revealed = true
    }

    private func backlogChanged(_ on: Bool, generation gen: Int) {
        guard gen == generation else { return }
        backlogged = on
        if !on, let inbox { drain(inbox) }
    }

    /// The view's grid (cols x rows, `gen` nil) or the screen's report of the grid its parser now runs
    /// at (`gen`). The client starts once the two agree, or `screenWait` after the screen began.
    /// #844: dch adopts the spawn size at attach and replays its screen drawn for it (dch
    /// attach.c:719-729, master.c:3358-3367); parsed at the new surface's creation grid (46x16 for
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
        let live = isLive(key)
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

    private func show(_ text: String) {
        notice = text
        after(Self.noticeFor) { [weak self] in if self?.notice == text { self?.notice = nil } }
    }

    /// Hidden, deselected, switched to Transcript, closed: the client goes (SIGHUP, then SIGKILL).
    func detach() {
        generation += 1
        inbox?.close()
        inbox = nil
        child?.terminate()
        child = nil
        writer.child = nil
        screen = nil
        sentSize = nil
        if phase != .idle { phase = .idle }
    }

    // MARK: Links and find

    /// ⌘-click on a URL or an OSC 8 link: web and mail links only, never a file or an app.
    func open(_ link: String) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return }
        openURL(url)
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
    TerminalSurfaceGridResizeDelegate {
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
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `screen` (a new attach rebuilds the surface: a fresh grid). Waits for a window, so a view
    /// rendered without one (an offscreen hosting view) never starts libghostty.
    func show(_ screen: AgentGhosttyScreen?) {
        wanted = screen
        guard window != nil, let screen, screen !== installed else { return }
        AgentTerminalLook.refresh(look())
        installed = screen
        // The backend first: a controller set while the options still name `.exec` (the default)
        // would build a surface that runs a login shell.
        configuration = TerminalSurfaceOptions(backend: .inMemory(screen.session),
                                               fontSize: Float(12 * ThemeRuntime.scale), context: .window)
        if controller !== look() { controller = look() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        show(wanted)
        if owner?.focusPending == true { owner?.focus() }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, window?.isKeyWindow == true { owner?.focusIn() }
        return ok
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        owner?.liveResizeStarted()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        owner?.liveResizeEnded()
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

    func terminalDidAttachSurface(_ surface: TerminalSurface) { self.surface = surface }
    func terminalDidDetachSurface() { surface = nil }

    /// The grid as laid out, on main right after the surface took its pixel size: the only size the pty
    /// gets. The in-memory session's own report (IO thread) trails it on every new surface (720x420 pt
    /// on 2x: 46x16, then 101x26 ~25 ms later); the client starts once that report reaches this grid.
    func terminalDidResize(_ size: TerminalGridMetrics) {
        owner?.gridChanged(cols: Int(size.columns), rows: Int(size.rows))
    }

    /// clipboard-write = ask routes every OSC 52 write here: it lands on the Pasteboard seam and the
    /// library is told no, so it never writes the system pasteboard itself. Reads are denied.
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        confirmClipboard(request)
    }

    /// The answer to every clipboard request, behind a protocol so a test can hand in a recorder.
    func confirmClipboard(_ request: some AgentClipboardRequest) {
        if request.kind == .osc52Write, !request.contents.isEmpty {
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
/// and font (what Ghostty draws), no key bindings inside libghostty (the window owns ⌘ keys, the
/// view's Edit-menu actions own ⌘C/⌘V/⌘A), OSC 52 reads denied and writes asked (see the view).
@MainActor
enum AgentTerminalLook {
    static let controller: TerminalController = TerminalController(configuration: configuration, theme: theme())

    static var configuration: TerminalConfiguration {
        TerminalConfiguration(startingFrom: .default) {
            $0.withCustom("keybind", "clear")
            $0.withCustom("clipboard-read", "deny")
            $0.withCustom("clipboard-write", "ask")
            $0.withCustom("copy-on-select", "false")
            $0.withCustom("macos-option-as-alt", "false")
            $0.withWindowPaddingX(4)
            $0.withWindowPaddingY(2)
        }
    }

    /// Prosper's palette follows its own theme, not the system appearance: both variants are the same.
    static func theme() -> TerminalTheme {
        let colours = TerminalConfiguration {
            $0.withBackground(hex(Neon.bgBottom))
            $0.withForeground(hex(Neon.textPrimary))
        }
        return TerminalTheme(light: colours, dark: colours)
    }

    /// A theme switch since the last attach: one reconfigure, no rebuild.
    static func refresh(_ c: TerminalController) { c.setTheme(theme()) }

    static func hex(_ c: Color) -> String {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
        let v = [n.redComponent, n.greenComponent, n.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02x%02x%02x", v[0], v[1], v[2])
    }
}

// MARK: - SwiftUI

struct AgentTerminalRepresentable: NSViewRepresentable {
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
        v.show(screen as? AgentGhosttyScreen)
    }
}

/// The Terminal mode's pane: the terminal to the window's bottom, with the state over it (never
/// beside or under it, so its frame changes only with the window or the mode).
struct AgentTerminalPane: View {
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
        case .idle, .attaching, .live:
            EmptyView()
        case .ended:
            AgentTerminalCard(icon: "stop.circle", text: "Session ended")
        case .detached(let why):
            AgentTerminalCard(icon: "rectangle.portrait.and.arrow.right", text: why) {
                AgentPillButton(title: "Reattach", icon: "arrow.clockwise", tint: Neon.blue) { controller.retry() }
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
    @ObservedObject var controller: AgentTerminalController
    @FocusState private var focused: Bool

    var count: String {
        guard !controller.findText.isEmpty, let total = controller.findTotal else { return " " }
        guard total > 0 else { return "No matches" }
        return controller.findSelected.map { "\($0 + 1) of \(total)" } ?? "\(total)"
    }

    var body: some View {
        HStack(spacing: sz(6)) {
            Image(systemName: "magnifyingglass").font(Neon.font(10.5)).foregroundStyle(Neon.textSecondary)
            TextField("Find", text: $controller.findText)
                .textFieldStyle(.plain).font(Neon.font(11.5)).frame(width: sz(160))
                .focused($focused)
                .onSubmit { controller.findNext() }
                .onExitCommand { controller.closeFind() }
                .onChange(of: controller.findText) { _, t in controller.search(t) }
            ZStack(alignment: .trailing) {   // the widest count's slot, so a count never moves the buttons
                Text("No matches").hidden()
                Text(count).foregroundStyle(Neon.textSecondary)
            }
            .font(Neon.font(10.5).monospacedDigit()).fixedSize()
            Button { controller.findNext(false) } label: { Image(systemName: "chevron.up") }
                .help("Previous (⇧⌘G)")
            Button { controller.findNext() } label: { Image(systemName: "chevron.down") }
                .help("Next (⌘G)")
            Button { controller.closeFind() } label: { Image(systemName: "xmark") }
                .help("Close (Esc)")
        }
        .buttonStyle(.plain).font(Neon.font(10.5, weight: .semibold)).foregroundStyle(Neon.textPrimary)
        .padding(.horizontal, sz(8)).padding(.vertical, sz(5))
        .background(RoundedRectangle(cornerRadius: sz(7)).fill(Neon.card))
        .overlay(RoundedRectangle(cornerRadius: sz(7)).stroke(Neon.stroke, lineWidth: 1))
        .onAppear { focused = true }
    }
}

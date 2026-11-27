import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// #797 Agent window D1: the "Agent Sessions" window. A sidebar of every dch session (fed by
// Agent Island's store, no new fork or poll) and the selected session's read-only
// conversation (spike A). Built on open and torn down on close, like
// MarketplaceWindow: a closed window leaves no view, model, timer or watch behind.
// #1784 (operator 2026-11-20, supersedes that for this window): a close hides it for `hideGrace`, stopped as an
// occluded window is; a show inside the grace presents it as it was; then the teardown above runs.

@MainActor
final class AgentsWindow {
    static let shared = AgentsWindow()

    private(set) var window: NSWindow?
    private(set) var model: AgentWindowModel?
    /// #831 B1 step 2 (4.1a, R899-3): the panes' last live sights, kept for the process: they outlive a window close.
    let lastLive = AgentLastLiveHome()
    private var observers: [NSObjectProtocol] = []
    /// #1784: how long a closed window is kept hidden before its teardown (the one place to change it).
    static let hideGrace: TimeInterval = 1800   // operator 2026-11-20: 30 minutes (3.4 MiB, zero CPU hidden)
    /// #1784: the one timer while the window is hidden; nil while shown and after the teardown. Rows fire it.
    private(set) var grace: Timer?
    /// Open for the person: shown (a hidden kept window is closed to them).
    var isOpen: Bool { window != nil && grace == nil }
    static let title = "Agent Sessions"
    static let themedIdentifier = NSUserInterfaceItemIdentifier("prosper.agentsWindow")
    /// #1925 (operator 2026-11-24, "just a smidge"): as narrow as the sidebar column and its 1 pt line (none in Slide,
    /// hidden or without a store) plus the panes' `AgentSidebarWidth.strip`, at `scale`. Full's column is its least width
    /// whatever the drag: at this window width the 40% line draws it so (AgentSidebarWidth.width). The height is as before.
    /// #1932: never under `floor`, the content width its title buttons need (`titleFloor`).
    static func contentMinSize(_ model: AgentWindowModel?, scale: CGFloat, floor: CGFloat = 0) -> NSSize {
        var column: CGFloat = 0
        if let model, model.hasStore, model.sidebarShown, model.sidebarMode != .slide {
            column = (model.sidebarMode == .mini ? AgentWindowModel.miniSidebarWidth(at: scale)
                                                 : AgentWindowModel.fullSidebarWidth(at: scale)) + 1
        }
        return NSSize(width: max(column + AgentSidebarWidth.strip * scale, floor), height: 420 * scale)
    }

    /// #1932: the content width at which the window's own title buttons fit, for its current style mask (Standard and No
    /// title bar are titled; Borderless has none): AppKit's least frame width converted to content width.
    static func titleFloor(_ win: NSWindow) -> CGFloat {
        guard win.styleMask.contains(.titled) else { return 0 }   // AppKit answers 90 for a borderless mask: no buttons there
        let frameWidth = NSWindow.minFrameWidth(withTitle: "", styleMask: win.styleMask)
        return win.contentRect(forFrameRect: NSRect(x: 0, y: 0, width: frameWidth, height: 100)).width
    }

    /// #1932: the minimum for `win` as it is now: its model's column at `scale`, floored at its title buttons' width.
    static func minimum(for win: AgentsNSWindow, scale: CGFloat) -> NSSize {
        contentMinSize(win.model, scale: scale, floor: titleFloor(win))
    }

    /// #1925: the open window's minimum re-read (a mode switch, the sidebar hidden or shown, a store); a window now under
    /// it grows to it.
    static func applyMinSize(_ win: AgentsNSWindow, scale: CGFloat = ThemeRuntime.scale) {
        win.minimum = minimum(for: win, scale: scale)
        win.clampToContentMinSize()
    }

    // Seams (QA #626 INFO-7: show and teardown run in tests with a window never put on screen).
    var island: () -> AgentIslandController = { .shared }
    var build: (AgentWindowModel) -> NSWindow = { AgentsWindow.makeWindow($0) }
    /// #1821: registers before ordering front, and re-asserts a refused activation (DockPolicy.present).
    var present: (NSWindow) -> Void = { DockPolicy.present($0) }
    /// #1846 n133: an agent's show (ControlSessions.showWindow): never activates an inactive Prosper.
    var presentQuietly: (NSWindow) -> Void = { DockPolicy.presentQuietly($0) }
    var dismissed: (NSWindow) -> Void = { DockPolicy.windowDidHide($0) }

    /// `quietly`: an agent's show (#1846 n133), through `presentQuietly`; else the person's, through `present`.
    func show(quietly: Bool = false) {
        let present = quietly ? presentQuietly : self.present
        if let window {
            grace?.invalidate()   // #1784: the kept window comes back as it was, no rebuild
            grace = nil
            present(window)
            model?.setVisible(window.occlusionState.contains(.visible))
            return
        }
        let island = island()
        let model = AgentWindowModel(lastLive: lastLive, layouts: Preferences.defaults)
        model.interaction.controller = island
        model.bind(island.store)
        island.onStoreChanged = { [weak model, weak island] in model?.bind(island?.store) }
        island.onHoldChanged = { [weak model] in model?.interaction.holdChanged() }
        let win = build(model)
        window = win
        XrayPanels.warm()   // #1351: the gate's dch probe, off main (none under XCTest)
        self.model = model

        let nc = NotificationCenter.default
        observers = [
            // #1847: weak: a block NotificationCenter holds must not keep the window (an owner gone without a teardown)
            nc.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self, weak win] _ in
                MainActor.assumeIsolated { if let win { self?.hide(win) } }
            },
            // Miniaturized, behind other windows fully, on another Space, the app hidden:
            // the transcript stops and the age clock with it (design "Energy").
            nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: win, queue: .main) { [weak model, weak win] _ in
                MainActor.assumeIsolated { if let win { model?.setVisible(win.occlusionState.contains(.visible)) } }
            },
        ]
        present(win)
        model.setVisible(win.occlusionState.contains(.visible))
    }

    /// #797: the status menu's "Agent Sessions…" item; its action opens `shared`. #805 (QA #629 R2):
    /// built here, not by MenuBarController, so a test checks the wiring with no status item.
    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Agent Sessions\u{2026}", action: #selector(MenuTarget.open(_:)), keyEquivalent: "")
        item.target = MenuTarget.shared
        return item
    }

    /// #858: the "Open Agent Sessions" hotkey opens `shared` through the same `show` as the island
    /// button and the menu item. A no-op while the island has no store (extension on but not live),
    /// the state that hides the menu item; a disabled extension leaves the hotkey unregistered.
    /// #1102: it follows WindowToggle's rule; a focused window closes through `close()`, the close
    /// button's teardown. The store guard holds for building only: an open window has its model.
    static func toggleFromShortcut() {
        guard shared.isOpen || shared.island().store != nil else { return }
        WindowToggle.apply(shared.window, open: { shared.show() }, focus: { shared.show() }, close: { shared.window?.close() })
    }

    /// The item's target: NSMenuItem holds it weakly, so one lives for the app.
    @MainActor
    private final class MenuTarget: NSObject {
        static let shared = MenuTarget()
        @objc func open(_ sender: Any?) { AgentsWindow.shared.show() }
    }

    /// The window, built but not shown (tests render it offscreen from here; #860: they pass a nil
    /// `autosave`, so no frame is read from or written to the defaults).
    static func makeWindow(_ model: AgentWindowModel, autosave: String? = "ProsperAgentsWindow") -> AgentsNSWindow {
        let hosting = NSHostingController(rootView: Themed(keepsViews: true) { AgentWindowRootView(model: model) })   // #891: in place
        // #1378: no title bar safe area for SwiftUI. Under No title bar's .fullSizeContentView it would pad the content
        // by the hidden bar, and a list touching that band grows under the title row (Standard has no such band).
        hosting.safeAreaRegions = []
        // #1925: by default the hosting controller writes SwiftUI's own minimum (the panes' is 0) over contentMinSize on
        // each layout, so the window's edge could hide the panes; the minimum is set here alone.
        hosting.sizingOptions = []
        let win = AgentsNSWindow(contentViewController: hosting)
        win.model = model
        model.sidebarColumnChanged = { [weak win] in if let win { AgentsWindow.applyMinSize(win) } }
        // 4.2 Pick Another: the sidebar gets the keys (called on the main actor, from a button's action).
        model.focusSidebar = { [weak win] in   // the model set keyFocus = .sidebar already
            win?.makeFirstResponder(nil)
        }
        win.title = title
        // The theme hook (AppDelegate.applyThemedWindowSizing) finds the open window by it.
        win.identifier = themedIdentifier
        let s = ThemeRuntime.scale
        win.setContentSize(NSSize(width: 1000 * s, height: 680 * s))
        applyStyle(win)   // #2045: every style, Standard too, is built by the live switch's own path
        win.isReleasedWhenClosed = false
        if let autosave { win.setFrameAutosaveName(autosave) }
        if !(autosave.map { win.setFrameUsingName($0) } ?? false) { win.centerOnScreen() }
        win.clampToContentMinSize()
        return win
    }

    /// #1378: Settings changed the style or the corners: the open window is restyled in place (a reopen would tear down
    /// the model, the panes' terminals and their last live sights). No window: nothing, the next build reads the settings.
    func restyle() { (window as? AgentsNSWindow).map { Self.applyStyle($0) } }

    /// #1379: Settings' sidebar mode: saved, and the open window's sidebar redrawn at once (no window: the next build reads it).
    func setSidebarMode(_ m: AgentSidebarMode) {
        Preferences.agentSidebarMode = m
        model?.setSidebarMode(m)
    }

    /// #1378: the window's chrome for `style`. Standard: #860's mask and buttons. No title bar: the full-size content
    /// under a hidden title bar, the three buttons hidden. Borderless: no frame; `rounded` masks the content's corners
    /// (the window clear outside them), off leaves it square and opaque to its edges (AgentsNSWindow's fill setters).
    /// Titled styles keep the system's rounded frame: AppKit has no public way to square it.
    static func applyStyle(_ win: AgentsNSWindow, style: AgentWindowStyle = Preferences.agentWindowStyle,
                           rounded: Bool = Preferences.agentWindowRoundedCorners) {
        win.style = style
        win.roundedCorners = rounded
        switch style {
        case .standard: win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        case .noTitleBar: win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        case .borderless: win.styleMask = [.borderless, .resizable, .miniaturizable]
        }
        // #860: Settings' chrome. The title hides (the sidebar's "Agent Sessions" header names the
        // window, and the Window menu still lists `title`); the strip is painted by applyWindowOpacity.
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        // #2045: a live mask change keeps the window's frame but can leave the content view where the old mask put it
        // (the whole frame under Borderless or No title bar), under the new title bar and its buttons: it is set to the
        // new mask's content rect. The frame stays, so the content gives up the bar's height (the window keeps its place).
        if let cv = win.contentView, let frameView = cv.superview {
            let r = win.contentRect(forFrameRect: win.frame).offsetBy(dx: -win.frame.minX, dy: -win.frame.minY)
            cv.frame = frameView.convert(r, from: nil)
        }
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            win.standardWindowButton(b)?.isHidden = style != .standard
        }
        win.hasShadow = true
        if let cv = win.contentView {
            let mask = style == .borderless && rounded
            cv.wantsLayer = true
            cv.layer?.cornerRadius = mask ? cornerRadius : 0
            cv.layer?.masksToBounds = mask
        }
        SettingsWindow.applyWindowOpacity(win)   // the fill through AgentsNSWindow's setters, then the shadow again
        applyMinSize(win)   // #1932: the new mask's title buttons need another width
    }

    /// #1378: the rounded Borderless window's corner radius, near the system's for a window without a toolbar.
    static let cornerRadius: CGFloat = 12

    /// #1784: the close keeps the window hidden: the model stops as for an occluded window (no transcript, terminal,
    /// clock or sidebar rebuild), the Dock lets go of it, and one coalescable timer ends the grace with the teardown.
    /// Already hidden (a second willClose): nothing, still one timer.
    private func hide(_ win: NSWindow) {
        guard grace == nil else { return }
        model?.setVisible(false)
        dismissed(win)
        let t = Timer(timeInterval: Self.hideGrace, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if let self, let w = self.window { self.teardown(w) } }
        }
        t.tolerance = Self.hideGrace / 10
        RunLoop.main.add(t, forMode: .common)
        grace = t
    }

    private func teardown(_ win: NSWindow) {
        grace?.invalidate()
        grace = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        model?.close()
        model = nil
        window = nil
        XrayPanels.shared.open = [:]   // #1351: no panel outlives its window
        let island = island()
        island.onStoreChanged = nil
        island.onHoldChanged = nil
        DispatchQueue.main.async { [weak win] in win?.contentViewController = nil }   // #1847: never keeps a torn-down window to the next main turn
    }
}

/// ⌘W closes; up/down move the selection while the sidebar has the focus (QA #626 INFO-2): the
/// last click landed in it and Tab has not moved on since. A text field or the input box keeps every key.
/// #822: so does the terminal, except the window's own shortcuts (`route`).
/// #845: a row click, Return and Right (on an unfolded section) move the keyboard into the session.
final class AgentsNSWindow: NSWindow {
    weak var model: AgentWindowModel?
    /// #1937: the Return (36), keypad Enter (76) or Escape (53) that answered the card and is still down: its auto-repeats are taken
    /// (they would go into the terminal and submit its prompt) until its keyUp, a resign key, or the end of the window.
    var heldConfirmKey: UInt16?
    /// #1925: the window's minimum content size, AgentsWindow's alone. On its update pass the hosting controller writes
    /// contentMinSize (SwiftUI's own minimum by default, zero with no sizing options; probed offscreen), so any other
    /// write puts this back.
    var minimum = NSSize.zero { didSet { super.contentMinSize = minimum } }
    override var contentMinSize: NSSize {
        get { super.contentMinSize }
        set { super.contentMinSize = minimum }
    }
    /// #1378: set by AgentsWindow.applyStyle; Standard and rounded until then.
    var style = AgentWindowStyle.standard
    var roundedCorners = true
    /// #1378: a borderless NSWindow answers false to both; every style here takes the keys and the main role.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// #1378: Borderless owns the window's fill, whatever the theme hook (applyWindowOpacity) asks: rounded, clear outside
    /// the content's rounded mask; square, opaque to the edges in the theme's colour (no wallpaper at a corner of a window
    /// sized to the screen). The titled styles take the theme's values as before.
    override var isOpaque: Bool {
        get { super.isOpaque }
        set { super.isOpaque = style == .borderless ? !roundedCorners : newValue }
    }
    override var backgroundColor: NSColor! {
        get { super.backgroundColor }
        set {
            guard style == .borderless else { return super.backgroundColor = newValue }
            super.backgroundColor = roundedCorners ? .clear : (newValue ?? NSColor(Neon.bgTop)).withAlphaComponent(1)
        }
    }
    /// #1378: No title bar and Borderless have no close button to press, so Command-W closes straight (no delegate here).
    override func performClose(_ sender: Any?) {
        style == .standard ? super.performClose(sender) : close()
    }
    /// #1378: Command-M minimises in No title bar and Borderless (#1726: the Window menu shows no Command-M; Standard keeps today's keys). Rows put
    /// a recorder here: the default is never run by a row.
    var minimize: (NSWindow) -> Void = { $0.miniaturize(nil) }
    static func isMinimizeChord(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command]
            && chordLetter(event) == "m"
    }
    /// #831 7.2: the model's `keyFocus` (B1 step 5); the name stays for the routes and their rows. No model: the sidebar.
    var sidebarFocused: Bool {
        get { model.map { $0.keyFocus == .sidebar && $0.sidebarShown } ?? true }   // #1383: a hidden Slide sidebar holds no keys, whatever keyFocus was left at
        set { model?.keyFocus = newValue ? .sidebar : .pane }
    }
    /// 7.6: the focusing click's down, drags and up are swallowed together.
    private(set) var focusClick = FocusClick()
    /// R6.9 (tests): every first-responder change asked of this window, AppKit's own included.
    private(set) var responderAsks = 0
    /// #900 B2 step 6b2b (R1196-1): what super.sendEvent does for a mouse-down in a window that is not key (key and
    /// front), asked for the focusing down that never reaches it. Runs on the main actor, inside sendEvent. Rows put a
    /// recorder here first: the default is never run by a row.
    var raise: (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }

    /// R900-5a-1: the window stops being key while a divider drag is under way (its up may never come): the drag ends,
    /// saved once. No drag (always with the gate off): nothing.
    override func resignKey() {
        super.resignKey(); Self.resignedKey(model)
        heldConfirmKey = nil   // #1937: its keyUp goes to whoever is key then
        let main = AgentGoMenu.mainMenu()
        for m in menus { m.remove(from: main) }
    }
    /// #1359: the Go menu after Edit while this window is key (resignKey above takes it out). #1726: Session, View and
    /// Layout with it, installed in this order so each finds the ones it goes after.
    override func becomeKey() {
        super.becomeKey()
        let main = AgentGoMenu.mainMenu()
        for m in menus { m.install(in: main) }
    }
    private(set) lazy var goMenu = AgentGoMenu(window: self)
    private(set) lazy var menus = [AgentGoMenu(window: self, kind: .session), AgentGoMenu(window: self, kind: .view), goMenu,
                                   AgentGoMenu(window: self, kind: .layout)]
    /// #1359 (tests): the last action `perform` ran, the key's or a Go menu item's.
    private(set) var lastPerformed: AgentGoMenu.Action?
    @MainActor static func resignedKey(_ m: AgentWindowModel?) { m?.dragEnded(); m?.dropPendingResume() }   // #1924: moved on

    @discardableResult override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        responderAsks += 1
        return super.makeFirstResponder(responder)
    }

    /// 7.6, pure: the pane a mouse-down at `p` (the pane area's coordinates, outside data) only focuses: one whose frame
    /// holds `p` and that is not `focused`. nil: the click passes (on the focused pane, outside every frame, a point
    /// that is not finite). With one pane every click passes. Frames tile half-open, so a shared edge is one pane's.
    static func firstClick(at p: CGPoint, frames: [UUID: CGRect], focused: UUID) -> UUID? {
        guard p.x.isFinite, p.y.isFinite else { return nil }
        return frames.first { $0.key != focused && $0.value.contains(p) }?.key
    }

    /// #1707 (OQ-170 b), pure: `p` (the pane area's coordinates) lies in the one-line header at the top of `frame`
    /// (AgentCompactHeader.height; the 1 pt line under it is the body's). nil frame: false.
    static func inHeader(_ p: CGPoint, _ frame: CGRect?) -> Bool {
        guard let f = frame else { return false }
        return f.contains(p) && p.y < f.minY + AgentCompactHeader.height
    }

    /// #900 B2 step 6b2b (R1196-1), pure: the focusing down (swallowed, so super.sendEvent never sees it) asks for key and
    /// front only while the window is not key; `isKey` is the window's isKeyWindow (rows pass a built value).
    static func asksKey(focusing: Bool, isKey: Bool) -> Bool { focusing && !isKey }

    /// #900 B2 step 3 (7.4): a left mouse-down at `p` in the content of `size` (top-left origin; outside data): the
    /// model's rule, the zoom included (step 4b, N900-f: AgentWindowModel.mouseDown, after its finiteness guard).
    /// True: the down only focused a pane (swallowed).
    @MainActor static func mouseDown(_ m: AgentWindowModel, at p: CGPoint, in size: CGSize) -> Bool {
        m.mouseDown(at: p, in: size)
    }

    /// #900 B2 step 5a (7.5): a left mouse event at `p` in the content of `size` (top-left origin; outside data, refused
    /// before any use when not finite) for the dividers. A down in a divider's hit area begins its drag (a double-click
    /// equalizes that split first); the drags and the up of that drag are the model's. True: the divider took it, so it
    /// is neither taken by the first-click rule nor passed to a pane. The window calls it with the split gate on only.
    @MainActor static func divider(_ event: NSEvent, _ m: AgentWindowModel, at p: CGPoint, in size: CGSize) -> Bool {
        // R900-5a-1: a key ends a drag whose up was lost; the key itself goes on. First: it needs no area and no point.
        if event.type == .keyDown { m.dragEnded(); return false }
        let finite = p.x.isFinite && p.y.isFinite && size.width.isFinite && size.height.isFinite
        let a = finite ? m.paneAreaFrame(in: size) : nil
        let local = a.map { CGPoint(x: p.x - $0.minX, y: p.y - $0.minY) }
        switch event.type {
        case .leftMouseDown:
            m.dividerHeld = false
            guard let a, let local else { return false }
            m.dividerHeld = m.dragBegan(at: local, in: a.size, clicks: event.clickCount)
            if let d = m.dividerDrag { AgentPaneArea.cursor(d.divider.axis).set() }   // R900-5a-2: held for the drag
            return m.dividerHeld
        case .leftMouseDragged, .leftMouseUp:
            // R900-5a-1: the button stays the divider's after its drag was ended by something else (a no-op move then).
            guard m.dividerHeld else { return false }
            if event.type == .leftMouseUp { m.dragEnded(); m.dividerHeld = false } else if let local { m.dragMoved(to: local) }
            return true
        default:
            return false
        }
    }

    /// 7.6: a small state machine per button (left, right, other; R1477b-m1). A mouse-down that only focused a pane is
    /// swallowed, and so are that button's drags and its up; any other down starts a click that passes. Every other event
    /// type passes.
    struct FocusClick: Equatable {
        /// The buttons (0 left, 1 right, 2 other) whose focusing down was swallowed and whose up has not come yet.
        private(set) var held: Set<Int> = []
        var swallowing: Bool { !held.isEmpty }
        static let downs: [NSEvent.EventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        static let drags: [NSEvent.EventType] = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        static let ups: [NSEvent.EventType] = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        /// True: swallow this event. `focusing` is read on a mouse-down only.
        mutating func take(_ type: NSEvent.EventType, focusing: Bool) -> Bool {
            if let b = Self.downs.firstIndex(of: type) {
                if focusing { held.insert(b) } else { held.remove(b) }
                return focusing
            }
            if let b = Self.drags.firstIndex(of: type) { return held.contains(b) }
            if let b = Self.ups.firstIndex(of: type) { return held.remove(b) != nil }
            return false
        }
    }

    /// #822 (spec 5.3): who gets a key.
    enum KeyRoute: Equatable {
        case close, session(Int), find, findNext(Bool)
        /// #847: ⌘N (the New session form, or its Name field when open) and ⇧⌘N (the quick shell).
        case newSession, newShell
        /// #1289 (#829 G2/G8): Cmd-Backspace on the selected row: Stop (live) or Remove from History, asked in the strip.
        case stopOrRemove
        /// #1110: Command-1...9, the numbered row at that position (1-based). #1470: Option-Command-1...9 are rows 10...18.
        case jump(Int)
        /// #895: the terminal's text size: +1, -1, 0 (back to today's size).
        case font(Int)
        /// Up, down, left, right, Return for the sidebar (sendEvent).
        case sidebar
        /// #1351 (#1346 3.1): Shift-Command-X (key code 7, any layout), the focused pane's X-ray panel (opens or closes it).
        case xray
        /// The window's, doing nothing here (a chord under the New session form, a held Command-N).
        case swallow
        case pass
    }

    enum ResponderKind { case text, terminal, other }

    var responderKind: ResponderKind {
        if firstResponder is NSText { return .text }
        return firstResponder is AgentTerminalHostView ? .terminal : .other
    }

    /// Pure: the event, the first responder's kind, the sidebar focus and the pane's mode.
    /// Command-W, T, F, G, Shift-Command-G, Command-N, Shift-Command-N go to the window; Command-Up/Down (previous / next session) too,
    /// except in a text view, where they move to its start and end (QA #669). Plain arrows and
    /// Return go to the sidebar only while it has the focus and nothing that types does.
    /// Everything else (Esc, Tab, ⌃C, arrows, Return) reaches the first responder.
    /// #829 G4: while the title is a rename field, every key but ⌘W is the field's (the
    /// row keys, Command-T, F, G, Up, Down and any shortcut added later stand down).
    /// #887 (QA #747 INFO-4): while the New session `form` covers the pane, a chord that acts on the session under it
    /// (Command-T, 1...9, F, G, Up, Down, Option-Command-1...9, Shift-Command-G) is swallowed; Command-W, Command-N and
    /// Shift-Command-N stay the window's.
    /// #1110: ⌘1…⌘9 from every responder, the terminal and a text view too; it stands down for the rename field and is
    /// swallowed under the form, as ⌘↑/⌘↓.
    static func route(_ event: NSEvent, responder: ResponderKind, sidebarFocused: Bool, terminalMode: Bool,
                      renaming: Bool = false, form: Bool = false) -> KeyRoute {
        let r = paneRoute(event, responder: responder, sidebarFocused: sidebarFocused, terminalMode: terminalMode,
                          renaming: renaming)
        switch r {
        case .session, .jump, .find, .findNext, .font, .stopOrRemove, .xray:
            return form ? .swallow : r
        default: return r
        }
    }

    private static func paneRoute(_ event: NSEvent, responder: ResponderKind, sidebarFocused: Bool, terminalMode: Bool,
                                  renaming: Bool) -> KeyRoute {
        guard event.type == .keyDown else { return .pass }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = chordLetter(event)
        if mods.contains(.command), key == "w" { return .close }
        if renaming { return .pass }
        if key == "n", mods == [.command] || mods == [.command, .shift] {   // #847: from every responder, the form's fields too
            if event.isARepeat { return .swallow }   // R2 F1: a held chord starts one session, not one per key repeat
            return mods == [.command] ? .newSession : .newShell
        }
        // #1470: Option-Command-1...9 jump to rows 10...18 in both modes, by key code as Command-1...9 (the old detail-level
        // keys are gone).
        if mods == [.command, .option], let n = digit(event.keyCode) { return .jump(n + 9) }
        if mods == [.command] {
            if let n = digit(event.keyCode) { return .jump(n) }
            // #1289: Cmd-Backspace with the sidebar focused only; a text field, the composer and the terminal keep it.
            if event.keyCode == 51 { return sidebarFocused && responder == .other ? .stopOrRemove : .pass }
            // #1471 b (R1471a-s1, R1): Command-T (the old mode toggle) and Command-L (by key code, as the old chapter list)
            // are swallowed in a terminal pane: no bytes, no menu.
            if event.keyCode == 37, terminalMode { return .swallow }
            switch key {
            case "t": if terminalMode { return .swallow }
            case "f": return terminalMode ? .find : .pass
            case "g": return terminalMode ? .findNext(true) : .pass
            // #895: the terminal's text size; Transcript keeps these keys. The 0 key by code too (AZERTY types a letter there).
            case "=", "+": return terminalMode ? .font(1) : .pass
            case "-": return terminalMode ? .font(-1) : .pass
            case "0": return terminalMode ? .font(0) : .pass
            default: if event.keyCode == 29 { return terminalMode ? .font(0) : .pass }
            }
            if event.keyCode == 126 || event.keyCode == 125 {
                return responder == .text ? .pass : .session(event.keyCode == 126 ? -1 : 1)
            }
        }
        if mods == [.command, .shift], event.keyCode == 7 { return .xray }   // #1351: both modes; the gate is perform's
        if mods == [.command, .shift], key == "g" { return terminalMode ? .findNext(false) : .pass }
        if mods == [.command, .shift], key == "+" || key == "=" { return terminalMode ? .font(1) : .pass }   // #895: Shift-Command-=
        if mods.isEmpty, sidebarFocused, responder == .other, [126, 125, 123, 124, 36, 76].contains(event.keyCode) {
            return .sidebar
        }
        return .pass
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if style != .standard, Self.isMinimizeChord(event) { minimize(self); return true }
        if let model, takesConfirmKey(event, model) { return true }   // #1930
        guard let model else {
            if event.modifierFlags.contains(.command), Self.chordLetter(event) == "w" {
                performClose(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
        // #900 B2 step 1: the tree keys first (before the terminal and the composer, 12.2), only when they acted;
        // otherwise (the gate off, an edge, one pane) today's route below, unchanged.
        let pane = PaneKeys.Context(responder: responderKind, keyFocus: model.keyFocus, panes: model.layout.panes.count,
                                    splitsEnabled: AgentPaneLayout.splitsEnabled)
        if let a = PaneKeys.treeAction(for: event, context: pane, renaming: model.renaming != nil || model.layoutRenaming != nil,
                                       form: model.newSession != nil), perform(pane: a) { return true }
        // #1379: Slide's Control-Command-S pins the sidebar with the split gate off too (on, the line above took it already).
        if model.sidebarMode == .slide, model.renaming == nil, model.layoutRenaming == nil, model.newSession == nil,
           PaneKeys.action(for: event, context: pane) == .toggleSidebar, perform(pane: .toggleSidebar) { return true }
        // #901 B3 step 6 (section 10): ⌘J, gate on only (read first) and never under the rename field or the New session
        // form; nothing to jump to: today's route below. Gate off: the line is skipped, ⌘J travels as before.
        if AgentPaneLayout.splitsEnabled, model.renaming == nil, model.layoutRenaming == nil, model.newSession == nil,
           PaneKeys.action(for: event, context: pane) == .nextNeedsYou, perform(pane: .nextNeedsYou) { return true }
        let r = Self.route(event, responder: responderKind, sidebarFocused: sidebarFocused,
                           terminalMode: model.paneHasTerminal, renaming: model.renaming != nil || model.layoutRenaming != nil,
                           form: model.newSession != nil)
        if perform(r) { return true }
        // #1916: a pane "⋯" item shows its key as a SwiftUI shortcut; the route above stays the key's only performer. A
        // chord it passed (the rename field, the form) skips the view tree, where a menu could match it, and goes to the
        // first responder alone, as before (a terminal, a text field).
        if Self.menuHintKey(event) { return (firstResponder as? NSView)?.performKeyEquivalent(with: event) ?? false }
        return super.performKeyEquivalent(with: event)
    }

    /// #1916: a chord a menu item shows (AgentWindowControls.keyHint), read by the window's own matchers.
    static func menuHintKey(_ event: NSEvent) -> Bool {
        let c = PaneKeys.Context(responder: .other, keyFocus: .pane, panes: 2, splitsEnabled: true)
        switch PaneKeys.action(for: event, context: c) {
        case .split?, .zoom?, .closePane?: return true
        default: return route(event, responder: .other, sidebarFocused: false, terminalMode: true) == .xray
        }
    }

    /// #1359: what a pane key does, for the key (above) and the Go menu's pane items alike.
    @discardableResult func perform(pane a: PaneAction) -> Bool {
        lastPerformed = .pane(a)
        guard let model else { return false }
        if a == .nextNeedsYou { return model.nextNeedsYou() }
        if case .layout(let n) = a { model.switchLayout(number: n); return true }   // #1726: the Layout menu's list, as ⌃N (layoutKey)
        return model.perform(a)   // #1659: a close of the form's pane cancels the form inside the model
    }

    /// #1379: the Go menu's sidebar mode: saved and this window's sidebar redrawn at once (the model's call; no model: nothing).
    func perform(mode m: AgentSidebarMode) {
        lastPerformed = .sidebarMode(m)
        model?.setSidebarMode(m)
    }

    /// #1359: what a routed key does, for the key (performKeyEquivalent) and the Go menu's items alike: one function.
    /// False: not the window's (.sidebar, .pass, a refused Command-T), so the key goes on to super.
    @discardableResult func perform(_ r: KeyRoute) -> Bool {
        lastPerformed = .key(r)
        guard let model else { return false }
        switch r {
        case .close: performClose(nil)
        case .session(let d): model.move(d)
        case .jump(let n): model.selectNumbered(n)   // no row there: nothing, and the key stops here (no beep, not the terminal's)
        case .find: model.terminal.openFind()
        case .findNext(let forward): model.terminal.findNext(forward)
        case .font(let step): model.terminal.zoomFont(step)
        // #847: the model checks the gate; refused, the key does nothing (handled: no beep).
        case .newSession: model.openNewSession()
        case .newShell: model.startShell()
        case .stopOrRemove: model.askStopOrRemove()
        case .xray: return toggleXray()   // below the gate: false, so the key goes on (passes through)
        case .swallow: break
        case .sidebar, .pass: return false
        }
        return true
    }

    /// #1359: the chords `route` acts on, one per action (Shift-Command-= and the keypad digits are aliases left out): the key
    /// equivalent as a menu shows it, the modifiers, the key code and the route. The Go menu's rows hold its list to this
    /// table and this table to `route`.
    static let keyTable: [(key: String, mods: NSEvent.ModifierFlags, keyCode: UInt16, route: KeyRoute)] = [
        ("w", .command, 13, .close), ("n", .command, 45, .newSession), ("n", [.command, .shift], 45, .newShell),
        ("1", .command, 18, .jump(1)), ("2", .command, 19, .jump(2)), ("3", .command, 20, .jump(3)),
        ("4", .command, 21, .jump(4)), ("5", .command, 23, .jump(5)), ("6", .command, 22, .jump(6)),
        ("7", .command, 26, .jump(7)), ("8", .command, 28, .jump(8)), ("9", .command, 25, .jump(9)),
        ("1", [.command, .option], 18, .jump(10)), ("2", [.command, .option], 19, .jump(11)),
        ("3", [.command, .option], 20, .jump(12)), ("4", [.command, .option], 21, .jump(13)),
        ("5", [.command, .option], 23, .jump(14)), ("6", [.command, .option], 22, .jump(15)),
        ("7", [.command, .option], 26, .jump(16)), ("8", [.command, .option], 28, .jump(17)),
        ("9", [.command, .option], 25, .jump(18)),
        ("\u{8}", .command, 51, .stopOrRemove),
        ("f", .command, 3, .find), ("g", .command, 5, .findNext(true)), ("g", [.command, .shift], 5, .findNext(false)),
        ("=", .command, 24, .font(1)), ("-", .command, 27, .font(-1)), ("0", .command, 29, .font(0)),
        ("\u{F700}", .command, 126, .session(-1)), ("\u{F701}", .command, 125, .session(1)),
        ("x", [.command, .shift], 7, .xray),
    ]

    /// #1359: a built key-down for a table chord (handed to `route`, never posted).
    static func keyEvent(_ key: String, _ mods: NSEvent.ModifierFlags, _ keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                         characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)
    }

    /// #882: the letter a chord matches. On a Cyrillic, Greek or Hebrew layout `charactersIgnoringModifiers` is
    /// the layout's own letter and the Command-modified `characters` the Latin one (what menu key equivalents
    /// match), so either one fires a chord; `characters` wins when both are chord letters. The letter, not the
    /// key position, stays the rule.
    /// #887: on "Dvorak - QWERTY ⌘" the two differ on Latin keys too (Command gives the QWERTY character), so with
    /// Command held and Option not, a printable ASCII `characters` decides alone: ⌘, there is Settings, not ⌘W.
    /// With Option held the rule above stays (⌥⌘W types an ASCII character on the Finnish/Norwegian Extended and
    /// Sami layouts, and must still close).
    /// #948 F1: the fields alone cannot tell "Dvorak - QWERTY Command"'s Option-Command on its W key (key 43, ",") from
    /// those layouts' Option-Command-W, so on that input source (by id, read only when Option and Command are held) the
    /// ASCII `characters` decides with Option too. Every other layout: the letter rule above, unchanged.
    static func chordLetter(_ event: NSEvent) -> String? {
        let typed = event.characters?.lowercased()
        let mods = event.modifierFlags
        if mods.contains(.command), !mods.contains(.option) || inputSourceID() == dvorakQwertyCommandID, let typed,
           typed.unicodeScalars.count == 1,
           typed.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }) { return typed }
        if let typed, chordLetters.contains(typed) { return typed }
        return event.charactersIgnoringModifiers?.lowercased()
    }

    static let chordLetters: Set<String> = ["w", "t", "f", "g", "n"]

    /// The X-ray card's surface (#1760: a Prosper card panel under the pane header's "..."). Rows put a fake here before the first key.
    var cards: XrayCardPresenter = XrayCardPanelPresenter()

    // MARK: #1351 the X-ray panel (#1346 P3a)

    /// Shift-Command-X, the "..." item and the Todos chip: closes the focused pane's open panel; else opens one on `tab`
    /// for the pane's live or remote session and reads it once. #1463: `tab` nil opens on the last tab the person chose (Prompts the first time; one the session lacks falls to the first tab it has, Prompts when there). Below XrayTabs.gate (XrayPanels.dch nil): false (the key
    /// passes through) and no process. `fallback` (the chip's list): run when the read finds no Tasks tab.
    @discardableResult func toggleXray(on tab: XrayTab? = nil, fallback: (() -> Void)? = nil) -> Bool {
        guard let model, let dch = XrayPanels.dch() else { return false }
        let pane = model.layout.focused, panels = XrayPanels.shared
        let target = model.newSession == nil ? XrayTarget.of(model.selectedRow) : nil
        if let open = panels.open[pane] {
            panels.close(pane)
            if open.target == target { panels.remembered[open.target] = false }   // #2055: this session's drawer, closed by the person
            if open.target == target || target == nil { return true }
        }
        guard let target else { return true }
        panels.remembered[target] = true   // #2055
        for other in model.layout.order where other != pane { panels.close(other) }   // #1476: one drawer per window
        let p = XrayPanelModel(target: target, tab: tab ?? Preferences.xrayLastTab)
        p.close = { panels.remembered[target] = false; panels.close(pane) }   // #2055: the panel's own close is the person's too
        p.fallback = fallback
        p.isCurrent = { [weak model, weak p] in
            guard let model, let p else { return false }
            return panels.open[pane] === p && model.newSession == nil && XrayTarget.of(model.selectedRow) == target
        }
        p.presentCard = { [weak self, weak model, weak p] t in
            guard let self, let anchor = XrayCardAnchor.view(for: pane, in: self) ?? self.contentView else { return }
            let card = XrayTaskCard(task: t, now: p?.now() ?? Date(), open: { model?.openURL($0) })
            self.cards.present(AnyView(card), size: XrayTaskCard.size, anchor: anchor) {}
        }
        panels.open[pane] = p
        p.read(dch: dch, run: XrayPanels.run)
        return true
    }

    /// The "..." item "X-Ray... Shift-Command-X": only at or above the gate and for a live or remote session.
    @MainActor static func xrayItem(_ m: AgentWindowModel) -> AgentWindowMenuEntry? {
        XrayPanels.dch() != nil && XrayTarget.of(m.selectedRow) != nil ? .xray(pane: m.layout.focused) : nil
    }

    /// The window that draws `pane`'s header: its newest anchor that is in an Agents window (#1951: one out of any window,
    /// or freed, is skipped), else the shared (nil) one's.
    @MainActor static func window(of pane: UUID) -> AgentsNSWindow? {
        XrayCardAnchor.candidates(pane).lazy.compactMap { $0.window as? AgentsNSWindow }.first
    }

    @MainActor static func xrayChosen(pane: UUID) { window(of: pane)?.toggleXray() }

    /// #1476: a pane header's X-ray button: that pane takes the focus first, then the window's one drawer toggles for it.
    @MainActor static func xrayClicked(pane: UUID, in win: AgentsNSWindow?) {
        guard let win, let m = win.model else { return }
        if pane != m.layout.focused { m.focusPane(pane) }
        win.toggleXray()
    }

    /// #1476 (operator: "One for the window"): focus moved from `old` while its drawer was open: the drawer follows to the
    /// focused pane on the same tab (closed when that pane shows no session X-ray can read).
    func xrayFollow(from old: UUID) {
        guard let model, old != model.layout.focused, let open = XrayPanels.shared.open[old] else { return }
        XrayPanels.shared.close(old)
        toggleXray(on: open.tab)
    }

    /// #2055: the focused pane shows another session (or none): the drawer takes that session's own state (XrayPanels.wants),
    /// the one it leaves keeps its own (remembered when it was toggled). Nothing to show, or not wanted: closed.
    func xrayShown() {
        guard let model else { return }
        let pane = model.layout.focused, panels = XrayPanels.shared, open = panels.open[pane]
        let target = model.newSession == nil ? XrayTarget.of(model.selectedRow) : nil
        if let target, panels.wants(target) {
            if open?.target != target { toggleXray(on: open?.tab) }   // closes the other session's panel, opens this one's
        } else if open != nil {
            panels.close(pane)
        }
    }

    /// Q3: the Todos chip opens the panel on Tasks when X-ray is there and the read finds a Tasks tab; else (the list
    /// already open, the gate off, no Tasks tab) `list` runs, today's AgentTodosList.
    func todosChipTapped(listOpen: Bool, list: @escaping () -> Void) {
        if listOpen || !toggleXray(on: .tasks, fallback: list) { list() }
    }

    static let dvorakQwertyCommandID = "com.apple.keylayout.DVORAK-QWERTYCMD"
    /// #948 F1 seam: the current keyboard input source's id, read only (never selected). Under XCTest "" unless a test
    /// sets it, so no test reads the machine's layout.
    static var inputSourceID: () -> String = {
        NSClassFromString("XCTestCase") == nil ? KeyboardSource.currentSourceID() : ""
    }

    /// #1110: the digit 1…9 of a key, by key code (any layout: a Cyrillic one, AZERTY's unshifted digit row): the top row
    /// (QuickSelect's table, its 0 left out: ⌘0 stays free) or the keypad.
    static func digit(_ keyCode: UInt16) -> Int? {
        if let slot = QuickSelect.slot(forKeyCode: keyCode), slot < 9 { return slot + 1 }
        return [83, 84, 85, 86, 87, 88, 89, 91, 92].firstIndex(of: keyCode).map { $0 + 1 }
    }

    override func sendEvent(_ event: NSEvent) {
        if let model, takesConfirmKey(event, model) { return }   // #1930: before the dividers, the routes and the responder
        // #900 B2 step 5a (7.5): a divider's down, drags and up go to the model before the first-click rule (gate on only).
        if AgentPaneLayout.splitsEnabled, let model, [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown].contains(event.type) {
            let r = contentLayoutRect, at = event.type == .keyDown ? CGPoint.zero : event.locationInWindow
            if Self.divider(event, model, at: CGPoint(x: at.x - r.minX, y: r.maxY - at.y), in: r.size) {
                // #900 B2 step 6b2c: the swallowed down asks for key and front as the focusing down does (its drags and up never).
                if Self.asksKey(focusing: event.type == .leftMouseDown, isKey: isKeyWindow) { raise(self) }
                return
            }
        }
        if event.type == .keyDown { model?.dropPendingResume() }   // #1924: typed before the resumed session listed
        var focusing = false
        let left = event.type == .leftMouseDown
        if FocusClick.downs.contains(event.type), let model {
            // 7.2: the frames come from the model's geometry in the content (top-left origin), never x alone.
            let r = contentLayoutRect, at = event.locationInWindow
            let p = CGPoint(x: at.x - r.minX, y: r.maxY - at.y)
            let inSidebar = model.sidebarFrame(in: r.size)?.contains(p) == true
            // R1477b-m1: a right or middle down takes the left first-click rule over the panes (never a mouse report or a
            // responder move in an unfocused pane); in the sidebar it stays AppKit's (a row's menu) and moves no keys.
            if left || !inSidebar { focusing = Self.mouseDown(model, at: p, in: r.size) }
            // #822: a sidebar click takes the keys from the terminal, so the arrows select again;
            // #845: from the input box too (a row's click then moves them in again, on mouse-up).
            if left, inSidebar, responderKind == .terminal || firstResponder is AgentComposerTextView { makeFirstResponder(nil) }
            if left, inSidebar { model.dropPendingFocus() }   // QA #694 INFO-2: a row's click asks again, on mouse-up
        }
        // R1196-1: `focusing` is true only for a down on an unfocused pane, which needs two panes shown: the gate on.
        // R1477b-m1: a right or middle down focuses the pane but asks no key and front (AppKit's own right-click does not).
        if Self.asksKey(focusing: focusing && left, isKey: isKeyWindow) { raise(self) }
        if focusClick.take(event.type, focusing: focusing) { return }   // 7.6: the first click only focuses
        let routed = model.map { m in
            Self.route(event, responder: responderKind, sidebarFocused: sidebarFocused, terminalMode: m.paneHasTerminal,
                       renaming: m.renaming != nil || m.layoutRenaming != nil, form: m.newSession != nil)
        }
        if AgentPaneLayout.splitsEnabled, let model, Self.layoutKey(event, model, responder: responderKind) { return }
        if event.type == .keyDown, event.keyCode == 48, responderKind != .terminal { sidebarFocused = false }   // Tab: focus moves on
        if let model, routed == .some(.sidebar), Self.handle(event, model) { return }
        super.sendEvent(event)
    }

    /// #901 B3 step 3 (8.1, 12.1): ⌃1…⌃9 switch to layout N and ⌃Tab to the previous one (the MRU pair), from every
    /// responder, the terminal too (12.2: window-level); sendEvent runs before the responder's keyDown. True: consumed,
    /// a refusal (no layout N, a lone MRU) too: a silent no-op, no beep, nothing written. The rename field and the New
    /// session form keep the key, as for the tree keys. Gate off: PaneKeys is nil, false, the key travels as before.
    /// Runs on the main actor, inside sendEvent; rows pass a built event.
    @MainActor static func layoutKey(_ event: NSEvent, _ m: AgentWindowModel, responder: ResponderKind) -> Bool {
        guard m.renaming == nil, m.layoutRenaming == nil, m.newSession == nil else { return false }   // 4b: the layout field too
        let c = PaneKeys.Context(responder: responder, keyFocus: m.keyFocus, panes: m.layout.panes.count,
                                 splitsEnabled: AgentPaneLayout.splitsEnabled)
        switch PaneKeys.action(for: event, context: c) {
        case .layout(let n)?: m.switchLayout(number: n)   // a held digit repeats onto the active layout: a no-op
        case .previousLayout? where event.isARepeat: break   // R901-s3-a: a held ⌃Tab is consumed, nothing flips or writes
        case .previousLayout?: m.previousLayout()
        default: return false
        }
        return true
    }

    /// #1937: confirmKey plus the held key (Return, keypad Enter, Escape): the repeats of the key that answered are taken until its keyUp (the
    /// keyUp itself goes on to the responders).
    @MainActor func takesConfirmKey(_ event: NSEvent, _ m: AgentWindowModel) -> Bool {
        if event.type == .keyUp { if event.keyCode == heldConfirmKey { heldConfirmKey = nil }; return false }
        if event.type == .keyDown, event.isARepeat, event.keyCode == heldConfirmKey { return true }
        guard Self.confirmKey(event, m, responder: firstResponder) else { return false }
        heldConfirmKey = event.keyCode   // confirmKey answers only 36, 76 and 53
        return true
    }

    /// #1930: while the window's confirmation card shows, Return (keypad Enter too) confirms and Escape cancels, whatever
    /// has the keys (the terminal, the sidebar, the composer): taken here, before any responder sees it. The first
    /// responder is never moved, so the keys are back where they were once the card closes. Command, Option or Control
    /// held: not the card's (it passes on). Nothing taken while no card shows.
    @MainActor static func confirmKey(_ event: NSEvent, _ m: AgentWindowModel, responder: NSResponder? = nil) -> Bool {
        guard event.type == .keyDown, m.confirmQuestion != nil,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        switch event.keyCode {
        // #1937: Return with marked text (an IME composition) commits the composition: not the card's, it passes on.
        case 36, 76:
            if (responder as? NSTextInputClient)?.hasMarkedText() == true { return false }
            m.confirm(true)
        case 53: m.confirm(false)
        default: return false
        }
        return true
    }

    /// #845: the keyboard into `view` (the terminal, the input box): first responder within its window only,
    /// never ordered front or made key. The sidebar no longer has the focus, so its keys stand down.
    @MainActor @discardableResult static func focus(_ view: NSView) -> Bool {
        guard let window = view.window, window.makeFirstResponder(view) else { return false }
        (window as? AgentsNSWindow)?.sidebarFocused = false
        return true
    }

    /// Plain up, down, left, right and Return only; anything with a modifier passes through.
    @MainActor static func handle(_ event: NSEvent, _ model: AgentWindowModel) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 126: model.move(-1)                   // up
        case 125: model.move(1)                    // down
        case 123: model.collapseSelected(true)     // #828 left: fold the selection's section
        // #845 right: into the session; a folded selection's section (or none selected) unfolds first.
        case 124 where model.selection != nil && !model.selectionFolded: model.focusSelection()
        case 124: model.collapseSelected(false)
        // Return, keypad Enter: #822/#845 into the terminal or the input box (Ghostty is the "⋯" menu's first item).
        // A History row, an ended session's row: nothing takes input, so it passes on.
        case 36, 76: return model.focusSelection()
        default: return false
        }
        return true
    }
}

// MARK: - Views

/// The state colors of the island; idle reads in the theme's secondary text (the
/// island's dim white disappears on a light theme).
func agentStateColor(_ s: AgentState?) -> Color {
    guard let s, s != .idle else { return Neon.textSecondary }
    return s.color
}

/// #1339: the sidebar row's state glyph. The fixed amber, orange and green read 1.2 to 2.3:1 on the light themes' sidebar
/// and selected row (graphics need 3:1); where either is under 3:1 the same hue is mixed toward black (toward white on a
/// dark sidebar) in 5% steps until both reach it. Dark themes already clear it and keep agentStateColor exactly.
func agentGlyphColor(_ s: AgentState?, sidebar: Color = Neon.sidebar, accent: Color = Neon.blue) -> Color {
    func rgb(_ c: Color) -> [Double] {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        return [Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent)]
    }
    func color(_ v: [Double]) -> Color { Color(red: v[0], green: v[1], blue: v[2]) }
    let side = rgb(sidebar), tint = rgb(accent)
    let selected = color(zip(side, tint).map { $0 * 0.86 + $1 * 0.14 })   // NeonSelectedRowFill: the accent at 0.14
    let base = agentStateColor(s)
    func reach(_ c: Color) -> Double { min(ThemeRuntime.contrastRatio(c, sidebar), ThemeRuntime.contrastRatio(c, selected)) }
    guard reach(base) < 3 else { return base }
    let end = ThemeRuntime.contrastRatio(sidebar, .white) > ThemeRuntime.contrastRatio(sidebar, .black) ? 1.0 : 0.0
    let from = rgb(base)
    var shade = base
    for step in 1...20 {
        let t = Double(step) * 0.05
        shade = color(from.map { $0 * (1 - t) + end * t })
        if reach(shade) >= 3.05 { break }
    }
    return shade
}

struct AgentWindowRootView: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var model: AgentWindowModel
    /// False for offscreen evidence only (the transcript without its ScrollView).
    var scrolls = true

    var body: some View {
        // QA #626 INFO-6: the island off is the window's only message.
        if !model.hasStore {
            AgentEmptyState(icon: "rectangle.dashed", title: "Agent Island is off",
                            detail: "Turn on Agent Island in Settings › Extensions to list your dch sessions here.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsBackground())
        } else {
            split
        }
    }

    // #860: Settings' surfaces, at the live opacity and frost: the rail's NeonSidebarSurface and
    // the content column's SettingsBackground. Both observe the store, so an opacity or frost
    // change repaints them in place; the panes on top add no full-width fill of their own.
    var split: some View {
        HStack(spacing: 0) {
            // #900 B2 step 4 (7.2): ⌃⌘S hides the sidebar and its line (gate on only, `sidebarShown`): the pane column takes
            // the width and nothing else moves (the column keeps its place in the stack, so its identity). Rider 1197 (a):
            // under the band's height while the band is shown, so the sidebar title sits on the session title's line.
            // #1379: Full sz(290), Mini its rail; Slide has no column (its sidebar is the overlay below).
            // #1923: Full at the person's dragged width (AgentSidebarColumn).
            if model.sidebarShown && model.sidebarMode != .slide {
                AgentSidebarColumn(model: model, width: model.sidebarWidth)
            }
            // #831 9.1: the band over the pane area, one whatever the number of panes, only while the split gate is on
            // (AgentWindowBand.shown; AgentWindowModel.paneAreaFrame mirrors this column for the 7.2 click rule).
            // #900 B2 step 3: the band's chip reads the pane area from this geometry (the model's paneArea is
            // not published, so a resize to too small would not redraw the band).
            // #1586: the pane area keeps one place in the tree whether the band shows or not (#1538 flips it at two
            // panes), so a band coming or going never remakes the panes' terminals.
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    if AgentWindowBand.shows(model) {
                        AgentWindowBand(model: model, area: CGRect(x: 0, y: 0, width: proxy.size.width,
                                                                   height: max(0, proxy.size.height - AgentWindowBand.height)))
                    }
                    AgentPaneArea(model: model, scrolls: scrolls)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsBackground())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // #1923: the content's width for the sidebar's 40% line (written on a change only)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { model.sidebarWidth.content = $0 }
        .overlay(alignment: .topLeading) { if model.sidebarMode == .slide { slideLayer } }
        // #1457: Mini's quick tooltip, over the panes beside its row (only Mini rows report bounds)
        .overlayPreferenceValue(AgentMiniTipAnchors.self) { AgentMiniTipLabel(tip: model.miniTip, anchors: $0) }
    }

    /// #1379 Slide: the left edge's hover area (#1458: a short dwell in it slides the sidebar in) and, while slid in or
    /// pinned, the full sidebar over the panes, which keep their width; the pointer leaving both slides it out a while later.
    var slideLayer: some View {
        ZStack(alignment: .topLeading) {
            AgentSlideTracker(edge: true) { model.slideArea($0) }
                .frame(width: AgentSlideTracker.areaWidth)
                .frame(maxHeight: .infinity)
                .padding(.top, AgentSlideTracker.areaTop(model))
            if model.slideOpen {
                AgentSidebarColumn(model: model, width: model.sidebarWidth)   // #1923: Full's width
                    .background(AgentSlideTracker(edge: false, onMenu: { model.slideMenu($0) }) { model.slide($0) })
                    .transition(.move(edge: .leading))
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

/// #1923: the sidebar and its 1 pt line: Full and Slide's overlay at AgentSidebarWidth's drawn width (observed here alone,
/// so a drag redraws this column and the layout), Mini at its fixed rail. Full's line is the drag handle: a few points of
/// hit area on the sidebar's side (never over a pane, so the window's first-click rule never takes it), the cursor set while
/// the pointer moves over it, as the X-ray drawer's edge and the split dividers do.
struct AgentSidebarColumn: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var model: AgentWindowModel
    @ObservedObject var width: AgentSidebarWidth

    var body: some View {
        HStack(spacing: 0) {
            AgentSidebarView(model: model)
                .padding(.top, AgentWindowBand.shows(model) ? AgentWindowBand.height : 0)
                .frame(width: model.sidebarMode == .mini ? AgentWindowModel.miniSidebarWidth : width.drawn)
                .background(NeonSidebarSurface())
            Rectangle().fill(Neon.stroke).frame(width: 1)
                .overlay(alignment: .trailing) { if model.sidebarMode == .full { handle } }
        }
    }

    var handle: some View {
        Color.clear.frame(width: sz(5)).contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { NSCursor.resizeLeftRight.set() } else if !width.dragging { NSCursor.arrow.set() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { model.sidebarDragged(by: $0.translation.width, from: $0.startLocation.x) }
                .onEnded { _ in
                    model.sidebarDragEnded()
                    NSCursor.arrow.set()   // a drag can end off the handle: no later hover end to restore it
                })
            .onDisappear { model.sidebarDragEnded() }   // R1923 i1: gone mid-drag, its gesture never ends
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            // the drawn width (clamped to the window), never the stored value: that is outside data and Int( could trap
            .accessibilityValue("\(Int(width.drawn / ThemeRuntime.scale)) points")
            .accessibilityAdjustableAction { d in
                model.sidebarDragged(by: d == .increment ? sz(20) : -sz(20))
                model.sidebarDragEnded()
            }
    }
}

/// #1379: the Agent Sessions sidebar's mode (Settings > Agent Island > Agent Sessions, and the Go menu).
enum AgentSidebarMode: String, CaseIterable {
    case full, mini, slide
    var label: String {
        switch self {
        case .full: return "Full"
        case .mini: return "Mini"
        case .slide: return "Hidden, slides in"
        }
    }
    /// Settings' line under the picker.
    var hint: String {
        switch self {
        case .full: return "Each session's name, state and details."
        case .mini: return "A narrow rail: each session's state, short name and number; hover for its full name."
        case .slide: return "Hidden: point at the window's left edge, or press Control-Command-S to keep it open."
        }
    }
    /// The Go menu's item.
    var menuTitle: String {
        switch self {
        case .full: return "Full Sidebar"
        case .mini: return "Mini Sidebar"
        case .slide: return "Slide-In Sidebar"
        }
    }
}

/// #1474 (operator 2026-11-17): the sidebar's mode switch at its bottom edge, radio-like and icon only (no text drawn; the
/// mode's label on hover and to VoiceOver). A row wherever it fits (#1539: Mini's rail too), stacked only when the width
/// given is narrower than the row; dimmed until the pointer is over it. A click is the model's setter, which Settings and
/// the Go menu use too.
struct AgentSidebarModeSwitch: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var model: AgentWindowModel
    @State private var hover = false

    static func symbol(_ m: AgentSidebarMode) -> String {
        switch m {
        case .full: return "sidebar.left"
        case .mini: return "sidebar.squares.left"
        case .slide: return "rectangle"
        }
    }
    /// The theme's inks: the current mode in the accent on a faint fill of it, the others secondary on nothing.
    static func ink(_ on: Bool) -> Color { on ? Neon.blue : Neon.textSecondary }
    /// Not Neon.faded: Increase Contrast would make the fill opaque, the accent symbol on it unseen (the X-ray button's fill).
    static func fill(_ on: Bool) -> Color { on ? Neon.blue.opacity(0.2) : .clear }
    /// #1474 b: the idle symbol's opacity until hover (1 under Increase Contrast). 0.75 is the least that keeps
    /// textSecondary at 3:1 (non-text UI) over the sidebar on every bundled theme (0.6 left 8 of them under).
    static let idleOpacity = 0.75
    static var segment: CGSize { CGSize(width: sz(20), height: sz(18)) }

    var body: some View {
        let mini = model.sidebarMode == .mini
        ViewThatFits(in: .horizontal) {
            HStack(spacing: sz(2)) { ForEach(AgentSidebarMode.allCases, id: \.self) { button($0) } }
            VStack(spacing: sz(2)) { ForEach(AgentSidebarMode.allCases, id: \.self) { button($0) } }   // too narrow for the row
        }
        .onHover { hover = $0 }
        .padding(.horizontal, mini ? 0 : sz(14)).padding(.vertical, sz(6))
        .frame(maxWidth: .infinity, alignment: mini ? .center : .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar mode")
    }

    func button(_ m: AgentSidebarMode) -> some View {
        let on = model.sidebarMode == m
        return Button { model.setSidebarMode(m) } label: {
            Image(systemName: Self.symbol(m)).font(Neon.font(11, weight: .medium))
                .foregroundStyle(Self.ink(on))
                .opacity(on || hover || ThemeRuntime.increaseContrast ? 1 : Self.idleOpacity)   // the current mode is never dimmed
                .frame(width: Self.segment.width, height: Self.segment.height)
                .background(RoundedRectangle(cornerRadius: sz(4)).fill(Self.fill(on)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(m.label)
        .accessibilityLabel(m.label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// #1379 Slide: a pointer tracker that never takes a click (no hit). `edge`: the window's left hover area, whose enter or
/// move (true) and exit (false) go to the model's dwell and hide (#1458); else behind the slid-in sidebar, whose exit
/// slides it out. Tests call the handlers directly.
struct AgentSlideTracker: NSViewRepresentable {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let edge: Bool
    /// #1461: a sidebar menu's tracking began (true) or ended (false).
    var onMenu: @MainActor (Bool) -> Void = { _ in }
    /// The pointer entered (true) or left (false).
    let action: @MainActor (Bool) -> Void
    /// #1458 (operator 2026-11-17): half the open sidebar's width (was 4 pt, too narrow to land on). It takes no click,
    /// so the panes' controls under it work as before.
    static var areaWidth: CGFloat { AgentWindowModel.fullSidebarWidth / 2 }
    /// The area starts below the row of the window's controls: the band's, or, band off under No title bar (the content
    /// runs under the title bar), the title bar's own height as AppKit gives it for a titled window.
    @MainActor static func areaTop(_ m: AgentWindowModel) -> CGFloat {
        if AgentWindowBand.shows(m) { return AgentWindowBand.height }
        return Preferences.agentWindowStyle == .noTitleBar ? NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height : 0
    }
    func makeNSView(context: Context) -> AgentSlideTrackerView { AgentSlideTrackerView(edge: edge) }
    func updateNSView(_ nsView: AgentSlideTrackerView, context: Context) { (nsView.action, nsView.onMenu) = (action, onMenu) }
}

final class AgentSlideTrackerView: NSView {
    let edge: Bool
    var action: @MainActor (Bool) -> Void = { _ in }
    var onMenu: @MainActor (Bool) -> Void = { _ in }
    private var menuTracking = false
    init(edge: Bool) {
        self.edge = edge
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // The sidebar slides in under the pointer, so its first event is the exit (assumeInside).
        // #1458: the area's moves too: a pointer already inside it (a hide landed there, or the area was made under it)
        // sends no fresh enter.
        let opts: NSTrackingArea.Options = edge ? [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect]
            : [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .assumeInside]
        addTrackingArea(NSTrackingArea(rect: .zero, options: opts, owner: self))
    }
    override func mouseEntered(with event: NSEvent) { action(true) }
    override func mouseMoved(with event: NSEvent) { if edge { action(true) } }
    override func mouseExited(with event: NSEvent) {
        guard !edge else { return action(false) }
        // #1461: a menu or submenu opened from the sidebar tracks in this mode; its window over the sidebar sends the exit.
        if !menuTracking, RunLoop.current.currentMode == .eventTracking { holdUntilTrackingEnds() }
        action(false)
    }

    /// #1461: the model holds the exit until the menu closes (the run loop is back in its default mode); then the
    /// sidebar hides only if the pointer is outside it. Strong self: the close must always reach the model's count.
    func holdUntilTrackingEnds() {
        menuTracking = true
        onMenu(true)
        RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { self.trackingEnded() } }
    }

    func trackingEnded() {
        menuTracking = false
        if let w = window, bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil)) { action(true) }
        onMenu(false)
    }
}

struct AgentSidebarView: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var model: AgentWindowModel
    /// #1455: the store's Row details; a toggle the Rows do not carry (model, effort, state, age, shortcut) leaves the
    /// sections equal (no publish), so the rows read the store's own value to redraw at once.
    @State private var details: AgentIslandRowDetails

    /// #1657: seeded from the store, so the first frame already hides what Row details turned off (no flash of every detail).
    init(model: AgentWindowModel) {
        _model = ObservedObject(wrappedValue: model)
        _details = State(initialValue: model.store?.details ?? .all)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentSidebarTitleRow(model: model)
            // #897 (G9): the store's own list-wide question (the island's line), answered through its confirm call.
            if let store = model.store { AgentStoreQuestionStrip(store: store) { model.answerStoreQuestion($0) } }
            AgentAlwaysAllowStrip(model: model)
            AgentNewGroupStrip(model: model)   // #2062
            if !model.hasStore {
                AgentEmptyState(icon: "rectangle.dashed", title: "Agent Island is off",
                                detail: "Turn on Agent Island in Settings › Extensions to list your dch sessions here.")
            } else if model.sections.isEmpty, let store = model.store {
                AgentNoSessionsState(store: store)
            } else {
                ScrollViewReader { proxy in
                    let drawn = model.drawnItems   // #1785: cached on the model
                    let numbers = model.numbers
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: sz(2)) {
                            // #901 B3 step 4a (8.1): the first section; nil (gate off, one layout of one pane): no view.
                            // #1379 Mini: the rail lists the rows alone (no Layouts section, no headers, nothing folded).
                            let mini = model.sidebarMode == .mini
                            if !mini, let rows = model.layoutRows { AgentLayoutsSection(model: model, rows: rows, show: details) }
                            ForEach(model.sections) { section in
                                // #828: Sessions, Sidekicks and History fold on a header click
                                // (remembered per Mac); a folded section keeps its selection.
                                let folded = !mini && model.isCollapsed(section.id), inView = model.inViewRows
                                let items = drawn[section.id] ?? []
                                if !mini && !items.isEmpty {
                                    AgentSectionHeader(title: section.title, count: items.reduce(0) { $0 + $1.rows.count },
                                                       collapsed: folded,
                                                       toggle: AgentSidebar.folds(section.id)
                                                           ? { model.toggleCollapsed(section.id) } : nil,
                                                       group: AgentSidebar.groupSessions(section).flatMap { rows in
                                                           model.store.map { (store: $0, rows: rows) } },
                                                       runGroup: { model.runGroup($0, name: section.title, rows: $1) })
                                }
                                if !folded {
                                    ForEach(items) { item in
                                        Group {
                                            if let row = item.rows.first {
                                                line(row, number: numbers[row.id], mini: mini, inView: inView)
                                            }
                                        }
                                        .id(ItemID(section: section.id, row: item.id))
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, sz(8)).padding(.bottom, sz(12))
                    }
                    .onChange(of: model.selection) { _, id in if let id, let item = item(id, drawn) { proxy.scrollTo(item) } }
                }
            }
            Spacer(minLength: 0)
            // #829 G0: the dir strip's fixed slot under the list (QA #665 INFO-4/5: the list ends above it).
            if let store = model.store { AgentDirStatusStrip(store: store) }
            AgentSidebarModeSwitch(model: model)   // #1474: at the very bottom, in every mode
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onReceive(model.store.map { $0.$details.eraseToAnyPublisher() } ?? Just(.all).eraseToAnyPublisher()) { details = $0 }
    }

    /// #1373: a row's identity in the one lazy list is its section and its row. With the row's id alone, a session that
    /// moved from one section to another (Needs you to Sessions, Sessions to Sidekicks) kept its old section's cell and
    /// drew its old title, state and number until the window was reopened.
    struct ItemID: Hashable {
        let section: String
        let row: AgentSidebar.RowID
    }

    /// The selection's scroll target: its row in the section that holds it now (nil: not listed).
    func item(_ id: AgentSidebar.RowID, _ drawn: [String: [AgentSidebar.Item]]) -> ItemID? {
        for s in model.sections {
            if let i = drawn[s.id]?.first(where: { $0.rows.contains { $0.id == id } }) { return ItemID(section: s.id, row: i.id) }
        }
        return nil
    }

    /// One session's row: its click, its number and its context menu, as before.
    func line(_ row: AgentSidebar.Row, number: Int?, mini: Bool, inView: Set<AgentSidebar.RowID>) -> some View {
        Button { model.click(row.id, flags: AgentWindowModel.clickFlags(NSApp.currentEvent)) } label: {   // #900 B2 step 6b1: read with the gate on only
            AgentSidebarRowView(row: row, selected: model.selection == row.id,
                                number: number, inView: inView.contains(row.id),
                                model: model, mini: mini, show: details,   // #1455
                                tip: mini ? model.miniTip : nil)   // #1457
            .equatable()   // #1786: redrawn only when one of its inputs changed (a switch: the two rows whose selection did)
        }
        .buttonStyle(.plain)
        .modifier(AgentRowDrag(token: AgentWindowModel.dragToken(row.id)))   // #1492: onto a pane
        .contextMenu {   // #829: a live row's Restart / Stop / Kill (asks); a History row's (G6-G8)
            if let s = row.session, let store = model.store {
                // #1103: the header's list, Open in terminal first (selects the row, as ask does).
                AgentSessionMenuItems(store: store, session: s, ask: { model.ask($0, s) },
                                      open: { open(s) }, row: model,
                                      side: { model.openToTheSide(row.id) })
                // #2062: Move to group (none for a remote row, which has no session here, or a dch before 1.196).
                let move = AgentWindowControls.moveToGroupMenu(s, store: store)
                if !move.isEmpty {
                    Divider()
                    AgentSidebarMenuEntries(entries: move) { model.runMove($0, s) }
                }
            } else if let r = row.record, row.host == nil, let store = model.store {   // #1324: a remote record has none
                AgentHistoryMenuItems(store: store, record: r) { model.act($0, r) }
            }
        }
    }

    /// #1103: a live row's Open in terminal: that row selected first (as ask does), then the header's action.
    func open(_ s: AgentSession) {
        model.select(.live(s.key))
        model.openSelected()
    }
}

/// #1378: the Agent Sessions window's style (Settings > Agent Island > Agent Sessions).
enum AgentWindowStyle: String, CaseIterable {
    case standard, noTitleBar, borderless
    var label: String {
        switch self {
        case .standard: return "Standard"
        case .noTitleBar: return "No title bar"
        case .borderless: return "Borderless"
        }
    }
}

/// #1378: behind the sidebar title row and the session header, so their empty parts drag the window in every style (the
/// controls drawn over it keep their clicks: SwiftUI hit-tests them first). Adds no accessibility element.
struct AgentWindowDragArea: NSViewRepresentable {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    var toolTip: String? = nil
    func makeNSView(context: Context) -> AgentWindowDragView { AgentWindowDragView() }
    func updateNSView(_ nsView: AgentWindowDragView, context: Context) { nsView.toolTip = toolTip }
}

final class AgentWindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return window?.performDrag(with: event) ?? () }
        // The app's defaults search the global domain, where the system keeps it (the test store under XCTest).
        Self.doubleClick(Preferences.defaults.string(forKey: "AppleActionOnDoubleClick"), window)
    }
    /// A title bar's double-click (the system's "double-click a window's title bar to" setting): Minimize, Do Nothing,
    /// else zoom (the default, "Maximize" or "Fill").
    static func doubleClick(_ action: String?, _ win: NSWindow?) {
        switch action {
        case "Minimize": win?.miniaturize(nil)
        case "None": break
        default: win?.zoom(nil)
        }
    }
}

/// The sidebar's title row: the window's name, the count, then #847's [>_] New shell and [+] New session in fixed
/// sz(18) slots. The count gives way first (lineLimit 1, lowest priority); the buttons never move or resize.
struct AgentSidebarTitleRow: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var model: AgentWindowModel
    /// #923: the Diagnostics pane's text while it is up (read once when the item is chosen).
    @State private var diagnostics: String?

    @ViewBuilder var body: some View {
        if model.sidebarMode == .mini { miniBody } else { fullBody }
    }

    /// #1379 Mini: the rail keeps the list-wide "..." and #847's [>_] [+] (buttonsWidth fits the rail, #1457 measured); the name and the count go.
    var miniBody: some View {
        HStack(spacing: 0) {
            if let store = model.store { buttons(store) }
        }
        .frame(minHeight: sz(18))
        .frame(minWidth: 0, maxWidth: .infinity)
        .padding(.top, Self.padTop).padding(.bottom, sz(8))
        .background(AgentWindowDragArea())
    }

    var fullBody: some View {
        HStack(spacing: sz(6)) {
            // #860: names the window (its title is hidden); "Sessions" in the accent, as Settings' rail titles.
            neonAccentedText(AgentsWindow.title, accent: "Sessions").font(Neon.font(13, weight: .semibold))
                .foregroundStyle(Neon.textPrimary).lineLimit(1)
                .allowsHitTesting(false)   // #1378: a press on the name drags the window, as on a title bar
            Spacer(minLength: 0)
            let rows = model.sections.filter { $0.id != "History" }.flatMap(\.rows)
            if !rows.isEmpty {
                // #1467: "6/17 active \u{B7} <robot glyph> 9" (#1546: the drawn RobotGlyph, inline); a header too narrow for it drops the word "active" first.
                let t = Self.countText(rows.map { (state: $0.state, agents: max(0, $0.session?.agents ?? 0)) })
                ViewThatFits(in: .horizontal) {
                    Self.countLine(t.short, subs: t.subs)
                    Self.countLine(t.narrow, subs: t.subs)
                }
                .font(Neon.font(10.5)).foregroundStyle(Neon.textSecondary)
                .lineLimit(1)
                .accessibilityElement(children: .ignore).accessibilityLabel(t.long)
                .allowsHitTesting(false)   // #1378: drags too
                // #1467 s1: .help on a view that takes no hits never shows; the count's own drag view carries the tooltip.
                .background(AgentWindowDragArea(toolTip: t.long))
                .layoutPriority(-1)   // after the background, so the HStack reads it on its direct child
            }
        }
        // The buttons sit over a reserved trailing strip, inside the row's height: a cut count can never move them.
        .frame(minHeight: sz(18))
        .padding(.trailing, Self.buttonsWidth + sz(6))
        // minWidth 0: the frame is the width offered, never its child's (a cut count's rounding moved the overlay 1 pt).
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if let store = model.store { buttons(store) }
        }
        .padding(.horizontal, sz(14)).padding(.top, Self.padTop).padding(.bottom, sz(8))
        .background(AgentWindowDragArea())   // #1378: the row's empty parts move the window
    }

    /// The row's buttons, one view for Full and Mini (#1379: Mini keeps every list-wide action of the "...").
    func buttons(_ store: AgentIslandStore) -> some View {
        HStack(spacing: sz(4)) {
            // #897 (G9): the list-wide "..." in its own fixed sz(18) slot, beside the count; #847's pair keeps
            // the trailing edge.
            AgentSidebarMenuButton(store: store) { v in
                if v == .diagnostics { diagnostics = AgentDiagnostics.text(model.transcript) } else { model.runSidebar(v) }
            }
            .popover(isPresented: Binding(get: { diagnostics != nil }, set: { if !$0 { diagnostics = nil } })) {
                AgentDiagnosticsView(text: diagnostics ?? "")
                    .onAppear { model.slideMenu(true) }.onDisappear { model.slideMenu(false) }   // #1461: holds a Slide exit
            }
            AgentNewSessionButtons(model: model, store: store)
        }
        .fixedSize()
    }

    /// #1103 F2: the content starts under the titlebar (no .fullSizeContentView), so the row's centre sits on the
    /// session header's title line: 14 + 18 / 2 = AgentSessionHeader's 10 + 26 / 2.
    static var padTop: CGFloat { sz(14) }

    /// #1546: the count line: `ratio`, then at subs > 0 " \u{B7} ", the robot glyph (a template image Text draws in the
    /// surrounding ink, 10.5 pt as the header's font) and the number.
    /// The header's robot: the 10.5 pt font at the UI scale (as Neon.font) times the glyph's side factor.
    static func countRobotImage() -> NSImage { RobotGlyph.nsImage(size: 10.5 * ThemeRuntime.scale * RobotGeometry.sideFactor) }
    static func countLine(_ ratio: String, subs: Int) -> Text {
        guard subs > 0 else { return Text(ratio) }
        return Text(ratio) + Text(" \u{B7} ") + Text(Image(nsImage: countRobotImage()).renderingMode(.template)) + Text(" \(subs)")
    }

    /// #1467: the header count of the listed sessions (state, sub-agents). short "6/17 active" and `subs` 9, drawn as
    /// "6/17 active \u{B7} <robot glyph> 9" by countLine (active = working or blocked; the robot part is left out at
    /// subs 0), narrow the same without "active", long the full split
    /// for the tooltip and VoiceOver: "4 working, 2 need input, 3 done, 8 idle \u{B7} 9 sub-agents" (zero parts left out).
    /// A row with no state reads as idle. n = 0 has no count: the caller shows nothing.
    static func countText(_ rows: [(state: AgentState?, agents: Int)]) -> (short: String, narrow: String, long: String, subs: Int) {
        func n(_ s: AgentState) -> Int { rows.filter { ($0.state ?? .idle) == s }.count }
        let (blocked, working, done, idle) = (n(.blocked), n(.working), n(.done), n(.idle))
        // #1467 m1: each term and the running total kept to 0...maxAgents, so no + can overflow whatever a caller passes.
        let subs = rows.reduce(0) { min($0 + min(max(0, $1.agents), DchListRow.maxAgents), DchListRow.maxAgents) }
        let ratio = "\(working + blocked)/\(rows.count)"
        let parts = [working > 0 ? "\(working) working" : nil, blocked > 0 ? "\(blocked) need\(blocked == 1 ? "s" : "") input" : nil,
                     done > 0 ? "\(done) done" : nil, idle > 0 ? "\(idle) idle" : nil].compactMap { $0 }
        let tail = subs > 0 ? " \u{B7} \(subs) sub-agent\(subs == 1 ? "" : "s")" : ""
        return ("\(ratio) active", ratio, parts.joined(separator: ", ") + tail, subs)
    }
    /// #897: the trailing strip the overlay holds: the "..." slot, the gap, #847's pair.
    static var buttonsWidth: CGFloat { AgentNewSessionButtons.width + sz(4) + sz(18) }
}

/// #901 B3 step 4a (8.1 :625-631): the Layouts section, built only from `model.layoutRows` (gate on and the show rule).
/// Header: the section label and count, then "+" (New layout); at 9 layouts the "+" is disabled and the fixed words
/// "(9 layouts max)" show. Rows: the name (one line, middle-truncated), the fixed attention slot (step 5), the active
/// the ⌃N keycap chip in the session rows' chip column (#1654); the active row in accent text.
/// Height: the header plus one fixed-height row per layout (text height at the scale + sz paddings); the chip and the
/// words are fixedSize, never an sz frame on text. Not in `sections`, so out of the
/// up/down walk and the ⌘1…9 jump. Closures run on the main actor (Buttons, the field's handlers).
/// Step 4b: the header folds through agentWindowCollapsedSections ("Layouts"; folded: rows left out, the active layout
/// unchanged); each row's context menu draws AgentWindowControls.layoutMenu (Rename opens the inline field in place of
/// the name, Duplicate, Delete); the row being renamed is drawn without its Button, the field over the name's own slot.
struct AgentLayoutsSection: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var model: AgentWindowModel
    let rows: [AgentWindowModel.LayoutRow]
    /// #1657: the store's Row details, as the session rows get them; Shortcut off: no ⌃N chip and no chip column.
    var show = AgentIslandRowDetails.all
    static let title = "Layouts"
    /// The attention slot's fixed width (section 10, step 5 fills it).
    static var attentionWidth: CGFloat { sz(14) }

    /// A row's click: the keys' own model call; the active row and a refusal are no-ops (nothing written, no beep).
    @MainActor static func click(_ m: AgentWindowModel, _ r: AgentWindowModel.LayoutRow) { m.switchLayout(number: r.number) }
    /// The header "+": New layout; at the cap the model refuses (.layoutCap) and the button is disabled anyway.
    @MainActor static func plus(_ m: AgentWindowModel) { m.newLayout() }
    static func full(_ rows: [AgentWindowModel.LayoutRow]) -> Bool { rows.count >= PaneLayoutStore.maxLayouts }

    var body: some View {
        let full = Self.full(rows), folded = model.isCollapsed(Self.title)
        AgentSectionHeader(title: Self.title, count: rows.count, collapsed: folded,
                           toggle: { model.toggleCollapsed(Self.title) })
            .overlay(alignment: .trailing) {
                HStack(spacing: sz(4)) {
                    if full {
                        Text(PaneRefusal.layoutCap.menuSuffix ?? "").font(Neon.font(9.5)).foregroundStyle(Neon.textSecondary)
                            .lineLimit(1).fixedSize()
                    }
                    Button { Self.plus(model) } label: {
                        Image(systemName: "plus").font(Neon.font(9.5, weight: .bold)).frame(width: sz(14), height: sz(14))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Neon.textSecondary)
                    .disabled(full)
                    .help("New layout")
                    .accessibilityLabel("New layout")
                }
                .padding(.horizontal, sz(8)).padding(.top, sz(12)).padding(.bottom, sz(4))
            }
        ForEach(folded ? [] : rows) { r in
            if model.layoutRenaming == r.id {
                AgentLayoutRowView(row: r, edit: model.layouts?.layouts.first { $0.id == r.id }?.name ?? "", end: {
                    model.endLayoutRename(r.id, $0)
                }, showShortcut: show.shortcut)
            } else {
                Button { Self.click(model, r) } label: { AgentLayoutRowView(row: r, showShortcut: show.shortcut) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.label(r))
                    .accessibilityValue(Self.value(r))
                    .accessibilityAddTraits(r.active ? .isSelected : [])
                    .contextMenu {
                        ForEach(AgentWindowControls.layoutMenu(model, r.id)) { e in
                            Button { AgentWindowControls.runLayout(e, model, r.id) } label: {
                                Label(e.title, systemImage: e.symbol)   // #1358
                            }.disabled(!e.enabled)
                        }
                    }
            }
        }
    }

    /// R901-s4a-a: VoiceOver reads what a sighted person sees, the name and the "⌃N" key.
    static func label(_ r: AgentWindowModel.LayoutRow) -> String { "\(r.name), Control \(r.number)" }
    /// #901 B3 step 5: the dot and count read aloud; nothing for 0 (the slot draws nothing). #1661: "Working" first when
    /// the mark is (the session rows read their state word); idle reads nothing, as before.
    static func value(_ r: AgentWindowModel.LayoutRow) -> String {
        let need = r.blocked == 0 ? nil : r.blocked == 1 ? "1 session needs input" : "\(r.blocked) sessions need input"
        return [r.working ? AgentState.working.label : nil, need].compactMap { $0 }.joined(separator: ", ")
    }
}

/// #901 B3 step 4b: a Layouts row's inline name field: Return ends with the text (the model cleans it), Escape, the focus
/// leaving and the field going away end with nil; each ends once (the model ignores a second end). Main actor.
struct AgentLayoutNameField: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let placeholder: String
    @State var text: String
    let end: (String?) -> Void
    @State private var ended = false

    init(placeholder: String, text: String, end: @escaping (String?) -> Void) {
        self.placeholder = placeholder
        _text = State(initialValue: text)
        self.end = end
    }

    private func finish(_ t: String?) {
        guard !ended else { return }
        ended = true
        end(t)
    }

    var body: some View {
        // #1450: our own field (a SwiftUI TextField could keep the last UI scale's height); Return, Escape and the focus leaving as before.
        ScaledTextField(placeholder: placeholder, text: $text, onSubmit: { finish(text) }, fontSize: 12.5, weight: .medium,
                        plain: true, focusOnAppear: true, onCancel: { finish(nil) }, onEndEditing: { finish(nil) })
            .accessibilityLabel("Layout name")
            .onDisappear { finish(nil) }
    }
}

/// #901 B3 step 4a: one Layouts row (the name and the attention slot). #1654 (operator 2026-11-19: "the layout shortcut
/// ... to the right and with border etc like cmd + 1"): its ⌃N is a session row's keycap chip (AgentDigitChip, glyph ⌃)
/// in the session rows' chip column, the attention slot to its left (#1895: no Edit / Done).
struct AgentLayoutRowView: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let row: AgentWindowModel.LayoutRow
    /// Step 4b: the inline rename field's first text; nil: no field.
    var edit: String?
    /// The field's end, once: Return's text, or nil (Escape, the focus left, the field gone). Main actor.
    var end: (String?) -> Void = { _ in }
    /// #1657: Row details > Shortcut; off: no chip and no chip column (the session rows' rule). The ⌃N keys work regardless.
    var showShortcut = true

    /// #1654: the trailing parts after the name, in order: the attention slot (`count`), the chip column.
    /// The row lays them out hidden; the overlay draws them over the same places (no frame moves).
    private func trailing(count: some View, chip: some View) -> some View {
        HStack(alignment: .center, spacing: sz(8)) {
            count.frame(width: AgentLayoutsSection.attentionWidth, alignment: .trailing)
            if showShortcut { ZStack { AgentSidebarRowView.digitColumn; chip } }
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: sz(8)) {
            // #1661 (operator 2026-11-19): the session rows' own mark, working if any of the layout's sessions is, else idle
            AgentSidebarRowView.stateMark(row.working ? .working : .idle)
                .accessibilityHidden(true)   // the rename branch is no Button: VoiceOver would read the glyph (the state is the row's value)
                .modifier(AgentSidebarRowProbe(kind: "layoutMark", title: "\(row.number) \(row.working ? "working" : "idle")", global: true))
            Text(row.name).font(Neon.font(12.5, weight: .medium))
                .foregroundStyle(row.active ? Neon.blue : Neon.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                // Step 4b: the field lies over the name's slot, the name goes transparent: no frame moves.
                .opacity(edit == nil ? 1 : 0).accessibilityHidden(edit != nil)
                .overlay(alignment: .leading) { if let edit { AgentLayoutNameField(placeholder: row.name, text: edit, end: end) } }
                .modifier(AgentSidebarRowProbe(kind: "layoutName", title: "\(row.number)", global: true))
                // #1654: the name's slot, all the room before the Spacer (priority 1: the Spacer gets 0, the Text the
                // same offer as before); a middle-truncated Text ends at a glyph edge, short of its slot
                .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                .modifier(AgentSidebarRowProbe(kind: "layoutSlot", title: "\(row.number)", global: true))
            Spacer(minLength: 0)
            trailing(count: Color.clear, chip: EmptyView()).hidden().frame(height: 0)   // the slots' widths, no height
        }
        .padding(.horizontal, sz(10)).padding(.vertical, sz(5))
        .frame(maxWidth: .infinity, alignment: .leading)
        // #901 B3 step 5 (section 10): an inactive layout's blocked count, a dot and the number over the slot (an
        // overlay: no frame moves; 0 builds nothing). The sidebar's blocked colour; read aloud through the row's value.
        // #1654: the ⌃N chip over the session rows' chip column, the row's line centred like theirs; read through the
        // row's label ("Control N"), so no element of its own.
        .overlay(alignment: .trailing) {
            trailing(count: Group {
                if row.blocked > 0 {
                    HStack(spacing: sz(2)) {
                        Circle().fill(agentStateColor(.blocked)).frame(width: sz(5), height: sz(5))
                        Text("\(row.blocked)").font(Neon.font(9.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(AgentSidebarRowView.amberInk).fixedSize()
                    }
                }
            }, chip: chip)
            .padding(.trailing, sz(10))
            .allowsHitTesting(false).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

extension AgentLayoutRowView {
    /// #1654: the layout's Control-number chip, drawn by AgentDigitChip with the ⌃ glyph; laid on an unseen Command chip
    /// of the same digit, trailing edges together, so its right edge is a session row's ⌘N chip's whatever the glyphs'
    /// widths. Brighter on the active layout, as on the selected session row.
    var chip: some View {
        AgentDigitChip(number: row.number).hidden()
            .overlay(alignment: .trailing) {
                AgentDigitChip(number: row.number, active: row.active, glyph: "\u{2303}")
                    .modifier(AgentSidebarRowProbe(kind: "layoutChip", title: "\(row.number)", global: true))
            }
    }
}

struct AgentSectionHeader: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let title: String
    let count: Int
    /// #828: folded (rows hidden; the count stays).
    var collapsed = false
    /// #828: nil for a section that never folds (Needs you): no chevron, no button.
    var toggle: (() -> Void)?
    /// #2060: a group section's rows (AgentSidebar.groupSessions): its "\u{22EF}" and right-click menu; nil, none.
    var group: (store: AgentIslandStore, rows: [AgentSession])? = nil
    var runGroup: (AgentSidebarVerb, [AgentSession]) -> Void = { _, _ in }
    /// StableMenuProbe.bodies key.
    static let groupMenuID = "agent.sidebar.group"

    var body: some View {
        let entries = group.map { AgentWindowControls.groupMenu(store: $0.store, rows: $0.rows) } ?? []
        let rows = group?.rows ?? [], run = { (v: AgentSidebarVerb) in runGroup(v, rows) }
        Group {
            if let toggle {
                Button(action: toggle) { content }
                    .buttonStyle(.plain)
                    .help(collapsed ? "Show \(title)" : "Hide \(title)")
                    .accessibilityLabel("\(title), \(count)")
                    .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            } else {
                content
            }
        }
        // #2060: the sidebar title row's "\u{22EF}" look, always shown; a right-click opens the same items.
        .padding(.trailing, entries.isEmpty ? 0 : sz(20))
        .overlay(alignment: .trailing) {
            if !entries.isEmpty {
                StableMenu(Self.groupMenuID, entries: entries, run: run) { e, r in
                    AgentSidebarMenuEntries(entries: e, run: r)
                } label: { _ in
                    Image(systemName: "ellipsis").font(Neon.font(11, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .frame(width: sz(18), height: sz(18))
                .padding(.top, sz(8))   // the title's line: the header's top padding is sz(8) more than its bottom
                .help("Restart, stop or end the sessions in \(title)")
                .accessibilityLabel("\(title) actions")
            }
        }
        .contextMenu { if !entries.isEmpty { AgentSidebarMenuEntries(entries: entries, run: run) } }
    }

    var content: some View {
        HStack(spacing: sz(5)) {
            if toggle != nil {
                // Rotated, not swapped: one glyph in one fixed box, so the title never moves.
                Image(systemName: "chevron.right").font(Neon.font(8, weight: .bold)).foregroundStyle(Neon.textSecondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: sz(9), height: sz(9))
            }
            // #860: Settings' section label (accent tick, caps, tracking) at the sidebar's 9.5 pt, so the
            // header keeps its height; Needs you tints tick and title in the blocked colour (was a dot).
            NeonSectionLabel(title: title, size: 9.5,
                             tint: title == AgentSidebar.needsYouTitle ? AgentState.blocked.color : nil)
            Text("\(count)").font(Neon.font(9.5, weight: .medium).monospacedDigit()).foregroundStyle(Neon.faded(Neon.textSecondary, 0.8))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, sz(8)).padding(.top, sz(12)).padding(.bottom, sz(4))
        .contentShape(Rectangle())
    }
}

/// #1786 (#1778 R5): Equatable over every value the row draws, so the sidebar's `.equatable()` skips a row whose inputs
/// are unchanged (a switch redraws the old and the new selected rows only). The theme, accent and UI size reach the row
/// through its own `liveTheme`, which redraws it whatever `==` says; `AgentPaneLayout.splitsEnabled` is a constant in the
/// product (tests set it before drawing).
struct AgentSidebarRowView: View, Equatable {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let row: AgentSidebar.Row
    let selected: Bool
    /// #1110: the row's number (1...18: Command-1...9, then Option-Command-1...9), nil for no chip.
    var number: Int?
    /// #900 B2 step 4b (7.2): the session is shown in another pane of the active layout (AgentWindowModel.inViewRows).
    var inView = false
    /// #1289 (G5): a URL chip's click goes to this model's openPR, its openURL seam (nothing opens from a row itself); nil,
    /// the chip opens nothing. #1786: the model, not a closure, so the row stays comparable (by identity).
    var model: AgentWindowModel? = nil
    /// Tests: a row part's frame in the row, by kind and row title (nil in the product). Main actor.
    static var probe: ((String, String, CGRect) -> Void)?
    /// #1786 tests: called with the row's title on every body evaluation (nil in the product).
    static var bodyProbe: ((String) -> Void)?
    /// #1379: Mini's rail row.
    var mini = false
    /// #1452 b: the island's own inks (Agent Island > Follow theme off); nil, the theme's. The Agent Sessions rows never set it.
    var inks: Inks? = nil
    struct Inks: Equatable { var primary, quiet, blue, blocked, mark: Color; var badges: ThemePalette }
    /// #1455: the Row details shown (Settings > Agent Island > Row details); the agents, merged and open PRs are the Row's.
    var show: AgentIslandRowDetails = .all
    /// #1457: Mini's quick full-name tooltip (the window model's); nil, none.
    var tip: AgentMiniTip? = nil

    /// #1786: every stored input but `liveTheme` (it redraws the row itself). A new input must be added here.
    nonisolated static func == (l: Self, r: Self) -> Bool {
        l.row == r.row && l.selected == r.selected && l.number == r.number && l.inView == r.inView && l.mini == r.mini
            && l.inks == r.inks && l.show == r.show && l.tip === r.tip && l.model === r.model
    }

    /// #1457: Mini's pointer entering (true) or leaving the row.
    func hover(_ inside: Bool) { tip?.hover(row, inside) }

    /// #1455: a live row's state word goes with State off, unless an action or notice stands in its place; History keeps it.
    var stateShown: Bool { show.state || row.state == nil || row.detail != row.state?.label }
    /// #1455: a live row's age goes with Age off (its slot too); History rows keep theirs.
    var ageShown: Bool { show.age || row.state == nil }
    var modelEffort: (model: String?, effort: String?, modelSlot: Bool, effortSlot: Bool) {
        show.modelEffort(model: row.model, effort: row.effort)
    }
    /// #1455: the Command chip's number, nil with Shortcut off.
    var shownNumber: Int? { show.shortcut ? number : nil }

    @ViewBuilder var body: some View {
        let _ = Self.bodyProbe?(row.title)
        if mini { miniBody } else { fullBody }
    }

    /// The row's one accessibility label (#1379: Mini's tooltip and label too).
    var accessibilityWords: String {
        ([row.title, row.record?.pinned == true ? "pinned" : nil,
          AgentPaneLayout.splitsEnabled && inView ? "in view" : nil, row.detail, row.agentKind?.rawValue,
          show.modelWords(model: row.model, effort: row.effort)] + row.countWords
         + [ageShown ? AgentIsland.ago(row.age) : nil]).compactMap { $0 }.joined(separator: ", ")
    }

    /// #1289 (G5): the element ignores its children, so each URL chip is an action on it, as on the island's row.
    var prActions: some View {
        ForEach(row.prLinks.indices, id: \.self) { i in
            if row.prLinks[i].url != nil {
                Button(AgentWindowControls.openPRLabel(row.prLinks[i])) { model?.openPR(row.prLinks[i]) }
            }
        }
    }

    /// #1379 Mini: the state mark, #1539 the name cut to the rail's width with its Command number as a superscript
    /// (rows 1-9 with Shortcut on), and the needs-you mark (blocked or done); the full row's words are its tooltip and its one
    /// VoiceOver label, and the hover shows the whole name beside the row after `AgentMiniTip.delay` (`hover`).
    var miniBody: some View {
        let needs = row.session.map(AgentSidebar.needsYou) ?? false
        let number = shownNumber.flatMap { $0 <= 9 ? $0 : nil }   // #1470: rows 10-18 (Option-Command) still jump, unmarked
        return Self.miniLine(mark: stateMark, name: Self.miniName(row.title), number: number, selected: selected,
                             ink: row.state == nil ? ink(.quiet) : inks?.primary ?? Neon.textPrimary, title: row.title) {
            Circle().fill(agentStateColor(.blocked)).frame(width: sz(6), height: sz(6)).opacity(needs ? 1 : 0)
                .modifier(AgentSidebarRowProbe(kind: needs ? "miniNeeds" : "miniSlot", title: row.title))
        }
        .padding(.vertical, sz(7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .anchorPreference(key: AgentMiniTipAnchors.self, value: .bounds) { [row.id: $0] }
        .onHover(perform: hover)
        .coordinateSpace(.named(agentSidebarRowSpace))
        .background(NeonSelectedRowFill(selected: selected))
        .overlay(alignment: .leading) { NeonSelectionBar().opacity(selected ? 1 : 0) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityWords)
        .help(accessibilityWords)   // on the one element, so VoiceOver's help reads it too
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityActions { prActions }
    }

    var fullBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: sz(8)) {
            stateMark
            VStack(alignment: .leading, spacing: sz(3)) {
                titleLine
                detailVariants
            }
            .anchorPreference(key: AgentDigitChipSlot.self, value: .bounds) { AgentDigitChipSlot.Value(block: $0) }
            .modifier(AgentSidebarRowProbe(kind: "block", title: row.title))
            .modifier(AgentSidebarRowProbe(kind: "nameAt", title: row.title, global: true))   // #1661 tests: the Layouts names' x
            // #1345: the ⌘<n> chip's own column on EVERY row (the widest digit's chip, at no height), so the badges and
            // the age end at one edge with a number or none and the row's height never changes. #1455: none with Shortcut off.
            if show.shortcut {
                Self.digitColumn
                    .anchorPreference(key: AgentDigitChipSlot.self, value: .bounds) { AgentDigitChipSlot.Value(column: $0) }
                    .modifier(AgentSidebarRowProbe(kind: "chipColumn", title: row.title))
            }
        }
        .padding(.horizontal, sz(10)).padding(.vertical, sz(7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(.named(agentSidebarRowSpace))
        // #860: Settings' selected row (accent fill and edge, the glowing accent bar), drawn behind and
        // over the row's padding so nothing in it moves.
        .background(NeonSelectedRowFill(selected: selected))
        .overlay(alignment: .leading) { NeonSelectionBar().opacity(selected ? 1 : 0) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityWords)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityActions { prActions }
        // #1110: drawn over the row's chip column (outside the row's element, so it is read with its own name and help);
        // no number, no chip. #1345: centred on the two lines (the column's x, the text block's y).
        .overlayPreferenceValue(AgentDigitChipSlot.self) { slot in
            if let column = slot.column, let block = slot.block, let number = shownNumber {
                GeometryReader { proxy in
                    AgentDigitChip(number: number, active: selected)
                        .modifier(AgentSidebarRowProbe(kind: "digitChip", title: "\(number)", global: true))   // #1654 tests, by number
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(AgentDigitChip.words(number))
                        .help("Select this session (\(AgentDigitChip.glyphs(number))\(AgentDigitChip.digit(number)))")
                        .position(x: proxy[column].midX, y: proxy[block].midY)
                }
            }
        }
    }
}

/// The sidebar row's coordinate space (AgentSidebarRowProbe's frames are in it).
let agentSidebarRowSpace = "agentSidebarRow"

/// Tests: a row part's frame in the row, through `AgentSidebarRowView.probe` (nil in the product). Main actor.
/// R900-4b-2: the observer is attached only while the probe is set (read at body time), so the product has none.
struct AgentSidebarRowProbe: ViewModifier {
    let kind: String, title: String
    struct Probed: Equatable, Sendable { let title: String, frame: CGRect }
    /// #1457: the frame in the window (Mini's tooltip, outside any row) instead of the row's space.
    var global = false
    @ViewBuilder func body(content: Content) -> some View {
        if AgentSidebarRowView.probe != nil {
            // #1661: the title is in the observed value, so a part whose title changes in place (a Layouts mark's state) reports again
            content.onGeometryChange(for: Probed.self, of: { Probed(title: title, frame: $0.frame(in: global ? .global : .named(agentSidebarRowSpace))) }) { v in
                agentProbeCalled()
                AgentSidebarRowView.probe?(kind, v.title, v.frame)
            }
        } else {
            content
        }
    }
}

/// #1457: Mini's quick tooltip: the hovered row's whole name, shown `delay` after the pointer enters it and gone when it
/// leaves. The window model holds one; the rows report to it through `AgentSidebarRowView.hover`.
@MainActor
final class AgentMiniTip: ObservableObject {
    struct Shown: Equatable { let id: AgentSidebar.RowID, title: String }
    static var delay: Duration = .milliseconds(300)
    @Published private(set) var shown: Shown?
    private var pending: (id: AgentSidebar.RowID, task: Task<Void, Never>)?

    /// A hovered row that leaves the list sends no hover-out: when the drawn rows no longer hold the shown or pending id,
    /// both go, so the tip never returns when that id is drawn again.
    func prune(_ drawn: Set<AgentSidebar.RowID>) {
        if let p = pending, !drawn.contains(p.id) { p.task.cancel(); pending = nil }
        if let s = shown, !drawn.contains(s.id) { shown = nil }
    }

    func hover(_ row: AgentSidebar.Row, _ inside: Bool) {
        if inside {
            pending?.task.cancel()
            let next = Shown(id: row.id, title: OutsideText.shown(row.title))
            pending = (row.id, Task { @MainActor [weak self] in
                try? await Task.sleep(for: AgentMiniTip.delay)
                guard !Task.isCancelled, let self else { return }
                self.shown = next
                self.pending = nil
            })
        } else {
            // another row's enter may come first: only this row's pending show and shown label go
            if pending?.id == row.id { pending?.task.cancel(); pending = nil }
            if shown?.id == row.id { shown = nil }
        }
    }
}

/// #1457: every drawn Mini row's bounds, by row (the tooltip's place).
struct AgentMiniTipAnchors: PreferenceKey {
    static let defaultValue: [AgentSidebar.RowID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [AgentSidebar.RowID: Anchor<CGRect>], nextValue: () -> [AgentSidebar.RowID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// #1457: the tooltip's label in the window's own overlay (never a window or panel of its own), beside the hovered Mini
/// row, one line cut to the window's width. Not hit-tested (the row keeps its hover) and not read (the row's label is).
struct AgentMiniTipLabel: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var tip: AgentMiniTip
    let anchors: [AgentSidebar.RowID: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            if let s = tip.shown, let a = anchors[s.id] {
                let r = proxy[a], gap = sz(6)
                Text(s.title).font(Neon.font(11, weight: .medium)).foregroundStyle(Neon.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, sz(6)).padding(.vertical, sz(3))
                    .background(RoundedRectangle(cornerRadius: sz(4)).fill(Neon.bgBottom)
                        .overlay(RoundedRectangle(cornerRadius: sz(4)).strokeBorder(Neon.stroke, lineWidth: 1)))
                    .modifier(AgentSidebarRowProbe(kind: "miniTip", title: s.title, global: true))
                    .frame(maxWidth: max(0, proxy.size.width - r.maxX - 2 * gap), alignment: .leading)
                    .alignmentGuide(.leading) { _ in -(r.maxX + gap) }
                    .alignmentGuide(.top) { d in d.height / 2 - r.midY }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onChange(of: Set(anchors.keys)) { _, ids in tip.prune(ids) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if DEBUG
/// Tests (R900-4b-2): geometry callbacks run by the three probe modifiers; with every probe nil it stays 0. Main actor.
@MainActor var agentProbeCallbacks = 0
#endif
/// Counts one probe callback in DEBUG builds; nothing in release. Main actor (SwiftUI runs the actions from layout).
@MainActor @inline(__always) func agentProbeCalled() {
    #if DEBUG
    agentProbeCallbacks += 1
    #endif
}

/// #1110: the bounds of the ⌘<n> chip's slot. #1345: the row's chip column (x) and its two-line text block (y).
private struct AgentDigitChipSlot: PreferenceKey {
    struct Value { var block: Anchor<CGRect>?, column: Anchor<CGRect>? }
    static let defaultValue = Value()
    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        value = Value(block: next.block ?? value.block, column: next.column ?? value.column)
    }
}

/// #1783: the chip column's slot: clear, as wide as the chips (AgentSidebarRowView.columnWidths) at this display scale.
private struct AgentDigitColumn: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: a UI scale change re-reads the width, as the chips re-themed
    let mini: Bool
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        let w = AgentSidebarRowView.columnWidths(backing: max(displayScale, 1))
        return Color.clear.frame(width: mini ? w.mini : w.full, height: 0)
    }
}

/// #1783: a window that is never shown, only reporting the backing its views lay out on.
private final class AgentMeasureWindow: NSWindow {
    var fixedBacking: CGFloat = 2
    override var backingScaleFactor: CGFloat { fixedBacking }
}

/// #1470 a2: records its subviews' ideal widths (AgentSidebarRowView.idealWidths); draws nothing.
private struct AgentIdealWidths: Layout {
    final class Box: @unchecked Sendable { var widths: [CGFloat] = [] }
    let box: Box
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        box.widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        return .zero
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}
}

/// #1110: a numbered row's ⌘<n> chip. #1111 (R1111-1): Clipboard History's position keycap itself (PositionKeyCap), with
/// this chord's glyphs (always ⌘, or ⌥⌘ for rows 10-18) instead of the clipboard's ⌘/⌃ setting. Brighter on the selected row.
/// Neon.blue, not the keycap's blueBright: a theme that sets only its accent leaves blueBright at the default cyan.
struct AgentDigitChip: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let number: Int
    var active = false
    /// #1654: the glyphs before the digit; nil: this chord's (`glyphs`). A Layouts row passes ⌃.
    var glyph: String? = nil

    /// #1470: rows 10...18 are Option-Command-1...9.
    static func glyphs(_ n: Int) -> String { n > 9 ? "\u{2325}\u{2318}" : "\u{2318}" }
    static func digit(_ n: Int) -> Int { n > 9 ? n - 9 : n }
    static func words(_ n: Int) -> String { (n > 9 ? "Option-Command-" : "Command-") + "\(digit(n))" }

    /// #1783 counting seam: chip bodies run (a sidebar row's column draws none).
    static var bodies = 0

    var body: some View {
        let _ = Self.bodies += 1
        PositionKeyCap(digit: "\(Self.digit(number))", active: active, glyph: glyph ?? Self.glyphs(number), accent: Neon.blue,
                       edge: Neon.faded(Neon.blue, active ? 0.9 : 0.6))
            .fixedSize()
    }
}

extension AgentSidebarRowView {
    /// The state mark's slot (#1371: moved out of `body` unchanged, the island's session row draws it too).
    var stateMark: some View {
        Self.stateMark(row.state, pinned: row.record?.pinned == true, pin: ink(.quiet), inks: inks)
    }

    /// #1661: the mark itself, by state; a Layouts row draws it too (its layout's working or idle), so its name starts at
    /// the session names' x.
    static func stateMark(_ state: AgentState?, pinned: Bool = false, pin: Color = .clear, inks: Inks? = nil) -> some View {
        Group {   // #829 G7: a pinned History record's glyph, in the same slot
            if pinned {
                Image(systemName: "pin.fill").font(Neon.font(9, weight: .bold)).foregroundStyle(pin)
            } else {
                Text(state?.glyph ?? "\u{25CB}")
                    .font(Neon.font(11, weight: .bold))
                    .foregroundStyle(inks.map { state?.color ?? $0.mark }   // #1452 b: off, AgentState's own colours
                                     ?? (state == nil ? Neon.faded(Neon.textSecondary, 0.6) : agentGlyphColor(state)))
            }
        }
        .frame(width: sz(14))
    }

    /// #1345: the Command-<n> chip's column, the widest digit's chip at no height (digits are proportional: the chips together
    /// are the widest whatever the font); the row draws the chip over it, only with a number. #1470: all 18 (Option-Command-9's).
    /// #1783: one clear slot of that width, measured once per UI scale (the chips' font is the only input) and cached, not 18
    /// hidden chips in every realized row.
    static var digitColumn: some View { AgentDigitColumn(mini: false) }

    /// #1470: Mini's column keeps the nine Command chips' width (its rail has no room for an Option-Command chip).
    static var miniDigitColumn: some View { AgentDigitColumn(mini: true) }

    /// #1783: the two columns' exact ideal widths at the current UI scale and the view's display scale (`backing`: the chips'
    /// text widths round to its pixel grid), measured offscreen from the chips themselves.
    static func columnWidths(backing: CGFloat) -> (full: CGFloat, mini: CGFloat) {
        let scale = [ThemeRuntime.scale, backing]   // the key: UI scale and backing (the chips' only inputs)
        if let w = columnWidthByScale[scale] { return w }
        digitMeasures += 1
        let w = idealWidths(ZStack { ForEach(1...18, id: \.self) { AgentDigitChip(number: $0) } },
                            ZStack { ForEach(1...9, id: \.self) { AgentDigitChip(number: $0) } }, backing: backing)
        guard w.count == 2 else { return (0, 0) }   // not measured: no slot, and measured again on the next read
        columnWidthByScale[scale] = (w[0], w[1])
        return (w[0], w[1])
    }
    private static var columnWidthByScale: [[CGFloat]: (full: CGFloat, mini: CGFloat)] = [:]
    /// #1783 counting seam: how many times the chips were measured (once per scale).
    static var digitMeasures = 0

    /// #1457 (operator 2026-11-17): the wide characters Mini's rail is measured to fit (`miniWidestLine`); #1539: no
    /// longer a cut, a name takes the row's width.
    static let miniNameLength = 8

    /// #1457: the name as Mini shows it, OutsideText's; #1539: whole, the line cuts it by width with "...".
    static func miniName(_ title: String) -> String { OutsideText.shown(title) }

    /// #1457: Mini's line: the mark's slot, the name with the Command number's superscript after it (the widest digit's slot
    /// kept), then the needs-you slot at the trailing edge. The rail is measured from this very line (`miniWidestLine`).
    static func miniLine<Mark: View, Needs: View>(mark: Mark, name: String, number: Int?, selected: Bool, ink: Color,
                                                  title: String, @ViewBuilder needs: () -> Needs) -> some View {
        HStack(spacing: sz(4)) {
            mark
            HStack(alignment: .top, spacing: sz(1)) {
                // A cut Text is as wide as its whole glyphs, up to a glyph short of what it was offered: a name that does not fit
                // takes the whole offer, so its slot ends at the superscript (a short one stays its own width).
                ViewThatFits(in: .horizontal) {
                    Text(name).fixedSize()
                    Text(name).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Neon.font(11, weight: .medium)).foregroundStyle(ink)
                .modifier(AgentSidebarRowProbe(kind: "miniName", title: title))
                ZStack(alignment: .leading) {
                    ForEach(1...9, id: \.self) { miniSuperscript($0, selected: selected).hidden() }
                    if let number { miniSuperscript(number, selected: selected).modifier(AgentSidebarRowProbe(kind: "miniSup", title: title)) }
                }
            }
            // #1539: the name takes the row up to the needs-you slot. #1585: a frame, not a Spacer, takes a short name's rest
            // (a zero-width Spacer still had the stack's spacing on both sides: sz(4) empty after a cut name's superscript).
            .frame(maxWidth: .infinity, alignment: .leading)
            needs()
        }
        .padding(.horizontal, sz(6))
    }

    /// #1505: the Command number's ink; the text tokens clear 4.5:1 on the rail on every theme, the faded blue did not.
    static func miniSuperscriptInk(selected: Bool) -> Color { selected ? Neon.textPrimary : Neon.textSecondary }

    static func miniSuperscript(_ n: Int, selected: Bool) -> some View {
        Text("\(n)").font(Neon.font(8, weight: .bold, design: .rounded))
            .foregroundStyle(miniSuperscriptInk(selected: selected)).fixedSize()
    }

    /// #1457: the widest Mini line: `miniNameLength` W's and "...", the mark's and needs-you slots (#1539: the same rail).
    static var miniWidestLine: some View {
        miniLine(mark: Color.clear.frame(width: sz(14), height: 0), name: String(repeating: "W", count: miniNameLength) + "\u{2026}",
                 number: nil, selected: false, ink: .clear, title: "") { Color.clear.frame(width: sz(6), height: sz(6)) }
    }

    /// #1470 a2: each view's exact ideal width, unrounded (a fittingSize is whole points rounded up); [] if not laid out.
    /// #1783: `backing` hosts it in a never-shown window of that backing, as a row's chips are laid out (their text widths
    /// round to that pixel grid; an unhosted view measures on whole points, up to a point wider).
    static func idealWidths<A: View, B: View>(_ a: A, _ b: B, backing: CGFloat? = nil) -> [CGFloat] {
        let box = AgentIdealWidths.Box()
        let host = NSHostingView(rootView: AgentIdealWidths(box: box) { a; b })
        guard let backing else { _ = host.fittingSize; return box.widths }
        let win = AgentMeasureWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless],
                                     backing: .buffered, defer: true)
        win.fixedBacking = backing
        win.isReleasedWhenClosed = false
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        win.contentView = nil
        return box.widths
    }

    /// The first line. #1345: the title, then the model and effort badges trailing (#1268's slot). Operator 2026-11-16
    /// ("Cut the name first"): the title is cut down to `badgeTitleFloor` before a badge goes; below that the model's
    /// badge goes (the effort's alone, same floor), then both, and the title alone truncates as before. #1365: on a row
    /// with a host the hidden host slot goes before any badge (both badges then end at the line's edge, not above the
    /// age); the effort step has none (it is reached only when both badges without it do not fit, and with it it is wider).
    var titleLine: some View {
        ViewThatFits(in: .horizontal) {
            titleLine(badges: true)
            titleLine(badges: true, hostSlot: false)
            titleLine(badges: true, effortOnly: true, hostSlot: false)
            titleLine(badges: false)
        }
    }

    /// #1345: the least a title beside the badges is cut to: a literal 8-character string and the "…", in the title's
    /// font at the UI scale (about 8 characters of a typical name; wide letters keep fewer, narrow ones more).
    static var badgeTitleFloor: CGFloat {
        ("abcdefgh\u{2026}" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: sz(12.5), weight: .medium)]).width
    }

    /// #1345: `badges` puts the model slot at the end (a Claude row only; `effortOnly`, the effort's badge alone), then,
    /// on a row with a host, a hidden host slot as wide as line two's, so the badges end right above the age. With the
    /// badges the title keeps `badgeTitleFloor` (ViewThatFits counts only that), so it is cut before they go. #1365:
    /// `hostSlot` false leaves the hidden host slot out.
    func titleLine(badges: Bool, effortOnly: Bool = false, hostSlot: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: sz(6)) {
            let me = modelEffort
            let withBadges = badges && row.modelSlot && (me.modelSlot || me.effortSlot)   // #1455: none shown, no slot
            let title = Text(row.title).font(Neon.font(12.5, weight: .medium))
                .foregroundStyle(row.state == nil ? ink(.quiet) : inks?.primary ?? Neon.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .modifier(AgentSidebarRowProbe(kind: "title", title: row.title))
            if withBadges {
                AgentWidthFloor(floor: Self.badgeTitleFloor) { title }.layoutPriority(1)
            } else {
                title
            }
            // #1490: with badges the "in view" glyph is drawn over the Spacer (its least sz(4) and the two sz(6) gaps are
            // sz(16), the glyph's sz(14) fits), so the slot takes no width the badges need; no badges: the slot as before.
            let inViewSlot = Image(systemName: "eye").font(Neon.font(9, weight: .semibold)).foregroundStyle(ink(.quiet))
                .frame(width: sz(14)).opacity(inView ? 1 : 0)
                .modifier(AgentSidebarRowProbe(kind: inView ? "glyph" : "slot", title: row.title))
            if AgentPaneLayout.splitsEnabled && withBadges {
                Spacer(minLength: sz(4)).overlay(alignment: .trailing) { inViewSlot.offset(x: sz(5)) }   // one column: 1 pt left of the badges
            } else {
                Spacer(minLength: sz(4))
                // #900 B2 step 4b (7.2, #828 slot rule): the "in view" glyph's slot is always laid out with
                // the gate on (hidden by opacity, never removed), so the title never moves; gate off: no slot.
                if AgentPaneLayout.splitsEnabled { inViewSlot }
            }
            if withBadges {
                HStack(spacing: sz(5)) {   // line two's spacing between the age and the host
                    modelSlotView(effortOnly: effortOnly)
                    if hostSlot, let h = row.remote?.host ?? row.host { Self.hostSlot(h).hidden() }
                }
            }
        }
    }

    /// The second line. The PR chips whole, else their count, else none: never a cut-off chip; the state text and the
    /// age slot are on every variant. #1345: the model badges are on the first line (was: a step of this ladder).
    var detailVariants: some View {
        ViewThatFits(in: .horizontal) {
            detailLine(row.prs)
            detailLine([], open: row.prCount)
            detailLine([])
        }
    }

    /// #1271: the three inks a row's text draws besides the title's primary: the quiet one (state text, counts, age, host),
    /// the accent one (the PR chips and the open-PR count) and the needs-input amber of a blocked row's state text. Over
    /// the selected row's fill (the accent at 0.14 over the sidebar) the quiet and accent inks miss 4.5:1 on several themes
    /// (the quiet one on Fern, Mint, Solar and Daylight) and the amber on every light one, so on the selected row they draw
    /// textPrimary, which clears it on all 22 (AgentRowSelectedTextTests); the glyph keeps its colour and the words stay.
    enum Ink { case quiet, blue, blocked }
    static func ink(_ ink: Ink, selected: Bool) -> Color {
        if selected { return Neon.textPrimary }
        switch ink {
        case .quiet: return Neon.textSecondary
        case .blue: return Neon.blue
        case .blocked: return amberInk
        }
    }
    /// #1452 b: this row's ink: the island's own when it passed `inks` (hover changes only its card), else `ink(_:selected:)`.
    func ink(_ k: Ink) -> Color {
        guard let inks else { return Self.ink(k, selected: selected) }
        switch k {
        case .quiet: return inks.quiet
        case .blue: return inks.blue
        case .blocked: return inks.blocked
        }
    }
    /// #1451 step b: the needs-input amber as TEXT. #FFB300 reads 1.4 to 1.6:1 on the light themes' surfaces (under the #1360
    /// 3:1 bar), so where it is under 3:1 over the theme's sidebar the same hue, darker, is drawn (#8A5A00: 4.6 to 5.4:1 over the
    /// light rows with the 0.14 wash); the dark themes read 8:1 and keep #FFB300 exactly. Fills and dots keep agentStateColor.
    static let darkAmber = Color(red: 138 / 255, green: 90 / 255, blue: 0)
    static var amberInk: Color {
        ThemeRuntime.contrastRatio(agentStateColor(.blocked), Neon.sidebar) < 3 ? darkAmber : agentStateColor(.blocked)
    }
    /// #1451: a PR chip wears the "Needs input" badge's amber (AgentStateChip: the state colour as text, at 0.14 as the fill; the
    /// badge has no stroke), in Agent Sessions rows and the island's cards. Selected (or hovered), the text is `ink`'s textPrimary.
    static func prChipInk(selected: Bool) -> Color { ink(.blocked, selected: selected) }
    static let prChipFillOpacity = 0.14
    static var prChipFill: Color { agentStateColor(.blocked).opacity(prChipFillOpacity) }
    /// #1776 (operator 2026-11-20, "it should have been borderless and the icon itself to be purle and its number, same way
    /// merges uses the colour of our theme"; replaces #1735's outline): the count groups (agents, shells) have no stroke and no
    /// fill; their glyph and number draw in their ink, as the open PRs' count draws in the theme blue. The shells' ink is white,
    /// or the theme's textPrimary where white misses 3:1 over the sidebar (the light themes); the agents' is one royal purple,
    /// the lighter #9D7BEA or the darker #7851A9, whichever contrasts more with the sidebar. Over the sidebar and the selected
    /// row each clears 3:1 on all 22 themes (AgentCountOutlineTests).
    static let purpleLight = Color(red: 0x9D / 255, green: 0x7B / 255, blue: 0xEA / 255)
    static let purpleDark = Color(red: 0x78 / 255, green: 0x51 / 255, blue: 0xA9 / 255)
    static var agentsInk: Color {
        ThemeRuntime.contrastRatio(purpleLight, Neon.sidebar) >= ThemeRuntime.contrastRatio(purpleDark, Neon.sidebar) ? purpleLight : purpleDark
    }
    static var shellsInk: Color { ThemeRuntime.contrastRatio(.white, Neon.sidebar) >= 3 ? .white : Neon.textPrimary }

    /// #1203: the model slot's width. #1268: the widest known short name and the widest effort word, each in its badge
    /// (not a model id); a longer name is cut in the middle inside its badge.
    static let modelWidest = "Sonnet 4.5"
    static let effortWidest = "medium"

    /// #1268: the effort badge's look by level, quietest to strongest, from the theme's own tokens (text, fill, fill
    /// opacity); an unknown word, and the model badge, take the neutral look. Every pair clears 4.5:1 over the sidebar
    /// on every bundled theme (AgentRowBadgeTests): a token's own 0.12 fill does not for most tokens, so the fill is
    /// quieter than the PR chips' and the strong levels keep textPrimary on an accent wash.
    typealias BadgeLook = (text: KeyPath<ThemePalette, Color>, fill: KeyPath<ThemePalette, Color>, opacity: Double)
    static var neutralLook: BadgeLook { (\ThemePalette.textSecondary, \ThemePalette.textSecondary, 0.06) }
    static func effortLook(_ effort: String?) -> BadgeLook {
        switch effort ?? "" {
        case "low": (\ThemePalette.textSecondary, \ThemePalette.blue, 0.06)
        case "medium": (\ThemePalette.textPrimary, \ThemePalette.blue, 0.12)
        case "high": (\ThemePalette.textPrimary, \ThemePalette.blue, 0.24)
        case "xhigh": (\ThemePalette.textPrimary, \ThemePalette.magenta, 0.18)
        case "max": (\ThemePalette.textPrimary, \ThemePalette.magenta, 0.32)
        default: neutralLook
        }
    }

    /// #1268: one badge: 8.5 medium (the PR chips are 9.5), padding sz(3) x sz(1), radius sz(3).
    static func badge(_ text: String, _ look: BadgeLook, palette p: ThemePalette = ThemeRuntime.palette) -> some View {
        Text(text).font(Neon.font(8.5, weight: .medium)).foregroundStyle(p[keyPath: look.text])
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, sz(3)).padding(.vertical, sz(1))
            .background(RoundedRectangle(cornerRadius: sz(3)).fill(p[keyPath: look.fill].opacity(look.opacity)))
    }

    /// #1268: which text with which look, in drawing order: the model's (neutral), then the effort's (by level); no
    /// model, none (an effort comes only with a model). On the selected row (the chip's `active: selected`) a look with
    /// the quiet text (the neutral and low ones) draws textPrimary: textSecondary misses 4.5:1 over the selected fill on
    /// 7 themes, textPrimary clears it on all 22 (AgentRowBadgeTests); fills and every other look unchanged.
    static func badges(model: String?, effort: String?, selected: Bool = false) -> [(text: String, look: BadgeLook)] {
        guard let model else { return [] }
        let all = [(text: model, look: neutralLook)] + (effort.map { [(text: $0, look: effortLook($0))] } ?? [])
        guard selected else { return all }
        return all.map { b -> (text: String, look: BadgeLook) in
            guard b.look.text == neutralLook.text else { return b }
            return (text: b.text, look: (text: \ThemePalette.textPrimary, fill: b.look.fill, opacity: b.look.opacity))
        }
    }

    /// #1203: the model and effort of the last answer, in a slot as wide as the widest pair whether or not a value is
    /// known (no size change when it arrives): the hidden widest pair sizes it, the value is drawn over it, trailing.
    /// #1268: two badges, the model's (neutral) then the effort's (tinted by level); no model, nothing drawn. The words
    /// stay the row's (modelWords): the badges are inside the row's element and add none of their own.
    var modelSlotView: some View { modelSlotView(effortOnly: false) }

    /// #1345: `effortOnly`, line one's step below the title's floor: the effort's badge alone, in a slot as wide as the
    /// widest effort word's (no size change when it arrives; none known, nothing drawn).
    func modelSlotView(effortOnly: Bool) -> some View {
        // #1455: a part hidden by Row details hands its slot back; with the model hidden the effort is drawn alone.
        let me = modelEffort, alone = effortOnly || !me.modelSlot
        return HStack(spacing: sz(3)) {
            if !alone { Self.badge(Self.modelWidest, Self.neutralLook) }
            if me.effortSlot { Self.badge(Self.effortWidest, Self.neutralLook) }
        }
        .hidden()
        .overlay(alignment: .trailing) {
            // A hidden model stands in as "" (badges draws the effort only with a model), then is dropped.
            let all = Self.badges(model: me.model ?? (me.effort == nil || me.modelSlot ? nil : ""), effort: me.effort, selected: selected)
            let shown = alone ? Array(all.dropFirst()) : all
            HStack(spacing: sz(3)) {
                // The effort badge (second) keeps its word whole before the model's name is cut.
                ForEach(shown.indices, id: \.self) { i in
                    Self.badge(shown[i].text, shown[i].look, palette: inks?.badges ?? ThemeRuntime.palette).layoutPriority(Double(i))
                }
            }
        }
        .fixedSize()
        .modifier(AgentSidebarRowProbe(kind: effortOnly ? "effort" : "badges", title: row.title))
        // At no height, as the chip's slot: the badges never change the line's height at any scale (0.7 read 1 pt).
        .frame(height: 0)
        .help("Model and effort of the last answer")
    }

    /// #1268: the age at the end of the second line, in one slot as wide as the widest age text (`ageWidest`), so
    /// nothing before it moves when it ticks; a live row keeps it with no age (working), as the first line did (#828,
    /// #829, R1115-2).
    var ageSlot: some View {
        // #1500: the font on each Text and the age an overlay of the hidden widest one: the slot's height is that text's
        // own line at the scale (it was 14 pt at every scale).
        Text(AgentIsland.ageWidest).font(Neon.font(10).monospacedDigit()).hidden()
            .overlay(alignment: .trailing) {
                Text(row.age).font(Neon.font(10).monospacedDigit()).foregroundStyle(ink(.quiet))
            }
        .fixedSize()
        .modifier(AgentSidebarRowProbe(kind: "age", title: row.title))
    }

    /// #1304: each shown chip with its own link (by position, as the accessibility actions do: two chips can share a
    /// label across owners); a "+N" or a chip with no allowlisted URL has none.
    static func chipLinks(_ chips: [String], _ links: [AgentIsland.PRChip]) -> [(text: String, link: AgentIsland.PRChip?)] {
        chips.enumerated().map { i, text in
            let link = links.indices.contains(i) && links[i].label == text && links[i].url != nil ? links[i] : nil
            return (text, link)
        }
    }

    /// #1115: the state text, the count groups (no " · ": the gap and the symbol separate them), then the PR chips,
    /// or with `open` the open PRs' count as a blue group in their place.
    /// #1268: then the age slot, trailing (live and History rows), then the host slot. #1345: the model badges are on
    /// the first line, right above the age; the ⌘<n> chip is in the row's own column.
    func detailLine(_ chips: [String], open: Int = 0) -> some View {
        HStack(spacing: sz(5)) {
            if stateShown {
                Text(row.detail).font(Neon.font(10.5))
                    .foregroundStyle(row.state == .blocked ? ink(.blocked) : ink(.quiet))
                    .lineLimit(1)
            }
            // #2002 (gap 3): the agent's symbol in the counts' quiet ink (the row's one label reads its name).
            if let k = row.agentKind {
                Image(systemName: k.symbol).font(Neon.font(9.5)).foregroundStyle(ink(.quiet)).help(k.rawValue)
                    .modifier(AgentSidebarRowProbe(kind: "agent.\(k)", title: row.title))
            }
            AgentCountGroups(counts: row.counts + (open > 0 ? [(AgentSidebar.Count.open, open)] : []), size: 10.5,
                             quiet: ink(.quiet), open: ink(.blue), tinted: true, ownCard: inks != nil, selected: selected,
                             help: row.countHelp)
            ForEach(Array(Self.chipLinks(chips, row.prLinks).enumerated()), id: \.offset) { _, entry in
                let pr = entry.text
                let chip = Text(pr).font(Neon.font(9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(inks?.blocked ?? Self.prChipInk(selected: selected))
                    .padding(.horizontal, sz(4)).padding(.vertical, sz(1))
                    .background(RoundedRectangle(cornerRadius: sz(3)).fill(Self.prChipFill))
                    .fixedSize()
                // #1289 (G5): a chip whose URL passed the allowlist is a button (the island's help); else text, as before.
                if let link = entry.link {
                    Button { model?.openPR(link) } label: { chip }
                        .buttonStyle(.plain).help(link.help).accessibilityLabel(AgentWindowControls.openPRLabel(link))
                } else {
                    chip
                }
            }
            Spacer(minLength: 0)
            if ageShown && (!row.age.isEmpty || row.state != nil) { ageSlot }
            if let h = row.remote?.host ?? row.host { Self.hostSlot(h, ink: ink(.quiet)) }   // #1324: a remote History row's too
        }
    }

    /// #836 (a): the host label, in a slot of one fixed width on every remote row, so a longer host never moves the
    /// line and a row's width never flickers; a long name is cut in the middle.
    static let hostWidth: CGFloat = 84
    /// #1330 (R836-q2): a host from dch is outside text: shown through OutsideText.shown; argv and keys keep it raw.
    static func hostLabel(_ host: String) -> String { OutsideText.shown(host) }
    static func hostSlot(_ host: String, ink: Color = AgentSidebarRowView.ink(.quiet, selected: false)) -> some View {
        Text(hostLabel(host)).font(Neon.font(10, weight: .medium)).foregroundStyle(ink)
            .lineLimit(1).truncationMode(.middle)
            .frame(width: sz(hostWidth), alignment: .trailing)
            .help("On \(hostLabel(host))")
    }
}

/// #1476: every pane header's X-ray button, just before the "...": open, the accent on a subtle fill and read as
/// selected; off (dimmed, the tooltip says why) where the "..." has no X-ray item. One slot in every state.
struct AgentXrayButton: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var panels = XrayPanels.shared
    let pane: UUID
    let target: XrayTarget?

    static let label = "X-ray"
    static let help = "X-ray (\u{21E7}\u{2318}X)"
    static let noDch = "X-ray needs dch 1.78 or later"
    static let noSession = "No session to X-ray in this pane"
    static var width: CGFloat { sz(22) }

    /// Why the button is off, nil when on: AgentsNSWindow.xrayItem's rule (the gate, then a session).
    @MainActor static func offReason(_ target: XrayTarget?) -> String? {
        XrayPanels.dch() == nil ? noDch : target == nil ? noSession : nil
    }

    /// The drawer is open for this pane on the session it shows (what XrayDrawer draws).
    var open: Bool { target != nil && panels.open[pane]?.target == target }

    var body: some View {
        let on = open, off = Self.offReason(target)
        Button { AgentsNSWindow.xrayClicked(pane: pane, in: AgentsNSWindow.window(of: pane)) } label: {
            Image(systemName: "sidebar.right").font(Neon.font(11, weight: .medium))
                .foregroundStyle(on ? Neon.blue : Neon.textSecondary)
                .frame(width: Self.width, height: sz(18))
                .background(RoundedRectangle(cornerRadius: sz(4)).fill(on ? Neon.blue.opacity(0.2) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: Self.width, height: sz(18))
        .disabled(off != nil).opacity(off == nil ? 1 : 0.45)
        .help(off ?? Self.help)
        .accessibilityLabel(Self.label)
        .accessibilityValue(off ?? "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// #836 (b): a remote session's header: its title and host, then the transcript controls drawn disabled with their
/// reason (a remote session has no transcript or todo list here).
struct AgentRemoteHeader: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let row: AgentSidebar.Row
    let remote: AgentSidebar.Remote

    static let todosReason = "No task list on that host"
    static let todosOpens = "Open the task list in X-ray"
    let pane: UUID
    /// #1513: the title is the pane's session switcher (a remote pick arms the attach); nil: a plain title.
    let switcher: AgentPaneSwitch?
    /// The row whose last chip click found no Tasks tab (a click on another session starts clean).
    @State private var none: AgentSidebar.RowID? = nil

    /// #1476: rows build the header too (the private @State keeps the memberwise init in this file).
    init(row: AgentSidebar.Row, remote: AgentSidebar.Remote, pane: UUID, switcher: AgentPaneSwitch? = nil) {
        self.row = row
        self.remote = remote
        self.pane = pane
        self.switcher = switcher
    }

    static func todosHelp(noList: Bool) -> String { noList ? todosReason : todosOpens }

    /// The chip's click: X-ray on Tasks as the local chip does; no list to fall back to, so `none` runs when X-ray is off
    /// or the read finds no Tasks tab.
    /// `clear` runs first: a reason from an earlier click must not outlive a click that finds the tab (#1398).
    @MainActor static func todosTapped(in win: AgentsNSWindow?, clear: () -> Void, none: @escaping () -> Void) {
        clear()
        win?.todosChipTapped(listOpen: false, list: none)
    }

    var body: some View {
        HStack(alignment: .center, spacing: sz(8)) {
            let text = Text(row.title).font(Neon.font(15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            if let switcher {   // #1513: the host stays its own text beside it, so the tooltip is the title and the hint
                AgentPaneSwitcherButton(text: text, size: 15, title: row.title, project: nil, help: row.title, switcher: switcher)
            } else { text }
            Text(AgentSidebarRowView.hostLabel(remote.host)).font(Neon.font(11, weight: .medium)).foregroundStyle(Neon.textSecondary).lineLimit(1)
            Spacer(minLength: sz(4))
            let noList = none == row.id
            Button { Self.todosTapped(in: AgentsNSWindow.window(of: pane), clear: { none = nil }) { none = row.id } } label: {
                Image(systemName: "checklist").font(Neon.font(11)).foregroundStyle(Neon.textSecondary).opacity(noList ? 0.45 : 1)
            }
            .buttonStyle(.plain).help(Self.todosHelp(noList: noList)).accessibilityLabel(Self.todosOpens)
            .accessibilityValue(noList ? Self.todosReason : "")
            .background(XrayCardAnchor())   // #1401: window(of: pane) finds this window, and the X-ray card hangs from the chip
            AgentXrayButton(pane: pane, target: XrayTarget.of(row))   // #1476: where the disabled mode toggle was (no "..." here)
        }
        .padding(.horizontal, sz(16)).padding(.vertical, sz(10))
        .contentShape(Rectangle())   // #1914: a layout pane drags from the header's gap too
    }
}

/// #1115: a session's count groups (the sidebar row and the header): symbol plus number, a wider gap between groups.
/// Each reads its words as help and to VoiceOver; the open PRs' group wears the chips' blue. Never cut (fixedSize).
struct AgentCountGroups: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let counts: [(AgentSidebar.Count, Int)]
    let size: CGFloat
    /// #1271: the inks of the other groups and of the open PRs' group (the selected sidebar row's, see `AgentSidebarRowView.ink`).
    var quiet = Neon.textSecondary
    var open = Neon.blue
    /// #1776: the agents and shells groups draw their glyph and number in their own ink (`tint`), no stroke, no fill; false: `quiet` (the header).
    var tinted = false
    /// #1739: drawn on the island's own dark card (Follow theme off): white shells and #9D7BEA agents inks, whatever the theme (the sidebar's choice is made against Neon.sidebar).
    var ownCard = false
    /// #1789: the row is the selected one (the accent at 0.14 over the sidebar): the digits' ink is held to 4.5:1 over it.
    var selected = false
    /// #1558: a group's help in place of its words (the shells group's list); VoiceOver keeps the words.
    var help: [AgentSidebar.Count: String] = [:]

    /// #1739, #1776: the ink of a group's glyph and number (nil: the caller's), chosen against the surface the row draws on.
    static func tint(_ c: AgentSidebar.Count, ownCard: Bool) -> Color? {
        switch c {
        case .agents: return ownCard ? AgentSidebarRowView.purpleLight : AgentSidebarRowView.agentsInk
        case .shells: return ownCard ? .white : AgentSidebarRowView.shellsInk
        default: return nil
        }
    }

    /// #1789 (QA n105, WCAG 1.4.3): the digits are text, so they need 4.5:1 over the row (the sidebar, or the selected wash: the accent
    /// at 0.14 over it); where the glyph's `tint` misses it they draw the theme's textPrimary, as the merges count does. The glyph keeps `tint` (3:1).
    static func digitInk(_ tint: Color?, selected: Bool, ownCard: Bool) -> Color? {
        guard let tint, !ownCard else { return tint }
        digitInkComputations += 1
        func rgb(_ c: Color) -> [Double] {
            let n = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
            return [Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent)]
        }
        let side = rgb(Neon.sidebar), accent = rgb(Neon.blue)
        let m = selected ? zip(side, accent).map { $0 * 0.86 + $1 * 0.14 } : side
        let row = Color(red: m[0], green: m[1], blue: m[2])
        return ThemeRuntime.contrastRatio(tint, row) >= 4.5 ? tint : Neon.textPrimary
    }

    /// #1795: (group, selected) -> digits ink, filled by `cachedDigitInk` and emptied on every palette or Increase Contrast change
    /// (`ThemeRuntime.refreshContrastTokens`), so the two NSColor conversions and the contrast run once per theme, not per row body.
    /// Only the sidebar (ownCard false) reaches it: the card's ink is the tint itself, no work.
    nonisolated(unsafe) static var digitInkCache: [String: Color] = [:]
    /// #1795: test-only counter of real `digitInk` computations (a plain increment in the product).
    nonisolated(unsafe) static var digitInkComputations = 0
    static func cachedDigitInk(_ c: AgentSidebar.Count, tint: Color?, selected: Bool, ownCard: Bool) -> Color? {
        guard let tint, !ownCard else { return tint }
        let key = "\(c)-\(selected)"
        if let hit = digitInkCache[key] { return hit }
        let ink = digitInk(tint, selected: selected, ownCard: ownCard)
        digitInkCache[key] = ink
        return ink
    }

    /// #1795: test-only hook, nil in the product: reports the digits' ink each group draws (the wiring of `selected` from the row).
    @MainActor static var digitProbe: ((AgentSidebar.Count, Color?) -> Void)?

    /// #1745: test-only hook, nil in the product (one nil check per group): reports the tint each group draws, so a row proves the wiring from the caller's `ownCard`.
    @MainActor static var tintProbe: ((AgentSidebar.Count, Color?) -> Void)?

    var body: some View {
        if !counts.isEmpty {   // no empty slot in the caller's HStack (it would add a spacing)
            HStack(spacing: sz(6)) {
                ForEach(Array(counts.enumerated()), id: \.offset) { _, g in
                    let tint = tinted ? Self.tint(g.0, ownCard: ownCard) : nil
                    let _ = Self.tintProbe?(g.0, tint)
                    let digits = g.0 == .open ? open : Self.cachedDigitInk(g.0, tint: tint, selected: selected, ownCard: ownCard) ?? quiet
                    let _ = Self.digitProbe?(g.0, digits)
                    HStack(spacing: sz(2)) {
                        // #1453, #1546: the sub-agents count is the drawn robot, not .agents' people symbol; the words stay the label below.
                        if g.0 == .agents { RobotGlyph(size: size - 1) } else { Image(systemName: g.0.symbol).font(Neon.font(size - 1)) }
                        Text(AgentIsland.count(g.1)).font(Neon.font(size).monospacedDigit())
                            .foregroundStyle(digits)
                    }
                    .modifier(AgentSidebarRowProbe(kind: "count.\(g.0)", title: g.0.words(g.1)))
                    .foregroundStyle(g.0 == .open ? open : tint ?? quiet)
                    .fixedSize()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(g.0.words(g.1))
                    .help(help[g.0] ?? g.0.words(g.1))   // after the element: a help set on an ignored child never reaches AX
                }
            }
        }
    }
}

/// The sidebar with no session and no record. #887 (QA #747 INFO-7): + and ⌘N are named only while they work.
struct AgentNoSessionsState: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var store: AgentIslandStore

    var body: some View {
        AgentEmptyState(icon: "terminal", title: "No agent sessions", detail: detail)
    }

    /// #1096 4: what the body shows, from the store's gate now.
    var detail: String { Self.detail(canStart: store.resumeGate.isOK) }

    static func detail(canStart: Bool) -> String {
        "Sessions started with dch show up here." + (canStart ? " Press + or ⌘N to start one." : "")
    }
}

struct AgentEmptyState<Extra: View>: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let icon: String
    let title: String
    let detail: String
    /// #847: under the detail (the detail pane's New session pill).
    @ViewBuilder var extra: Extra
    var body: some View {
        VStack(spacing: sz(8)) {
            Image(systemName: icon).font(Neon.font(22)).foregroundStyle(Neon.textSecondary)
            Text(title).font(Neon.font(13, weight: .semibold)).foregroundStyle(Neon.textPrimary)
            Text(detail).font(Neon.font(11)).foregroundStyle(Neon.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            extra
        }
        .padding(sz(20))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension AgentEmptyState where Extra == EmptyView {
    init(icon: String, title: String, detail: String) { self.init(icon: icon, title: title, detail: detail) { EmptyView() } }
}

struct AgentDetailView: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var model: AgentWindowModel
    @ObservedObject var transcript: AgentTranscriptModel
    /// False for offscreen evidence (no ScrollView).
    var scrolls = true
    /// #831 B1 step 4 (9.2): more than one pane shown: the one-line header (one pane: the full header).
    var compact = false

    /// QA #668 F1: the input box's lock store; nil for an ended session's held row (the plain, ended pane).
    var inputStore: AgentIslandStore? { model.focusedEnded ? nil : model.store }

    var body: some View {
        if model.launchKey != nil {
            // #2058: a local Start's own terminal from the click (blank until the agent draws); the form waits unseen.
            AgentTerminalPane(controller: model.terminal, open: {})
                .frame(minHeight: 0, maxHeight: .infinity)
                .modifier(AgentPaneProbe(kind: "terminal"))
        } else if let form = model.newSession {
            // #847: the form in place of the pane's content (the selected session's terminal detaches meanwhile).
            // D5.4: a short window scrolls the form instead of clipping Start.
            if scrolls {
                // #1731: the viewport's height is the content's minimum, so the form is centred when it fits (the ScrollView
                // gives it its own height, which #1479's outer frame cannot centre) and starts at the top and scrolls when not.
                GeometryReader { geo in
                    ScrollView(.vertical) {
                        AgentNewSessionView(model: model, form: form).frame(minHeight: geo.size.height, alignment: .center)
                    }
                }
            } else {
                AgentNewSessionView(model: model, form: form)
            }
        } else if let row = model.selectedRow, let s = row.session {
            // QA #668 F1: an ended session's held row is display-only.
            let ended = model.focusedEnded
            VStack(spacing: 0) {
                let id = model.layout.focused
                header(row, s)
                Rectangle().fill(Neon.stroke).frame(height: 1)
                VStack(spacing: 0) {
                    // #1477: gate on, an Ended pane's terminal keeps its last frame under the Ended chip and card
                    // #1471: Terminal is the only mode; an Ended pane without its kept frame shows the ended card
                    if !ended || model.keptFrame(id) != nil {
                        terminalPane(row, s)
                    } else {
                        AgentTerminalCard(icon: "stop.circle", text: "Session ended")
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Neon.bgBottom)
                            .overlay(alignment: .top) { overTop(row, s) }
                    }
                }
                // #1351: over, never resizing; #2055: docked, beside. #1476: several panes: the window's one drawer (AgentPaneArea) instead.
                .modifier(XrayDock(pane: id, target: XrayTarget.of(row)) { _ in !compact })
            }
        } else if let row = model.selectedRow, let r = row.remote {
            // #836 (b): another machine's session: Terminal only, under a header whose transcript controls are off.
            VStack(spacing: 0) {
                AgentRemoteHeader(row: row, remote: r, pane: model.layout.focused,
                                  switcher: AgentPaneSwitch(model: model, pane: model.layout.focused, detail: true)).modifier(AgentPaneProbe(kind: "header"))
                Rectangle().fill(Neon.stroke).frame(height: 1)
                AgentTerminalPane(controller: model.terminal, open: {})
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .modifier(AgentPaneProbe(kind: "terminal"))
                    .overlay(alignment: .top) { XrayRecapStrip(pane: model.layout.focused, target: XrayTarget.of(row)) }   // #1625
                    .modifier(XrayDock(pane: model.layout.focused, target: XrayTarget.of(row)) { _ in !compact })   // #2055
            }
        } else if let row = model.selectedRow, let r = row.record {
            titled(row.title) {
                AgentHistoryDetail(row: row, record: r, store: model.store,
                                   refusal: model.refusalText(row.id) ?? model.remoteResumeText[r.id],
                                   act: { model.actInPane($0, r) },   // #1924: its Resume follows the session
                                   close: AgentPanePlaceholder.close(model, pane: model.layout.focused))   // #1906
                    // #900 6b2d: the refusal line waits while a question is open; #1930: the question is the pane area's card.
                    .overlay(alignment: .top) { if model.confirming == nil { paneRefusalLine } }
            }
        } else if let title = AgentPanePlaceholder.title(model.content) {
            // 4.2 (QA 956 R1217-a): a pane that holds a target whose session is gone says so by name; the list (and Pick
            // Another) still picks another session into it. Same slot as the empty pane's below.
            let pane = model.layout.focused
            titled(title) {
                AgentPanePlaceholder(title: title, close: AgentPanePlaceholder.close(model, pane: pane),
                                     pick: { model.pickAnother(pane) })
                    .overlay(alignment: .top) { paneRefusalLine }
            }
        } else {
            titled("", drag: model.paneDragToken(model.layout.focused)) { emptyPane.overlay(alignment: .top) { paneRefusalLine } }   // #1927
        }
    }

    /// 9.2: with several panes, every content keeps the one-line header's height above it (table 4.2: only the body
    /// swaps); one pane: the body alone, as before.
    /// #1927: `drag`, an empty pane's drag token (its header drags the pane as a session pane's does).
    @ViewBuilder func titled<B: View>(_ title: String, drag: String? = nil, @ViewBuilder _ body: () -> B) -> some View {
        if compact {
            VStack(spacing: 0) {
                AgentCompactHeader(title: title).modifier(AgentPaneProbe(kind: "header")).modifier(AgentRowDrag(token: drag))
                Rectangle().fill(Neon.stroke).frame(height: 1)
                body()
            }
        } else {
            body()
        }
    }

    /// No target: today's state (the hint and the New session pill, #847); #1658: with several panes, Close Pane first.
    var emptyPane: some View {
            AgentPanePlaceholder.emptyCard(model, pane: model.layout.focused)   // #1928: the unfocused pane's card too
    }

    /// #822 (spec 5.4): the terminal to the window's bottom, no prompt panel or input box (the terminal
    /// is both). The notice, the question and the todo list float over its top, so nothing that
    /// changes with state ever resizes it.
    func terminalPane(_ row: AgentSidebar.Row, _ s: AgentSession) -> some View {
        AgentTerminalPane(controller: model.terminal, open: { model.openSelected() })
            .frame(minHeight: 0, maxHeight: .infinity)
            .modifier(AgentPaneProbe(kind: "terminal"))   // tests only: the terminal's own frame, before the overlay (nil probe: nothing)
            .overlay(alignment: .top) { terminalOverTop(row, s) }
    }

    /// The focused session's header: one-line with several panes, else the full one. #1645: AgentPaneTerminalColumn
    /// draws it too.
    @ViewBuilder func header(_ row: AgentSidebar.Row, _ s: AgentSession) -> some View {
        // #900 B2 step 6a: the "⋯" pane items act on this pane (the focused one); empty with the gate off.
        let id = model.layout.focused, ended = model.focusedEnded, keyPanes = model.layout.panes.count   // #1916
        let panes = [.divider] + [AgentsNSWindow.xrayItem(model)].compactMap { $0 }
            + AgentWindowControls.paneMenu(model, pane: id) + AgentWindowControls.swapMenu(model, pane: id)   // #1895
        Group {
            if compact {
                AgentCompactHeader.of(row, s, cwd: transcript.cwd, ended: ended, store: model.store,
                                      ask: { model.ask($0, s) }, open: { model.openSelected() }, panes: panes,
                                      pane: { AgentWindowControls.runPane($0, pane: id, in: model) }, keyPanes: keyPanes,
                                      xrayPane: id, switcher: AgentPaneSwitch(model: model, pane: id, detail: true))   // #1491
            } else {
                AgentSessionHeader(row: row, session: s, cwd: transcript.cwd, open: { model.openSelected() },
                                   todos: transcript.todos,
                                   todosOpen: todosChip(floatingTodos),
                                   store: model.store, ask: { model.ask($0, s) }, ended: ended,
                                   rename: ended ? nil : model.renameEdit.flatMap { $0.key == s.key ? $0 : nil },
                                   endRename: { model.endRename($0, $1) }, panes: panes,
                                   pane: { AgentWindowControls.runPane($0, pane: id, in: model) }, keyPanes: keyPanes,
                                   xrayPane: id, switcher: AgentPaneSwitch(model: model, pane: id, detail: true))   // #1491
            }
        }
        .modifier(AgentPaneProbe(kind: "header"))
    }

    /// What floats over the focused session's terminal top: the notice, the question, the recap strip, the unsent
    /// first message, the todo list. #1645: AgentPaneTerminalColumn draws it too.
    func terminalOverTop(_ row: AgentSidebar.Row, _ s: AgentSession) -> some View {
        VStack(spacing: 0) {
            overTop(row, s)
            XrayRecapStrip(pane: model.layout.focused, target: XrayTarget.of(row))   // #1625
            if let u = model.unsentFirst, u.key == s.key, !model.focusedEnded {
                AgentUnsentFirstHost(model: model, terminal: model.terminal)
            }
            if transcript.todosOpen, let todos = transcript.todos {
                AgentTodosList(todos: todos)
                    .padding(.horizontal, sz(16)).padding(.bottom, sz(8))
                    .background(Neon.card)
                    .overlay(alignment: .bottom) { Rectangle().fill(Neon.stroke).frame(height: 1) }
            }
        }
    }

    /// #900 B2 step 6b2c (R900-6b1-4, 3.3, 224): a refused split's notice (a fixed product string) belongs to the focused
    /// pane, the one this view draws; it wins over the window's refusal and the store's notice in the same slot. Gate on
    /// only: a refusal left from before the gate went off draws nothing. Gone when the model clears it (no timer).
    var paneRefusalText: String? { AgentPaneLayout.splitsEnabled ? model.paneRefusal?.notice : nil }

    /// The notice slot of a pane content with no session (History, the 4.2 placeholder, the empty pane): a top overlay,
    /// so nothing moves. The key is never read (the refusal is set, so the store's notice is not asked).
    @ViewBuilder var paneRefusalLine: some View {
        if let store = model.store, let text = paneRefusalText {
            AgentNoticeLine(store: store, key: AgentSessionKey(dir: "", name: ""), refusal: text)
        }
    }

    func overTop(_ row: AgentSidebar.Row, _ s: AgentSession) -> some View {
        VStack(spacing: 0) {
            if let store = model.store {
                AgentNoticeLine(store: store, key: s.key, refusal: paneRefusalText ?? model.refusalText(row.id),
                                open: { model.openSelected() }, ended: model.focusedEnded)
            }
        }
    }

    /// #1351 (Q3): the Todos chip's binding: opening goes to the X-ray panel on Tasks when it can (todosChipTapped).
    /// Whether the list is open is read from the transcript model in both modes: Terminal mode's floatingTodos getter is
    /// always false and its setter toggles, so neither its value nor `v` says open or closed there. `win`: rows pass theirs.
    func todosChip(_ list: Binding<Bool>, in win: AgentsNSWindow? = nil) -> Binding<Bool> {
        let pane = model.layout.focused
        return Binding(get: { list.wrappedValue }, set: { [transcript] v in
            let apply = { list.wrappedValue = v }
            guard v, !transcript.todosOpen, let win = win ?? AgentsNSWindow.window(of: pane) else { return apply() }   // a close: never X-ray
            win.todosChipTapped(listOpen: false, list: apply)
        })
    }

    /// Terminal mode: the header's todo chip opens the list over the terminal, never inside the header
    /// (the header keeps its height, the terminal its grid).
    var floatingTodos: Binding<Bool> {
        Binding(get: { false }, set: { [transcript] _ in transcript.todosOpen.toggle() })
    }

}

// MARK: - #831 B1 step 5b: the band (9.1)

/// The band's coordinate space (AgentWindowBand.probe frames are in it).
let agentBandSpace = "agentWindowBand"

/// #831 9.1: the window-level band over the pane area, one row of 30·s whatever the number of panes, shown only while
/// the split gate is on (`shown`; #1224: off, the window is the parent's and the header draws the picker). Slots, left to
/// right: the layout slot (empty before the Layouts section) and the chip slot (zoom and too small: `chip`), the
/// All slot (its room kept, empty until phase C: no control, no text, no accessibility element). #1471 b: the detail
/// level picker is gone with the transcript. Fixed slots: each slot's size comes from the UI scale alone. A narrow band
/// gives way in `Tier` order: the chip slot first, then the layout slot; the All slot never goes.
struct AgentWindowBand: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var model: AgentWindowModel
    /// #900 B2 step 3: the pane area under the band (the root's geometry); nil: the model's paneArea.
    var area: CGRect?
    /// Tests only: (slot, frame in the band) as "layout", "chip", "all", "picker" and "band" are laid out. Main actor
    /// (SwiftUI calls it from layout).
    static var probe: ((String, CGRect) -> Void)?

    /// The one gate for the band (#1224): the window's content, AgentWindowModel.paneAreaFrame and the session header's
    /// picker all read it. Off (the product, the split gate's default): no band, the parent's window. Read at layout
    /// time, not observed: a flip shows at the next build of the view, as the split gate does.
    @MainActor static var shown: Bool { AgentPaneLayout.splitsEnabled }
    /// #1538 (operator 2026-11-18: "also a lot of empty space in the top?"): the band takes its height only when it has
    /// something to show: two panes or more (the zoom and too-small chip; #1646: a saved layout alone no more, its
    /// name and Edit left the band), or the hidden sidebar's show glyph (Full and Mini; Slide has its hover edge,
    /// and its slide-in must not move the panes). Else no band at all, as with the gate off. One rule for the view, the
    /// sidebar's top padding, the Slide hover area and AgentWindowModel.paneAreaFrame.
    /// #1697 (operator 2026-11-20, "empty row on layouts"): two panes alone left the band empty above the pane headers;
    /// it shows for the chip's words only (zoomed, or too small; #1698: the tier is measured without its own band). Both are
    /// published, so the root redraws when either flips.
    @MainActor static func shows(_ m: AgentWindowModel) -> Bool {
        shown && (m.paneTooSmall || showsBesidesTier(m))
    }
    /// #1698: the band's reasons other than the too-small tier (the zoom's chip, the hidden sidebar's glyph).
    @MainActor static func showsBesidesTier(_ m: AgentWindowModel) -> Bool {
        (m.layout.zoomed != nil && m.layout.panes.count >= 2) || (m.sidebarMode != .slide && !m.sidebarShown)
    }
    static var height: CGFloat { sz(30) }
    /// shortcut: fixed widths for slots that draw nothing before B2/B3/C; the phase that fills one sizes it to its widest.
    static var layoutWidth: CGFloat { sz(100) }
    static var allWidth: CGFloat { sz(140) }
    /// #900 B2 step 4: the show-sidebar glyph's square slot.
    static var sidebarWidth: CGFloat { sz(22) }
    /// 3.4's chip at the 6-pane cap: the chip slot's widest variant.
    static let chipWidest = "5 panes hidden, window too small"

    /// Widest first, so ViewThatFits takes the first that fits: the order in which the slots give way.
    enum Tier: CaseIterable { case full, noChip, noLayout }

    /// 7.4 / 3.4 (#900 B2 step 3): the chip slot's words for the pane area `area`. Zoomed (the view draws one pane over a
    /// tiling of more): "Zoomed · i of n", i the zoomed pane's place in tree order. Else too small: "k panes hidden,
    /// window too small". nil otherwise, and always with the split gate off (15.0: a decoded multi-pane layout shows its
    /// focused pane with no chip). Both: the zoom's words (the zoomed pane is the focused one, drawn the same).
    @MainActor static func chip(_ m: AgentWindowModel, in area: CGRect) -> String? {
        let order = m.layout.order
        guard shown, order.count > 1 else { return nil }
        if let z = m.layout.zoomed, m.shownPanes == [z], let i = order.firstIndex(of: z) {
            return "Zoomed · \(i + 1) of \(order.count)"
        }
        let hidden = order.count - m.paneFrames(in: area).count
        return hidden > 0 ? "\(hidden) \(hidden == 1 ? "pane" : "panes") hidden, window too small" : nil
    }

    var body: some View {
        let chip = Self.chip(model, in: area ?? model.paneArea)
        ViewThatFits(in: .horizontal) {
            line(.full, chip: chip)
            line(.noChip, chip: chip)
            line(.noLayout, chip: chip)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .modifier(AgentBandProbe(kind: "band"))
        .coordinateSpace(.named(agentBandSpace))
    }

    /// The layout slot: its fixed empty room in the wide tiers. #1646 (operator 2026-11-19): the layout name and Edit layout
    /// / Done left the band (#1895: no edit mode at all), so a layout alone never shows the band.
    @ViewBuilder func layoutSlotView(_ t: Tier) -> some View {
        if t == .full || t == .noChip {
            Color.clear.frame(width: Self.layoutWidth).accessibilityHidden(true).modifier(AgentBandProbe(kind: "layout"))
        }
    }

    func line(_ t: Tier, chip: String?) -> some View {
        HStack(spacing: sz(8)) {
            // Slots that give way are left out of the stack, never zero-width (a zero-width child still takes a spacing).
            layoutSlotView(t)
            if t == .full {
                Text(Self.chipWidest).font(Neon.font(11)).lineLimit(1).fixedSize().hidden().accessibilityHidden(true)
                    // #900 B2 step 3: the words over the widest variant's room: the slot never changes a frame.
                    .overlay(alignment: .leading) {
                        if let chip { Text(chip).font(Neon.font(11)).foregroundStyle(Neon.textSecondary).lineLimit(1) }
                    }
                    .modifier(AgentBandProbe(kind: "chip"))
            }
            Spacer(minLength: 0)
            // #900 B2 step 4 (7.2): shows the sidebar again. The slot is laid out in every tier and state; while the
            // sidebar is shown the button is invisible, disabled and not read (hidden, never removed: no frame moves).
            Button { model.toggleSidebar() } label: {   // the action runs on the main actor (a SwiftUI button's)
                Image(systemName: "sidebar.left").font(Neon.font(12)).foregroundStyle(Neon.textSecondary)
                    .frame(width: Self.sidebarWidth, height: Self.sidebarWidth).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: Self.sidebarWidth, height: Self.sidebarWidth)
            .accessibilityLabel("Show sidebar").help(model.sidebarShown ? "" : "Show sidebar (⌃⌘S)")   // no tooltip over the empty slot
            .opacity(model.sidebarShown ? 0 : 1).disabled(model.sidebarShown).accessibilityHidden(model.sidebarShown)
            .modifier(AgentBandProbe(kind: "sidebar"))
            Color.clear.frame(width: Self.allWidth).accessibilityHidden(true).modifier(AgentBandProbe(kind: "all"))
        }
        .padding(.horizontal, sz(16))
        .frame(maxWidth: .infinity)   // the ideal width still decides the tier; the taken line spans the band
    }
}

/// Tests: a band part's frame in the band, through `AgentWindowBand.probe` (nil in the product). Main actor.
struct AgentBandProbe: ViewModifier {
    let kind: String
    @ViewBuilder func body(content: Content) -> some View {
        if AgentWindowBand.probe != nil {   // R900-4b-2: no observer while the probe is nil
            content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(agentBandSpace)) }) { r in
                agentProbeCalled()
                AgentWindowBand.probe?(kind, r)
            }
        } else {
            content
        }
    }
}

// MARK: - #831 B1 step 4: the pane area (view A)

/// The pane area's coordinate space (pane frames are the model's, in it).
let agentPaneAreaSpace = "agentPaneArea"

private struct AgentComposerTwoLinesKey: EnvironmentKey { static let defaultValue = false }
private struct AgentPaneIDKey: EnvironmentKey { static let defaultValue: UUID? = nil }
private struct AgentPaneModelKey: EnvironmentKey { static let defaultValue: AgentWindowModel? = nil }

extension EnvironmentValues {
    /// 5.1: more than one row of panes is shown: the composer row is 44·s.
    var agentComposerTwoLines: Bool {
        get { self[AgentComposerTwoLinesKey.self] }
        set { self[AgentComposerTwoLinesKey.self] = newValue }
    }
    /// The pane a view is drawn in (AgentPaneProbe).
    var agentPaneID: UUID? {
        get { self[AgentPaneIDKey.self] }
        set { self[AgentPaneIDKey.self] = newValue }
    }
    /// #1492 (QA m1): the window model of the pane a view is drawn in, for a terminal's row drop; nil outside a pane.
    var agentPaneModel: AgentWindowModel? {
        get { self[AgentPaneModelKey.self] }
        set { self[AgentPaneModelKey.self] = newValue }
    }
}

/// Tests: a pane part's frame in the pane area, by pane, through `AgentPaneArea.probe` (nil in the product). The action
/// runs on the main actor (SwiftUI calls it from layout).
struct AgentPaneProbe: ViewModifier {
    let kind: String
    @Environment(\.agentPaneID) private var pane
    @ViewBuilder func body(content: Content) -> some View {
        if AgentPaneArea.probe != nil {   // R900-4b-2: no observer while the probe is nil
            content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(agentPaneAreaSpace)) }) { r in
                agentProbeCalled()
                if let pane { AgentPaneArea.probe?(kind, pane, r) }
            }
        } else {
            content
        }
    }
}

/// #831 B1 step 4 (spec 4.2, 5.1, 9.2, R1193-4): the pane area. One pane view per entry of the model's frames, at its
/// frame (the model tiles; this view only places); its size is the model's `paneArea`. Split gate off (15.0): the
/// focused pane alone at the whole area, so a person sees the one-pane window. More than one pane shown: the compact
/// headers (9.2); more than one row of panes: the 44·s composer row (5.1). A layout property, never focus or state.
struct AgentPaneArea: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var model: AgentWindowModel
    var scrolls = true
    /// Tests only: (part, pane, frame in the area) as "pane", "header" and "composer" are laid out.
    static var probe: ((String, UUID, CGRect) -> Void)?
    /// R900-5a-2, pure: the resize cursor of a divider: left-right for columns (a vertical line), up-down for rows.
    static func cursor(_ axis: PaneNode.Axis) -> NSCursor { axis == .columns ? .resizeLeftRight : .resizeUpDown }
    /// #2055: more than one pane in the whole area (the drawer's room included, so docking never flips it).
    @MainActor static func compact(_ m: AgentWindowModel, _ size: CGSize) -> Bool { drawn(m, in: CGRect(origin: .zero, size: size)).count > 1 }

    var body: some View {
        XrayDockGeometry { proxy, dockInset in   // #2055: a GeometryReader that also reads the room the drawer took
            let area = CGRect(origin: .zero, size: proxy.size)
            let frames = Self.drawn(model, in: area)
            let compact = Self.compact(model, CGSize(width: proxy.size.width + dockInset, height: proxy.size.height))
            let twoLines = Set(frames.values.map { ($0.minY * 1000).rounded() }).count > 1
            let ids = model.layout.order.filter { frames[$0] != nil }
            ZStack(alignment: .topLeading) {
                ForEach(ids, id: \.self) { id in
                    let f = frames[id] ?? .zero
                    let label: String? = compact ? "\(title(id)), pane \((ids.firstIndex(of: id) ?? 0) + 1) of \(ids.count)" : nil
                    pane(id, compact: compact)
                        .frame(width: f.width, height: f.height)
                        .clipped()
                        // 7.5: the line on an edge shared with a neighbour is an overlay, never padding: the pane keeps its frame.
                        .overlay(alignment: .topLeading) { edge(f) }
                        // 7.6: the focus border or the dim, an overlay too (fixed slots: nothing moves when focus does).
                        .overlay { mark(id, compact: compact) }
                        // #901 B3 step 5 (section 10): an unfocused pane's blocked session: the 3·s top-edge bar.
                        .overlay(alignment: .top) { attentionBar(id, compact: compact) }
                        // #1492: a sidebar row dragged over the pane: the zone it would take; the drop goes to the model.
                        .overlay(alignment: .topLeading) { dropMark(id, f.size) }
                        // #1927: the whole pane takes the drop; SwiftUI hit-tests only what is drawn, so an empty pane's
                        // blank edge bands took none (a session pane's terminal takes its own, AgentTerminalHostView)
                        .contentShape(Rectangle())
                        .onDrop(of: [.agentRow], delegate: AgentPaneDropDelegate(model: model, pane: id, size: f.size))
                        // 13: more than one pane shown: each pane one container, "<title>, pane i of n".
                        .modifier(AgentPaneContainer(label: label))
                        .modifier(AgentPaneProbe(kind: "pane"))
                        .environment(\.agentPaneID, id)
                        .environment(\.agentPaneModel, model)   // #1492 (QA m1): the terminal's own row drop
                        .environment(\.agentComposerTwoLines, twoLines)
                        .position(x: f.midX, y: f.midY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            // #900 B2 step 5a (7.5): the resize cursor over each divider's 6·s hit area, an overlay (nothing inserted or
            // resized; none with the gate off). The 1 pt line is each pane's `edge`; the window routes the clicks.
            // Step 5b (R900-5a-2): the cursor is SET while the pointer moves over the band (no push or pop to unbalance
            // when a divider leaves under a resting pointer); leaving the band resets the arrow unless a drag holds it.
            // 13: each divider one splitter element (AgentDividerAXElement, the hover rect's background: the hit area's
            // frame) after the panes (sort priority below theirs), parents first. The modifiers sit before .position, so
            // the element's frame and the hover are the hit area, not the whole pane area.
            .overlay(alignment: .topLeading) {
                ForEach(model.dividers(in: proxy.size), id: \.path) { d in
                    Color.clear.contentShape(Rectangle())
                        .frame(width: d.hitArea.width, height: d.hitArea.height)
                        .onContinuousHover { phase in
                            if case .active = phase { Self.cursor(d.axis).set() } else if model.dividerDrag == nil { NSCursor.arrow.set() }
                        }
                        .accessibilityHidden(true)
                        .background {
                            AgentDividerAXElement(label: d.axis == .columns ? "Vertical divider" : "Horizontal divider",
                                                  value: model.dividerPercent(d.path).map { "\($0) percent" },
                                                  increment: { model.nudge(d.path, up: true, in: proxy.size, sides: d.sides) },
                                                  decrement: { model.nudge(d.path, up: false, in: proxy.size, sides: d.sides) })
                                .accessibilitySortPriority(-1)
                        }
                        .position(x: d.hitArea.midX, y: d.hitArea.midY)
                }
            }
            // #2055: the whole site (the docked drawer's room included); 0: the area's own frame, as before
            .frame(width: proxy.size.width + dockInset, height: proxy.size.height, alignment: .topLeading)
            // #1476 (operator: "One for the window"): several panes: one X-ray drawer at the area's trailing edge for the
            // focused pane, under the top row's headers (#2055 docked: full height, in the room the panes made); one pane:
            // the pane draws it as before (AgentDetailView).
            .overlay(alignment: .trailing) {
                if compact {
                    XrayDrawer(pane: model.layout.focused, target: shownTarget)
                        .padding(.top, dockInset > 0 ? 0 : AgentCompactHeader.height + 1)
                        .environment(\.agentPaneID, model.layout.focused)   // its links and probe: the focused pane's, as in the pane
                }
            }
            .overlay(alignment: .topLeading) { confirmCard(frames, in: area) }   // #1930: over everything in the area
            // #2055: one change of the focused pane or of the session it shows: a focus move keeps #1476's follow; the
            // same pane showing another session takes that session's drawer state (xrayShown)
            .onChange(of: XrayShown(pane: model.layout.focused, target: shownTarget)) { old, new in
                let w = AgentsNSWindow.window(of: old.pane) ?? AgentsNSWindow.window(of: new.pane)
                if old.pane != new.pane { w?.xrayFollow(from: old.pane) } else { w?.xrayShown() }
            }
            .coordinateSpace(.named(agentPaneAreaSpace))
            .onAppear { feed(area) }
            .onChange(of: proxy.size) { _, size in feed(CGRect(origin: .zero, size: size)) }
        }
        // #2055: the room for the window's docked drawer (drawn above, in it)
        .modifier(XrayDock(pane: model.layout.focused, target: shownTarget, drawer: false) {
            Self.compact(model, $0)
        })
    }

    /// The focused pane's session, nil under the New session form (the drawer's target, toggleXray's rule).
    var shownTarget: XrayTarget? { model.newSession == nil ? XrayTarget.of(model.selectedRow) : nil }

    /// #2055: what the area's onChange compares (the focused pane and the session it shows).
    struct XrayShown: Equatable {
        let pane: UUID
        let target: XrayTarget?
    }

    /// #900 B2 step 3 (7.4, R1.1): the frames this view draws (and the window hit-tests) in `area`: the model's tiling;
    /// zoomed (the model's shownPanes is the zoomed pane alone while the tiling holds more), that pane over the whole
    /// area and no other. The tiling itself is never changed, so an unzoom draws exactly the frames from before the zoom.
    /// N900-b: a split while zoomed is measured against that tiling, not this rect: the layout unzooms first
    /// (PaneLayout.split), so the result is the tiling with one more pane, not zoomed. shownPanes reads the model's
    /// paneArea, which can be a pass behind a resize; under a zoom it is the zoomed pane for any area (too small shows
    /// the focused pane, which is the zoomed one), so this holds on every pass.
    @MainActor static func drawn(_ m: AgentWindowModel, in area: CGRect) -> [UUID: CGRect] {
        let frames = m.paneFrames(in: area)
        guard frames.count > 1, let z = m.layout.zoomed, m.shownPanes == [z] else { return frames }
        return [z: area]
    }

    /// #1930: the window's open question (Remove from History, Stop, Kill, Restart) as a card centred over its subject's
    /// pane, that pane dimmed and lightly blurred behind it, and a clear layer over the whole area, under the card, that
    /// cancels on a click outside it. Return and Escape: AgentsNSWindow.confirmKey. Nothing at all while none is open or its
    /// subject is gone (R5: the question re-read each draw). The blur is a material over that pane alone (the compositor's,
    /// no view work per frame).
    @ViewBuilder func confirmCard(_ frames: [UUID: CGRect], in area: CGRect) -> some View {
        if let c = model.confirming, let text = model.confirmQuestion {
            let id = model.confirmPane(among: model.layout.order.filter { frames[$0] != nil }), f = frames[id] ?? area
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture { model.confirm(false) }.accessibilityHidden(true)
                    .modifier(AgentPaneProbe(kind: "confirmOutside"))
                Rectangle().fill(.ultraThinMaterial).overlay(Neon.bgBottom.opacity(0.35))
                    .frame(width: f.width, height: f.height)
                    .allowsHitTesting(false).accessibilityHidden(true)
                    .modifier(AgentPaneProbe(kind: "confirmDim"))
                    .position(x: f.midX, y: f.midY)
                // VoiceOver: the question, Cancel, the verb (the strip's own order)
                AgentConfirmStrip(text: text, action: AgentWindowControls.confirmTitle(c.verb),
                                  confirm: { model.confirm(true) }, cancel: { model.confirm(false) })
                    .frame(width: max(0, min(f.width - sz(32), sz(460))))
                    .clipShape(RoundedRectangle(cornerRadius: sz(10)))
                    .overlay(RoundedRectangle(cornerRadius: sz(10)).strokeBorder(Neon.stroke))
                    .contentShape(Rectangle())   // a click on the card is never the outside layer's
                    .shadow(color: .black.opacity(0.3), radius: sz(12), y: sz(4))
                    .modifier(AgentPaneProbe(kind: "confirm"))
                    .position(x: f.midX, y: f.midY)
            }
            .frame(width: area.width, height: area.height, alignment: .topLeading)
            .environment(\.agentPaneID, id)
        }
    }

    /// R1193-4: the area's size reaches the model, once per size.
    func feed(_ area: CGRect) {
        if model.paneArea != area { model.paneArea = area }
    }

    /// #1645: gate on, a terminal pane is one AgentPaneTerminalColumn focused or not, so a focus switch keeps both panes'
    /// terminal views (was: the branch below swapped for both, a new view, surface and dch attach each, #1615's remount).
    @ViewBuilder func pane(_ id: UUID, compact: Bool) -> some View {
        let focused = id == model.layout.focused
        if AgentPaneLayout.splitsEnabled, let r = model.runtimes[id],
           let shown = AgentPaneTerminalColumn.shown(model, r, focused: focused) {
            AgentPaneTerminalColumn(model: model, runtime: r, transcript: r.transcript, shown: shown, focused: focused,
                                    scrolls: scrolls, compact: compact)
        } else if focused {
            AgentDetailView(model: model, transcript: model.transcript, scrolls: scrolls, compact: compact)
        } else if let r = model.runtimes[id] {
            AgentUnfocusedPane(model: model, runtime: r, transcript: r.transcript, interaction: model.interaction,
                               scrolls: scrolls)
        }
    }

    @ViewBuilder func edge(_ f: CGRect) -> some View {
        if f.minX > 0.5 { Rectangle().fill(Neon.stroke).frame(width: 1).frame(maxHeight: .infinity).modifier(AgentPaneProbe(kind: "vline")) }
        if f.minY > 0.5 { Rectangle().fill(Neon.stroke).frame(height: 1).frame(maxWidth: .infinity).modifier(AgentPaneProbe(kind: "hline")) }
    }

    /// 7.6: more than one pane shown: the focused pane's 2·s accent border inside its frame, every other pane the dim.
    /// One pane: neither (R1.3). Both take no hits and are hidden from accessibility (13: decorative).
    @ViewBuilder func mark(_ id: UUID, compact: Bool) -> some View {
        if compact {
            if id == model.layout.focused {
                Rectangle().strokeBorder(Neon.blue, lineWidth: sz(2))
                    .allowsHitTesting(false).accessibilityHidden(true).modifier(AgentPaneProbe(kind: "mark"))
            } else {
                AgentPaneDim().modifier(AgentPaneProbe(kind: "mark"))
            }
        }
    }

    /// #901 B3 step 5 (section 10 :747): more than one pane shown and this pane's session blocked (paneNeed: never the
    /// focused pane): a sz(3) bar on the top edge in the sidebar's blocked colour, an overlay (no frame moves), no hits,
    /// hidden from accessibility (the header chip "Needs input" says it). It goes when the session stops being blocked
    /// or the pane takes focus: no timer. Gate off: one pane, never compact, so never built.
    @ViewBuilder func attentionBar(_ id: UUID, compact: Bool) -> some View {
        if compact, model.paneNeed(id) == .blocked {
            Rectangle().fill(agentStateColor(.blocked)).frame(height: sz(3)).frame(maxWidth: .infinity)
                .allowsHitTesting(false).accessibilityHidden(true).modifier(AgentPaneProbe(kind: "attention"))
        }
    }

    /// #1492: the drop indicator over pane `id` while a row is dragged over it: Neon.blue over the zone, no hits.
    @ViewBuilder func dropMark(_ id: UUID, _ size: CGSize) -> some View {
        if let h = model.dropHover, h.pane == id {
            let r = PaneLayout.dropRect(h.zone, in: size)
            Rectangle().fill(Neon.blue.opacity(0.25)).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    /// 13: the pane's name for its container: the row's title, the record's, the gone target's name; "Empty" for none.
    func title(_ id: UUID) -> String {
        switch model.runtimes[id]?.content {
        case let .live(s)?: model.row(.live(s.key))?.title ?? s.key.name
        case let .history(r)?: model.row(.history(r.id))?.title ?? r.id.name
        case let .notRunning(k)?: k.name
        case let .removed(t)?: AgentPanePlaceholder.name(t)
        case nil: "Empty"
        }
    }
}

extension UTType {
    /// #1492 (QA m1, i1): a sidebar row's drag: Prosper's own type and no text, so no text field or other app takes it as
    /// text and a session name never leaves as text. Not declared in Info.plist: it only travels inside Prosper.
    static var agentRow: UTType { UTType(exportedAs: "eu.illegible.prosper.agent-row") }
}

extension NSPasteboard.PasteboardType {
    /// #1492: the same type on a drag pasteboard (AgentTerminalHostView's own drop).
    static var agentRow: Self { Self(UTType.agentRow.identifier) }
}

/// #1492: a pane as a drop target for a sidebar row (its own type only): every call goes to the model (location in the
/// pane's own coordinates). The token loads off the main thread, so its closure is @Sendable and hops to the main actor.
struct AgentPaneDropDelegate: DropDelegate {
    let model: AgentWindowModel, pane: UUID, size: CGSize
    /// QA s1: a copy, never a move (a move takes the dragged item away from where it came from).
    static var proposal: DropProposal { DropProposal(operation: .copy) }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.agentRow]) }
    func dropEntered(info: DropInfo) { model.dropOver(pane, at: info.location, in: size) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        model.dropOver(pane, at: info.location, in: size)
        return Self.proposal
    }
    func dropExited(info: DropInfo) { model.dropExit(pane) }
    func performDrop(info: DropInfo) -> Bool {
        let (model, pane, size, at) = (model, pane, size, info.location)
        model.dropExit(pane)
        guard let p = info.itemProviders(for: [.agentRow]).first else { return false }
        _ = p.loadDataRepresentation(forTypeIdentifier: UTType.agentRow.identifier) { @Sendable data, _ in
            let token = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            Task { @MainActor in model.drop(token, into: pane, at: at, in: size) }
        }
        return true
    }
}

/// #1492: a draggable sidebar row (a live or remote row's token); no token (History), no drag.
struct AgentRowDrag: ViewModifier {
    let token: String?
    @ViewBuilder func body(content: Content) -> some View {
        if let token { content.onDrag { Self.item(token) } } else { content }
    }

    /// QA m1, i1: the token as Prosper's own row type only, never text.
    static func item(_ token: String) -> NSItemProvider {
        NSItemProvider(item: Data(token.utf8) as NSData, typeIdentifier: UTType.agentRow.identifier)
    }
}

/// 7.6: an unfocused pane's dim. It takes no hits (the window's first-click rule decides) and is hidden from
/// accessibility (13).
struct AgentPaneDim: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    var body: some View {
        Neon.bgBottom.opacity(0.25).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// #900 B2 step 5b (13): one divider's accessibility element, an AppKit view because a SwiftUI element on a clear
/// colour reads role AXUnknown and no value (measured): a splitter named `label`, valued "<n> percent", whose increment
/// and decrement nudge the split. It draws nothing, takes the hover rect's frame (no room of its own), takes no hits
/// (the window's route keeps the mouse) and never the keys (NSView's acceptsFirstResponder is false). updateNSView only
/// stores plain values and the two closures; the closures run on the main actor from an accessibility call (AppKit
/// delivers those on the main thread), never inside a view update.
private struct AgentDividerAXElement: NSViewRepresentable {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let label: String, value: String?
    let increment: @MainActor () -> Void, decrement: @MainActor () -> Void

    func makeNSView(context: Context) -> Element { Element() }
    func updateNSView(_ v: Element, context: Context) {
        v.label = label; v.value = value; v.increment = increment; v.decrement = decrement
    }

    final class Element: NSView {
        var label = "", value: String?
        var increment: @MainActor () -> Void = {}, decrement: @MainActor () -> Void = {}
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
        override func accessibilityLabel() -> String? { label }
        override func accessibilityValue() -> Any? { value }
        override func accessibilityPerformIncrement() -> Bool { increment(); return true }
        override func accessibilityPerformDecrement() -> Bool { decrement(); return true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// 13: with more than one pane shown, a pane is one accessibility container under `label`; one pane: no name.
/// R1196-a (#900 B2 step 3): one branch per window, chosen by the split gate (read at layout, fixed while a window is
/// drawn), never by the pane count, so a pane's content keeps its identity (its @State, its NSViews: the composer, the
/// terminal) across 1, 2, 1 panes and a zoom. Gate off (always one pane, no label): the content as before, no container.
struct AgentPaneContainer: ViewModifier {
    let label: String?
    @ViewBuilder func body(content: Content) -> some View {
        if AgentPaneLayout.splitsEnabled {
            content.accessibilityElement(children: .contain).accessibilityLabel(label ?? "")
        } else {
            content
        }
    }
}

/// #1645: gate on, a pane that draws a terminal (a local session's, its Ended pane's kept frame or card, a listed remote's),
/// focused or not: the focused pane's header and overlays by AgentDetailView's rule, an unfocused pane's by
/// AgentUnfocusedPane's, the terminal at the same place in both. A focus switch changes only the header and the
/// overlays: the pane's AgentTerminalHostView, its libghostty surface and its dch client stay (no new view, no #1615
/// remount, no resize), and libghostty's own focus state moves the cursor (the window's first responder).
struct AgentPaneTerminalColumn: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var model: AgentWindowModel
    @ObservedObject var runtime: AgentPaneRuntime
    @ObservedObject var transcript: AgentTranscriptModel
    let shown: Shown
    let focused: Bool
    var scrolls = true
    var compact = false

    enum Shown {
        case local(AgentSidebar.Row, AgentSession, ended: Bool)
        case remote(AgentSidebar.Row, AgentSidebar.Remote)
    }

    /// What pane `r` draws here; nil: no terminal pane (the New session form, History, a placeholder, empty), drawn by
    /// AgentDetailView or AgentUnfocusedPane as before. Focused: AgentDetailView's rule (the selected row); unfocused:
    /// AgentUnfocusedPane's (Ended's kept row, the live session's row, then a listed remote).
    @MainActor static func shown(_ m: AgentWindowModel, _ r: AgentPaneRuntime, focused: Bool) -> Shown? {
        if focused {
            guard m.newSession == nil, let row = m.selectedRow else { return nil }
            if let s = row.session { return .local(row, s, ended: m.focusedEnded) }
            return row.remote.map { .remote(row, $0) }
        }
        if let e = r.ended, let s = e.row.session { return .local(e.row, s, ended: true) }
        if case .live(let s)? = r.content, let row = m.row(.live(s.key)) { return .local(row, s, ended: false) }
        if let x = m.paneRemote(r.pane), let row = m.row(.remote(host: x.host, name: x.name)) { return .remote(row, x) }
        return nil
    }

    /// The focused pane's parts (its header and overlays), AgentDetailView's own.
    var detail: AgentDetailView { AgentDetailView(model: model, transcript: transcript, scrolls: scrolls, compact: compact) }

    var row: AgentSidebar.Row {
        switch shown { case let .local(row, _, _), let .remote(row, _): row }
    }

    /// An Ended pane without its kept frame draws the ended card instead.
    var terminalShown: Bool {
        if case .local(_, _, true) = shown { return model.keptFrame(runtime.pane) != nil }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            header.modifier(AgentRowDrag(token: model.paneDragToken(runtime.pane)))   // #1895: drag the pane to move it
            Rectangle().fill(Neon.stroke).frame(height: 1)
            VStack(spacing: 0) {
                if terminalShown {
                    // The one terminal of this pane, focused or not: model.terminal is this runtime's with the gate on.
                    AgentTerminalPane(controller: model.paneTerminal(runtime), open: open)
                        .frame(minHeight: 0, maxHeight: .infinity)
                        .modifier(AgentPaneProbe(kind: "terminal"))
                        .overlay(alignment: .top) { if focused { overTop } }
                        .overlay { connect }
                } else {
                    AgentTerminalCard(icon: "stop.circle", text: "Session ended")
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Neon.bgBottom)
                        .overlay(alignment: .top) { if focused, case let .local(row, s, _) = shown { detail.overTop(row, s) } }
                }
            }
            // #1351: over, never resizing; #2055: docked, beside. #1476: several panes: the window's one drawer (AgentPaneArea) instead.
            .modifier(XrayDock(pane: runtime.pane, target: XrayTarget.of(row)) { _ in focused && !compact })
        }
    }

    @ViewBuilder var header: some View {
        switch shown {
        case let .local(row, s, ended):
            if focused && !compact {
                detail.header(row, s)
            } else {
                // #1707: one header view, focused or not (detail.header's compact one, same arguments): the click on an
                // unfocused pane's header focuses it, and the control under it keeps its identity to act on its up.
                AgentCompactHeader.of(row, s, cwd: transcript.cwd, ended: ended, store: model.store,
                                      ask: { model.ask($0, s) }, open: open,
                                      // #900 B2 step 6a: this pane's items; choosing one focuses this pane first.
                                      panes: (focused ? [AgentWindowMenuEntry.divider] + [AgentsNSWindow.xrayItem(model)].compactMap { $0 } : [])
                                          + AgentWindowControls.paneMenu(model, pane: runtime.pane)
                                          + AgentWindowControls.swapMenu(model, pane: runtime.pane),   // #1895
                                      pane: { AgentWindowControls.runPane($0, pane: runtime.pane, in: model) },
                                      keyPanes: focused ? model.layout.panes.count : nil,   // #1916
                                      xrayPane: runtime.pane, switcher: AgentPaneSwitch(model: model, pane: runtime.pane))   // #1491
                    .modifier(AgentPaneProbe(kind: "header"))
            }
        case let .remote(row, x):
            AgentRemoteHeader(row: row, remote: x, pane: runtime.pane, switcher: AgentPaneSwitch(model: model, pane: runtime.pane))
                .modifier(AgentPaneProbe(kind: "header"))
        }
    }

    var open: () -> Void {
        guard case let .local(_, s, _) = shown else { return {} }
        return focused ? { model.openSelected() } : { model.openSession(s) }
    }

    @ViewBuilder var overTop: some View {
        switch shown {
        case let .local(row, s, _): detail.terminalOverTop(row, s)
        case let .remote(row, _): XrayRecapStrip(pane: runtime.pane, target: XrayTarget.of(row))   // #1625
        }
    }

    /// #1477 (11.3): an unfocused pane over the cap or the session's second pane: its last frame and Connect.
    @ViewBuilder var connect: some View {
        if !focused, model.connectPanes.contains(runtime.pane) {
            switch shown {
            case .local(_, _, false):
                AgentTerminalCard(icon: "pause.circle", text: "Not connected") {
                    AgentPillButton(title: "Connect", icon: "arrow.right.circle", tint: Neon.blue) { model.focusPane(runtime.pane) }
                }
            case .remote:
                AgentTerminalCard(icon: "pause.circle", text: "Not connected") {
                    AgentPillButton(title: "Connect", icon: "arrow.right.circle", tint: Neon.blue) { model.connectPane(runtime.pane) }
                }
            case .local:
                EmptyView()
            }
        }
    }
}

/// #831 B1 step 4: a pane that does not hold the input (reachable only with the split gate set, 15.0): the compact
/// header, the pane's own transcript and the inert composer slot (5.1); its History card without buttons (a press on
/// an unfocused pane focuses it first: step 5); the 4.2 placeholders.
struct AgentUnfocusedPane: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var model: AgentWindowModel
    @ObservedObject var runtime: AgentPaneRuntime
    @ObservedObject var transcript: AgentTranscriptModel
    @ObservedObject var interaction: AgentWindowInteraction
    var scrolls = true

    /// The session it draws: Ended's kept row (4.4), else the live session's row.
    var shown: (row: AgentSidebar.Row, session: AgentSession)? {
        if let e = runtime.ended, let s = e.row.session { return (e.row, s) }
        if case .live(let s)? = runtime.content, let row = model.row(.live(s.key)) { return (row, s) }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let p = shown {
                let ended = runtime.ended != nil
                // #1477 (spec 15 C): B1's Terminal-to-transcript fallback is gone: a Terminal-mode pane draws its own terminal
                let kept = model.keptFrame(runtime.pane)
                AgentCompactHeader.of(p.row, p.session, cwd: transcript.cwd, ended: ended, store: model.store,
                                      ask: { model.ask($0, p.session) }, open: { model.openSession(p.session) },
                                      // #900 B2 step 6a: this pane's items; choosing one focuses this pane first.
                                      panes: AgentWindowControls.paneMenu(model, pane: runtime.pane)
                                          + AgentWindowControls.swapMenu(model, pane: runtime.pane),   // #1895
                                      pane: { AgentWindowControls.runPane($0, pane: runtime.pane, in: model) },
                                      keyPanes: runtime.pane == model.layout.focused ? model.layout.panes.count : nil,   // #1916
                                      xrayPane: runtime.pane, switcher: AgentPaneSwitch(model: model, pane: runtime.pane))   // #1491
                    .modifier(AgentPaneProbe(kind: "header"))
                    .modifier(AgentRowDrag(token: model.paneDragToken(runtime.pane)))   // #1895
                Rectangle().fill(Neon.stroke).frame(height: 1)
                if !ended || kept != nil {   // #1471: Terminal is the only mode
                    AgentTerminalPane(controller: kept ?? model.paneTerminal(runtime), open: { model.openSession(p.session) })
                        .overlay {
                            // #1477 (11.3): over the cap or the session's second pane: the last frame, and Connect focuses
                            if !ended, model.connectPanes.contains(runtime.pane) {
                                AgentTerminalCard(icon: "pause.circle", text: "Not connected") {
                                    AgentPillButton(title: "Connect", icon: "arrow.right.circle", tint: Neon.blue) {
                                        model.focusPane(runtime.pane)
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 0, maxHeight: .infinity)
                        .modifier(AgentPaneProbe(kind: "terminal"))
                } else {
                    AgentTerminalCard(icon: "stop.circle", text: "Session ended")
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Neon.bgBottom)
                }
            } else if let x = model.paneRemote(runtime.pane), let row = model.row(.remote(host: x.host, name: x.name)) {
                // #902 (11.2 remote column): a listed remote pane, unfocused: its terminal while the human's pick holds,
                // else Connect (arms the attach and focuses the pane); never "isn't running", never an attach by itself.
                AgentRemoteHeader(row: row, remote: x, pane: runtime.pane, switcher: AgentPaneSwitch(model: model, pane: runtime.pane))
                    .modifier(AgentPaneProbe(kind: "header"))
                    .modifier(AgentRowDrag(token: model.paneDragToken(runtime.pane)))   // #1895
                Rectangle().fill(Neon.stroke).frame(height: 1)
                AgentTerminalPane(controller: model.paneTerminal(runtime), open: {})
                    .overlay {
                        if model.connectPanes.contains(runtime.pane) {
                            AgentTerminalCard(icon: "pause.circle", text: "Not connected") {
                                AgentPillButton(title: "Connect", icon: "arrow.right.circle", tint: Neon.blue) {
                                    model.connectPane(runtime.pane)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .modifier(AgentPaneProbe(kind: "terminal"))
            } else {
                let title = AgentPanePlaceholder.title(runtime.content)
                AgentCompactHeader(title: historyTitle ?? title ?? "").modifier(AgentPaneProbe(kind: "header"))
                    .modifier(AgentRowDrag(token: runtime.content == nil ? model.paneDragToken(runtime.pane) : nil))   // #1927: an empty pane
                Rectangle().fill(Neon.stroke).frame(height: 1)
                if case .history(let r)? = runtime.content {
                    AgentHistoryDetail(row: model.row(.history(r.id)) ?? AgentSidebar.row(r, now: model.now()), record: r,
                                       store: nil, act: { _ in },
                                       close: AgentPanePlaceholder.close(model, pane: runtime.pane))   // #1906
                } else if let title {
                    AgentPanePlaceholder(title: title, close: { model.closePane(runtime.pane) },
                                         pick: { model.pickAnother(runtime.pane) })
                } else {
                    AgentPanePlaceholder.emptyCard(model, pane: runtime.pane)   // #1928: the focused pane's card too
                }
            }
        }
    }

    var historyTitle: String? {
        if case .history(let r)? = runtime.content { return model.row(.history(r.id))?.title ?? r.id.name }
        return nil
    }
}

/// #831 4.2: the pane holds a target whose session is not running, or whose record was removed: it says so by name,
/// with Pick Another (focus the pane, the sidebar gets the keys) and, with more than one pane, Close Pane.
struct AgentPanePlaceholder: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let title: String
    var close: (() -> Void)?
    let pick: () -> Void

    static let detail = "Pick another session from the list."

    /// 4.2's words for a content that has no row (`.live` and `.history` draw their own; no target: nil).
    static func title(_ c: PaneContent?) -> String? {
        switch c {
        case let .notRunning(k)?: "\(k.name) isn't running"
        case let .removed(t)?: "\(name(t)) was removed from History"
        case .live?, .history?, nil: nil
        }
    }

    static func name(_ t: PaneTarget) -> String {
        switch t {
        case let .session(_, name), let .remote(_, name): name
        case let .history(_, id, _): id
        }
    }

    /// #1658: Close Pane for `pane`, captured now (never the pane focused at the press); nil with one pane (7.3).
    @MainActor
    static func close(_ model: AgentWindowModel, pane: UUID) -> (() -> Void)? {
        model.layout.panes.count > 1 ? { model.closePane(pane) } : nil
    }

    /// #1920: New shell on an empty pane's card: the quick login shell at once (⇧⌘N's, no form). `pane` is captured at
    /// draw (as close): it takes the focus first, so the shell's row lands in it (#1895 rule 2: an empty focused pane
    /// takes the next pick). Gate and help as the sidebar's [>_].
    @MainActor @ViewBuilder static func newShellPill(_ model: AgentWindowModel, pane: UUID) -> some View {
        AgentPillButton(title: "New shell", icon: "apple.terminal", tint: Neon.terminal,
                        enabled: model.store?.resumeGate.isOK == true) { model.focusPane(pane); model.startShell() }
            .help(AgentNewSessionButtons.help("New shell (⇧⌘N)", refusal: model.store?.resumeGate.refusal))
            .accessibilityLabel("New shell")
    }

    static let emptyDetail = "Pick a session from the list, or start one here."

    /// #1928: the empty pane's card, one view for the focused and the unfocused pane: the same text and pills (Close Pane
    /// with several panes, New shell, New session). `pane` is captured at draw: a press focuses it first (as #1920's New
    /// shell), so New session's form opens in it.
    @MainActor @ViewBuilder static func emptyCard(_ model: AgentWindowModel, pane: UUID) -> some View {
        AgentEmptyState(icon: "sidebar.left", title: "Select a session", detail: emptyDetail) {
            HStack(spacing: sz(8)) {
                closePill(close(model, pane: pane))   // #1658
                newShellPill(model, pane: pane)   // #1920
                AgentPillButton(title: "New session", icon: "plus", tint: Neon.blue,
                                enabled: model.store?.resumeGate.isOK == true) { model.focusPane(pane); model.openNewSession() }
                    .help(AgentNewSessionButtons.help("New session… (⌘N)", refusal: model.store?.resumeGate.refusal))
                    .accessibilityLabel("New session")
            }
            .padding(.top, sz(4))
        }
    }

    /// The Close Pane pill (nil: none), the placeholder's and #1658's empty pane's alike.
    @ViewBuilder static func closePill(_ close: (() -> Void)?) -> some View {
        if let close {
            AgentPillButton(title: "Close Pane", icon: "xmark", tint: Neon.textSecondary, action: close)
                .help("Close this pane (⌘W)")
        }
    }

    var body: some View {
        AgentEmptyState(icon: "moon.zzz", title: title, detail: Self.detail) {
            HStack(spacing: sz(8)) {
                Self.closePill(close)
                AgentPillButton(title: "Pick Another", icon: "sidebar.left", tint: Neon.blue, action: pick)
            }
            .padding(.top, sz(4))
        }
    }
}

/// #831 9.2: the header of a pane among several: one line, 26·s, in every content and focus state. The title gives way
/// first (cut in the middle; its whole text and the folder in the help); the state chip keeps its widest-variant slot
/// (#828), the mode toggle (icon pair) and the "⋯" keep their size.
struct AgentCompactHeader: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let title: String
    var project: String?
    var chip: AgentStateChip?
    var ended = false
    var menu: AgentSessionMenuButton?
    /// #1476: the X-ray button before the "...", with the menu (a session's header).
    var xray: AgentXrayButton?
    /// #1491: the title is the pane's session switcher; nil: a plain title.
    var switcher: AgentPaneSwitch?

    static var height: CGFloat { sz(26) }

    static func of(_ row: AgentSidebar.Row, _ s: AgentSession, cwd: String?, ended: Bool, store: AgentIslandStore?,
                   ask: @escaping (AgentWindowVerb) -> Void, open: @escaping () -> Void, panes: [AgentWindowMenuEntry] = [],
                   pane: @escaping (AgentPaneVerb) -> Void = { _ in }, keyPanes: Int? = nil, xrayPane: UUID? = nil,
                   switcher: AgentPaneSwitch? = nil) -> AgentCompactHeader {
        AgentCompactHeader(title: row.title, project: AgentSessionHeader.project(cwd: cwd, session: s),
                           chip: AgentStateChip(state: s.state, ended: ended), ended: ended,
                           menu: AgentSessionMenuButton(store: ended ? nil : store, session: s, ask: ask, open: open, ended: ended,
                                                        panes: panes, pane: pane, keyPanes: keyPanes),
                           xray: xrayPane.map { AgentXrayButton(pane: $0, target: XrayTarget.of(row)) }, switcher: switcher)
    }

    var body: some View {
        HStack(alignment: .center, spacing: sz(8)) {
            let text = Text(title).font(Neon.font(13, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            if let switcher {
                AgentPaneSwitcherButton(text: text, size: 13, title: title, project: project,
                                        help: project.map { "\(title)\n\($0)" }, switcher: switcher)
            } else {
                AgentProjectTitle(text: text, label: title, project: project, help: project.map { "\(title)\n\($0)" })
            }
            if let chip { chip }
            Spacer(minLength: 0)
            if let xray { xray }   // #1476: narrower than the icon pair it replaces (sz(22) against about 60 points times the scale)
            if let menu { menu.background(XrayCardAnchor()) }   // #1319: the list's popover hangs from it
        }
        .padding(.horizontal, sz(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .clipped()
        .contentShape(Rectangle())   // #1914: the gap between the title and the "⋯" takes the pane drag too
    }
}

/// #1491: what a pane title's switcher acts on: the window model and the pane whose title it is.
struct AgentPaneSwitch {
    let model: AgentWindowModel
    let pane: UUID

    static let hint = "Choose a session for this pane"
    /// R1895 f1: built by AgentDetailView's header (its pane is the focused one, not the view's own), which yields a
    /// Swap Session… request to the pane header's switcher when both are mounted.
    var detail = false
    /// R1895 f1 (tests): records the switcher whose list a Swap Session… request opens, instead of the popover.
    @MainActor static var opened: ((AgentPaneSwitch) -> Void)?

    /// The chevron's room after the title (its spacing and its fixed width) at a title font of `size`.
    static func chevronRoom(_ size: CGFloat) -> CGFloat { sz(4) + chevronWidth(size) }
    static func chevronWidth(_ size: CGFloat) -> CGFloat { sz(size * 0.6) }
}

/// #1491: a pane title as a menu button: the title (its own font and truncation) and a chevron; a click opens the
/// pane's session list in a popover hung from the title. VoiceOver: the title, the folder as value, the hint.
struct AgentPaneSwitcherButton<T: View>: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let text: T
    let size: CGFloat
    let title: String
    let project: String?
    /// The tooltip's first line (the compact header's whole title and folder); nil: the folder.
    let help: String?
    let switcher: AgentPaneSwitch
    @State private var list: AgentPaneSwitcherList?

    var body: some View {
        Button { list = AgentPaneSwitcherList.of(switcher, dismiss: { list = nil }) } label: {
            HStack(spacing: sz(4)) {
                AgentSlotWidth { text }
                Image(systemName: "chevron.down").font(Neon.font(size, weight: .semibold)).imageScale(.small)
                    .foregroundStyle(Neon.textSecondary)
                    .frame(width: AgentPaneSwitch.chevronWidth(size)).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The hint rides in the tooltip (AXHelp): a separate accessibilityHint and a .help would both claim AXHelp.
        .help((help ?? project).map { "\($0)\n\(AgentPaneSwitch.hint)" } ?? AgentPaneSwitch.hint)
        .accessibilityLabel(title)
        .accessibilityValue(project ?? "")
        .popover(isPresented: Binding(get: { list != nil }, set: { if !$0 { list = nil } }), arrowEdge: .bottom) {
            if let list { AgentPaneSwitcherView(list: list) }
        }
        // #1895: the ⋯ menu's Swap Session… for this pane opens the same list; after this update (never inside it), once.
        // A switcher mounted after the request (the pane's view changes with its focus) takes it on subscribe. R1895 f1: a
        // stale one is prevented at its source (a focus move drops it, swapMenu offers none where no switcher is drawn).
        .onReceive(switcher.model.$swapRequest) { p in
            guard p == switcher.pane else { return }
            let take = {
                guard switcher.model.swapRequest == switcher.pane else { return }
                switcher.model.swapRequest = nil
                if let opened = AgentPaneSwitch.opened { opened(switcher); return }   // tests: no popover
                list = AgentPaneSwitcherList.of(switcher, dismiss: { list = nil })
            }
            // R1895 f1: one consumer per pane: a detail-view header's switcher waits one more turn, so the pane's own
            // header, when both are mounted, takes it first; alone (the focused full header) it still takes it.
            DispatchQueue.main.async { if switcher.detail { DispatchQueue.main.async(execute: take) } else { take() } }
        }
    }
}

/// #1491: its child takes the whole width offered, up to its ideal: a cut title keeps its slot to the point (a cut Text
/// alone comes out up to a glyph narrower than offered, so the chevron would take more than its own room).
struct AgentSlotWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        let ideal = s.sizeThatFits(.unspecified)
        let fit = s.sizeThatFits(proposal)
        return CGSize(width: min(proposal.width ?? ideal.width, ideal.width), height: fit.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// #1491: the switcher's list (the popover's state): the sidebar's rows, the filter (by name, case-insensitive) and the
/// highlighted row. The search field's commands go through `command` (doCommandBy): Down and Up move, Return picks,
/// Escape closes.
@MainActor
final class AgentPaneSwitcherList: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: AgentSidebar.RowID
        let title: String
        /// The number of ANOTHER pane that shows it; nil: none.
        let inPane: Int?
    }

    let items: [Item]
    @Published var query = "" { didSet { if query != oldValue { index = 0 } } }
    @Published var index = 0
    let pick: (AgentSidebar.RowID) -> Void
    let close: () -> Void

    init(_ items: [Item], pick: @escaping (AgentSidebar.RowID) -> Void, close: @escaping () -> Void) {
        self.items = items
        self.pick = pick
        self.close = close
    }

    /// The list for `s`'s pane: a pick goes into that pane (AgentWindowModel.choose) and closes the list; Escape closes it
    /// and gives the keys back to the pane.
    static func of(_ s: AgentPaneSwitch, dismiss: @escaping () -> Void) -> AgentPaneSwitcherList {
        let (model, pane) = (s.model, s.pane)
        let items = model.switcherRows(for: pane).map { Item(id: $0.row.id, title: $0.row.title, inPane: $0.inPane) }
        return AgentPaneSwitcherList(items, pick: { id in
            dismiss()
            model.choose(id, into: pane)
        }, close: {
            dismiss()
            model.focusPane(pane)
            model.focusSelection()
        })
    }

    var shown: [Item] { query.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(query) } }

    func move(_ by: Int) {
        let n = shown.count
        guard n > 0 else { return }
        index = min(max(index + by, 0), n - 1)
    }

    /// Return: the highlighted row; an empty filter result only closes.
    func choose() {
        guard index >= 0, let item = shown.dropFirst(index).first else { return close() }
        pick(item.id)
    }

    /// The search field's commands; false: not the list's (the field edits).
    func command(_ s: Selector) -> Bool {
        switch s {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): choose()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }
}

/// #1491: the popover: the search field on top, then the rows (a row shown in another pane says which).
struct AgentPaneSwitcherView: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var list: AgentPaneSwitcherList

    static func mark(_ n: Int) -> String { "in pane \(n)" }

    var body: some View {
        let shown = list.shown
        VStack(alignment: .leading, spacing: sz(6)) {
            AgentPaneSwitcherField(list: list).frame(height: sz(22))
            if shown.isEmpty {
                Text("No sessions").font(Neon.font(12)).foregroundStyle(Neon.textSecondary).padding(.horizontal, sz(8))
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                            Button { list.index = i; list.choose() } label: {
                                HStack(spacing: sz(8)) {
                                    Text(item.title).font(Neon.font(13)).foregroundStyle(Neon.textPrimary).lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    if let n = item.inPane {
                                        Text(Self.mark(n)).font(Neon.font(11)).foregroundStyle(Neon.textSecondary).fixedSize()
                                    }
                                }
                                .padding(.horizontal, sz(8)).frame(height: sz(24))
                                .background(RoundedRectangle(cornerRadius: sz(4)).fill(i == list.index ? Neon.blue.opacity(0.25) : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(i == list.index ? .isSelected : [])
                            .id(i)
                        }
                    }
                }
                .onChange(of: list.index) { _, i in proxy.scrollTo(i) }
            }
            .frame(height: min(CGFloat(shown.count) * sz(24), sz(300)))
        }
        .padding(sz(8))
        .frame(width: sz(260))
    }
}

/// #1491: the switcher's search field: its text is the list's filter; Down, Up, Return and Escape go to the list.
struct AgentPaneSwitcherField: NSViewRepresentable {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let list: AgentPaneSwitcherList

    func makeCoordinator() -> Coordinator { Coordinator(list) }

    func makeNSView(context: Context) -> AgentPaneSwitcherTextField {
        let f = AgentPaneSwitcherTextField(string: list.query)
        f.placeholderString = "Search sessions"
        f.focusRingType = .none
        f.font = NSFont.systemFont(ofSize: sz(13))
        f.delegate = context.coordinator
        f.setAccessibilityLabel("Search sessions")
        return f
    }

    func updateNSView(_ f: AgentPaneSwitcherTextField, context: Context) { context.coordinator.list = list }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var list: AgentPaneSwitcherList
        init(_ list: AgentPaneSwitcherList) { self.list = list }

        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSTextField { list.query = f.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            list.command(selector)
        }
    }
}

final class AgentPaneSwitcherTextField: NSSearchField {
    /// Takes the keys as soon as it is in the popover's window: first responder within that window only.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}

/// #1191, R1191-1: a header title: the folder is its tooltip and accessibility value only when there is one, so a title
/// with none keeps its own words as value; the words stay its label.
struct AgentProjectTitle<T: View>: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let text: T
    let label: String
    let project: String?
    /// The tooltip when it says more than the folder (the compact header's whole title); nil: the folder.
    var help: String?
    var body: some View {
        if let project {
            text.help(help ?? project).accessibilityLabel(label).accessibilityValue(project)
        } else {
            text.accessibilityLabel(label)
        }
    }
}

/// #1239: the belt under the Rename field: a title-slot part (one with no accessibilityHidden of its own) leaves the
/// accessibility tree while renaming by the flag itself, whatever the slot's opacity 0 does on a given macOS. Always
/// applied, only its value changes: nothing is rebuilt, nothing moves. Per part, never on the slot (#1120).
struct AgentHeaderRenameHidden: ViewModifier {
    let renaming: Bool
    func body(content: Content) -> some View { content.accessibilityHidden(renaming) }
}

struct AgentSessionHeader: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let row: AgentSidebar.Row
    let session: AgentSession
    let cwd: String?
    let open: () -> Void
    /// #821: the session's todo list (its chip) and whether its list is open (the transcript model's, reset on a
    /// session switch).
    var todos: AgentTodos?
    var todosOpen: Binding<Bool> = .constant(false)
    /// #829: the "⋯" menu's store (its gates) and its ask.
    var store: AgentIslandStore?
    var ask: (AgentWindowVerb) -> Void = { _ in }
    /// QA #668 F1: the session ended (a held row): the "⋯" (Open in terminal's home since #1103) is off, in its slot.
    var ended = false
    /// The "⋯" menu's store: none for an ended session, so it offers only Open in terminal, off, and is disabled.
    var menuStore: AgentIslandStore? { ended ? nil : store }
    /// QA #668 INFO-4: the state chip reads "Ended" for an ended session, in the same slot.
    var stateChip: AgentStateChip { AgentStateChip(state: session.state, ended: ended, renaming: renaming) }
    /// #829 G4: the title is a text field (Rename…) while `rename` is set; `endRename` gets the text on Return,
    /// nil on Esc or focus loss (true: the edit goes on).
    var rename: AgentRenameEdit?
    var renaming: Bool { rename != nil }
    var endRename: (AgentRenameEdit, String?) -> Bool = { _, _ in false }
    /// #900 B2 step 6a: the "⋯" pane items (empty with the gate off) and their run.
    var panes: [AgentWindowMenuEntry] = []
    var pane: (AgentPaneVerb) -> Void = { _ in }
    /// #1916: AgentSessionMenuButton.keyPanes.
    var keyPanes: Int? = nil
    /// #1476: the pane the X-ray button acts on; nil: no button (a header drawn outside a pane).
    var xrayPane: UUID?
    /// #1491: the title is the pane's session switcher; nil: a plain title.
    var switcher: AgentPaneSwitch?

    /// #1191: the session's folder, no longer drawn in the header: the title's tooltip and accessibility value carry it
    /// (two sessions of one name stay apart for VoiceOver). Nil when there is no text at all.
    var project: String? { Self.project(cwd: cwd, session: session) }

    static func project(cwd: String?, session: AgentSession) -> String? {
        let text = cwd.map { ($0 as NSString).abbreviatingWithTildeInPath }
            ?? (session.key.dir == DchCommand.defaultSocketDir ? "dch \(session.name)" : "dch \(session.name) in \(session.key.dir)")
        return text.isEmpty ? nil : text
    }

    /// #1103: the header's padding above and below its one line. The content view starts under the titlebar
    /// (no .fullSizeContentView, SettingsWindow.applyWindowOpacity), so nothing up there needs clearing.
    static var padTop: CGFloat { sz(10) }
    static var padBottom: CGFloat { sz(10) }
    /// The title line's own height, the same in both modes, so the toggle and the "⋯" sit at one height: the drawn
    /// controls differ (no picker in Terminal mode) and an AppKit Menu keeps a 20 pt minimum at every scale, so the
    /// content alone gave Transcript mode a taller line below 1.0. Fits the tallest control at 1.0 (a capsule, about
    /// 23 pt) and the Rename field.
    static var lineHeight: CGFloat { sz(26) }
    /// Terminal mode's header (one line) without an open todo list; Transcript mode adds the counts-and-age line.
    static var height: CGFloat { padTop + lineHeight + padBottom }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            // The whole title and the labelled controls when they fit, else smaller ones.
            titleLines.frame(height: Self.lineHeight)
            if todosOpen.wrappedValue, let todos = shownTodos { AgentTodosList(todos: todos) }
        }
        .padding(.horizontal, sz(16)).padding(.top, Self.padTop).padding(.bottom, Self.padBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgentWindowDragArea())   // #1378: the header's empty parts move the window
        // #860: on the window's backdrop, as Settings' pane title (no opaque band under the titlebar).
    }

    /// The row's detail (whole or not at all): Transcript mode's second line, the title line's tail in Terminal mode
    /// (#1103). #1191: no folder glyph and no path (the title's tooltip and accessibility value carry it).
    var folder: some View {
        HStack(spacing: sz(6)) {
            // #1115: the row's count groups from its fields (no split of the detail text), then the age in words.
            let ago = AgentIsland.ago(row.age)
            if !row.counts.isEmpty || ago != nil {
                // Whole or not at all: a squeezed low-priority Text overshot the line by a
                // fraction of a point next to the #821 todo chip.
                AgentWidthFloor(floor: 0) {   // #1103 F1: an extra, never part of what the line must hold
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: sz(6)) {
                            Text("\u{00B7}").accessibilityHidden(true)   // after the chip
                            // #1239: under the Rename field.
                            AgentCountGroups(counts: row.counts, size: 11, help: row.countHelp)
                                .modifier(AgentHeaderRenameHidden(renaming: renaming))
                            if let ago {
                                if !row.counts.isEmpty { Text("·").accessibilityHidden(true) }   // a count never runs into "4m ago"
                                Text(ago).modifier(AgentHeaderRenameHidden(renaming: renaming))
                            }
                        }
                        .font(Neon.font(11)).foregroundStyle(Neon.textSecondary).lineLimit(1)
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                .layoutPriority(-1)
            }
        }
    }

    /// The title, the state chip, in Terminal mode the counts and age, and the room after them: one slot. G4: while
    /// renaming, the field lies over the whole slot and its parts only go transparent, so nothing moves. The title, which
    /// names the session, takes the room and cuts at its tail.
    var titleSlot: some View {
        // #1120: no accessibilityHidden on the slot: hidden(false) on the slot overrode the folder icon's own hidden when
        // the header still drew a folder glyph (read "Move"). While renaming, the opacity 0 leaves the parts out of the tree
        // on macOS 27 (testRenameHidesTheTitleChipAndPathUnderTheFieldInTheTree); #1239: each part that has no hidden of its
        // own carries AgentHeaderRenameHidden too, so no macOS depends on the opacity (the separators keep their own).
        Group { slotParts }
        .opacity(renaming ? 0 : 1)
        .overlay(alignment: .leading) {
            if let rename {
                AgentRenameField(name: session.name, edit: rename, end: endRename)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(ObjectIdentifier(rename))   // per edit: Rename on another row gets a new field, never this one's text
            }
        }
    }

    /// #1103 F1: the counts and age only with a readable title and the chip.
    @ViewBuilder var slotParts: some View {
        ViewThatFits(in: .horizontal) {   // #1471 b: one layout (Terminal's)
            slotLine(folder: true)
            slotLine(folder: false)
        }
    }

    /// #1103 F1: a title keeps about 9 characters before the extras are dropped.
    static var titleFloor: CGFloat { sz(80) }

    /// The title, the chip and, with `folder`, the counts and age: the title keeps its floor there, so ViewThatFits
    /// takes this line exactly when the floor, the chip and the extras fit (the extras are dropped first).
    func slotLine(folder withFolder: Bool) -> some View {
        HStack(alignment: .center, spacing: sz(8)) {
            let title = titleView.modifier(AgentHeaderRenameHidden(renaming: renaming))
            if withFolder {
                AgentWidthFloor(floor: Self.titleFloor) { title }.layoutPriority(1)
            } else {
                title.layoutPriority(1)
            }
            stateChip
            if withFolder { folder }
            Spacer(minLength: sz(8))
        }
    }

    /// The title, or #1491 the pane's session switcher (the title and its chevron).
    @ViewBuilder var titleView: some View {
        let text = Text(row.title).font(Neon.font(15, weight: .semibold)).foregroundStyle(Neon.textPrimary).lineLimit(1)
            .truncationMode(.tail)
        if let switcher {
            AgentPaneSwitcherButton(text: text, size: 15, title: row.title, project: project, help: nil, switcher: switcher)
        } else {
            AgentProjectTitle(text: text, label: row.title, project: project)
        }
    }

    var shownTodos: AgentTodos? { todos }

    /// #1471 b: one tier (the picker's labels, icons and menu tiers went with it).
    var titleLines: some View { titleLine() }

    /// #1103: the title line. Its size (and so the tier ViewThatFits picks) is the same in both modes: the whole
    /// title, the chips, the picker, the toggle and the "⋯", measured hidden. The line drawn over it puts the toggle
    /// and the "⋯" at the right edge, so a mode change never moves them; Terminal mode draws no picker, and its
    /// folder takes that room.
    func titleLine() -> some View {
        HStack(alignment: .center, spacing: sz(8)) {
            Text(row.title).font(Neon.font(15, weight: .semibold)).lineLimit(1)
            if switcher != nil { Color.clear.frame(width: AgentPaneSwitch.chevronRoom(15), height: 1) }   // #1491
            stateChip
            if let todos = shownTodos { AgentTodosChip(todos: todos, open: todosOpen) }
            if xrayPane != nil { Color.clear.frame(width: AgentXrayButton.width, height: sz(18)) }   // #1476: the X-ray button
            Color.clear.frame(width: sz(18), height: sz(18))   // the "⋯"
        }
        .hidden()
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity)
        .overlay { shownLine() }
    }

    func shownLine() -> some View {
        HStack(alignment: .center, spacing: sz(8)) {
            // The slot takes what the controls leave and nothing more (its parts cut, then clip): the controls never
            // push the line past the header, so they sit at the right edge, where the mode does not move them.
            titleSlot.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
            if let todos = shownTodos { AgentTodosChip(todos: todos, open: todosOpen) }
            if let xrayPane { AgentXrayButton(pane: xrayPane, target: XrayTarget.of(row)) }   // #1476: just before the "..."
            menuButton.background(XrayCardAnchor())   // #829: always last, fixed size; #1319: the list hangs from it
        }
    }

    /// #1103: Open in terminal is its first item, with the header's `open` and `ended`.
    var menuButton: AgentSessionMenuButton {
        AgentSessionMenuButton(store: menuStore, session: session, ask: ask, open: open, ended: ended, panes: panes,
                               pane: pane, keyPanes: keyPanes)
    }
}

/// #1103 F1: its child is never narrower than min(its ideal width, `floor`), and that is the width it asks for when
/// asked for its ideal: in an HStack the other parts give way before it, in a ViewThatFits it counts only its floor.
struct AgentWidthFloor: Layout {
    let floor: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        let ideal = s.sizeThatFits(.unspecified)
        let least = min(ideal.width, floor)
        guard let w = proposal.width else { return CGSize(width: least, height: ideal.height) }
        let fit = s.sizeThatFits(ProposedViewSize(width: max(w, least), height: proposal.height))
        return CGSize(width: max(fit.width, least), height: fit.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// #821 (Q4): Default's one-line todo chip; a click opens the list under the header.
struct AgentTodosChip: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let todos: AgentTodos
    @Binding var open: Bool
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: sz(4)) {
                Image(systemName: open ? "chevron.down" : "checklist")
                Text(todos.label)
            }
            .font(Neon.font(10.5, weight: .medium)).foregroundStyle(Neon.textSecondary)
            .padding(.horizontal, sz(7)).padding(.vertical, sz(2))
            .background(Capsule().fill(Neon.bgBottom.opacity(0.6)))
            .overlay(Capsule().stroke(Neon.stroke, lineWidth: 1))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(todos.label), \(open ? "hide" : "show") the list")
    }
}

struct AgentTodosList: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let todos: AgentTodos
    /// About 8 one-line rows; a longer list scrolls, so it never pushes the prompt pane off-screen.
    static var maxHeight: CGFloat { sz(8 * 16) }
    /// #1270 (QA #657 r3): shown only for a partial list (no task store, history not loaded).
    static let partialNote = "Partial list: tasks from earlier in the session are not loaded, so some may be missing or out of date."
    var body: some View {
        ScrollView { list }
            .frame(maxHeight: Self.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: sz(2)) {
            if todos.partial {
                Text(Self.partialNote)
                    .font(Neon.font(10.5)).foregroundStyle(Neon.textSecondary)
            }
            ForEach(Array(todos.rows.enumerated()), id: \.offset) { _, t in
                HStack(alignment: .firstTextBaseline, spacing: sz(6)) {
                    Image(systemName: t.status == "completed" ? "checkmark.circle.fill"
                          : t.status == "in_progress" ? "circle.dotted" : "circle")
                        .foregroundStyle(t.status == "completed" ? Neon.terminal : t.status == "in_progress" ? Neon.blue : Neon.textSecondary)
                    Text(t.text).foregroundStyle(t.status == "completed" ? Neon.textSecondary : Neon.textPrimary)
                        .strikethrough(t.status == "completed").lineLimit(2)
                }
                .font(Neon.font(11))
            }
        }
        .padding(.top, sz(2))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AgentStateChip: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let state: AgentState
    /// QA #668 INFO-4: the session ended (the window's held row): "Ended", not its last live state.
    var ended = false
    static let endedLabel = "Ended"
    /// #1239: the header's Rename field lies over the chip: the drawn chip leaves the tree (AgentHeaderRenameHidden). On the
    /// drawn chip only: the width chips keep their own hidden(), which a hidden(false) above them could override (#1120).
    var renaming = false
    /// QA #672 #3: Ended's own glyph (History rows' hollow dot), not Idle's filled one.
    static let endedGlyph = "○"
    /// The chip's words (and VoiceOver's).
    var label: String { ended ? Self.endedLabel : state.label }
    /// #828: the slot is the widest state's (Ended included), so a state change never moves the title, the
    /// picker or the button (nor flips the header to its compact form); the capsule hugs its text.
    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(AgentState.allCases, id: \.self) { chip($0.glyph, $0.label, agentStateColor($0)).hidden() }
            chip(Self.endedGlyph, Self.endedLabel, Neon.textSecondary).hidden()
            if ended {
                chip(Self.endedGlyph, label, Neon.textSecondary).modifier(AgentHeaderRenameHidden(renaming: renaming))
            } else {
                chip(state.glyph, label, agentStateColor(state), ink: state == .blocked ? AgentSidebarRowView.amberInk : nil).modifier(AgentHeaderRenameHidden(renaming: renaming))
            }
        }
        .fixedSize()
    }

    /// `ink`: the text's colour when it is not the fill's (#1451 step b: the readable amber of a light theme).
    func chip(_ glyph: String, _ label: String, _ color: Color, ink: Color? = nil) -> some View {
        HStack(spacing: sz(4)) {
            Text(glyph).font(Neon.font(9, weight: .bold))
            Text(label).font(Neon.font(10, weight: .semibold))
        }
        .foregroundStyle(ink ?? color)
        .padding(.horizontal, sz(7)).padding(.vertical, sz(2))
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }
}

struct AgentHistoryDetail: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let row: AgentSidebar.Row
    let record: DchHistoryRecord
    let store: AgentIslandStore?
    /// QA #665 INFO-6: a Remove the window refused at the answer, shown on the status line.
    var refusal: String?
    let act: (AgentWindowVerb) -> Void
    /// #1906: Close Pane for the pane this card is drawn in (AgentPanePlaceholder.close: nil with one pane).
    var close: (() -> Void)?

    var body: some View {
        VStack(spacing: sz(10)) {
            Image(systemName: "clock.arrow.circlepath").font(Neon.font(26)).foregroundStyle(Neon.indigo)
            Text(row.title).font(Neon.font(15, weight: .semibold)).foregroundStyle(Neon.textPrimary).lineLimit(1)
            Text([row.detail, AgentIsland.ago(row.age)].compactMap { $0 }.joined(separator: " · "))
                .font(Neon.font(11)).foregroundStyle(Neon.textSecondary)
            if !record.cwd.isEmpty {
                Text((record.cwd as NSString).abbreviatingWithTildeInPath).font(Neon.font(11, design: .monospaced))
                    .foregroundStyle(Neon.textSecondary).lineLimit(1).truncationMode(.middle)
            }
            if let store, let host = row.host {
                AgentRemoteResumeButton(store: store, record: record, host: host, status: refusal, act: act)
            } else if let store { AgentHistoryButtons(store: store, record: record, refusal: refusal, act: act) }
            AgentPanePlaceholder.closePill(close)
        }
        .padding(sz(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// #1324 (b): a remote record's one verb, Resume on its host (no pin, remove or no-message: those would run here),
/// and the status line in AgentHistoryButtons' fixed two-line slot.
struct AgentRemoteResumeButton: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var store: AgentIslandStore
    let record: DchHistoryRecord
    let host: String
    var status: String?
    let act: (AgentWindowVerb) -> Void

    var body: some View {
        let on = store.resumeGate.isOK && AgentIsland.passable(record.name)
        let help = "\(AgentIsland.resumeLabel) on \(AgentSidebarRowView.hostLabel(host))"
        VStack(spacing: sz(6)) {
            AgentPillButton(title: AgentIsland.resumeLabel, icon: "play.fill", tint: Neon.blue, enabled: on) { act(.resume) }
                .help(help).accessibilityLabel(help)
            ZStack {
                Text(" \n ").hidden()
                Text(status ?? " ").foregroundStyle(Neon.textSecondary)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .accessibilityHidden(status == nil)
            }
            .font(Neon.font(10.5))
        }
    }
}

/// #829 G6-G8: Resume, Resume (no message), Pin/Unpin and Remove from History… through the island
/// (its gates, its status line). Every button is always drawn, in a fixed slot (off while its gate
/// refuses, its reason in the help), so a gate or a pin never moves a neighbour.
struct AgentHistoryButtons: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var store: AgentIslandStore
    let record: DchHistoryRecord
    var refusal: String?
    let act: (AgentWindowVerb) -> Void

    var body: some View {
        let entries = AgentWindowControls.historyMenu(record, store: store)
        VStack(spacing: sz(6)) {
            HStack(spacing: sz(8)) {
                button(entries, .resume, AgentIsland.resumeLabel, icon: "play.fill", tint: Neon.blue)
                button(entries, .resumeNoMessage, AgentIsland.resumeNoMessageLabel, icon: "play", tint: Neon.textSecondary)
            }
            HStack(spacing: sz(8)) {
                // Pin and Unpin share one slot, the wider one's.
                ZStack {
                    pill(AgentIsland.unpinLabel, icon: "pin.slash", tint: Neon.textSecondary, on: true) {}.hidden()
                    pill(AgentIsland.pinLabel, icon: "pin", tint: Neon.textSecondary, on: true) {}.hidden()
                    button(entries, .pin, record.pinned ? AgentIsland.unpinLabel : AgentIsland.pinLabel,
                           icon: record.pinned ? "pin.slash" : "pin", tint: Neon.textSecondary)
                }
                button(entries, .remove, AgentIsland.removeLabel + "…", icon: "xmark", tint: Neon.magenta)
            }
            // #828: the line is always there, so a status arriving never re-centres the detail.
            let status = refusal ?? store.historyActions[record.id]
            // Two real lines' room (lineLimit's reservesSpace came out 2 pt short of a wrapped status at 1.0).
            ZStack {
                Text(" \n ").hidden()
                Text(status ?? " ").foregroundStyle(Neon.textSecondary)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .accessibilityHidden(status == nil)
            }
            .font(Neon.font(10.5))
        }
    }

    /// The menu's item for `verb` as a button: its title as help (the older records, why it is off).
    private func button(_ entries: [AgentWindowMenuEntry], _ verb: AgentWindowVerb, _ title: String, icon: String,
                        tint: Color) -> some View {
        let item = entries.lazy.compactMap { e -> (String, Bool)? in
            if case .item(let t, let on, let v) = e, v == verb { return (t, on) }
            return nil
        }.first
        let on = item?.1 ?? false
        // Absent from the menu (a gate refused): the label with the gate's reason ("Pin (needs dch 1.25.0)").
        let help = item?.0 ?? AgentWindowControls.historyOff(verb, record, store: store)
        return pill(title, icon: icon, tint: tint, on: on) { act(verb) }
            .help(help)
            .accessibilityLabel(help)
    }

    private func pill(_ title: String, icon: String, tint: Color, on: Bool, _ action: @escaping () -> Void) -> some View {
        AgentPillButton(title: title, icon: icon, tint: tint, enabled: on, action: action)
    }
}

// MARK: - #798: the pill button and the composer field (#1471 b: the Send column and the prompt panel went with the transcript)

struct AgentPillButton: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let title: String
    let icon: String
    let tint: Color
    var enabled = true
    /// #828: stretch to the width its container offers (equal-width button columns).
    var fill = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(Neon.font(11, weight: .semibold)).foregroundStyle(tint)
                .fixedSize()
                .padding(.horizontal, sz(10)).padding(.vertical, sz(5))
                .frame(maxWidth: fill ? .infinity : nil)
                .background(Capsule().fill(tint.opacity(0.12)))
                .overlay(Capsule().stroke(Neon.faded(tint, 0.45), lineWidth: 1))
                .contentShape(Capsule())
                .fixedSize(horizontal: !fill, vertical: true)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// The input box: an NSTextView, so Return sends and Shift-Return adds a line, and the
/// window's sidebar keys never reach it (`firstResponder is NSText`).
struct AgentComposerField: NSViewRepresentable {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @Binding var text: String
    var onSubmit: () -> Void
    /// QA #668 INFO-3: false for an ended session (NSTextView ignores SwiftUI's .disabled).
    var editable = true
    /// #845: the window's interaction model, which moves the keyboard here (a row click, Return, Right).
    var owner: AgentWindowInteraction?
    /// #847 D5.2: false for the New session prompt: Return adds a line and Command-Return submits.
    var returnSubmits = true
    /// #1392: VoiceOver's name for the field; nil keeps `label(editable:)`.
    var label: String?
    /// #1822: the New session prompt's image paste; nil (every other composer): paste as before.
    var imagePaste: AgentComposerTextView.ImagePaste?

    var accessibilityName: String { label ?? Self.label(editable: editable) }

    /// QA #672 #2: VoiceOver hears why the field takes nothing (only an ended session's is not editable).
    static func label(editable: Bool) -> String { editable ? "Message Claude" : "Message Claude, session ended" }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = AgentComposerTextView(frame: .zero)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: sz(4), height: sz(6))
        tv.delegate = context.coordinator
        tv.owner = owner   // #845: before it joins the window, so a pending focus lands as it does
        owner?.composer = tv
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? AgentComposerTextView else { return }
        if tv.string != text { tv.string = text }
        tv.font = .systemFont(ofSize: sz(12))
        tv.textColor = NSColor(Neon.textPrimary)
        tv.insertionPointColor = NSColor(Neon.textPrimary)
        tv.onSubmit = { context.coordinator.parent.onSubmit() }
        tv.returnSubmits = returnSubmits
        tv.imagePaste = imagePaste
        // Selectable first: a false isSelectable clears isEditable, a true isEditable sets isSelectable.
        tv.isSelectable = editable
        tv.isEditable = editable
        tv.setAccessibilityLabel(accessibilityName)
        tv.owner = owner
        owner?.composer = tv
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentComposerField
        init(_ parent: AgentComposerField) { self.parent = parent }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

final class AgentComposerTextView: NSTextView {
    var onSubmit: () -> Void = {}
    /// #847 D5.2: false: Return or Enter alone adds a line, Command-Return submits.
    var returnSubmits = true
    weak var owner: AgentWindowInteraction?

    /// #1822: where pasted images go and who hears of them (on main, after the path is inserted).
    struct ImagePaste: Sendable {
        var dir: URL
        /// #1836: a paste's encode starts; `added` ends it, whatever came of it.
        var began: @MainActor @Sendable () -> Void
        var added: @MainActor @Sendable (AgentPromptImages.Outcome) -> Void
    }
    var imagePaste: ImagePaste?

    /// #1822: with `imagePaste` set, a paste of images writes them and inserts their paths; any other paste is the
    /// text view's own.
    override func paste(_ sender: Any?) {
        guard imagePaste != nil else { return super.paste(sender) }
        paste(from: Pasteboard.general)
    }

    /// The paste from `pb` (the seam rows use, with a named pasteboard): images to `imagePaste`, else the text as
    /// NSTextView's paste reads it.
    func paste(from pb: NSPasteboard) {
        guard isEditable, let sink = imagePaste, let sources = AgentPromptImages.sources(pb) else {
            _ = readSelection(from: pb)
            return
        }
        sink.began()
        AgentPromptImages.store(sources, skipped: AgentPromptImages.skippedFiles(pb), dir: sink.dir) { [weak self] out in
            if let self, !out.made.isEmpty {
                let r = self.selectedRange(), ns = self.string as NSString
                let previous = r.location > 0 && r.location <= ns.length ? Character(ns.substring(with: NSRange(location: r.location - 1, length: 1))) : nil
                self.insertText(AgentPromptImages.insertion(out.made.map(\.path), after: previous), replacementRange: r)
            }
            sink.added(out)   // after the insert: its text change clears the note this sets
        }
    }

    /// #845: a focus asked for before the box was in the window (a row click from Terminal mode builds it next pass).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, owner?.composerFocusPending == true { owner?.focusComposer() }
    }

    /// Return or keypad Enter alone sends (returnSubmits; else adds a line, and Command-Return sends); Shift-Return
    /// adds a line; an IME's marked text keeps Return.
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() {
            if mods.isEmpty { return returnSubmits ? onSubmit() : insertNewlineIgnoringFieldEditor(nil) }
            if mods == .shift { return insertNewlineIgnoringFieldEditor(nil) }
            if mods == .command, !returnSubmits { return onSubmit() }
        }
        super.keyDown(with: event)
    }
}

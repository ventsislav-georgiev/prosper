import AppKit
import SwiftUI

// #797 Agent window D1: the "Agent Sessions" window. A sidebar of every dch session (fed by
// Agent Island's store, no new fork or poll) and the selected session's read-only
// conversation (spike A). Built on open and torn down on close, like
// MarketplaceWindow: a closed window leaves no view, model, timer or watch behind.

@MainActor
final class AgentsWindow {
    static let shared = AgentsWindow()

    private(set) var window: NSWindow?
    private(set) var model: AgentWindowModel?
    /// #831 B1 step 2 (4.1a, R899-3): the panes' last live sights, kept for the process: they outlive a window close.
    let lastLive = AgentLastLiveHome()
    private var observers: [NSObjectProtocol] = []
    var isOpen: Bool { window != nil }
    static let title = "Agent Sessions"
    static let themedIdentifier = NSUserInterfaceItemIdentifier("prosper.agentsWindow")
    static func contentMinSize(scale: CGFloat) -> NSSize { NSSize(width: 640 * scale, height: 420 * scale) }

    // Seams (QA #626 INFO-7: show and teardown run in tests with a window never put on screen).
    var island: () -> AgentIslandController = { .shared }
    var build: (AgentWindowModel) -> NSWindow = { AgentsWindow.makeWindow($0) }
    var present: (NSWindow) -> Void = { win in
        DockPolicy.windowDidShow(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
    var dismissed: (NSWindow) -> Void = { DockPolicy.windowDidHide($0) }

    func show() {
        if let window { return present(window) }
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
            nc.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.teardown(win) }
            },
            // Miniaturized, behind other windows fully, on another Space, the app hidden:
            // the transcript stops and the age clock with it (design "Energy").
            nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: win, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated { model?.setVisible(win.occlusionState.contains(.visible)) }
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
        let hosting = NSHostingController(rootView: Themed { AgentWindowRootView(model: model) })
        // #1378: no title bar safe area for SwiftUI. Under No title bar's .fullSizeContentView it would pad the content
        // by the hidden bar, and a list touching that band grows under the title row (Standard has no such band).
        hosting.safeAreaRegions = []
        let win = AgentsNSWindow(contentViewController: hosting)
        win.model = model
        // 4.2 Pick Another: the sidebar gets the keys (called on the main actor, from a button's action).
        model.focusSidebar = { [weak win] in   // the model set keyFocus = .sidebar already
            win?.makeFirstResponder(nil)
        }
        win.title = title
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // #860: Settings' chrome. The title hides (the sidebar's "Agent Sessions" header names the
        // window, and the Window menu still lists `title`); the strip is painted by applyWindowOpacity.
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        // The theme hook (AppDelegate.applyThemedWindowSizing) finds the open window by it.
        win.identifier = themedIdentifier
        let s = ThemeRuntime.scale
        win.setContentSize(NSSize(width: 1000 * s, height: 680 * s))
        win.contentMinSize = contentMinSize(scale: s)
        SettingsWindow.applyWindowOpacity(win)
        if Preferences.agentWindowStyle != .standard { applyStyle(win) }   // #1378: Standard is built as before
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
    }

    /// #1378: the rounded Borderless window's corner radius, near the system's for a window without a toolbar.
    static let cornerRadius: CGFloat = 12

    private func teardown(_ win: NSWindow) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        model?.close()
        model = nil
        window = nil
        XrayPanels.shared.open = [:]   // #1351: no panel outlives its window
        let island = island()
        island.onStoreChanged = nil
        island.onHoldChanged = nil
        dismissed(win)
        DispatchQueue.main.async { win.contentViewController = nil }
    }
}

/// ⌘W closes; up/down move the selection while the sidebar has the focus (QA #626 INFO-2): the
/// last click landed in it and Tab has not moved on since. A text field or the input box keeps every key.
/// #822: so does the terminal, except the window's own shortcuts (`route`).
/// #845: a row click, Return and Right (on an unfolded section) move the keyboard into the session.
final class AgentsNSWindow: NSWindow {
    weak var model: AgentWindowModel?
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
    /// #1378: Command-M minimises in No title bar and Borderless (Prosper has no Window menu; Standard keeps today's keys). Rows put
    /// a recorder here: the default is never run by a row.
    var minimize: (NSWindow) -> Void = { $0.miniaturize(nil) }
    static func isMinimizeChord(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command]
            && chordLetter(event) == "m"
    }
    /// #831 7.2: the model's `keyFocus` (B1 step 5); the name stays for the routes and their rows. No model: the sidebar.
    var sidebarFocused: Bool {
        get { model.map { $0.keyFocus == .sidebar } ?? true }
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
    override func resignKey() { super.resignKey(); Self.resignedKey(model); goMenu.remove(from: AgentGoMenu.mainMenu()) }
    /// #1359: the Go menu after Edit while this window is key (resignKey above takes it out).
    override func becomeKey() { super.becomeKey(); goMenu.install(in: AgentGoMenu.mainMenu()) }
    private(set) lazy var goMenu = AgentGoMenu(window: self)
    /// #1359 (tests): the last action `perform` ran, the key's or a Go menu item's.
    private(set) var lastPerformed: AgentGoMenu.Action?
    @MainActor static func resignedKey(_ m: AgentWindowModel?) { m?.dragEnded() }

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

    /// 7.6: a small state machine over the left button. A mouse-down that only focused a pane is swallowed, and so are
    /// its drags and its up; any other down starts a click that passes. Every other event type passes.
    struct FocusClick: Equatable {
        private(set) var swallowing = false
        /// True: swallow this event. `focusing` is read on a mouse-down only.
        mutating func take(_ type: NSEvent.EventType, focusing: Bool) -> Bool {
            switch type {
            case .leftMouseDown:
                swallowing = focusing
                return focusing
            case .leftMouseDragged:
                return swallowing
            case .leftMouseUp:
                let s = swallowing
                swallowing = false
                return s
            default:
                return false
            }
        }
    }

    /// #822 (spec 5.3): who gets a key.
    enum KeyRoute: Equatable {
        case close, toggleMode, verbosity(AgentVerbosity), session(Int), find, findNext(Bool)
        /// #847: ⌘N (the New session form, or its Name field when open) and ⇧⌘N (the quick shell).
        case newSession, newShell
        /// #1289 (#829 G2/G8): Cmd-Backspace on the selected row: Stop (live) or Remove from History, asked in the strip.
        case stopOrRemove
        /// #1110: ⌘1…⌘9, the numbered row at that position (1-based).
        case jump(Int)
        /// #895: the terminal's text size: +1, -1, 0 (back to today's size).
        case font(Int)
        /// Up, down, left, right, Return for the sidebar (sendEvent).
        case sidebar
        /// #1319 (spec 8.3): Command-L, the focused Transcript pane's Jump to Chapter list (opens it, or closes it when open).
        case chapters
        /// #1351 (#1346 3.1): Shift-Command-X (key code 7, any layout), the focused pane's X-ray panel (opens or closes it).
        case xray
        /// The window's, doing nothing here (⌥⌘1/2/3 in Terminal mode).
        case swallow
        case pass
    }

    enum ResponderKind { case text, terminal, other }

    var responderKind: ResponderKind {
        if firstResponder is NSText { return .text }
        return firstResponder is AgentTerminalHostView ? .terminal : .other
    }

    /// Pure: the event, the first responder's kind, the sidebar focus and the pane's mode.
    /// ⌘W, ⌘T, ⌥⌘1/2/3, ⌘F, ⌘G, ⇧⌘G, ⌘N, ⇧⌘N go to the window; ⌘↑/⌘↓ (previous / next session) too,
    /// except in a text view, where they move to its start and end (QA #669). Plain arrows and
    /// Return go to the sidebar only while it has the focus and nothing that types does.
    /// Everything else (Esc, Tab, ⌃C, arrows, Return) reaches the first responder.
    /// #829 G4: while the title is a rename field, every key but ⌘W is the field's (the
    /// verbosity keys, ⌘T, ⌘F, ⌘G, ⌘↑/⌘↓ and any shortcut added later stand down).
    /// #887 (QA #747 INFO-4): while the New session `form` covers the pane, a chord that acts on the session under it
    /// (⌘T, ⌥⌘1/2/3, ⌘F, ⌘G, ⇧⌘G, ⌘↑/⌘↓) is swallowed; ⌘W, ⌘N and ⇧⌘N stay the window's.
    /// #1110: ⌘1…⌘9 from every responder, the terminal and a text view too; it stands down for the rename field and is
    /// swallowed under the form, as ⌘↑/⌘↓.
    static func route(_ event: NSEvent, responder: ResponderKind, sidebarFocused: Bool, terminalMode: Bool,
                      renaming: Bool = false, form: Bool = false) -> KeyRoute {
        let r = paneRoute(event, responder: responder, sidebarFocused: sidebarFocused, terminalMode: terminalMode,
                          renaming: renaming)
        switch r {
        case .toggleMode, .verbosity, .session, .jump, .find, .findNext, .font, .stopOrRemove, .chapters, .xray:
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
        if let v = verbosity(for: event) { return terminalMode ? .swallow : .verbosity(v) }
        if mods == [.command] {
            if let n = digit(event.keyCode) { return .jump(n) }
            // #1289: Cmd-Backspace with the sidebar focused only; a text field, the composer and the terminal keep it.
            if event.keyCode == 51 { return sidebarFocused && responder == .other ? .stopOrRemove : .pass }
            // #1319 (v3.2.6 :2590): Command-L by key code from every responder; a terminal pane consumes it with no action (10.1).
            if isChapterKey(event) { return terminalMode ? .swallow : .chapters }
            switch key {
            case "t": return .toggleMode
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
                           terminalMode: model.paneMode == .terminal, renaming: model.renaming != nil || model.layoutRenaming != nil,
                           form: model.newSession != nil)
        return perform(r) || super.performKeyEquivalent(with: event)
    }

    /// #1359: what a pane key does, for the key (above) and the Go menu's pane items alike.
    @discardableResult func perform(pane a: PaneAction) -> Bool {
        lastPerformed = .pane(a)
        guard let model else { return false }
        return a == .nextNeedsYou ? model.nextNeedsYou() : model.perform(a)
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
        case .verbosity(let v): model.verbosity = v
        case .toggleMode:
            guard model.toggleMode() else { return false }
            model.focusSelection()   // #845: the shown mode's input, Transcript's too
        case .session(let d): model.move(d)
        case .jump(let n): model.selectNumbered(n)   // no row there: nothing, and the key stops here (no beep, not the terminal's)
        case .find: model.terminal.openFind()
        case .findNext(let forward): model.terminal.findNext(forward)
        case .font(let step): model.terminal.zoomFont(step)
        // #847: the model checks the gate; refused, the key does nothing (handled: no beep).
        case .newSession: model.openNewSession()
        case .newShell: model.startShell()
        case .stopOrRemove: model.askStopOrRemove()
        case .chapters: toggleChapters()
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
        ("1", [.command, .option], 18, .verbosity(.focused)), ("2", [.command, .option], 19, .verbosity(.default)),
        ("3", [.command, .option], 20, .verbosity(.verbose)),
        ("1", .command, 18, .jump(1)), ("2", .command, 19, .jump(2)), ("3", .command, 20, .jump(3)),
        ("4", .command, 21, .jump(4)), ("5", .command, 23, .jump(5)), ("6", .command, 22, .jump(6)),
        ("7", .command, 26, .jump(7)), ("8", .command, 28, .jump(8)), ("9", .command, 25, .jump(9)),
        ("\u{8}", .command, 51, .stopOrRemove), ("l", .command, 37, .chapters), ("t", .command, 17, .toggleMode),
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

    /// #1319 (spec 8.3, v2.1 QA4 INFO-20): Command-L is the L key's position (kVK_ANSI_L, 37) with exactly Command, on every
    /// layout (a Cyrillic one types U+0434 there); Shift-Command-L, Option-Command-L and Control-Command-L pass through.
    static func isChapterKey(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == 37
            && event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command]
    }

    // MARK: #1319 the Jump to Chapter list

    /// The list's surface (spec 8.3: a popover from the pane header's "..."). Rows put a fake here before the first key.
    var cards: XrayCardPresenter = XrayPopoverPresenter()
    /// The open list, nil while closed.
    private(set) var chapterList: TranscriptChapterListModel?

    /// Command-L and the "..." item: closes an open list; else opens one on the focused pane while it shows a session's
    /// transcript (a terminal pane, the New session form, a History row or an empty pane: nothing). On close the keys go
    /// back where they were: the composer (first responder, its draft and selection untouched) or the sidebar.
    func toggleChapters() {
        if chapterList != nil || cards.isShown {
            cards.close()   // its `closed` puts the keys back
            chapterList = nil
            return
        }
        guard let model, model.paneMode == .transcript, model.newSession == nil, model.selectedRow?.session != nil,
              let rt = model.focusedRuntime, let anchor = XrayCardAnchor.view(for: rt.pane, in: self) ?? contentView else { return }
        let list = TranscriptChapterListModel(transcript: rt.transcript, jumper: .of(rt.transcript))
        list.close = { [weak self] in self?.cards.close() }
        let focus = model.keyFocus, back = firstResponder
        chapterList = list
        cards.present(AnyView(TranscriptChapterList(list: list)), size: TranscriptChapterList.size, anchor: anchor) { [weak self] in
            guard let self else { return }
            self.chapterList = nil
            self.model?.keyFocus = focus
            if self.firstResponder !== back { self.makeFirstResponder(back) }
        }
    }

    /// The "..." item "Jump to Chapter... Command-L": on in a Transcript pane, off in a terminal pane (10.1).
    @MainActor static func chaptersItem(_ m: AgentWindowModel) -> AgentWindowMenuEntry {
        .chapters(enabled: m.paneMode == .transcript, pane: m.layout.focused)
    }

    /// The item's run: the window that draws `pane`'s header opens its list (runs on main, a menu Button's action).
    @MainActor static func chaptersChosen(pane: UUID) {
        (XrayCardAnchor.views[pane]?.view ?? XrayCardAnchor.views[nil]?.view).flatMap { $0.window as? AgentsNSWindow }?
            .toggleChapters()
    }

    // MARK: #1351 the X-ray panel (#1346 P3a)

    /// Shift-Command-X, the "..." item and the Todos chip: closes the focused pane's open panel; else opens one on `tab`
    /// for the pane's live or remote session and reads it once. Below XrayTabs.gate (XrayPanels.dch nil): false (the key
    /// passes through) and no process. `fallback` (the chip's list): run when the read finds no Tasks tab.
    @discardableResult func toggleXray(on tab: XrayTab = .tasks, fallback: (() -> Void)? = nil) -> Bool {
        guard let model, let dch = XrayPanels.dch() else { return false }
        let pane = model.layout.focused, panels = XrayPanels.shared
        let target = model.newSession == nil ? XrayTarget.of(model.selectedRow) : nil
        if let open = panels.open[pane] {
            panels.close(pane)
            if open.target == target || target == nil { return true }
        }
        guard let target else { return true }
        let p = XrayPanelModel(target: target, tab: tab)
        p.close = { panels.close(pane) }
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

    /// The window that draws `pane`'s header (as chaptersChosen).
    @MainActor static func window(of pane: UUID) -> AgentsNSWindow? {
        (XrayCardAnchor.views[pane]?.view ?? XrayCardAnchor.views[nil]?.view).flatMap { $0.window as? AgentsNSWindow }
    }

    @MainActor static func xrayChosen(pane: UUID) { window(of: pane)?.toggleXray() }

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

    /// #821: ⌥⌘1 / ⌥⌘2 / ⌥⌘3 pick Focused / Default / Verbose (no app menu item uses them).
    static func verbosity(for event: NSEvent) -> AgentVerbosity? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option] else { return nil }
        return AgentVerbosity.allCases.first { $0.keyCode == event.keyCode }
    }

    override func sendEvent(_ event: NSEvent) {
        // #900 B2 step 5a (7.5): a divider's down, drags and up go to the model before the first-click rule (gate on only).
        if AgentPaneLayout.splitsEnabled, let model, [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown].contains(event.type) {
            let r = contentLayoutRect, at = event.type == .keyDown ? CGPoint.zero : event.locationInWindow
            if Self.divider(event, model, at: CGPoint(x: at.x - r.minX, y: r.maxY - at.y), in: r.size) {
                // #900 B2 step 6b2c: the swallowed down asks for key and front as the focusing down does (its drags and up never).
                if Self.asksKey(focusing: event.type == .leftMouseDown, isKey: isKeyWindow) { raise(self) }
                return
            }
        }
        var focusing = false
        if event.type == .leftMouseDown, let model {
            // 7.2: the frames come from the model's geometry in the content (top-left origin), never x alone.
            let r = contentLayoutRect, at = event.locationInWindow
            let p = CGPoint(x: at.x - r.minX, y: r.maxY - at.y)
            let inSidebar = model.sidebarFrame(in: r.size)?.contains(p) == true
            focusing = Self.mouseDown(model, at: p, in: r.size)
            // #822: a sidebar click takes the keys from the terminal, so the arrows select again;
            // #845: from the input box too (a row's click then moves them in again, on mouse-up).
            if inSidebar, responderKind == .terminal || firstResponder is AgentComposerTextView { makeFirstResponder(nil) }
            if inSidebar { model.dropPendingFocus() }   // QA #694 INFO-2: a row's click asks again, on mouse-up
        }
        // R1196-1: `focusing` is true only for a down on an unfocused pane, which needs two panes shown: the gate on.
        if Self.asksKey(focusing: focusing, isKey: isKeyWindow) { raise(self) }
        if focusClick.take(event.type, focusing: focusing) { return }   // 7.6: the first click only focuses
        if AgentPaneLayout.splitsEnabled, let model, Self.layoutKey(event, model, responder: responderKind) { return }
        if event.type == .keyDown, event.keyCode == 48, responderKind != .terminal { sidebarFocused = false }   // Tab: focus moves on
        if let model, Self.route(event, responder: responderKind, sidebarFocused: sidebarFocused,
                                 terminalMode: model.paneMode == .terminal, renaming: model.renaming != nil || model.layoutRenaming != nil,
                                 form: model.newSession != nil) == .sidebar,
           Self.handle(event, model) { return }
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

struct AgentWindowRootView: View {
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
            if model.sidebarShown && model.sidebarMode != .slide {
                AgentSidebarView(model: model)
                    .padding(.top, AgentWindowBand.shown ? AgentWindowBand.height : 0)
                    .frame(width: model.sidebarColumnWidth)
                    .background(NeonSidebarSurface())
                Rectangle().fill(Neon.stroke).frame(width: 1)
            }
            // #831 9.1: the band over the pane area, one whatever the number of panes, only while the split gate is on
            // (AgentWindowBand.shown; AgentWindowModel.paneAreaFrame mirrors this column for the 7.2 click rule).
            Group {
                if AgentWindowBand.shown {
                    // #900 B2 step 3: the band's chip reads the pane area from this geometry (the model's paneArea is
                    // not published, so a resize to too small would not redraw the band).
                    GeometryReader { proxy in
                        VStack(spacing: 0) {
                            AgentWindowBand(model: model, area: CGRect(x: 0, y: 0, width: proxy.size.width,
                                                                       height: max(0, proxy.size.height - AgentWindowBand.height)))
                            AgentPaneArea(model: model, scrolls: scrolls)
                        }
                    }
                } else {
                    AgentPaneArea(model: model, scrolls: scrolls)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsBackground())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) { if model.sidebarMode == .slide { slideLayer } }
    }

    /// #1379 Slide: the left edge's strip (its pointer enter slides the sidebar in) and, while slid in or pinned, the full
    /// sidebar over the panes, which keep their width; the pointer leaving it slides it out.
    var slideLayer: some View {
        ZStack(alignment: .topLeading) {
            AgentSlideTracker(edge: true) { model.slide(true) }
                .frame(width: AgentSlideTracker.edgeWidth)
                .frame(maxHeight: .infinity)
            if model.slideOpen {
                HStack(spacing: 0) {
                    AgentSidebarView(model: model)
                        .padding(.top, AgentWindowBand.shown ? AgentWindowBand.height : 0)
                        .frame(width: AgentWindowModel.fullSidebarWidth)
                        .background(NeonSidebarSurface())
                    Rectangle().fill(Neon.stroke).frame(width: 1)
                }
                .background(AgentSlideTracker(edge: false) { model.slide(false) })
                .transition(.move(edge: .leading))
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
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
        case .mini: return "A narrow rail: each session's state and number; hover for its name."
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

/// #1379 Slide: a pointer tracker that never takes a click (no hit). `edge`: the window's left edge strip, whose enter
/// slides the sidebar in; else behind the slid-in sidebar, whose exit slides it out. Tests call the handlers directly.
struct AgentSlideTracker: NSViewRepresentable {
    let edge: Bool
    let action: @MainActor () -> Void
    /// A few points: the pointer at the window's very edge, never over the panes' own controls.
    static let edgeWidth: CGFloat = 4
    func makeNSView(context: Context) -> AgentSlideTrackerView { AgentSlideTrackerView(edge: edge) }
    func updateNSView(_ nsView: AgentSlideTrackerView, context: Context) { nsView.action = action }
}

final class AgentSlideTrackerView: NSView {
    let edge: Bool
    var action: @MainActor () -> Void = {}
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
        let opts: NSTrackingArea.Options = edge ? [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
            : [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .assumeInside]
        addTrackingArea(NSTrackingArea(rect: .zero, options: opts, owner: self))
    }
    override func mouseEntered(with event: NSEvent) { if edge { action() } }
    override func mouseExited(with event: NSEvent) { if !edge { action() } }
}

struct AgentSidebarView: View {
    @ObservedObject var model: AgentWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentSidebarTitleRow(model: model)
            // #897 (G9): the store's own list-wide question (the island's line), answered through its confirm call.
            if let store = model.store { AgentStoreQuestionStrip(store: store) { model.answerStoreQuestion($0) } }
            AgentAlwaysAllowStrip(model: model)
            if !model.hasStore {
                AgentEmptyState(icon: "rectangle.dashed", title: "Agent Island is off",
                                detail: "Turn on Agent Island in Settings › Extensions to list your dch sessions here.")
            } else if model.sections.isEmpty, let store = model.store {
                AgentNoSessionsState(store: store)
            } else {
                ScrollViewReader { proxy in
                    // #909 (R909-1): the groups once per draw, never per row (every row's menu reads them).
                    let groups = model.store?.groups
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: sz(2)) {
                            // #901 B3 step 4a (8.1): the first section; nil (gate off, one layout of one pane): no view.
                            // #1379 Mini: the rail lists the rows alone (no Layouts section, no headers, nothing folded).
                            let mini = model.sidebarMode == .mini
                            if !mini, let rows = model.layoutRows { AgentLayoutsSection(model: model, rows: rows) }
                            ForEach(model.sections) { section in
                                // #828: Sessions, Sidekicks and History fold on a header click
                                // (remembered per Mac); a folded section keeps its selection.
                                let folded = !mini && model.isCollapsed(section.title), inView = model.inViewRows
                                if !mini {
                                    AgentSectionHeader(title: section.title, count: section.rows.count, collapsed: folded,
                                                       toggle: AgentSidebar.collapsible.contains(section.title)
                                                           ? { model.toggleCollapsed(section.title) } : nil)
                                }
                                if !folded {
                                    ForEach(section.rows) { row in
                                        Button { model.click(row.id, flags: AgentWindowModel.clickFlags(NSApp.currentEvent)) } label: {   // #900 B2 step 6b1: read with the gate on only
                                            AgentSidebarRowView(row: row, selected: model.selection == row.id,
                                                                number: model.number(row.id), inView: inView.contains(row.id),
                                                                openPR: model.openPR, mini: mini)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {   // #829: a live row's Restart / Stop / Kill (asks); a History row's (G6-G8)
                                            if let s = row.session, let store = model.store {
                                                // #1103: the header's list, Open in terminal first (selects the row, as ask does).
                                                AgentSessionMenuItems(store: store, session: s, ask: { model.ask($0, s) },
                                                                      open: { open(s) }, row: model,
                                                                      side: { model.openToTheSide(row.id) }, groups: groups)
                                            } else if let r = row.record, row.host == nil, let store = model.store {   // #1324: a remote record has none
                                                AgentHistoryMenuItems(store: store, record: r, groups: groups) { model.act($0, r) }
                                            }
                                        }
                                        .id(ItemID(section: section.title, row: row.id))
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, sz(8)).padding(.bottom, sz(12))
                    }
                    .onChange(of: model.selection) { _, id in if let id, let item = item(id) { proxy.scrollTo(item) } }
                }
            }
            Spacer(minLength: 0)
            // #829 G0: the dir strip's fixed slot under the list (QA #665 INFO-4/5: the list ends above it).
            if let store = model.store { AgentDirStatusStrip(store: store) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// #1373: a row's identity in the one lazy list is its section and its row. With the row's id alone, a session that
    /// moved from one section to another (Needs you to Sessions, Sessions to Sidekicks) kept its old section's cell and
    /// drew its old title, state and number until the window was reopened.
    struct ItemID: Hashable {
        let section: String
        let row: AgentSidebar.RowID
    }

    /// The selection's scroll target: its row in the section that holds it now (nil: not listed).
    func item(_ id: AgentSidebar.RowID) -> ItemID? {
        model.sections.first { $0.rows.contains { $0.id == id } }.map { ItemID(section: $0.title, row: id) }
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
    func makeNSView(context: Context) -> AgentWindowDragView { AgentWindowDragView() }
    func updateNSView(_ nsView: AgentWindowDragView, context: Context) {}
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
    @ObservedObject var model: AgentWindowModel
    /// #923: the Diagnostics pane's text while it is up (read once when the item is chosen).
    @State private var diagnostics: String?

    @ViewBuilder var body: some View {
        if model.sidebarMode == .mini { miniBody } else { fullBody }
    }

    /// #1379 Mini: the rail keeps the list-wide "..." and #847's [>_] [+] (buttonsWidth fits sz(84)); the name and the count go.
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
            let n = model.sections.filter { $0.title != "History" }.reduce(0) { $0 + $1.rows.count }
            if n > 0 {
                Text(n == 1 ? "1 session" : "\(n) sessions").font(Neon.font(10.5)).foregroundStyle(Neon.textSecondary)
                    .lineLimit(1).layoutPriority(-1).allowsHitTesting(false)   // #1378: drags too
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
            }
            AgentNewSessionButtons(model: model, store: store)
        }
        .fixedSize()
    }

    /// #1103 F2: the content starts under the titlebar (no .fullSizeContentView), so the row's centre sits on the
    /// session header's title line: 14 + 18 / 2 = AgentSessionHeader's 10 + 26 / 2.
    static var padTop: CGFloat { sz(14) }
    /// #897: the trailing strip the overlay holds: the "..." slot, the gap, #847's pair.
    static var buttonsWidth: CGFloat { AgentNewSessionButtons.width + sz(4) + sz(18) }
}

/// #901 B3 step 4a (8.1 :625-631): the Layouts section, built only from `model.layoutRows` (gate on and the show rule).
/// Header: the section label and count, then "+" (New layout); at 9 layouts the "+" is disabled and the fixed words
/// "(9 layouts max)" show. Rows: "⌃N", the name (one line, middle-truncated), the fixed empty attention slot (step 5);
/// the active row in accent text. Height: the header plus one fixed-height row per layout (text height at the scale +
/// sz paddings); the "⌃N" label and the words are fixedSize, never an sz frame on text. Not in `sections`, so out of the
/// up/down walk and the ⌘1…9 jump. Closures run on the main actor (Buttons, the field's handlers).
/// Step 4b: the header folds through agentWindowCollapsedSections ("Layouts"; folded: rows left out, the active layout
/// unchanged); each row's context menu draws AgentWindowControls.layoutMenu (Rename opens the inline field in place of
/// the name, Duplicate, Delete); the row being renamed is drawn without its Button, the field over the name's own slot.
struct AgentLayoutsSection: View {
    @ObservedObject var model: AgentWindowModel
    let rows: [AgentWindowModel.LayoutRow]
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
                AgentLayoutRowView(row: r, edit: model.layouts?.layouts.first { $0.id == r.id }?.name ?? "") {
                    model.endLayoutRename(r.id, $0)
                }
            } else {
                Button { Self.click(model, r) } label: { AgentLayoutRowView(row: r) }
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
    /// #901 B3 step 5: the dot and count read aloud; nothing for 0 (the slot draws nothing).
    static func value(_ r: AgentWindowModel.LayoutRow) -> String {
        r.blocked == 0 ? "" : r.blocked == 1 ? "1 session needs input" : "\(r.blocked) sessions need input"
    }
}

/// #901 B3 step 4b: a Layouts row's inline name field: Return ends with the text (the model cleans it), Escape, the focus
/// leaving and the field going away end with nil; each ends once (the model ignores a second end). Main actor.
struct AgentLayoutNameField: View {
    let placeholder: String
    @State var text: String
    let end: (String?) -> Void
    @FocusState private var focused: Bool
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
        TextField(placeholder, text: $text).textFieldStyle(.plain).font(Neon.font(12.5, weight: .medium))
            .foregroundStyle(Neon.textPrimary).lineLimit(1)
            .accessibilityLabel("Layout name")
            .focused($focused)
            .onSubmit { finish(text) }
            .onExitCommand { finish(nil) }
            .onAppear { focused = true }
            .onChange(of: focused) { was, now in if was, !now { finish(nil) } }
            .onDisappear { finish(nil) }
    }
}

/// #901 B3 step 4a: one Layouts row ("⌃N  name" and the attention slot).
struct AgentLayoutRowView: View {
    let row: AgentWindowModel.LayoutRow
    /// Step 4b: the inline rename field's first text; nil: no field.
    var edit: String?
    /// The field's end, once: Return's text, or nil (Escape, the focus left, the field gone). Main actor.
    var end: (String?) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: sz(8)) {
            Text("⌃\(row.number)").font(Neon.font(10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Neon.textSecondary).fixedSize()
            Text(row.name).font(Neon.font(12.5, weight: .medium))
                .foregroundStyle(row.active ? Neon.blue : Neon.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                // Step 4b: the field lies over the name's slot, the name goes transparent: no frame moves.
                .opacity(edit == nil ? 1 : 0).accessibilityHidden(edit != nil)
                .overlay(alignment: .leading) { if let edit { AgentLayoutNameField(placeholder: row.name, text: edit, end: end) } }
            Spacer(minLength: 0)
            Color.clear.frame(width: AgentLayoutsSection.attentionWidth, height: 1)   // the attention slot
        }
        .padding(.horizontal, sz(10)).padding(.vertical, sz(5))
        .frame(maxWidth: .infinity, alignment: .leading)
        // #901 B3 step 5 (section 10): an inactive layout's blocked count, a dot and the number over the slot (an
        // overlay: no frame moves; 0 builds nothing). The sidebar's blocked colour; read aloud through the row's value.
        .overlay(alignment: .trailing) {
            if row.blocked > 0 {
                HStack(spacing: sz(2)) {
                    Circle().fill(agentStateColor(.blocked)).frame(width: sz(5), height: sz(5))
                    Text("\(row.blocked)").font(Neon.font(9.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(agentStateColor(.blocked)).fixedSize()
                }
                .frame(width: AgentLayoutsSection.attentionWidth, alignment: .trailing)
                .padding(.trailing, sz(10))
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

struct AgentSectionHeader: View {
    let title: String
    let count: Int
    /// #828: folded (rows hidden; the count stays).
    var collapsed = false
    /// #828: nil for a section that never folds (Needs you): no chevron, no button.
    var toggle: (() -> Void)?

    var body: some View {
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

struct AgentSidebarRowView: View {
    let row: AgentSidebar.Row
    let selected: Bool
    /// #1110: the row's ⌘<n> (1…9), nil for no chip.
    var number: Int?
    /// #900 B2 step 4b (7.2): the session is shown in another pane of the active layout (AgentWindowModel.inViewRows).
    var inView = false
    /// #1289 (G5): a URL chip's click, the model's openURL seam (nothing opens from a row itself).
    var openPR: @MainActor (AgentIsland.PRChip) -> Void = { _ in }
    /// Tests: a row part's frame in the row, by kind and row title (nil in the product). Main actor.
    static var probe: ((String, String, CGRect) -> Void)?
    /// #1379: Mini's rail row.
    var mini = false

    @ViewBuilder var body: some View {
        if mini { miniBody } else { fullBody }
    }

    /// The row's one accessibility label (#1379: Mini's tooltip and label too).
    var accessibilityWords: String {
        ([row.title, row.record?.pinned == true ? "pinned" : nil,
          AgentPaneLayout.splitsEnabled && inView ? "in view" : nil, row.detail, row.modelWords] + row.countWords
         + [AgentIsland.ago(row.age)]).compactMap { $0 }.joined(separator: ", ")
    }

    /// #1289 (G5): the element ignores its children, so each URL chip is an action on it, as on the island's row.
    var prActions: some View {
        ForEach(row.prLinks.indices, id: \.self) { i in
            if row.prLinks[i].url != nil {
                Button(AgentWindowControls.openPRLabel(row.prLinks[i])) { openPR(row.prLinks[i]) }
            }
        }
    }

    /// #1379 Mini: the state mark, the Command-<n> chip (its column kept without one) and the needs-you mark (blocked or done);
    /// the full row's words are its tooltip and its one VoiceOver label.
    var miniBody: some View {
        let needs = row.session.map(AgentSidebar.needsYou) ?? false
        return HStack(spacing: sz(4)) {
            stateMark
            ZStack {
                Self.digitColumn
                if let number {
                    AgentDigitChip(number: number, active: selected).modifier(AgentSidebarRowProbe(kind: "miniChip", title: row.title))
                }
            }
            Circle().fill(agentStateColor(.blocked)).frame(width: sz(6), height: sz(6)).opacity(needs ? 1 : 0)
                .modifier(AgentSidebarRowProbe(kind: needs ? "miniNeeds" : "miniSlot", title: row.title))
        }
        .padding(.horizontal, sz(6)).padding(.vertical, sz(7))
        .frame(maxWidth: .infinity, alignment: .leading)
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
            // #1345: the ⌘<n> chip's own column on EVERY row (the widest digit's chip, at no height), so the badges and
            // the age end at one edge with a number or none and the row's height never changes.
            Self.digitColumn
                .anchorPreference(key: AgentDigitChipSlot.self, value: .bounds) { AgentDigitChipSlot.Value(column: $0) }
                .modifier(AgentSidebarRowProbe(kind: "chipColumn", title: row.title))
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
            if let column = slot.column, let block = slot.block, let number {
                GeometryReader { proxy in
                    AgentDigitChip(number: number, active: selected)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Command-\(number)")
                        .help("Select this session (⌘\(number))")
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
    @ViewBuilder func body(content: Content) -> some View {
        if AgentSidebarRowView.probe != nil {
            content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(agentSidebarRowSpace)) }) { r in
                agentProbeCalled()
                AgentSidebarRowView.probe?(kind, title, r)
            }
        } else {
            content
        }
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

/// #1110: a numbered row's ⌘<n> chip, Clipboard History's position keycap (ClipboardPanel.swift's PositionKeyCap: private
/// there, and its glyph follows the clipboard's ⌘/⌃ setting while this chord is always ⌘). Brighter on the selected row.
/// Neon.blue, not the keycap's blueBright: a theme that sets only its accent leaves blueBright at the default cyan.
struct AgentDigitChip: View {
    let number: Int
    var active = false

    var body: some View {
        HStack(spacing: sz(1)) {
            Text("\u{2318}")
            Text("\(number)")
        }
        .font(Neon.font(10, weight: .bold, design: .rounded))
        .foregroundStyle(active ? Neon.bgTop : Neon.blue)
        .padding(.horizontal, sz(5))
        .padding(.vertical, sz(2))
        .background(
            RoundedRectangle(cornerRadius: sz(4))
                .fill(active ? Neon.blue : Neon.bgBottom)
                .overlay(
                    RoundedRectangle(cornerRadius: sz(4))
                        .strokeBorder(Neon.faded(Neon.blue, active ? 0.9 : 0.6), lineWidth: 1))
        )
        .fixedSize()
    }
}

extension AgentSidebarRowView {
    /// The state mark's slot (#1371: moved out of `body` unchanged, the island's session row draws it too).
    var stateMark: some View {
        Group {   // #829 G7: a pinned History record's glyph, in the same slot
            if row.record?.pinned == true {
                Image(systemName: "pin.fill").font(Neon.font(9, weight: .bold)).foregroundStyle(Self.ink(.quiet, selected: selected))
            } else {
                Text(row.state?.glyph ?? "\u{25CB}")
                    .font(Neon.font(11, weight: .bold))
                    .foregroundStyle(row.state == nil ? Neon.faded(Neon.textSecondary, 0.6) : agentStateColor(row.state))
            }
        }
        .frame(width: sz(14))
    }

    /// #1345: the ⌘<n> chip's column, the widest digit's chip at no height (digits are proportional: the nine together are
    /// the widest whatever the font); the row draws the chip over it, only with a number.
    static var digitColumn: some View {
        ZStack { ForEach(1...9, id: \.self) { AgentDigitChip(number: $0) } }.hidden().frame(height: 0)
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
            let withBadges = badges && row.modelSlot
            let title = Text(row.title).font(Neon.font(12.5, weight: .medium))
                .foregroundStyle(row.state == nil ? Self.ink(.quiet, selected: selected) : Neon.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .modifier(AgentSidebarRowProbe(kind: "title", title: row.title))
            if withBadges {
                AgentWidthFloor(floor: Self.badgeTitleFloor) { title }.layoutPriority(1)
            } else {
                title
            }
            Spacer(minLength: sz(4))
            if AgentPaneLayout.splitsEnabled {
                // #900 B2 step 4b (7.2, #828 slot rule): the "in view" glyph's slot is always laid out with
                // the gate on (hidden by opacity, never removed), so the title never moves; gate off: no slot.
                Image(systemName: "eye").font(Neon.font(9, weight: .semibold)).foregroundStyle(Self.ink(.quiet, selected: selected))
                    .frame(width: sz(14)).opacity(inView ? 1 : 0)
                    .modifier(AgentSidebarRowProbe(kind: inView ? "glyph" : "slot", title: row.title))
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
        case .blocked: return agentStateColor(.blocked)
        }
    }
    /// #1360: the subagents count's outline: textPrimary, selected or not (3:1 over the row on all 22 themes, and stronger
    /// than the quiet ink of the counts beside it on an unselected row; AgentCountOutlineTests).
    static func outlineInk(selected: Bool) -> Color { Neon.textPrimary }

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
    static func badge(_ text: String, _ look: BadgeLook) -> some View {
        let p = ThemeRuntime.palette
        return Text(text).font(Neon.font(8.5, weight: .medium)).foregroundStyle(p[keyPath: look.text])
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
        HStack(spacing: sz(3)) {
            if !effortOnly { Self.badge(Self.modelWidest, Self.neutralLook) }
            Self.badge(Self.effortWidest, Self.neutralLook)
        }
        .hidden()
        .overlay(alignment: .trailing) {
            let all = Self.badges(model: row.model, effort: row.effort, selected: selected)
            let shown = effortOnly ? Array(all.dropFirst()) : all
            HStack(spacing: sz(3)) {
                // The effort badge (second) keeps its word whole before the model's name is cut.
                ForEach(shown.indices, id: \.self) { i in Self.badge(shown[i].text, shown[i].look).layoutPriority(Double(i)) }
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
        ZStack(alignment: .trailing) {
            Text(AgentIsland.ageWidest).hidden()
            Text(row.age).foregroundStyle(Self.ink(.quiet, selected: selected))
        }
        .font(Neon.font(10).monospacedDigit())
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
            Text(row.detail).font(Neon.font(10.5))
                .foregroundStyle(row.state == .blocked ? Self.ink(.blocked, selected: selected) : Self.ink(.quiet, selected: selected))
                .lineLimit(1)
            AgentCountGroups(counts: row.counts + (open > 0 ? [(AgentSidebar.Count.open, open)] : []), size: 10.5,
                             quiet: Self.ink(.quiet, selected: selected), open: Self.ink(.blue, selected: selected),
                             outline: Self.outlineInk(selected: selected))
            ForEach(Array(Self.chipLinks(chips, row.prLinks).enumerated()), id: \.offset) { _, entry in
                let pr = entry.text
                let chip = Text(pr).font(Neon.font(9.5, weight: .medium, design: .monospaced)).foregroundStyle(Self.ink(.blue, selected: selected))
                    .padding(.horizontal, sz(4)).padding(.vertical, sz(1))
                    .background(RoundedRectangle(cornerRadius: sz(3)).fill(Neon.blue.opacity(0.12)))
                    .fixedSize()
                // #1289 (G5): a chip whose URL passed the allowlist is a button (the island's help); else text, as before.
                if let link = entry.link {
                    Button { openPR(link) } label: { chip }
                        .buttonStyle(.plain).help(link.help).accessibilityLabel(AgentWindowControls.openPRLabel(link))
                } else {
                    chip
                }
            }
            Spacer(minLength: 0)
            if !row.age.isEmpty || row.state != nil { ageSlot }
            if let h = row.remote?.host ?? row.host { Self.hostSlot(h, selected: selected) }   // #1324: a remote History row's too
        }
    }

    /// #836 (a): the host label, in a slot of one fixed width on every remote row, so a longer host never moves the
    /// line and a row's width never flickers; a long name is cut in the middle.
    static let hostWidth: CGFloat = 84
    /// #1330 (R836-q2): a host from dch is outside text: shown through OutsideText.shown; argv and keys keep it raw.
    static func hostLabel(_ host: String) -> String { OutsideText.shown(host) }
    static func hostSlot(_ host: String, selected: Bool = false) -> some View {
        Text(hostLabel(host)).font(Neon.font(10, weight: .medium)).foregroundStyle(ink(.quiet, selected: selected))
            .lineLimit(1).truncationMode(.middle)
            .frame(width: sz(hostWidth), alignment: .trailing)
            .help("On \(hostLabel(host))")
    }
}

/// #836 (b): a remote session's header: its title and host, then the transcript controls drawn disabled with their
/// reason (a remote session has no transcript, todo list or view level here) and the mode toggle fixed on Terminal.
struct AgentRemoteHeader: View {
    let row: AgentSidebar.Row
    let remote: AgentSidebar.Remote

    static let modeReason = "A session on another machine opens in Terminal only"
    static let levelReason = "No transcript for a session on another machine"
    static let todosReason = "No task list on that host"
    static let todosOpens = "Open the task list in X-ray"
    let pane: UUID
    /// The row whose last chip click found no Tasks tab (a click on another session starts clean).
    @State private var none: AgentSidebar.RowID? = nil

    static func todosHelp(noList: Bool) -> String { noList ? todosReason : todosOpens }

    /// The chip's click: X-ray on Tasks as the local chip does; no list to fall back to, so `none` runs when X-ray is off
    /// or the read finds no Tasks tab.
    @MainActor static func todosTapped(in win: AgentsNSWindow?, none: @escaping () -> Void) {
        win?.todosChipTapped(listOpen: false, list: none)
    }

    var body: some View {
        HStack(alignment: .center, spacing: sz(8)) {
            Text(row.title).font(Neon.font(15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(AgentSidebarRowView.hostLabel(remote.host)).font(Neon.font(11, weight: .medium)).foregroundStyle(Neon.textSecondary).lineLimit(1)
            Spacer(minLength: sz(4))
            let noList = none == row.id
            Button { Self.todosTapped(in: AgentsNSWindow.window(of: pane)) { none = row.id } } label: {
                Image(systemName: "checklist").font(Neon.font(11)).foregroundStyle(Neon.textSecondary).opacity(noList ? 0.45 : 1)
            }
            .buttonStyle(.plain).help(Self.todosHelp(noList: noList)).accessibilityLabel(Self.todosOpens)
            .accessibilityValue(noList ? Self.todosReason : "")
            if !AgentWindowBand.shown {
                // The picker's own buttons carry their own help, which would win over a reason set around them.
                Image(systemName: AgentVerbosity.default.icon).font(Neon.font(11)).foregroundStyle(Neon.textSecondary)
                    .opacity(0.45).help(Self.levelReason).accessibilityLabel("View").accessibilityValue(Self.levelReason)
            }
            AgentPaneModeToggle(mode: .terminal, style: .icons, set: { _ in }, off: Self.modeReason)
                .disabled(true).opacity(0.45)
        }
        .padding(.horizontal, sz(16)).padding(.vertical, sz(10))
    }
}

/// #1115: a session's count groups (the sidebar row and the header): symbol plus number, a wider gap between groups.
/// Each reads its words as help and to VoiceOver; the open PRs' group wears the chips' blue. Never cut (fixedSize).
struct AgentCountGroups: View {
    let counts: [(AgentSidebar.Count, Int)]
    let size: CGFloat
    /// #1271: the inks of the other groups and of the open PRs' group (the selected sidebar row's, see `AgentSidebarRowView.ink`).
    var quiet = Neon.textSecondary
    var open = Neon.blue
    /// #1360: the agents group's outline ink (a capsule, stroke only, its padding in the group's width); nil: none (the header).
    var outline: Color?

    var body: some View {
        if !counts.isEmpty {   // no empty slot in the caller's HStack (it would add a spacing)
            HStack(spacing: sz(6)) {
                ForEach(Array(counts.enumerated()), id: \.offset) { _, g in
                    let ring = g.0 == .agents ? outline : nil
                    HStack(spacing: sz(2)) {
                        Image(systemName: g.0.symbol).font(Neon.font(size - 1))
                        Text(AgentIsland.count(g.1)).font(Neon.font(size).monospacedDigit())
                    }
                    .padding(.horizontal, ring == nil ? 0 : sz(4))
                    .background {   // no vertical padding: the line's height stays (31/39/45)
                        if let ring {
                            Capsule().strokeBorder(ring, lineWidth: 1)
                                .modifier(AgentSidebarRowProbe(kind: "capsule.\(g.0)", title: g.0.words(g.1)))
                        }
                    }
                    .modifier(AgentSidebarRowProbe(kind: "count.\(g.0)", title: g.0.words(g.1)))
                    .foregroundStyle(g.0 == .open ? open : quiet)
                    .fixedSize()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(g.0.words(g.1))
                    .help(g.0.words(g.1))   // after the element: a help set on an ignored child never reaches AX
                }
            }
        }
    }
}

/// The sidebar with no session and no record. #887 (QA #747 INFO-7): + and ⌘N are named only while they work.
struct AgentNoSessionsState: View {
    @ObservedObject var store: AgentIslandStore

    var body: some View {
        AgentEmptyState(icon: "terminal", title: "No agent sessions", detail: Self.detail(canStart: store.resumeGate.isOK))
    }

    static func detail(canStart: Bool) -> String {
        "Sessions started with dch show up here." + (canStart ? " Press + or ⌘N to start one." : "")
    }
}

struct AgentEmptyState<Extra: View>: View {
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
    @ObservedObject var model: AgentWindowModel
    @ObservedObject var transcript: AgentTranscriptModel
    /// False for offscreen evidence (no ScrollView).
    var scrolls = true
    /// #831 B1 step 4 (9.2): more than one pane shown: the one-line header (one pane: the full header).
    var compact = false

    /// QA #668 F1: the input box's lock store; nil for an ended session's held row (the plain, ended pane).
    var inputStore: AgentIslandStore? { model.focusedEnded ? nil : model.store }

    var body: some View {
        if let form = model.newSession {
            // #847: the form in place of the pane's content (the selected session's terminal detaches meanwhile).
            // D5.4: a short window scrolls the form instead of clipping Start.
            if scrolls {
                ScrollView(.vertical) { AgentNewSessionView(model: model, form: form) }
            } else {
                AgentNewSessionView(model: model, form: form)
            }
        } else if let row = model.selectedRow, let s = row.session {
            // QA #668 F1: an ended session's held row is display-only.
            let ended = model.focusedEnded
            let mode = model.paneMode
            VStack(spacing: 0) {
                // #900 B2 step 6a: the "⋯" pane items act on this pane (the focused one); empty with the gate off.
                let id = model.layout.focused
                let panes = [.divider, AgentsNSWindow.chaptersItem(model)] + [AgentsNSWindow.xrayItem(model)].compactMap { $0 }
                    + AgentWindowControls.paneMenu(model, pane: id)
                Group {
                    if compact {
                        AgentCompactHeader.of(row, s, cwd: transcript.cwd, ended: ended, store: model.store,
                                              ask: { model.ask($0, s) }, open: { model.openSelected() },
                                              mode: mode, setMode: { model.switchMode($0, for: s) }, panes: panes,
                                              pane: { AgentWindowControls.runPane($0, pane: id, in: model) })
                    } else {
                        AgentSessionHeader(row: row, session: s, cwd: transcript.cwd, open: { model.openSelected() },
                                           level: $model.verbosity, todos: transcript.todos,
                                           todosOpen: todosChip(mode == .terminal ? floatingTodos : $transcript.todosOpen),
                                           store: model.store, ask: { model.ask($0, s) }, ended: ended,
                                           rename: ended ? nil : model.renameEdit.flatMap { $0.key == s.key ? $0 : nil },
                                           endRename: { model.endRename($0, $1) },
                                           mode: mode, setMode: { model.switchMode($0, for: s) }, panes: panes,
                                           pane: { AgentWindowControls.runPane($0, pane: id, in: model) })
                    }
                }
                .modifier(AgentPaneProbe(kind: "header"))
                Rectangle().fill(Neon.stroke).frame(height: 1)
                VStack(spacing: 0) {
                    if mode == .terminal {
                        terminalPane(row, s)
                    } else {
                        transcriptPane(row, s, ended: ended)
                    }
                }
                .overlay(alignment: .trailing) { XrayDrawer(pane: id, target: XrayTarget.of(row)) }   // #1351: over, never resizing
            }
        } else if let row = model.selectedRow, let r = row.remote {
            // #836 (b): another machine's session: Terminal only, under a header whose transcript controls are off.
            VStack(spacing: 0) {
                AgentRemoteHeader(row: row, remote: r, pane: model.layout.focused).modifier(AgentPaneProbe(kind: "header"))
                Rectangle().fill(Neon.stroke).frame(height: 1)
                AgentTerminalPane(controller: model.terminal, open: {})
                    .frame(minHeight: 0, maxHeight: .infinity)
                    .modifier(AgentPaneProbe(kind: "terminal"))
                    .overlay(alignment: .trailing) { XrayDrawer(pane: model.layout.focused, target: XrayTarget.of(row)) }
            }
        } else if let row = model.selectedRow, let r = row.record {
            titled(row.title) {
                AgentHistoryDetail(row: row, record: r, store: model.store,
                                   refusal: model.refusalText(row.id) ?? model.remoteResumeText[r.id],
                                   act: { model.act($0, r) })
                    // #829 G8: Remove asks, over the pane's top. #900 6b2d (fixed slots): one slot, the question wins it, so
                    // the strip never moves; the refusal line takes it once the question is gone.
                    .overlay(alignment: .top) { VStack(spacing: 0) { if model.confirming == nil { paneRefusalLine }; confirmStrip } }
            }
        } else if let title = AgentPanePlaceholder.title(model.content) {
            // 4.2 (QA 956 R1217-a): a pane that holds a target whose session is gone says so by name; the list (and Pick
            // Another) still picks another session into it. Same slot as the empty pane's below.
            let pane = model.layout.focused
            titled(title) {
                AgentPanePlaceholder(title: title, close: model.layout.panes.count > 1 ? { model.closePane(pane) } : nil,
                                     pick: { model.pickAnother(pane) })
                    .overlay(alignment: .top) { paneRefusalLine }
            }
        } else {
            titled("") { emptyPane.overlay(alignment: .top) { paneRefusalLine } }
        }
    }

    /// 9.2: with several panes, every content keeps the one-line header's height above it (table 4.2: only the body
    /// swaps); one pane: the body alone, as before.
    @ViewBuilder func titled<B: View>(_ title: String, @ViewBuilder _ body: () -> B) -> some View {
        if compact {
            VStack(spacing: 0) {
                AgentCompactHeader(title: title).modifier(AgentPaneProbe(kind: "header"))
                Rectangle().fill(Neon.stroke).frame(height: 1)
                body()
            }
        } else {
            body()
        }
    }

    /// No target: today's state (the hint and the New session pill, #847).
    var emptyPane: some View {
            AgentEmptyState(icon: "sidebar.left", title: "Select a session",
                            detail: "Up and down move through the list; Return or a click moves into it.") {
                AgentPillButton(title: "New session", icon: "plus", tint: Neon.blue,
                                enabled: model.store?.resumeGate.isOK == true) { model.openNewSession() }
                    .help(AgentNewSessionButtons.help("New session… (⌘N)", refusal: model.store?.resumeGate.refusal))
                    .accessibilityLabel("New session")
                    .padding(.top, sz(4))
            }
    }

    @ViewBuilder func transcriptPane(_ row: AgentSidebar.Row, _ s: AgentSession, ended: Bool) -> some View {
        AgentTranscriptView(model: transcript, scrolls: scrolls, openTerminal: { model.openSelected() },
                            ownsLifecycle: false, level: model.verbosity, ended: ended, jumper: .of(transcript))
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
            .overlay(alignment: .top) { overTop(row, s) }   // #829 R5, QA #665 INFO-1: over the conversation, so nothing moves
        Rectangle().fill(Neon.stroke).frame(height: 1)
        // #798: the prompt pinned at the bottom, the input box under it. #829: locked while a Restart or Stop types.
        if let store = inputStore {
            AgentLockedInteraction(store: store, model: model.interaction, session: s, open: { model.openSelected() })
        } else {
            AgentInteractionPane(model: model.interaction, session: s, open: { model.openSelected() }, ended: ended)
        }
    }

    /// #822 (spec 5.4): the terminal to the window's bottom, no prompt panel or input box (the terminal
    /// is both). The notice, the question and the todo list float over its top, so nothing that
    /// changes with state ever resizes it.
    func terminalPane(_ row: AgentSidebar.Row, _ s: AgentSession) -> some View {
        AgentTerminalPane(controller: model.terminal, open: { model.openSelected() })
            .frame(minHeight: 0, maxHeight: .infinity)
            .modifier(AgentPaneProbe(kind: "terminal"))   // tests only: the terminal's own frame, before the overlay (nil probe: nothing)
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    overTop(row, s)
                    if transcript.todosOpen, model.verbosity == .default, let todos = transcript.todos {
                        AgentTodosList(todos: todos)
                            .padding(.horizontal, sz(16)).padding(.bottom, sz(8))
                            .background(Neon.card)
                            .overlay(alignment: .bottom) { Rectangle().fill(Neon.stroke).frame(height: 1) }
                    }
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
            confirmStrip
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

    /// R5: the question, re-read from the store each draw (a gone session or record draws none).
    @ViewBuilder var confirmStrip: some View {
        if let c = model.confirming {
            let text = model.confirmingSession.map { AgentWindowControls.question(c.verb, $0, others: model.confirmingOthers) }
                ?? model.confirmingRecord.map { AgentWindowControls.removeQuestion($0, in: model.store?.history ?? []) }
            if let text {
                AgentConfirmStrip(text: text, action: AgentWindowControls.confirmTitle(c.verb),
                                  confirm: { model.confirm(true) }, cancel: { model.confirm(false) })
            }
        }
    }
}

// MARK: - #831 B1 step 5b: the band (9.1)

/// The band's coordinate space (AgentWindowBand.probe frames are in it).
let agentBandSpace = "agentWindowBand"

/// #831 9.1: the window-level band over the pane area, one row of 30·s whatever the number of panes, shown only while
/// the split gate is on (`shown`; #1224: off, the window is the parent's and the header draws the picker). Slots, left to
/// right: the layout slot (empty before the Layouts section) and the chip slot (zoom and too small: `chip`), the
/// All slot (its room kept, empty until phase C: no control, no text, no accessibility element), the verbosity picker
/// (moved in from the session header). Fixed slots: each slot's size comes from the UI scale alone. A narrow band gives
/// way in `Tier` order: the chip slot first, then the layout slot, then the picker's icons, then its menu; the All slot
/// and the picker never go.
struct AgentWindowBand: View {
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
    /// #901 B3 step 4b: the layout slot's row, the Layouts section's active one; nil (gate off, one layout of one pane):
    /// nothing is built in the slot.
    @MainActor static func layoutSlot(_ m: AgentWindowModel) -> AgentWindowModel.LayoutRow? { m.layoutRows?.first { $0.active } }
    static var height: CGFloat { sz(30) }
    /// shortcut: fixed widths for slots that draw nothing before B2/B3/C; the phase that fills one sizes it to its widest.
    static var layoutWidth: CGFloat { sz(100) }
    static var allWidth: CGFloat { sz(140) }
    /// #900 B2 step 4: the show-sidebar glyph's square slot.
    static var sidebarWidth: CGFloat { sz(22) }
    /// 3.4's chip at the 6-pane cap: the chip slot's widest variant.
    static let chipWidest = "5 panes hidden, window too small"

    /// Widest first, so ViewThatFits takes the first that fits: the order in which the slots give way.
    enum Tier: CaseIterable { case full, noChip, noLayout, icons, menu }

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
        let on = Self.transcriptShown(model)
        let chip = Self.chip(model, in: area ?? model.paneArea)
        ViewThatFits(in: .horizontal) {
            line(.full, on: on, chip: chip)
            line(.noChip, on: on, chip: chip)
            line(.noLayout, on: on, chip: chip)
            line(.icons, on: on, chip: chip)
            line(.menu, on: on, chip: chip)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .modifier(AgentBandProbe(kind: "band"))
        .coordinateSpace(.named(agentBandSpace))
    }

    func line(_ t: Tier, on: Bool, chip: String?) -> some View {
        HStack(spacing: sz(8)) {
            // Slots that give way are left out of the stack, never zero-width (a zero-width child still takes a spacing).
            if t == .full || t == .noChip {
                Color.clear.frame(width: Self.layoutWidth).accessibilityHidden(true)
                    // #901 B3 step 4b (9.1 :708): "⌃N name" of the active layout over the slot's fixed room, only while the
                    // Layouts section is built (layoutRows: gate on and the show rule); else the slot stays empty.
                    .overlay(alignment: .leading) {
                        if let r = Self.layoutSlot(model) {
                            HStack(spacing: sz(6)) {
                                Text("⌃\(r.number)").font(Neon.font(10.5, weight: .medium).monospacedDigit())
                                    .foregroundStyle(Neon.textSecondary).fixedSize()
                                Text(r.name).font(Neon.font(11, weight: .medium)).foregroundStyle(Neon.textPrimary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .frame(maxWidth: Self.layoutWidth, alignment: .leading)
                            .accessibilityElement(children: .combine).accessibilityLabel(AgentLayoutsSection.label(r))
                            .modifier(AgentBandProbe(kind: "layoutName"))
                        }
                    }
                    .modifier(AgentBandProbe(kind: "layout"))
            }
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
            AgentVerbosityPicker(level: $model.verbosity, style: t == .menu ? .menu : t == .icons ? .icons : .labels)
                .disabled(!on).opacity(on ? 1 : 0.45)
                .modifier(AgentBandProbe(kind: "picker"))
        }
        .padding(.horizontal, sz(16))
        .frame(maxWidth: .infinity)   // the ideal width still decides the tier; the taken line spans the band
    }

    /// 9.1 (#822 5.1, window-wide): some shown pane draws a transcript. The focused pane as AgentDetailView draws it (a
    /// session row, no New session form, Transcript mode); any other shown pane as AgentUnfocusedPane does.
    /// shortcut: the band observes the window model only, so an unfocused pane's own change (gate on) shows at the
    /// model's next publish; upgrade when B2 lets a person see two panes.
    static func transcriptShown(_ m: AgentWindowModel) -> Bool {
        m.shownPanes.contains { id in   // #900 B2 step 3: a zoomed-away pane is not drawn
            if id == m.layout.focused {
                return m.newSession == nil && m.selectedRow?.session != nil && m.paneMode == .transcript
            }
            guard let r = m.runtimes[id] else { return false }
            return AgentUnfocusedPane(model: m, runtime: r, transcript: r.transcript, interaction: m.interaction).shown != nil
        }
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
    @ObservedObject var model: AgentWindowModel
    var scrolls = true
    /// Tests only: (part, pane, frame in the area) as "pane", "header" and "composer" are laid out.
    static var probe: ((String, UUID, CGRect) -> Void)?
    /// R900-5a-2, pure: the resize cursor of a divider: left-right for columns (a vertical line), up-down for rows.
    static func cursor(_ axis: PaneNode.Axis) -> NSCursor { axis == .columns ? .resizeLeftRight : .resizeUpDown }

    var body: some View {
        GeometryReader { proxy in
            let area = CGRect(origin: .zero, size: proxy.size)
            let frames = Self.drawn(model, in: area)
            let compact = frames.count > 1
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
                        // 13: more than one pane shown: each pane one container, "<title>, pane i of n".
                        .modifier(AgentPaneContainer(label: label))
                        .modifier(AgentPaneProbe(kind: "pane"))
                        .environment(\.agentPaneID, id)
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
            .coordinateSpace(.named(agentPaneAreaSpace))
            .onAppear { feed(area) }
            .onChange(of: proxy.size) { _, size in feed(CGRect(origin: .zero, size: size)) }
        }
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

    /// R1193-4: the area's size reaches the model, once per size.
    func feed(_ area: CGRect) {
        if model.paneArea != area { model.paneArea = area }
    }

    @ViewBuilder func pane(_ id: UUID, compact: Bool) -> some View {
        if id == model.layout.focused {
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

/// 7.6: an unfocused pane's dim. It takes no hits (the window's first-click rule decides) and is hidden from
/// accessibility (13).
struct AgentPaneDim: View {
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

/// #831 B1 step 4: a pane that does not hold the input (reachable only with the split gate set, 15.0): the compact
/// header, the pane's own transcript and the inert composer slot (5.1); its History card without buttons (a press on
/// an unfocused pane focuses it first: step 5); the 4.2 placeholders.
struct AgentUnfocusedPane: View {
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
                AgentCompactHeader.of(p.row, p.session, cwd: transcript.cwd, ended: ended, store: model.store,
                                      ask: { model.ask($0, p.session) }, open: { model.openSession(p.session) },
                                      mode: .transcript, setMode: { model.switchMode($0, for: p.session) },
                                      // #900 B2 step 6a: this pane's items; choosing one focuses this pane first.
                                      panes: AgentWindowControls.paneMenu(model, pane: runtime.pane),
                                      pane: { AgentWindowControls.runPane($0, pane: runtime.pane, in: model) })
                    .modifier(AgentPaneProbe(kind: "header"))
                Rectangle().fill(Neon.stroke).frame(height: 1)
                AgentTranscriptView(model: transcript, scrolls: scrolls, ownsLifecycle: false, level: model.verbosity,
                                    ended: ended, jumper: .of(transcript))
                    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .clipped()
                Rectangle().fill(Neon.stroke).frame(height: 1)
                AgentInertComposer(text: AgentInertComposer.text(draft: interaction.draft(for: p.session.key),
                                                                 title: p.row.title, ended: ended),
                                   blocked: !ended && p.session.state == .blocked)
            } else {
                let title = AgentPanePlaceholder.title(runtime.content)
                AgentCompactHeader(title: historyTitle ?? title ?? "").modifier(AgentPaneProbe(kind: "header"))
                Rectangle().fill(Neon.stroke).frame(height: 1)
                if case .history(let r)? = runtime.content {
                    AgentHistoryDetail(row: model.row(.history(r.id)) ?? AgentSidebar.row(r, now: model.now()), record: r,
                                       store: nil, act: { _ in })
                } else if let title {
                    AgentPanePlaceholder(title: title, close: { model.closePane(runtime.pane) },
                                         pick: { model.pickAnother(runtime.pane) })
                } else {
                    AgentEmptyState(icon: "sidebar.left", title: "Select a session", detail: AgentPanePlaceholder.detail)
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

    var body: some View {
        AgentEmptyState(icon: "moon.zzz", title: title, detail: Self.detail) {
            HStack(spacing: sz(8)) {
                if let close { AgentPillButton(title: "Close Pane", icon: "xmark", tint: Neon.textSecondary, action: close) }
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
    let title: String
    var project: String?
    var chip: AgentStateChip?
    var mode = AgentPaneMode.transcript
    var setMode: ((AgentPaneMode) -> Void)?
    var ended = false
    var menu: AgentSessionMenuButton?

    static var height: CGFloat { sz(26) }

    static func of(_ row: AgentSidebar.Row, _ s: AgentSession, cwd: String?, ended: Bool, store: AgentIslandStore?,
                   ask: @escaping (AgentWindowVerb) -> Void, open: @escaping () -> Void, mode: AgentPaneMode,
                   setMode: @escaping (AgentPaneMode) -> Void, panes: [AgentWindowMenuEntry] = [],
                   pane: @escaping (AgentPaneVerb) -> Void = { _ in }) -> AgentCompactHeader {
        AgentCompactHeader(title: row.title, project: AgentSessionHeader.project(cwd: cwd, session: s),
                           chip: AgentStateChip(state: s.state, ended: ended), mode: mode, setMode: setMode, ended: ended,
                           menu: AgentSessionMenuButton(store: ended ? nil : store, session: s, ask: ask, open: open, ended: ended,
                                                        panes: panes, pane: pane))
    }

    var body: some View {
        HStack(alignment: .center, spacing: sz(8)) {
            AgentProjectTitle(text: Text(title).font(Neon.font(13, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                .lineLimit(1).truncationMode(.middle), label: title, project: project, help: project.map { "\(title)\n\($0)" })
            if let chip { chip }
            Spacer(minLength: 0)
            if let setMode {
                AgentPaneModeToggle(mode: mode, style: .icons, set: setMode, off: ended ? AgentPaneModeToggle.endedReason : nil)
                    .disabled(ended).opacity(ended ? 0.45 : 1)
            }
            if let menu { menu.background(XrayCardAnchor()) }   // #1319: the list's popover hangs from it
        }
        .padding(.horizontal, sz(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .clipped()
    }
}

/// #1191, R1191-1: a header title: the folder is its tooltip and accessibility value only when there is one, so a title
/// with none keeps its own words as value; the words stay its label.
struct AgentProjectTitle<T: View>: View {
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

/// #831 5.1: the composer slot of a pane that does not hold the input: the row only, at the focused row's height,
/// dimmed and inert, hidden from accessibility (13, QA INFO-7). The session's draft (first line), else "Message <title>…";
/// a blocked session: "Needs input · ⌘J"; Ended: the ended placeholder.
struct AgentInertComposer: View {
    let text: String
    var blocked = false
    @Environment(\.agentComposerTwoLines) private var twoLines

    static let needsInput = "Needs input · ⌘J"

    static func text(draft: String, title: String, ended: Bool) -> String {
        if ended { return AgentInteractionPane.endedPlaceholder }
        let line = draft.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces).isEmpty ? "Message \(title)…" : line
    }

    var body: some View {
        let h = AgentInteractionPane.rowHeight(twoLines: twoLines)
        HStack(alignment: .bottom, spacing: sz(8)) {
            ZStack(alignment: .topLeading) {
                Color.clear
                if blocked {
                    Text(Self.needsInput).font(Neon.font(10.5, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                        .padding(.horizontal, sz(7)).padding(.vertical, sz(2))
                        .background(Capsule().fill(Neon.blue.opacity(0.2)))
                        .padding(.horizontal, sz(6)).padding(.vertical, sz(6))
                } else {
                    Text(text).font(Neon.font(12)).foregroundStyle(Neon.textSecondary)
                        .lineLimit(1).truncationMode(.tail).padding(.horizontal, sz(9)).padding(.vertical, sz(7))
                }
            }
            .frame(height: h)
            .background(RoundedRectangle(cornerRadius: sz(8)).fill(Neon.bgBottom))
            .overlay(RoundedRectangle(cornerRadius: sz(8)).stroke(Neon.stroke, lineWidth: 1))
            AgentSendColumn(canInterrupt: false, canSend: false, interrupt: {}, send: {}, side: twoLines)
        }
        .frame(height: h)
        .modifier(AgentPaneProbe(kind: "composer"))
        .padding(.horizontal, sz(16)).padding(.vertical, sz(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(0.5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
    let row: AgentSidebar.Row
    let session: AgentSession
    let cwd: String?
    let open: () -> Void
    /// #821: the window's verbosity, the session's todo list (Default's chip) and whether
    /// its list is open (the transcript model's, reset on a session switch).
    var level: Binding<AgentVerbosity> = .constant(.default)
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
    /// #822: Terminal | Transcript (the window passes `setMode`; without it there is no toggle).
    var mode = AgentPaneMode.transcript
    var setMode: ((AgentPaneMode) -> Void)?
    /// #900 B2 step 6a: the "⋯" pane items (empty with the gate off) and their run.
    var panes: [AgentWindowMenuEntry] = []
    var pane: (AgentPaneVerb) -> Void = { _ in }

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
            // #1103: Transcript mode keeps its second line (the picker takes the first line's room the extras need).
            // #1191: a fixed slot: the hidden 11 pt text line gives it its height with no counts, no age and no todo chip,
            // as the age's own text would (a placeholder, not a minHeight: it reads the font's metrics at every scale).
            if mode == .transcript {
                // A ZStack, not a stack child: a zero-width first child still takes one spacing (the line would start 6 pt in).
                ZStack(alignment: .leading) {
                    Text(" ").font(Neon.font(11)).hidden().accessibilityHidden(true)
                    HStack(spacing: sz(6)) {
                        folder
                        Spacer(minLength: 0)
                        if let todos = shownTodos { AgentTodosChip(todos: todos, open: todosOpen) }
                    }
                }
            }
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
                            if mode == .terminal { Text("·").accessibilityHidden(true) }   // after the chip; nothing leads Transcript's line
                            // #1239: under the field only in Terminal mode (Transcript's second line is not in the slot).
                            AgentCountGroups(counts: row.counts, size: 11)
                                .modifier(AgentHeaderRenameHidden(renaming: renaming && mode == .terminal))
                            if let ago {
                                if !row.counts.isEmpty { Text("·").accessibilityHidden(true) }   // a count never runs into "4m ago"
                                Text(ago).modifier(AgentHeaderRenameHidden(renaming: renaming && mode == .terminal))
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
        if mode == .terminal {
            ViewThatFits(in: .horizontal) {
                slotLine(folder: true)
                slotLine(folder: false)
            }
        } else {
            slotLine(folder: false)
        }
    }

    /// #1103 F1: a title keeps about 9 characters before the extras are dropped.
    static var titleFloor: CGFloat { sz(80) }

    /// The title, the chip and, with `folder`, the counts and age: the title keeps its floor there, so ViewThatFits
    /// takes this line exactly when the floor, the chip and the extras fit (the extras are dropped first).
    func slotLine(folder withFolder: Bool) -> some View {
        HStack(alignment: .center, spacing: sz(8)) {
            let title = AgentProjectTitle(text: Text(row.title).font(Neon.font(15, weight: .semibold))
                .foregroundStyle(Neon.textPrimary).lineLimit(1).truncationMode(.tail), label: row.title, project: project)
                .modifier(AgentHeaderRenameHidden(renaming: renaming))
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

    /// Focused hides todos; Verbose draws the todo/task cards in the conversation instead.
    var shownTodos: AgentTodos? { level.wrappedValue == .default ? todos : nil }

    /// Widest first: the labelled picker and toggle, the icons, menus.
    @ViewBuilder var titleLines: some View {
        ViewThatFits(in: .horizontal) {
            titleLine(picker: .labels)
            titleLine(picker: .icons)
            titleLine(picker: .menu)
        }
    }

    /// #1103: the title line. Its size (and so the tier ViewThatFits picks) is the same in both modes: the whole
    /// title, the chips, the picker, the toggle and the "⋯", measured hidden. The line drawn over it puts the toggle
    /// and the "⋯" at the right edge, so a mode change never moves them; Terminal mode draws no picker, and its
    /// folder takes that room.
    func titleLine(picker: AgentVerbosityPicker.Style) -> some View {
        HStack(alignment: .center, spacing: sz(8)) {
            Text(row.title).font(Neon.font(15, weight: .semibold)).lineLimit(1)
            stateChip
            if let todos = shownTodos { AgentTodosChip(todos: todos, open: todosOpen) }
            // #831 9.1: the picker's room counts here whether the header or the band (AgentWindowBand.shown) draws it,
            // so the header picks its tier at the same widths and the toggle and the "⋯" stay where they were.
            AgentVerbosityPicker(level: level, style: picker)
            if setMode != nil { AgentPaneModeToggle(mode: mode, style: picker, set: { _ in }) }
            Color.clear.frame(width: sz(18), height: sz(18))   // the "⋯"
        }
        .hidden()
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity)
        .overlay { shownLine(picker: picker) }
    }

    func shownLine(picker: AgentVerbosityPicker.Style) -> some View {
        HStack(alignment: .center, spacing: sz(8)) {
            // The slot takes what the controls leave and nothing more (its parts cut, then clip): the controls never
            // push the line past the header, so they sit at the right edge, where the mode does not move them.
            titleSlot.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
            if mode == .terminal, let todos = shownTodos { AgentTodosChip(todos: todos, open: todosOpen) }
            // #1103: none in Terminal mode. #831 9.1: with the band shown the picker is the band's, not drawn here.
            if mode == .transcript && !AgentWindowBand.shown { AgentVerbosityPicker(level: level, style: picker) }
            if let setMode {
                AgentPaneModeToggle(mode: mode, style: picker, set: setMode,
                                    off: ended ? AgentPaneModeToggle.endedReason : nil)
                    .disabled(ended).opacity(ended ? 0.45 : 1)
            }
            menuButton.background(XrayCardAnchor())   // #829: always last, fixed size; #1319: the list hangs from it
        }
    }

    /// #1103: Open in terminal is its first item, with the header's `open` and `ended`.
    var menuButton: AgentSessionMenuButton {
        AgentSessionMenuButton(store: menuStore, session: session, ask: ask, open: open, ended: ended, panes: panes,
                               pane: pane)
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

/// #821: Focused | Default | Verbose. Plain buttons in a capsule, not a segmented Picker:
/// segmented controls ignore ThemeRuntime.scale (they clip below 1.0).
struct AgentVerbosityPicker: View {
    enum Style { case labels, icons, menu }
    @Binding var level: AgentVerbosity
    var style = Style.labels

    var body: some View {
        if style == .menu {
            Menu {
                ForEach(AgentVerbosity.allCases, id: \.self) { v in
                    Button("\(v.title) (\(v.shortcut))") { level = v }
                }
            } label: {
                Image(systemName: level.icon).font(Neon.font(11, weight: .medium)).foregroundStyle(Neon.textPrimary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize()
            .help("\(level.title) view")
            .accessibilityLabel("View: \(level.title)")
        } else {
            HStack(spacing: 0) {
                ForEach(AgentVerbosity.allCases, id: \.self) { v in
                    Button { level = v } label: {
                        Group {
                            if style == .icons { Image(systemName: v.icon) } else { Text(v.title) }
                        }
                        .font(Neon.font(10.5, weight: .medium))
                        .foregroundStyle(v == level ? Neon.textPrimary : Neon.textSecondary)
                        .padding(.horizontal, sz(8)).padding(.vertical, sz(3))
                        .background(Capsule().fill(v == level ? Neon.blue.opacity(0.2) : .clear))
                        .contentShape(Capsule())
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help("\(v.title) view (\(v.shortcut))")
                    .accessibilityLabel("\(v.title) view")
                    .accessibilityAddTraits(v == level ? .isSelected : [])
                }
            }
            .padding(sz(2))
            .overlay(Capsule().stroke(Neon.stroke, lineWidth: 1))
            .fixedSize()
        }
    }
}

/// #822: Terminal | Transcript, built like AgentVerbosityPicker (same tiers). Every label keeps its
/// width whichever is on, so a toggle never moves a neighbour. #1103: the default (Terminal) on the left.
struct AgentPaneModeToggle: View {
    let mode: AgentPaneMode
    var style = AgentVerbosityPicker.Style.labels
    let set: (AgentPaneMode) -> Void
    /// Why there is no terminal to show (an ended session); the caller disables the toggle.
    var off: String?

    static let endedReason = "This session ended: there is no terminal to attach to"
    static let modes: [(mode: AgentPaneMode, title: String, icon: String)] = [
        (.terminal, "Terminal", "terminal"), (.transcript, "Transcript", "text.bubble"),
    ]

    var body: some View {
        if style == .menu {
            Menu {
                ForEach(Self.modes, id: \.title) { m in Button("\(m.title) (⌘T)") { set(m.mode) } }
            } label: {
                Image(systemName: mode == .terminal ? "terminal" : "text.bubble")
                    .font(Neon.font(11, weight: .medium)).foregroundStyle(Neon.textPrimary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            // #1103: framed as the "⋯" is: a fixed-size Menu took each glyph's own width, so the switch's left edge
            // moved by a point with the mode.
            .frame(width: sz(22), height: sz(18))
            .help(off ?? "Terminal or transcript (⌘T)")
            .accessibilityLabel("Showing: \(mode == .terminal ? "Terminal" : "Transcript")")
        } else {
            HStack(spacing: 0) {
                ForEach(Self.modes, id: \.title) { m in
                    Button { if m.mode != mode { set(m.mode) } } label: {
                        Group {
                            if style == .icons { Image(systemName: m.icon) } else { Text(m.title) }
                        }
                        .font(Neon.font(10.5, weight: .medium))
                        .foregroundStyle(m.mode == mode ? Neon.textPrimary : Neon.textSecondary)
                        .padding(.horizontal, sz(8)).padding(.vertical, sz(3))
                        .background(Capsule().fill(m.mode == mode ? Neon.blue.opacity(0.2) : .clear))
                        .contentShape(Capsule())
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help(off ?? "\(m.title) (⌘T)")
                    .accessibilityLabel(m.title)
                    .accessibilityAddTraits(m.mode == mode ? .isSelected : [])
                }
            }
            .padding(sz(2))
            .overlay(Capsule().stroke(Neon.stroke, lineWidth: 1))
            .fixedSize()
        }
    }
}

/// #821 (Q4): Default's one-line todo chip; a click opens the list under the header.
struct AgentTodosChip: View {
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
    let todos: AgentTodos
    /// About 8 one-line rows; a longer list scrolls, so it never pushes the prompt pane off-screen.
    static var maxHeight: CGFloat { sz(8 * 16) }
    var body: some View {
        ScrollView { list }
            .frame(maxHeight: Self.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: sz(2)) {
            if todos.partial {
                Text("Tasks from the loaded part of the transcript only")
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
                chip(state.glyph, label, agentStateColor(state)).modifier(AgentHeaderRenameHidden(renaming: renaming))
            }
        }
        .fixedSize()
    }

    func chip(_ glyph: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: sz(4)) {
            Text(glyph).font(Neon.font(9, weight: .bold))
            Text(label).font(Neon.font(10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, sz(7)).padding(.vertical, sz(2))
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }
}

struct AgentHistoryDetail: View {
    let row: AgentSidebar.Row
    let record: DchHistoryRecord
    let store: AgentIslandStore?
    /// QA #665 INFO-6: a Remove the window refused at the answer, shown on the status line.
    var refusal: String?
    let act: (AgentWindowVerb) -> Void

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
        }
        .padding(sz(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// #1324 (b): a remote record's one verb, Resume on its host (no pin, remove or no-message: those would run here),
/// and the status line in AgentHistoryButtons' fixed two-line slot.
struct AgentRemoteResumeButton: View {
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

// MARK: - #798: the input box, interrupt and prompt answers

/// Under the conversation: the prompt panel (pinned), the last action's notice, the input box.
struct AgentInteractionPane: View {
    @ObservedObject var model: AgentWindowInteraction
    let session: AgentSession
    let open: () -> Void
    /// #829 (spec 3.5): a Restart or Stop's running text on this session; nil: none.
    var lock: String?
    /// QA #668 F1: the session ended (a held row): nothing is sent, interrupted or answered.
    var ended = false
    /// #831 B1 step 4 (5.1): the pane area's: more than one row of panes shown.
    @Environment(\.agentComposerTwoLines) private var twoLines

    /// 5.1: the composer row's fixed height, from the UI scale and the layout alone (never focus or state): 60·s, or 44·s
    /// (two lines) when more than one row of panes is shown.
    static func rowHeight(twoLines: Bool) -> CGFloat { twoLines ? sz(44) : sz(60) }

    var canSend: Bool {
        (session.state == .idle || session.state == .done) && !model.busy && lock == nil && !ended
            && AgentWindowDriver.message(model.draft) != nil
    }

    var canInterrupt: Bool { session.state == .working && !model.busy && lock == nil && !ended }

    static let endedPlaceholder = "This session ended"

    var placeholder: String {
        if ended { return Self.endedPlaceholder }
        if let lock { return AgentWindowControls.lockPlaceholder(lock) }
        return switch session.state {
        case .blocked: "Answer the prompt above first"
        case .working: "Claude is working. Type now, send when it's done"
        case .idle, .done: "Message Claude. Return sends, Shift-Return adds a line"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(8)) {
            AgentPromptPanel(model: model, open: open).disabled(lock != nil || ended)
            if let n = model.notice { AgentActionNotice(text: n, open: open) }
            HStack(alignment: .bottom, spacing: sz(8)) {
                ZStack(alignment: .topLeading) {
                    // QA #668 INFO-3: an ended session's field neither edits nor reads as editable; same slot.
                    // QA #672 #2: no .disabled here: it never reached the NSTextView; `editable` is what turns it off.
                    AgentComposerField(text: $model.draft, onSubmit: { if canSend { model.send() } }, editable: !ended,
                                       owner: model)
                    if model.draft.isEmpty {
                        Text(placeholder).font(Neon.font(12)).foregroundStyle(Neon.textSecondary)
                            .lineLimit(1).padding(.horizontal, sz(9)).padding(.vertical, sz(7))
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: Self.rowHeight(twoLines: twoLines))
                .background(RoundedRectangle(cornerRadius: sz(8)).fill(Neon.bgBottom))
                .overlay(RoundedRectangle(cornerRadius: sz(8)).stroke(Neon.stroke, lineWidth: 1))
                AgentSendColumn(canInterrupt: canInterrupt, canSend: canSend,
                                interrupt: { model.interrupt() }, send: { model.send() }, side: twoLines)
            }
            .frame(height: Self.rowHeight(twoLines: twoLines))
            .modifier(AgentPaneProbe(kind: "composer"))
        }
        .padding(.horizontal, sz(16)).padding(.vertical, sz(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        // #860: on the window's backdrop (its input box keeps its own field fill).
    }
}

/// #828: Interrupt over Send in one fixed column. Both are always there and stretch to the
/// wider one's width; Interrupt only dims when Claude is not working, so the input box
/// beside the column never changes width.
struct AgentSendColumn: View {
    let canInterrupt: Bool
    let canSend: Bool
    let interrupt: () -> Void
    let send: () -> Void
    /// #831 5.1: the 44·s row has no room for two pills one above the other: side by side there.
    var side = false
    var body: some View {
        let stack = side ? AnyLayout(HStackLayout(spacing: sz(6))) : AnyLayout(VStackLayout(spacing: sz(6)))
        stack {
            AgentPillButton(title: "Interrupt", icon: "stop.fill", tint: Neon.magenta, enabled: canInterrupt, fill: true,
                            action: interrupt)
                .help("Press Esc in the session")
            AgentPillButton(title: "Send", icon: "arrow.up", tint: Neon.blue, enabled: canSend, fill: true, action: send)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct AgentPillButton: View {
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

/// Why the window did not (or could not confirm it did) act, with the way out.
struct AgentActionNotice: View {
    let text: String
    let open: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: sz(8)) {
            Image(systemName: "exclamationmark.triangle.fill").font(Neon.font(11)).foregroundStyle(AgentState.blocked.color)
            Text(text).font(Neon.font(11.5)).foregroundStyle(Neon.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: sz(4))
            OpenInTerminalButton(action: open, compact: true)
        }
    }
}

struct AgentPromptPanel: View {
    @ObservedObject var model: AgentWindowInteraction
    let open: () -> Void

    var body: some View {
        switch model.panel {
        case .none:
            EmptyView()
        case .reading:
            status("ellipsis.circle", "Reading the prompt…")
        case .held:
            status("checkmark.shield", AgentWindowText.held)
        case .terminal(let why, let tail):
            VStack(alignment: .leading, spacing: sz(6)) {
                AgentActionNotice(text: why, open: open)
                screenLines(Array(tail.suffix(4)))
            }
        case .prompt(let w):
            prompt(w)
        }
    }

    func status(_ icon: String, _ text: String) -> some View {
        HStack(spacing: sz(6)) {
            Image(systemName: icon).foregroundStyle(Neon.textSecondary)
            Text(text).foregroundStyle(Neon.textSecondary)
            Spacer(minLength: 0)
        }
        .font(Neon.font(11.5))
    }

    func screenLines(_ lines: [String]) -> some View {
        Text(lines.map(AgentPrompt.visible).joined(separator: "\n"))
            .font(Neon.font(10.5, design: .monospaced)).foregroundStyle(Neon.textSecondary)
            .lineLimit(Self.contextLines).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static let contextLines = 8

    func prompt(_ w: AgentWindowPrompt) -> some View {
        let p = w.screen.prompt
        let context = p.context.filter { !AgentPrompt.isChipLine($0) }
        return VStack(alignment: .leading, spacing: sz(6)) {
            // #802: why a plan approval's approve rows are off, with the way out.
            if let why = w.why { AgentActionNotice(text: why, open: open) }
            // #802: an approvable plan shows the transcript's plan (checked against the screen), whole.
            if let plan = w.plan { planText(plan) } else if !context.isEmpty { screenLines(context) }
            Text(AgentPrompt.visible(p.question)).font(Neon.font(12.5, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if w.kind == .preview, !p.preview.isEmpty { screenLines(p.preview) }
            ForEach(w.buttons, id: \.digit) { o in option(w, o) }
            if let other = w.other {
                HStack(spacing: sz(8)) {
                    Text("\(other.digit).").font(Neon.font(11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Neon.textSecondary)
                    // #802: on a multi-select the text goes with Submit (and ticks its box there).
                    TextField(w.kind == .multi ? "Your own answer (optional)" : "Your own answer", text: $model.otherText)
                        .textFieldStyle(.roundedBorder).font(Neon.font(12))
                        .onSubmit { if w.kind == .multi { model.submitPicks() } else { model.sendOther() } }
                    if w.kind != .multi {
                        AgentPillButton(title: "Answer", icon: "arrow.up", tint: Neon.blue,
                                        enabled: !model.busy && AgentWindowDriver.otherText(model.otherText) != nil) {
                            model.sendOther()
                        }
                    }
                }
            }
            if let chat = w.chat { option(w, chat) }
            if w.kind == .multi {
                HStack {
                    Spacer(minLength: 0)
                    AgentPillButton(title: "Submit", icon: "checkmark", tint: Neon.blue,
                                    enabled: !model.busy && !w.enabled.isEmpty) {
                        model.submitPicks()
                    }
                }
            }
            if !w.caption.isEmpty {
                Text(w.caption.joined(separator: " ")).font(Neon.font(10.5)).foregroundStyle(Neon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// #802: the transcript's plan, scrolled in a box (a plan is often longer than the pane).
    func planText(_ plan: String) -> some View {
        ScrollView {
            Text(Self.planDisplay(plan))
                .font(Neon.font(10.5, design: .monospaced)).foregroundStyle(Neon.textPrimary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(sz(8))
        }
        .frame(height: sz(Self.planHeight))
        .background(RoundedRectangle(cornerRadius: sz(7)).fill(Neon.bgBottom))
        .overlay(RoundedRectangle(cornerRadius: sz(7)).stroke(Neon.stroke, lineWidth: 1))
    }

    static let planHeight: CGFloat = 150

    /// The plan as shown: the transcript's text, which the screen check cannot vouch for character by
    /// character (the renderer may drop what it can't draw), so every hidden character is escaped
    /// (⟨U+202E⟩). Line by line: a newline is no hidden character here.
    static func planDisplay(_ plan: String) -> String {
        plan.components(separatedBy: "\n").map(AgentPrompt.visible).joined(separator: "\n")
    }

    func option(_ w: AgentWindowPrompt, _ o: AgentPromptOption) -> some View {
        let isChat = o.digit == w.chat?.digit
        let on = (w.enabled.contains(o.digit) || isChat) && !model.busy
        let ticked = model.picks.contains(o.digit)
        return Button {
            if isChat { return model.chat() }
            switch w.kind {
            case .choose: model.answer(o)
            case .preview: model.choosePreview(o)
            case .multi: if ticked { model.picks.remove(o.digit) } else { model.picks.insert(o.digit) }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: sz(8)) {
                if w.kind == .multi, !isChat {
                    Image(systemName: ticked ? "checkmark.square.fill" : "square")
                        .font(Neon.font(12)).foregroundStyle(ticked ? Neon.blue : Neon.textSecondary)
                } else {
                    Text("\(o.digit).").font(Neon.font(11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Neon.textSecondary)
                }
                VStack(alignment: .leading, spacing: sz(2)) {
                    Text(AgentPrompt.visible(o.label)).font(Neon.font(12, weight: .medium))
                        .foregroundStyle(o.style(first: o.digit == 1) == .deny ? Neon.magenta : Neon.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !o.detail.isEmpty {
                        Text(o.detail.map(AgentPrompt.visible).joined(separator: " ")).font(Neon.font(10.5))
                            .foregroundStyle(Neon.textSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if w.kind == .preview, w.screen.caret == o.digit {
                    Text("previewed").font(Neon.font(9.5)).foregroundStyle(Neon.textSecondary)
                }
            }
            .padding(.horizontal, sz(10)).padding(.vertical, sz(6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: sz(7)).fill(Neon.cardHi))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!on)
        .opacity(on ? 1 : 0.45)
    }
}

/// The input box: an NSTextView, so Return sends and Shift-Return adds a line, and the
/// window's sidebar keys never reach it (`firstResponder is NSText`).
struct AgentComposerField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    /// QA #668 INFO-3: false for an ended session (NSTextView ignores SwiftUI's .disabled).
    var editable = true
    /// #845: the window's interaction model, which moves the keyboard here (a row click, Return, Right).
    var owner: AgentWindowInteraction?
    /// #847 D5.2: false for the New session prompt: Return adds a line and Command-Return submits.
    var returnSubmits = true

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
        // Selectable first: a false isSelectable clears isEditable, a true isEditable sets isSelectable.
        tv.isSelectable = editable
        tv.isEditable = editable
        tv.setAccessibilityLabel(AgentComposerField.label(editable: editable))
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

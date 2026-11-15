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
        win.isReleasedWhenClosed = false
        if let autosave { win.setFrameAutosaveName(autosave) }
        if !(autosave.map { win.setFrameUsingName($0) } ?? false) { win.centerOnScreen() }
        win.clampToContentMinSize()
        return win
    }

    private func teardown(_ win: NSWindow) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        model?.close()
        model = nil
        window = nil
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
    /// #831 7.2: the model's `keyFocus` (B1 step 5); the name stays for the routes and their rows. No model: the sidebar.
    var sidebarFocused: Bool {
        get { model.map { $0.keyFocus == .sidebar } ?? true }
        set { model?.keyFocus = newValue ? .sidebar : .pane }
    }
    /// 7.6: the focusing click's down, drags and up are swallowed together.
    private(set) var focusClick = FocusClick()
    /// R6.9 (tests): every first-responder change asked of this window, AppKit's own included.
    private(set) var responderAsks = 0

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
        /// #1110: ⌘1…⌘9, the numbered row at that position (1-based).
        case jump(Int)
        /// Up, down, left, right, Return for the sidebar (sendEvent).
        case sidebar
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
        case .toggleMode, .verbosity, .session, .jump, .find, .findNext: return form ? .swallow : r
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
            switch key {
            case "t": return .toggleMode
            case "f": return terminalMode ? .find : .pass
            case "g": return terminalMode ? .findNext(true) : .pass
            default: break
            }
            if event.keyCode == 126 || event.keyCode == 125 {
                return responder == .text ? .pass : .session(event.keyCode == 126 ? -1 : 1)
            }
        }
        if mods == [.command, .shift], key == "g" { return terminalMode ? .findNext(false) : .pass }
        if mods.isEmpty, sidebarFocused, responder == .other, [126, 125, 123, 124, 36, 76].contains(event.keyCode) {
            return .sidebar
        }
        return .pass
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
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
        if let a = PaneKeys.treeAction(for: event, context: pane, renaming: model.renaming != nil,
                                       form: model.newSession != nil), model.perform(a) { return true }
        switch Self.route(event, responder: responderKind, sidebarFocused: sidebarFocused,
                          terminalMode: model.paneMode == .terminal, renaming: model.renaming != nil,
                          form: model.newSession != nil) {
        case .close: performClose(nil)
        case .verbosity(let v): model.verbosity = v
        case .toggleMode:
            guard model.toggleMode() else { return super.performKeyEquivalent(with: event) }
            model.focusSelection()   // #845: the shown mode's input, Transcript's too
        case .session(let d): model.move(d)
        case .jump(let n): model.selectNumbered(n)   // no row there: nothing, and the key stops here (no beep, not the terminal's)
        case .find: model.terminal.openFind()
        case .findNext(let forward): model.terminal.findNext(forward)
        // #847: the model checks the gate; refused, the key does nothing (handled: no beep).
        case .newSession: model.openNewSession()
        case .newShell: model.startShell()
        case .swallow: break
        case .sidebar, .pass: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// #882: the letter a chord matches. On a Cyrillic, Greek or Hebrew layout `charactersIgnoringModifiers` is
    /// the layout's own letter and the Command-modified `characters` the Latin one (what menu key equivalents
    /// match), so either one fires a chord; `characters` wins when both are chord letters. The letter, not the
    /// key position, stays the rule.
    /// #887: on "Dvorak - QWERTY ⌘" the two differ on Latin keys too (Command gives the QWERTY character), so with
    /// Command held and Option not, a printable ASCII `characters` decides alone: ⌘, there is Settings, not ⌘W.
    /// With Option held the rule above stays (⌥⌘W types an ASCII character on the Finnish/Norwegian Extended and
    /// Sami layouts, and must still close).
    static func chordLetter(_ event: NSEvent) -> String? {
        let typed = event.characters?.lowercased()
        let mods = event.modifierFlags
        if mods.contains(.command), !mods.contains(.option), let typed, typed.unicodeScalars.count == 1,
           typed.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }) { return typed }
        if let typed, chordLetters.contains(typed) { return typed }
        return event.charactersIgnoringModifiers?.lowercased()
    }

    static let chordLetters: Set<String> = ["w", "t", "f", "g", "n"]

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
        var focusing = false
        if event.type == .leftMouseDown, let model {
            // 7.2: the frames come from the model's geometry in the content (top-left origin), never x alone.
            let r = contentLayoutRect, at = event.locationInWindow
            let p = CGPoint(x: at.x - r.minX, y: r.maxY - at.y)
            let inSidebar = model.sidebarFrame(in: r.size)?.contains(p) == true
            focusing = model.mouseDown(at: p, in: r.size)
            // #822: a sidebar click takes the keys from the terminal, so the arrows select again;
            // #845: from the input box too (a row's click then moves them in again, on mouse-up).
            if inSidebar, responderKind == .terminal || firstResponder is AgentComposerTextView { makeFirstResponder(nil) }
            if inSidebar { model.dropPendingFocus() }   // QA #694 INFO-2: a row's click asks again, on mouse-up
        }
        if focusClick.take(event.type, focusing: focusing) { return }   // 7.6: the first click only focuses
        if event.type == .keyDown, event.keyCode == 48, responderKind != .terminal { sidebarFocused = false }   // Tab: focus moves on
        if let model, Self.route(event, responder: responderKind, sidebarFocused: sidebarFocused,
                                 terminalMode: model.paneMode == .terminal, renaming: model.renaming != nil,
                                 form: model.newSession != nil) == .sidebar,
           Self.handle(event, model) { return }
        super.sendEvent(event)
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
            AgentSidebarView(model: model)
                .frame(width: sz(290))
                .background(NeonSidebarSurface())
            Rectangle().fill(Neon.stroke).frame(width: 1)
            // #831 9.1: the band over the pane area, one whatever the number of panes, only while the split gate is on
            // (AgentWindowBand.shown; AgentWindowModel.paneAreaFrame mirrors this column for the 7.2 click rule).
            Group {
                if AgentWindowBand.shown {
                    VStack(spacing: 0) {
                        AgentWindowBand(model: model)
                        AgentPaneArea(model: model, scrolls: scrolls)
                    }
                } else {
                    AgentPaneArea(model: model, scrolls: scrolls)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsBackground())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AgentSidebarView: View {
    @ObservedObject var model: AgentWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentSidebarTitleRow(model: model)
            if !model.hasStore {
                AgentEmptyState(icon: "rectangle.dashed", title: "Agent Island is off",
                                detail: "Turn on Agent Island in Settings › Extensions to list your dch sessions here.")
            } else if model.sections.isEmpty, let store = model.store {
                AgentNoSessionsState(store: store)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: sz(2)) {
                            ForEach(model.sections) { section in
                                // #828: Sessions, Sidekicks and History fold on a header click
                                // (remembered per Mac); a folded section keeps its selection.
                                let folded = model.isCollapsed(section.title)
                                AgentSectionHeader(title: section.title, count: section.rows.count, collapsed: folded,
                                                   toggle: AgentSidebar.collapsible.contains(section.title)
                                                       ? { model.toggleCollapsed(section.title) } : nil)
                                if !folded {
                                    ForEach(section.rows) { row in
                                        Button { model.click(row.id) } label: {
                                            AgentSidebarRowView(row: row, selected: model.selection == row.id,
                                                                number: model.number(row.id))
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {   // #829: a live row's Restart / Stop / Kill (asks); a History row's (G6-G8)
                                            if let s = row.session, let store = model.store {
                                                // #1103: the header's list, Open in terminal first (selects the row, as ask does).
                                                AgentSessionMenuItems(store: store, session: s, ask: { model.ask($0, s) },
                                                                      open: { open(s) })
                                            } else if let r = row.record, let store = model.store {
                                                AgentHistoryMenuItems(store: store, record: r) { model.act($0, r) }
                                            }
                                        }
                                        .id(row.id)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, sz(8)).padding(.bottom, sz(12))
                    }
                    .onChange(of: model.selection) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
            Spacer(minLength: 0)
            // #829 G0: the dir strip's fixed slot under the list (QA #665 INFO-4/5: the list ends above it).
            if let store = model.store { AgentDirStatusStrip(store: store) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// #1103: a live row's Open in terminal: that row selected first (as ask does), then the header's action.
    func open(_ s: AgentSession) {
        model.select(.live(s.key))
        model.openSelected()
    }
}

/// The sidebar's title row: the window's name, the count, then #847's [>_] New shell and [+] New session in fixed
/// sz(18) slots. The count gives way first (lineLimit 1, lowest priority); the buttons never move or resize.
struct AgentSidebarTitleRow: View {
    @ObservedObject var model: AgentWindowModel

    var body: some View {
        HStack(spacing: sz(6)) {
            // #860: names the window (its title is hidden); "Sessions" in the accent, as Settings' rail titles.
            neonAccentedText(AgentsWindow.title, accent: "Sessions").font(Neon.font(13, weight: .semibold))
                .foregroundStyle(Neon.textPrimary).lineLimit(1)
            Spacer(minLength: 0)
            let n = model.sections.filter { $0.title != "History" }.reduce(0) { $0 + $1.rows.count }
            if n > 0 {
                Text(n == 1 ? "1 session" : "\(n) sessions").font(Neon.font(10.5)).foregroundStyle(Neon.textSecondary)
                    .lineLimit(1).layoutPriority(-1)
            }
        }
        // The buttons sit over a reserved trailing strip, inside the row's height: a cut count can never move them.
        .frame(minHeight: sz(18))
        .padding(.trailing, AgentNewSessionButtons.width + sz(6))
        // minWidth 0: the frame is the width offered, never its child's (a cut count's rounding moved the overlay 1 pt).
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            if let store = model.store { AgentNewSessionButtons(model: model, store: store) }
        }
        .padding(.horizontal, sz(14)).padding(.top, Self.padTop).padding(.bottom, sz(8))
    }

    /// #1103 F2: the content starts under the titlebar (no .fullSizeContentView), so the row's centre sits on the
    /// session header's title line: 14 + 18 / 2 = AgentSessionHeader's 10 + 26 / 2.
    static var padTop: CGFloat { sz(14) }
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
            Text("\(count)").font(Neon.font(9.5, weight: .medium).monospacedDigit()).foregroundStyle(Neon.textSecondary.opacity(0.8))
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: sz(8)) {
            Group {   // #829 G7: a pinned History record's glyph, in the same slot
                if row.record?.pinned == true {
                    Image(systemName: "pin.fill").font(Neon.font(9, weight: .bold)).foregroundStyle(Neon.textSecondary)
                } else {
                    Text(row.state?.glyph ?? "○")
                        .font(Neon.font(11, weight: .bold))
                        .foregroundStyle(row.state == nil ? Neon.textSecondary.opacity(0.6) : agentStateColor(row.state))
                }
            }
            .frame(width: sz(14))
            VStack(alignment: .leading, spacing: sz(3)) {
                HStack(alignment: .firstTextBaseline, spacing: sz(6)) {
                    Text(row.title).font(Neon.font(12.5, weight: .medium))
                        .foregroundStyle(row.state == nil ? Neon.textSecondary : Neon.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: sz(4))
                    if !row.age.isEmpty || row.state != nil {
                        // #828: a fixed slot, so "now" -> "1m" never re-truncates the title; #829 (QA #660
                        // note 4): the widest age the formatter returns, so "120d" fits it too. R1115-2: a live
                        // row keeps it with no age (working, #1114), so working <-> idle never moves the title.
                        ZStack(alignment: .trailing) {
                            Text(AgentIsland.ageWidest).hidden()
                            Text(row.age).foregroundStyle(Neon.textSecondary)
                        }
                        .font(Neon.font(10).monospacedDigit())
                        .fixedSize()
                    }
                }
                detailVariants
            }
        }
        .padding(.horizontal, sz(10)).padding(.vertical, sz(7))
        .frame(maxWidth: .infinity, alignment: .leading)
        // #860: Settings' selected row (accent fill and edge, the glowing accent bar), drawn behind and
        // over the row's padding so nothing in it moves.
        .background(NeonSelectedRowFill(selected: selected))
        .overlay(alignment: .leading) { NeonSelectionBar().opacity(selected ? 1 : 0) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([row.title, row.record?.pinned == true ? "pinned" : nil, row.detail, row.modelWords] + row.countWords
                             + [AgentIsland.ago(row.age)]).compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
        // #1110: drawn over the slot the detail line kept (outside the row's element, so it is read with its own name
        // and help); no slot, no chip.
        .overlayPreferenceValue(AgentDigitChipSlot.self) { slot in
            if let slot, let number {
                GeometryReader { proxy in
                    let r = proxy[slot]
                    AgentDigitChip(number: number, active: selected)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Command-\(number)")
                        .help("Select this session (⌘\(number))")
                        .position(x: r.midX, y: r.midY)
                }
            }
        }
    }
}

/// #1110: the bounds of the ⌘<n> chip's slot on the row's detail line.
private struct AgentDigitChipSlot: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
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
                        .strokeBorder(Neon.blue.opacity(active ? 0.9 : 0.6), lineWidth: 1))
        )
        .fixedSize()
    }
}

extension AgentSidebarRowView {
    /// The second line. The PR chips whole, else their count, else none: never a cut-off chip. #1110: the ⌘<n> chip's
    /// room is kept on every variant but the last, so it goes after the PR chips, whole. #1203: the model slot shows only
    /// where the variant taken without it still fits with it (each variant is tried with the slot first, then as before).
    var detailVariants: some View {
        ViewThatFits(in: .horizontal) {
            if row.modelSlot { detailLine(row.prs, chipSlot: true, modelSlot: true) }
            detailLine(row.prs, chipSlot: true)
            if !row.prs.isEmpty {
                if row.modelSlot { detailLine([], open: row.prCount, chipSlot: true, modelSlot: true) }
                detailLine([], open: row.prCount, chipSlot: true)
            }
            if row.modelSlot { detailLine([], chipSlot: true, modelSlot: true) }
            detailLine([], chipSlot: true)
            detailLine([])
        }
    }

    /// #1203: the model slot's width, a display text no shorter than any known short name with the longest effort
    /// word (not a model id). A longer name is cut in the middle to it.
    static let modelWidest = "Sonnet 4.5 · medium"

    /// #1203: the model and effort of the last answer, in a slot as wide as `modelWidest` whether or not a value is
    /// known (no size change when it arrives): the hidden widest text sizes it, the value is drawn over it.
    var modelSlotView: some View {
        Text(Self.modelWidest).hidden()
            .overlay(alignment: .trailing) {
                Text(row.modelText).foregroundStyle(Neon.textSecondary).lineLimit(1).truncationMode(.middle)
            }
            .font(Neon.font(10))
            .fixedSize()
            .help("Model and effort of the last answer")
    }

    /// #1115: the state text, the count groups (no " · ": the gap and the symbol separate them), then the PR chips,
    /// or with `open` the open PRs' count as a blue group in their place.
    /// #1110: `chipSlot` keeps the ⌘<n> chip's width at the end (a numbered row only) at no height: the chip is drawn over
    /// it by the row and overhangs into the row's padding, so the row's height never changes.
    /// #1203: `modelSlot` puts the model slot after the Spacer, before the chip slot (a Claude row only): trailing, so
    /// it never moves the state text, and it is never a zero-width child (it always has the widest text's width).
    /// #1267: a row with the slot and no number keeps a hidden chip's room after it too (no anchor: nothing is drawn).
    func detailLine(_ chips: [String], open: Int = 0, chipSlot: Bool = false, modelSlot: Bool = false) -> some View {
        HStack(spacing: sz(5)) {
            Text(row.detail).font(Neon.font(10.5))
                .foregroundStyle(row.state == .blocked ? agentStateColor(.blocked) : Neon.textSecondary)
                .lineLimit(1)
            AgentCountGroups(counts: row.counts + (open > 0 ? [(AgentSidebar.Count.open, open)] : []), size: 10.5)
            ForEach(chips, id: \.self) { pr in
                Text(pr).font(Neon.font(9.5, weight: .medium, design: .monospaced)).foregroundStyle(Neon.blue)
                    .padding(.horizontal, sz(4)).padding(.vertical, sz(1))
                    .background(RoundedRectangle(cornerRadius: sz(3)).fill(Neon.blue.opacity(0.12)))
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if modelSlot, row.modelSlot { modelSlotView }
            if chipSlot, let number {
                AgentDigitChip(number: number).hidden().frame(height: 0)
                    .anchorPreference(key: AgentDigitChipSlot.self, value: .bounds) { $0 }
            } else if chipSlot, modelSlot, row.modelSlot {
                // #1267: no number, the same room after the model slot (the widest digit's chip), so its edge lines up.
                ZStack { ForEach(1...9, id: \.self) { AgentDigitChip(number: $0) } }.hidden().frame(height: 0)
            }
        }
    }
}

/// #1115: a session's count groups (the sidebar row and the header): symbol plus number, a wider gap between groups.
/// Each reads its words as help and to VoiceOver; the open PRs' group wears the chips' blue. Never cut (fixedSize).
struct AgentCountGroups: View {
    let counts: [(AgentSidebar.Count, Int)]
    let size: CGFloat

    var body: some View {
        if !counts.isEmpty {   // no empty slot in the caller's HStack (it would add a spacing)
            HStack(spacing: sz(6)) {
                ForEach(Array(counts.enumerated()), id: \.offset) { _, g in
                    HStack(spacing: sz(2)) {
                        Image(systemName: g.0.symbol).font(Neon.font(size - 1))
                        Text(AgentIsland.count(g.1)).font(Neon.font(size).monospacedDigit())
                    }
                    .foregroundStyle(g.0 == .open ? Neon.blue : Neon.textSecondary)
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
            AgentNewSessionView(model: model, form: form)
        } else if let row = model.selectedRow, let s = row.session {
            // QA #668 F1: an ended session's held row is display-only.
            let ended = model.focusedEnded
            let mode = model.paneMode
            VStack(spacing: 0) {
                Group {
                    if compact {
                        AgentCompactHeader.of(row, s, cwd: transcript.cwd, ended: ended, store: model.store,
                                              ask: { model.ask($0, s) }, open: { model.openSelected() },
                                              mode: mode, setMode: { model.switchMode($0, for: s) })
                    } else {
                        AgentSessionHeader(row: row, session: s, cwd: transcript.cwd, open: { model.openSelected() },
                                           level: $model.verbosity, todos: transcript.todos,
                                           todosOpen: mode == .terminal ? floatingTodos : $transcript.todosOpen,
                                           store: model.store, ask: { model.ask($0, s) }, ended: ended,
                                           rename: ended ? nil : model.renameEdit.flatMap { $0.key == s.key ? $0 : nil },
                                           endRename: { model.endRename($0, $1) },
                                           mode: mode, setMode: { model.switchMode($0, for: s) })
                    }
                }
                .modifier(AgentPaneProbe(kind: "header"))
                Rectangle().fill(Neon.stroke).frame(height: 1)
                if mode == .terminal {
                    terminalPane(row, s)
                } else {
                    transcriptPane(row, s, ended: ended)
                }
            }
        } else if let row = model.selectedRow, let r = row.record {
            titled(row.title) {
                AgentHistoryDetail(row: row, record: r, store: model.store, refusal: model.refusalText(row.id),
                                   act: { model.act($0, r) })
                    .overlay(alignment: .top) { confirmStrip }   // #829 G8: Remove asks, over the pane's top
            }
        } else if let title = AgentPanePlaceholder.title(model.content) {
            // 4.2 (QA 956 R1217-a): a pane that holds a target whose session is gone says so by name; the list (and Pick
            // Another) still picks another session into it. Same slot as the empty pane's below.
            let pane = model.layout.focused
            titled(title) {
                AgentPanePlaceholder(title: title, close: model.layout.panes.count > 1 ? { model.closePane(pane) } : nil,
                                     pick: { model.pickAnother(pane) })
            }
        } else {
            titled("") { emptyPane }
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
                            ownsLifecycle: false, level: model.verbosity, ended: ended)
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

    func overTop(_ row: AgentSidebar.Row, _ s: AgentSession) -> some View {
        VStack(spacing: 0) {
            if let store = model.store {
                AgentNoticeLine(store: store, key: s.key, refusal: model.refusalText(row.id),
                                open: { model.openSelected() }, ended: model.focusedEnded)
            }
            confirmStrip
        }
    }

    /// Terminal mode: the header's todo chip opens the list over the terminal, never inside the header
    /// (the header keeps its height, the terminal its grid).
    var floatingTodos: Binding<Bool> {
        Binding(get: { false }, set: { [transcript] _ in transcript.todosOpen.toggle() })
    }

    /// R5: the question, re-read from the store each draw (a gone session or record draws none).
    @ViewBuilder var confirmStrip: some View {
        if let c = model.confirming {
            let text = model.confirmingSession.map { AgentWindowControls.question(c.verb, $0) }
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
/// right: the layout slot and the chip slot (empty before the Layouts section, zoom and the too-small chip: B2/B3), the
/// All slot (its room kept, empty until phase C: no control, no text, no accessibility element), the verbosity picker
/// (moved in from the session header). Fixed slots: each slot's size comes from the UI scale alone. A narrow band gives
/// way in `Tier` order: the chip slot first, then the layout slot, then the picker's icons, then its menu; the All slot
/// and the picker never go.
struct AgentWindowBand: View {
    @ObservedObject var model: AgentWindowModel
    /// Tests only: (slot, frame in the band) as "layout", "chip", "all", "picker" and "band" are laid out. Main actor
    /// (SwiftUI calls it from layout).
    static var probe: ((String, CGRect) -> Void)?

    /// The one gate for the band (#1224): the window's content, AgentWindowModel.paneAreaFrame and the session header's
    /// picker all read it. Off (the product, the split gate's default): no band, the parent's window. Read at layout
    /// time, not observed: a flip shows at the next build of the view, as the split gate does.
    @MainActor static var shown: Bool { AgentPaneLayout.splitsEnabled }
    static var height: CGFloat { sz(30) }
    /// shortcut: fixed widths for slots that draw nothing before B2/B3/C; the phase that fills one sizes it to its widest.
    static var layoutWidth: CGFloat { sz(100) }
    static var allWidth: CGFloat { sz(140) }
    /// 3.4's chip at the 6-pane cap: the chip slot's widest variant.
    static let chipWidest = "5 panes hidden, window too small"

    /// Widest first, so ViewThatFits takes the first that fits: the order in which the slots give way.
    enum Tier: CaseIterable { case full, noChip, noLayout, icons, menu }

    var body: some View {
        let on = Self.transcriptShown(model)
        ViewThatFits(in: .horizontal) {
            line(.full, on: on)
            line(.noChip, on: on)
            line(.noLayout, on: on)
            line(.icons, on: on)
            line(.menu, on: on)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.height)
        .modifier(AgentBandProbe(kind: "band"))
        .coordinateSpace(.named(agentBandSpace))
    }

    func line(_ t: Tier, on: Bool) -> some View {
        HStack(spacing: sz(8)) {
            // Slots that give way are left out of the stack, never zero-width (a zero-width child still takes a spacing).
            if t == .full || t == .noChip {
                Color.clear.frame(width: Self.layoutWidth).accessibilityHidden(true).modifier(AgentBandProbe(kind: "layout"))
            }
            if t == .full {
                Text(Self.chipWidest).font(Neon.font(11)).lineLimit(1).fixedSize().hidden().accessibilityHidden(true)
                    .modifier(AgentBandProbe(kind: "chip"))
            }
            Spacer(minLength: 0)
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
        m.paneFrames(in: m.paneArea).keys.contains { id in
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
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(agentBandSpace)) }) { r in
            AgentWindowBand.probe?(kind, r)
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
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(agentPaneAreaSpace)) }) { r in
            if let pane { AgentPaneArea.probe?(kind, pane, r) }
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

    var body: some View {
        GeometryReader { proxy in
            let area = CGRect(origin: .zero, size: proxy.size)
            let frames = model.paneFrames(in: area)
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
                        // 13: more than one pane shown: each pane one container, "<title>, pane i of n".
                        .modifier(AgentPaneContainer(label: label))
                        .modifier(AgentPaneProbe(kind: "pane"))
                        .environment(\.agentPaneID, id)
                        .environment(\.agentComposerTwoLines, twoLines)
                        .position(x: f.midX, y: f.midY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .coordinateSpace(.named(agentPaneAreaSpace))
            .onAppear { feed(area) }
            .onChange(of: proxy.size) { _, size in feed(CGRect(origin: .zero, size: size)) }
        }
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
        if f.minX > 0.5 { Rectangle().fill(Neon.stroke).frame(width: 1).frame(maxHeight: .infinity) }
        if f.minY > 0.5 { Rectangle().fill(Neon.stroke).frame(height: 1).frame(maxWidth: .infinity) }
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

/// 13: with more than one pane shown, a pane is one accessibility container under `label`; one pane: the tree as before.
struct AgentPaneContainer: ViewModifier {
    let label: String?
    @ViewBuilder func body(content: Content) -> some View {
        if let label {
            content.accessibilityElement(children: .contain).accessibilityLabel(label)
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
                                      mode: .transcript, setMode: { model.switchMode($0, for: p.session) })
                    .modifier(AgentPaneProbe(kind: "header"))
                Rectangle().fill(Neon.stroke).frame(height: 1)
                AgentTranscriptView(model: transcript, scrolls: scrolls, ownsLifecycle: false, level: model.verbosity,
                                    ended: ended)
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
                   setMode: @escaping (AgentPaneMode) -> Void) -> AgentCompactHeader {
        AgentCompactHeader(title: row.title, project: AgentSessionHeader.project(cwd: cwd, session: s),
                           chip: AgentStateChip(state: s.state, ended: ended), mode: mode, setMode: setMode, ended: ended,
                           menu: AgentSessionMenuButton(store: ended ? nil : store, session: s, ask: ask, open: open, ended: ended))
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
            if let menu { menu }
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
    var stateChip: AgentStateChip { AgentStateChip(state: session.state, ended: ended) }
    /// #829 G4: the title is a text field (Rename…) while `rename` is set; `endRename` gets the text on Return,
    /// nil on Esc or focus loss (true: the edit goes on).
    var rename: AgentRenameEdit?
    var renaming: Bool { rename != nil }
    var endRename: (AgentRenameEdit, String?) -> Bool = { _, _ in false }
    /// #822: Terminal | Transcript (the window passes `setMode`; without it there is no toggle).
    var mode = AgentPaneMode.transcript
    var setMode: ((AgentPaneMode) -> Void)?

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
                            AgentCountGroups(counts: row.counts, size: 11)
                            if let ago {
                                if !row.counts.isEmpty { Text("·").accessibilityHidden(true) }   // a count never runs into "4m ago"
                                Text(ago)
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
        // #1120: no accessibilityHidden here or on its parts: hidden(false) on the slot overrode the folder icon's own
        // hidden when the header still drew a folder glyph (read "Move"). While renaming, the opacity 0 leaves the parts out of the tree (SwiftUI
        // drops a fully transparent view; testRenameHidesTheTitleChipAndPathUnderTheFieldInTheTree reads it).
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
            menuButton   // #829: always last, fixed size
        }
    }

    /// #1103: Open in terminal is its first item, with the header's `open` and `ended`.
    var menuButton: AgentSessionMenuButton {
        AgentSessionMenuButton(store: menuStore, session: session, ask: ask, open: open, ended: ended)
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
            if ended { chip(Self.endedGlyph, label, Neon.textSecondary) } else { chip(state.glyph, label, agentStateColor(state)) }
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
            if let store { AgentHistoryButtons(store: store, record: record, refusal: refusal, act: act) }
        }
        .padding(sz(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 1))
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
    weak var owner: AgentWindowInteraction?

    /// #845: a focus asked for before the box was in the window (a row click from Terminal mode builds it next pass).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, owner?.composerFocusPending == true { owner?.focusComposer() }
    }

    /// Return or keypad Enter alone sends; Shift-Return adds a line; an IME's marked text keeps Return.
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() {
            if mods.isEmpty { return onSubmit() }
            if mods == .shift { return insertNewlineIgnoringFieldEditor(nil) }
        }
        super.keyDown(with: event)
    }
}

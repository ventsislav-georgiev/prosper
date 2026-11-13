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
        let model = AgentWindowModel()
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
    /// The last click was in the sidebar (where the window starts).
    var sidebarFocused = true

    /// #822 (spec 5.3): who gets a key.
    enum KeyRoute: Equatable {
        case close, toggleMode, verbosity(AgentVerbosity), session(Int), find, findNext(Bool)
        /// #847: ⌘N (the New session form, or its Name field when open) and ⇧⌘N (the quick shell).
        case newSession, newShell
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
    static func route(_ event: NSEvent, responder: ResponderKind, sidebarFocused: Bool, terminalMode: Bool,
                      renaming: Bool = false, form: Bool = false) -> KeyRoute {
        let r = paneRoute(event, responder: responder, sidebarFocused: sidebarFocused, terminalMode: terminalMode,
                          renaming: renaming)
        switch r {
        case .toggleMode, .verbosity, .session, .find, .findNext: return form ? .swallow : r
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
        switch Self.route(event, responder: responderKind, sidebarFocused: sidebarFocused,
                          terminalMode: model.paneMode == .terminal, renaming: model.renaming != nil,
                          form: model.newSession != nil) {
        case .close: performClose(nil)
        case .verbosity(let v): model.verbosity = v
        case .toggleMode:
            guard model.toggleMode() else { return super.performKeyEquivalent(with: event) }
            model.focusSelection()   // #845: the shown mode's input, Transcript's too
        case .session(let d): model.move(d)
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

    /// #821: ⌥⌘1 / ⌥⌘2 / ⌥⌘3 pick Focused / Default / Verbose (no app menu item uses them).
    static func verbosity(for event: NSEvent) -> AgentVerbosity? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option] else { return nil }
        return AgentVerbosity.allCases.first { $0.keyCode == event.keyCode }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            sidebarFocused = event.locationInWindow.x < sz(290)
            // #822: a sidebar click takes the keys from the terminal, so the arrows select again;
            // #845: from the input box too (a row's click then moves them in again, on mouse-up).
            if sidebarFocused, responderKind == .terminal || firstResponder is AgentComposerTextView { makeFirstResponder(nil) }
            if sidebarFocused { model?.dropPendingFocus() }   // QA #694 INFO-2: a row's click asks again, on mouse-up
        }
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
        // Return, keypad Enter: #822/#845 into the terminal or the input box (Ghostty is the header's button).
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
            AgentDetailView(model: model, transcript: model.transcript, scrolls: scrolls)
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
                                            AgentSidebarRowView(row: row, selected: model.selection == row.id)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {   // #829: a live row's Restart / Stop / Kill (asks); a History row's (G6-G8)
                                            if let s = row.session, let store = model.store {
                                                AgentSessionMenuItems(store: store, session: s) { model.ask($0, s) }
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
        .padding(.horizontal, sz(14)).padding(.top, sz(30)).padding(.bottom, sz(8))
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
                    if !row.age.isEmpty {
                        // #828: a fixed slot, so "9s" -> "10s" never re-truncates the title; #829 (QA #660
                        // note 4): the widest age the formatter returns, so "120d" fits it too.
                        ZStack(alignment: .trailing) {
                            Text(AgentIsland.ageWidest).hidden()
                            Text(row.age).foregroundStyle(Neon.textSecondary)
                        }
                        .font(Neon.font(10).monospacedDigit())
                        .fixedSize()
                    }
                }
                // The PR chips whole, else their count, else none: never a cut-off chip.
                ViewThatFits(in: .horizontal) {
                    detailLine(row.prs)
                    if !row.prs.isEmpty { detailLine([row.prCount == 1 ? "1 PR" : "\(row.prCount) PRs"]) }
                    detailLine([])
                }
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
        .accessibilityLabel([row.title, row.record?.pinned == true ? "pinned" : nil, row.detail,
                             row.age.isEmpty ? nil : "\(row.age) ago"].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension AgentSidebarRowView {
    func detailLine(_ chips: [String]) -> some View {
        HStack(spacing: sz(5)) {
            Text(row.detail).font(Neon.font(10.5))
                .foregroundStyle(row.state == .blocked ? agentStateColor(.blocked) : Neon.textSecondary)
                .lineLimit(1)
            ForEach(chips, id: \.self) { pr in
                Text(pr).font(Neon.font(9.5, weight: .medium, design: .monospaced)).foregroundStyle(Neon.blue)
                    .padding(.horizontal, sz(4)).padding(.vertical, sz(1))
                    .background(RoundedRectangle(cornerRadius: sz(3)).fill(Neon.blue.opacity(0.12)))
                    .fixedSize()
            }
            Spacer(minLength: 0)
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

    /// QA #668 F1: the input box's lock store; nil for an ended session's held row (the plain, ended pane).
    var inputStore: AgentIslandStore? { model.selectionIsHeld ? nil : model.store }

    var body: some View {
        if let form = model.newSession {
            // #847: the form in place of the pane's content (the selected session's terminal detaches meanwhile).
            AgentNewSessionView(model: model, form: form)
        } else if let row = model.selectedRow, let s = row.session {
            // QA #668 F1: an ended session's held row is display-only.
            let ended = model.selectionIsHeld
            let mode = model.paneMode
            VStack(spacing: 0) {
                AgentSessionHeader(row: row, session: s, cwd: transcript.cwd, open: { model.openSelected() },
                                   level: $model.verbosity, todos: transcript.todos,
                                   todosOpen: mode == .terminal ? floatingTodos : $transcript.todosOpen,
                                   store: model.store, ask: { model.ask($0, s) }, ended: ended,
                                   rename: ended ? nil : model.renameEdit.flatMap { $0.key == s.key ? $0 : nil },
                                   endRename: { model.endRename($0, $1) },
                                   mode: mode, setMode: { model.switchMode($0, for: s) })
                Rectangle().fill(Neon.stroke).frame(height: 1)
                if mode == .terminal {
                    terminalPane(row, s)
                } else {
                    transcriptPane(row, s, ended: ended)
                }
            }
        } else if let row = model.selectedRow, let r = row.record {
            AgentHistoryDetail(row: row, record: r, store: model.store, refusal: model.refusalText(row.id),
                               act: { model.act($0, r) })
                .overlay(alignment: .top) { confirmStrip }   // #829 G8: Remove asks, over the pane's top
        } else {
            AgentEmptyState(icon: "sidebar.left", title: "Select a session",
                            detail: "Up and down move through the list; Return or a click moves into it.") {
                AgentPillButton(title: "New session", icon: "plus", tint: Neon.blue,
                                enabled: model.store?.resumeGate.isOK == true) { model.openNewSession() }
                    .help(AgentNewSessionButtons.help("New session… (⌘N)", refusal: model.store?.resumeGate.refusal))
                    .accessibilityLabel("New session")
                    .padding(.top, sz(4))
            }
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
                AgentNoticeLine(store: store, key: s.key, refusal: model.refusalText(row.id))
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
    /// QA #668 F1: the session ended (a held row): Open in terminal and the "⋯" are off, in their slots.
    var ended = false
    /// The "⋯" menu's store: none for an ended session, so it offers nothing and is disabled.
    var menuStore: AgentIslandStore? { ended ? nil : store }
    /// QA #668 INFO-4: the state chip reads "Ended" for an ended session, in the same slot.
    var stateChip: AgentStateChip { AgentStateChip(state: session.state, ended: ended) }
    /// #829 G4: the title is a text field (Rename…) while `rename` is set; `endRename` gets the text on Return,
    /// nil on Esc or focus loss (true: the edit goes on).
    var rename: AgentRenameEdit?
    var renaming: Bool { rename != nil }
    var endRename: (AgentRenameEdit, String?) -> Bool = { _, _ in false }
    /// #822: Transcript | Terminal (the window passes `setMode`; without it there is no toggle).
    var mode = AgentPaneMode.transcript
    var setMode: ((AgentPaneMode) -> Void)?

    var project: String {
        if let cwd { return (cwd as NSString).abbreviatingWithTildeInPath }
        return session.key.dir == DchCommand.defaultSocketDir ? "dch \(session.name)" : "dch \(session.name) in \(session.key.dir)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            // The whole title and the labelled controls when they fit, else smaller ones.
            titleLines
            HStack(spacing: sz(6)) {
                Image(systemName: "folder").font(Neon.font(10)).foregroundStyle(Neon.textSecondary)
                Text(project).font(Neon.font(11, design: .monospaced)).foregroundStyle(Neon.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                let extra = [row.detail.split(separator: " · ").dropFirst().joined(separator: " · "),
                             row.age.isEmpty ? "" : "\(row.age) ago"].filter { !$0.isEmpty }
                if !extra.isEmpty {
                    // Whole or not at all: a squeezed low-priority Text overshot the line by a
                    // fraction of a point next to the #821 todo chip.
                    ViewThatFits(in: .horizontal) {
                        Text("· " + extra.joined(separator: " · ")).font(Neon.font(11)).foregroundStyle(Neon.textSecondary)
                            .lineLimit(1)
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .layoutPriority(-1)
                }
                Spacer(minLength: 0)
                if let todos = shownTodos { AgentTodosChip(todos: todos, open: todosOpen) }
            }
            if todosOpen.wrappedValue, let todos = shownTodos { AgentTodosList(todos: todos) }
        }
        .padding(.horizontal, sz(16)).padding(.top, sz(30)).padding(.bottom, sz(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        // #860: on the window's backdrop, as Settings' pane title (no opaque band under the titlebar).
    }

    /// The title, the state chip and the room after them: one slot. G4: while renaming, the field
    /// lies over the whole slot and the title and chip only go transparent, so nothing moves.
    var titleSlot: some View {
        HStack(alignment: .center, spacing: sz(8)) {
            Text(row.title).font(Neon.font(15, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                .lineLimit(1).truncationMode(.middle)
            stateChip
            Spacer(minLength: sz(8))
        }
        .opacity(renaming ? 0 : 1)
        .accessibilityHidden(renaming)
        .overlay(alignment: .leading) {
            if let rename {
                AgentRenameField(name: session.name, edit: rename, end: endRename)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(ObjectIdentifier(rename))   // per edit: Rename on another row gets a new field, never this one's text
            }
        }
    }

    /// Focused hides todos; Verbose draws the todo/task cards in the conversation instead.
    var shownTodos: AgentTodos? { level.wrappedValue == .default ? todos : nil }

    /// Widest first: the labelled picker and button, the icon button, the icon picker, a menu.
    @ViewBuilder var titleLines: some View {
        ViewThatFits(in: .horizontal) {
            titleLine(picker: .labels, compact: false)
            titleLine(picker: .labels, compact: true)
            titleLine(picker: .icons, compact: true)
            titleLine(picker: .menu, compact: true)
        }
    }

    func titleLine(picker: AgentVerbosityPicker.Style, compact: Bool) -> some View {
        HStack(alignment: .center, spacing: sz(8)) {
            titleSlot
            AgentVerbosityPicker(level: level, style: picker)   // #822: in its slot, off in Terminal mode
                .disabled(mode == .terminal).opacity(mode == .terminal ? 0.45 : 1)
            if let setMode {
                AgentPaneModeToggle(mode: mode, style: picker, set: setMode,
                                    off: ended ? AgentPaneModeToggle.endedReason : nil)
                    .disabled(ended).opacity(ended ? 0.45 : 1)
            }
            HStack(spacing: sz(6)) {   // #829: the "⋯" sits close to the button, always last, fixed size
                OpenInTerminalButton(action: open, compact: compact, ended: ended)
                AgentSessionMenuButton(store: menuStore, session: session, ask: ask)
            }
        }
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

/// #822: Transcript | Terminal, built like AgentVerbosityPicker (same tiers). Every label keeps its
/// width whichever is on, so a toggle never moves a neighbour.
struct AgentPaneModeToggle: View {
    let mode: AgentPaneMode
    var style = AgentVerbosityPicker.Style.labels
    let set: (AgentPaneMode) -> Void
    /// Why there is no terminal to show (an ended session); the caller disables the toggle.
    var off: String?

    static let endedReason = "This session ended: there is no terminal to attach to"
    static let modes: [(mode: AgentPaneMode, title: String, icon: String)] = [
        (.transcript, "Transcript", "text.bubble"), (.terminal, "Terminal", "terminal"),
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
            .fixedSize()
            .help(off ?? "Transcript or terminal (⌘T)")
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
            Text([row.detail, row.age.isEmpty ? nil : "\(row.age) ago"].compactMap { $0 }.joined(separator: " · "))
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
                .frame(height: sz(60))
                .background(RoundedRectangle(cornerRadius: sz(8)).fill(Neon.bgBottom))
                .overlay(RoundedRectangle(cornerRadius: sz(8)).stroke(Neon.stroke, lineWidth: 1))
                AgentSendColumn(canInterrupt: canInterrupt, canSend: canSend,
                                interrupt: { model.interrupt() }, send: { model.send() })
            }
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
    var body: some View {
        VStack(spacing: sz(6)) {
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

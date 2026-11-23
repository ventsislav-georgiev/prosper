import AppKit
import SwiftUI

// #829 Phase 1: the window's live-session lifecycle (Restart agent, Stop, Kill) and the island's
// results shown in the window. Phase 2: a History row's Resume, Resume (no message), Pin/Unpin and
// Remove from History. Every action is the island controller's own method (its gates, runner keys,
// busy refusal and row texts); the window adds the asking and nothing else.

enum AgentWindowVerb: Equatable {
    case restart, stop, kill
    /// #829 Phase 2: a History record's.
    case resume, resumeNoMessage, pin, remove
    /// #829 G4: a live session's; edits the header title in place (never asks).
    case rename
    /// #1469: a live session's Model or Effort item (runs at once through the window's act, asks nothing).
    case switchTo(AgentModelSwitch.Command)
}

/// The confirm strip's question: what, on which session (by key; re-resolved at the answer).
/// `.remove`'s key is a History record's id (it can equal a live key, #580).
struct AgentWindowConfirm: Equatable {
    let verb: AgentWindowVerb
    let key: AgentSessionKey
}

/// QA #665 INFO-6: an answer that ran nothing because a gate closed since the question: why, on that row.
struct AgentWindowRefusal: Equatable {
    let id: AgentSidebar.RowID
    let text: String
}

enum AgentWindowMenuEntry: Equatable {
    case item(String, enabled: Bool, verb: AgentWindowVerb)
    case divider
    /// A disabled line: the gate's reason ("Controls <refusal>").
    case note(String)
    /// #1103: "Open in terminal" (the header's button until then): the window's own action, no verb (it asks
    /// nothing and runs no dch); off for an ended session.
    case open(enabled: Bool)
    /// #900 B2 step 6a (7.3): a pane item of the header "⋯" (only with the split gate on): runs at once, asks nothing.
    case pane(String, enabled: Bool, verb: AgentPaneVerb)
    /// #900 B2 step 6b1 (7.1): a live row's "Open to the Side" (only with the split gate on): runs at once, asks nothing.
    case side(String, enabled: Bool)
    /// #1351: "X-Ray... Shift-Command-X" for `pane`'s header; only at or above XrayTabs.gate.
    case xray(pane: UUID)
}

/// #900 B2 step 6a: what a pane item runs: the key's own PaneAction through `perform`, or Equalize (no key, no
/// PaneAction: the whole tree, 7.5).
enum AgentPaneVerb: Equatable {
    case action(PaneAction)
    case equalize
    /// #1895: Swap Session…: the pane's title switcher opens (AgentWindowModel.swapRequest).
    case swap
}

/// #901 B3 step 4b (8.1): what a Layouts row's context menu entry runs.
enum AgentLayoutVerb: Equatable { case rename, duplicate, delete }

/// One entry of a Layouts row's context menu, a value (rows read the list; no menu is popped).
struct AgentLayoutMenuEntry: Equatable, Identifiable {
    let title: String
    let enabled: Bool
    let verb: AgentLayoutVerb
    var id: AgentLayoutVerb { verb }
}

/// #1358: the leading SF Symbol of every item in the Agent Sessions menus (pane and row more-menus, History row, sidebar more-menu, Layouts
/// row). One action, one symbol, wherever its menu draws it: every table below reads this one list. The title stays the
/// item's own words (Label's title is its VoiceOver label).
enum AgentMenuSymbol {
    static let open = "terminal", rename = "pencil", restart = "arrow.clockwise", stop = "stop.circle"
    /// The door with an arrow: prosper-ios's exit button (TerminalScreen.swift).
    static let exit = "rectangle.portrait.and.arrow.right"
    static let resume = AgentIsland.resumeWithMessageSymbol, resumeNoMessage = AgentIsland.resumeNoMessageSymbol
    static let pin = "pin", unpin = "pin.slash", remove = "trash", duplicate = "plus.square.on.square"
    static let side = "sidebar.right", chapters = "list.bullet", splitRight = "rectangle.split.2x1"
    static let splitDown = "rectangle.split.1x2", zoom = "arrow.up.left.and.arrow.down.right"
    static let equalize = "equal.square", closePane = "xmark.rectangle", swap = "arrow.left.arrow.right"
    static let newSession = "plus", folder = "folder", chooseFolder = "folder.badge.plus"
    static let sort = "arrow.up.arrow.down", sortActivity = "clock", sortName = "textformat"
    static let rowDetails = "list.bullet.rectangle", rowDetail = "list.bullet", autoAllow = "checkmark.shield"
    static let settings = "gearshape", diagnostics = "stethoscope"
    /// #1469: the Model and Effort submenus.
    static let model = "cpu", effort = "speedometer"
    static let xray = "rectangle.righthalf.inset.filled"

    /// Every name above, for the test that resolves each one (a typo draws no image).
    static let all: Set<String> = [open, rename, restart, stop, exit, resume, resumeNoMessage, pin, unpin, remove, duplicate, side,
                                   chapters, splitRight, splitDown, zoom, equalize, closePane, swap, newSession, folder, chooseFolder,
                                   sort, sortActivity, sortName, rowDetails, rowDetail, autoAllow, settings, diagnostics, model, effort, xray]
}

extension AgentWindowVerb {
    /// `.pin` is Pin or Unpin by the item's title (AgentWindowMenuEntry.symbol).
    var symbol: String {
        switch self {
        case .restart: AgentMenuSymbol.restart
        case .stop: AgentMenuSymbol.stop
        case .kill: AgentMenuSymbol.exit
        case .resume: AgentMenuSymbol.resume
        case .resumeNoMessage: AgentMenuSymbol.resumeNoMessage
        case .pin: AgentMenuSymbol.pin
        case .remove: AgentMenuSymbol.remove
        case .rename: AgentMenuSymbol.rename
        case .switchTo(let c): c.isModel ? AgentMenuSymbol.model : AgentMenuSymbol.effort
        }
    }
}

extension AgentWindowMenuEntry {
    /// nil for a divider or a note, else the item's leading symbol.
    var symbol: String? {
        switch self {
        case .item(let title, _, let verb):
            verb == .pin && title.hasPrefix(AgentIsland.unpinLabel) ? AgentMenuSymbol.unpin : verb.symbol
        case .divider, .note: nil
        case .open: AgentMenuSymbol.open
        case .pane(_, _, let verb):
            switch verb {
            case .equalize: AgentMenuSymbol.equalize
            case .swap: AgentMenuSymbol.swap
            case .action(.split(.columns)): AgentMenuSymbol.splitRight
            case .action(.split(.rows)): AgentMenuSymbol.splitDown
            case .action(.zoom): AgentMenuSymbol.zoom
            case .action(.closePane): AgentMenuSymbol.closePane
            // R1358-n1: the menu draws only the cases above; every other PaneAction is named, so a new one fails to compile.
            case .action(.focus), .action(.cycle), .action(.layout), .action(.previousLayout),
                 .action(.nextNeedsYou), .action(.toggleSidebar), .action(.sidebar): nil
            }
        case .side: AgentMenuSymbol.side
        case .xray: AgentMenuSymbol.xray
        }
    }
}

extension AgentSidebarVerb {
    var symbol: String {
        switch self {
        case .newSession: AgentMenuSymbol.folder
        case .chooseFolder: AgentMenuSymbol.chooseFolder
        case .restartAll: AgentMenuSymbol.restart
        case .stopAll: AgentMenuSymbol.stop
        case .killAll: AgentMenuSymbol.exit
        case .resumeInterrupted(let noMessage): noMessage ? AgentMenuSymbol.resumeNoMessage : AgentMenuSymbol.resume
        case .clearUnpinned: AgentMenuSymbol.remove
        case .sort(let s): s == .activity ? AgentMenuSymbol.sortActivity : AgentMenuSymbol.sortName
        case .rowDetail: AgentMenuSymbol.rowDetail
        case .autoAllow: AgentMenuSymbol.autoAllow
        case .settings: AgentMenuSymbol.settings
        case .diagnostics: AgentMenuSymbol.diagnostics
        }
    }
}

extension AgentSidebarMenuEntry {
    /// nil for a divider or a note, else the item's or submenu's leading symbol.
    var symbol: String? {
        switch self {
        case .item(_, _, _, let verb): verb.symbol
        case .submenu(let title, _, _):
            // shortcut: submenus are told apart by title (no kind field); an unknown title has no symbol, a test row
            // catches it. Upgrade: a submenu kind enum.
            title == AgentIsland.newSessionLabel ? AgentMenuSymbol.newSession
                : title == AgentWindowControls.sortLabel ? AgentMenuSymbol.sort
                : title == AgentWindowControls.rowDetailsLabel ? AgentMenuSymbol.rowDetails : nil
        case .divider, .note: nil
        }
    }
}

extension AgentLayoutMenuEntry {
    var symbol: String {
        switch verb {
        case .rename: AgentMenuSymbol.rename
        case .duplicate: AgentMenuSymbol.duplicate
        case .delete: AgentMenuSymbol.remove
        }
    }
}

enum AgentWindowControls {
    /// #901 B3 step 4b: Delete's fixed words on the last layout, read as PaneRefusal.menuSuffix reads ("Delete (last
    /// layout)", as "Split Right (6 panes max)"); PaneRefusal has no words for .lastLayout.
    static let lastLayoutSuffix = "(last layout)"

    /// #901 B3 step 4b (8.1): a Layouts row's context menu: Rename, Duplicate, Delete. Gate off or no store: empty (the
    /// section is not built then either). Duplicate is off at the 9-layout cap with its words; Delete is off on the last
    /// layout with `lastLayoutSuffix`. A pure read of the store's own answers.
    @MainActor
    static func layoutMenu(_ m: AgentWindowModel, _ id: UUID) -> [AgentLayoutMenuEntry] {
        guard AgentPaneLayout.splitsEnabled, let s = m.layouts else { return [] }
        func entry(_ title: String, _ verb: AgentLayoutVerb, _ suffix: String?) -> AgentLayoutMenuEntry {
            AgentLayoutMenuEntry(title: suffix.map { "\(title) \($0)" } ?? title, enabled: suffix == nil, verb: verb)
        }
        let full = s.layouts.count >= PaneLayoutStore.maxLayouts ? PaneRefusal.layoutCap.menuSuffix : nil
        var last: String? { if case .failure(.lastLayout) = s.deleting(id) { return lastLayoutSuffix }; return nil }
        return [entry("Rename", .rename, nil), entry("Duplicate", .duplicate, full), entry("Delete", .delete, last)]
    }

    /// The entry's run: the model op once (Rename only opens the inline field; Delete asks nothing, 8.1). A disabled
    /// entry runs nothing; gate off nothing runs (deleteLayout itself is ungated, D4). Main actor (a Button's action).
    @MainActor
    static func runLayout(_ e: AgentLayoutMenuEntry, _ m: AgentWindowModel, _ id: UUID) {
        guard AgentPaneLayout.splitsEnabled, e.enabled else { return }
        switch e.verb {
        case .rename: m.beginLayoutRename(id)
        case .duplicate: m.duplicateLayout(id)
        case .delete: m.deleteLayout(id)
        }
    }

    /// The header "⋯" and row context menu for a live session: the island row menu's items,
    /// gates and titles (AgentIslandView.Drawn). An item that asks gets an ellipsis; a disabled
    /// one reads the island's title, its reason included. A name dch would read as a flag gets
    /// no item (#627).
    @MainActor
    static func menu(_ s: AgentSession, store: AgentIslandStore) -> [AgentWindowMenuEntry] {
        let d = AgentIslandView.Drawn(session: s, card: nil, open: {}, answer: { _, _ in }, refused: store.resumeGate.refusal,
                                      canStop: AgentIsland.canStop(s), needs: store.restartNeeds)
        // G4: any name (dch -m takes it verbatim), any dch that runs: no gate but the control binary.
        var out: [AgentWindowMenuEntry] = [.item(AgentIsland.renameLabel, enabled: store.controlDch != nil, verb: .rename)]
        if d.controls {
            out.append(.divider)
            out.append(.item(d.restartEnabled ? AgentIsland.restartLabel + "…" : d.restartTitle, enabled: d.restartEnabled,
                             verb: .restart))
            out.append(.item(d.stopEnabled ? AgentIsland.stopLabel + "…" : d.stopTitle, enabled: d.stopEnabled, verb: .stop))
            out.append(.divider)
            out.append(.item(AgentIsland.killLabel, enabled: d.killEnabled, verb: .kill))
        }
        if let why = d.refused { out.append(.note("Controls \(why)")) }
        return out
    }

    /// #1103: Open in terminal's title, the words of the button it replaced (and of every text that names it).
    static let openLabel = "Open in terminal"
    /// QA #672 #4: why Open in terminal is off for an ended session (#1471: moved here from the old mode toggle).
    static let endedReason = "This session ended: there is no terminal to attach to"

    /// #1103: the header "⋯" and a live row's context menu: Open in terminal first, then `menu`. An ended session's
    /// (a held row; the header passes no store) offers Open in terminal, off, and nothing else.
    @MainActor
    static func sessionMenu(_ s: AgentSession, store: AgentIslandStore?, ended: Bool) -> [AgentWindowMenuEntry] {
        let rest: [AgentWindowMenuEntry] = ended ? [] : store.map { menu(s, store: $0) } ?? []
        return [.open(enabled: !ended)] + (rest.isEmpty ? [] : [.divider] + rest)
    }

    static let sideLabel = "Open to the Side"

    /// #900 B2 step 6b1 (7.1, 3.3, 15.0): a live row's context menu: sessionMenu with "Open to the Side" right after Open
    /// in terminal (the spec's table places it nowhere; first after Open, before the verbs that ask). Gate off: exactly
    /// sessionMenu. At the cap the item is off with the cap's own suffix; no room leaves it on, so choosing it shows the
    /// notice (one room rule, the layout's show). `side`: show(.side)'s refusal for the row, read only with the gate on.
    @MainActor
    static func rowMenu(_ s: AgentSession, store: AgentIslandStore, splits: Bool,
                        side: @autoclosure () -> PaneRefusal?) -> [AgentWindowMenuEntry] {
        let out = sessionMenu(s, store: store, ended: false)
        guard splits else { return out }
        let suffix = side()?.menuSuffix
        return Array(out.prefix(1)) + [.side(suffix.map { "\(sideLabel) \($0)" } ?? sideLabel, enabled: suffix == nil)]
            + out.dropFirst()
    }

    /// The row menu for `s`'s row in `m`: the gate and the layout's own answer for that row.
    @MainActor
    static func rowMenu(_ s: AgentSession, store: AgentIslandStore, in m: AgentWindowModel) -> [AgentWindowMenuEntry] {
        func refusal() -> PaneRefusal? {
            if case let .failure(r) = m.showing(.live(s.key), placement: .side) { return r }
            return nil
        }
        return rowMenu(s, store: store, splits: AgentPaneLayout.splitsEnabled, side: refusal())
    }

    static let closePaneLabel = "Close Pane"   // #1817 (operator 2026-11-21): the short label
    static let swapLabel = "Swap Session\u{2026}"   // #1895 (operator 2026-11-23)
    /// #1351: the "..." item of the X-ray panel.
    static let xrayLabel = "X-Ray\u{2026} \u{21E7}\u{2318}X"

    /// #900 B2 step 6a (7.3, 3.3, 15.0): the pane part of the header "⋯", appended after `sessionMenu` behind one
    /// divider. Gate off: nothing, whatever the layout holds (the menu is today's). Gate on: Split Right and Split Down;
    /// at the cap each is off with the cap's own suffix; any other refusal (no room) leaves it on, so choosing it runs the
    /// key's split and the key's notice shows (one room rule, the split's). With more than one pane in the layout (the
    /// keys' rule: PaneKeys.action's `many`, the active layout's count, so zoomed or too small still counts every pane):
    /// Zoom (both ways: the spec names no "Unzoom"), Equalize and Close Pane. `right` and `down`: the split's answer for
    /// the menu's pane (AgentWindowModel.splitting), read only with the gate on.
    @MainActor
    static func paneMenu(splits: Bool, panes: Int, right: @autoclosure () -> PaneRefusal?,
                         down: @autoclosure () -> PaneRefusal?) -> [AgentWindowMenuEntry] {
        guard splits else { return [] }
        // Only the cap has a menu suffix (a split never answers .layoutCap).
        func split(_ title: String, _ axis: PaneNode.Axis, _ r: PaneRefusal?) -> AgentWindowMenuEntry {
            let suffix = r?.menuSuffix
            return .pane(suffix.map { "\(title) \($0)" } ?? title, enabled: suffix == nil, verb: .action(.split(axis)))
        }
        var out: [AgentWindowMenuEntry] = [.divider, split("Split Right", .columns, right()), split("Split Down", .rows, down())]
        if panes > 1 {
            out += [.pane("Zoom", enabled: true, verb: .action(.zoom)), .pane("Equalize", enabled: true, verb: .equalize),
                    .pane(closePaneLabel, enabled: true, verb: .action(.closePane))]
        }
        return out
    }

    /// The pane part for `pane`'s header in `m`: the gate, the active layout's pane count and the split's own answers
    /// for that pane (focused first, as `runPane` runs it).
    @MainActor
    static func paneMenu(_ m: AgentWindowModel, pane: UUID) -> [AgentWindowMenuEntry] {
        func refusal(_ axis: PaneNode.Axis) -> PaneRefusal? {
            if case let .failure(r) = m.splitting(axis, pane: pane) { return r }
            return nil
        }
        return paneMenu(splits: AgentPaneLayout.splitsEnabled, panes: m.layout.panes.count, right: refusal(.columns),
                        down: refusal(.rows))
    }

    /// #1895 (operator 2026-11-23): Swap Session…, after the pane items, for a pane that shows a session with the split gate
    /// on: the pane's title switcher list (the same rows), whose pick replaces the pane's session and is saved.
    @MainActor
    static func swapMenu(_ m: AgentWindowModel, pane: UUID) -> [AgentWindowMenuEntry] {
        guard AgentPaneLayout.splitsEnabled, m.layout.panes.contains(where: { $0.id == pane && $0.target != nil }) else { return [] }
        return [.pane(swapLabel, enabled: true, verb: .swap)]
    }

    /// A pane item chosen in `pane`'s header: that pane is focused in the action's result (every drawn pane has its own
    /// header; one layout write per choice, R900-6a-1), the key's action running through perform (a refused
    /// split puts the key's notice in the notice line). Equalize: the whole tree, as the divider's double-click adopts
    /// its split. A pane closed since the menu was built: nothing. Runs on the main actor (a Button's action).
    @MainActor
    static func runPane(_ v: AgentPaneVerb, pane: UUID, in m: AgentWindowModel) {
        guard m.layout.order.contains(pane) else { return }
        m.keyFocus = .pane   // focusPane's 7.2 rule; the focus itself rides in the action's one write (R900-6a-1)
        switch v {
        case let .action(a): m.perform(a, pane: pane)
        case .equalize:
            let l = (try? m.layout.focus(pane).get()) ?? m.layout
            let e = (try? l.equalize(path: [], deep: true).get()) ?? l   // R900-6b1-5: refused, the pane is still focused
            if e != m.layout { m.adopt(e) }
        case .swap:
            m.focusPane(pane)
            m.swapRequest = pane   // the pane's title switcher opens its list (AgentPaneSwitcherButton)
        }
    }

    /// #829 G6-G8: a History row's context menu and its detail buttons: the island row's items and
    /// gates (AgentIslandView.historyDrawn: absent while a gate refuses, nothing for a name dch
    /// would read as a flag). Remove asks, so it carries an ellipsis; on a pinned record it stays,
    /// off, saying why (the island hides its X).
    @MainActor
    static func historyMenu(_ r: DchHistoryRecord, store: AgentIslandStore) -> [AgentWindowMenuEntry] {
        var out: [AgentWindowMenuEntry] = []
        let ok = AgentIsland.passable(r.name)
        if ok, store.resumeGate.isOK {
            out.append(.item(AgentIsland.resumeLabel, enabled: true, verb: .resume))
        }
        if ok, store.reviveNoMessageGate.isOK { out.append(.item(AgentIsland.resumeNoMessageLabel, enabled: true, verb: .resumeNoMessage)) }
        if ok, store.historyEditGate.isOK {
            let older = AgentIsland.older(r, in: store.history)
            if !out.isEmpty { out.append(.divider) }
            out.append(.item(AgentIsland.editLabel(r.pinned ? AgentIsland.unpinLabel : AgentIsland.pinLabel, older: older.count),
                             enabled: true, verb: .pin))
            out.append(r.pinned ? .item(removePinnedTitle, enabled: false, verb: .remove)
                : .item(AgentIsland.removeEditLabel(older: older.count, unpinned: older.filter { !$0.pinned }.count) + "\u{2026}",
                        enabled: true, verb: .remove))
        }
        if let why = store.resumeGate.refusal { out.append(.note("Resume \(why)")) }
        return out
    }

    static let removePinnedTitle = AgentIsland.label(AgentIsland.removeLabel, needs: "unpin it first")

    /// The entry for `verb` in `entries`: on (nil), or why not. A live row's: the gate's note ("Not
    /// run: Controls <refusal>"), else the off item's own title ("Not run: Stop (restart this session
    /// first)"). A History row's (`absent`, its verb's own reason): the off item's title, else `absent`.
    static func notRun(_ entries: [AgentWindowMenuEntry], _ verb: AgentWindowVerb, absent: String? = nil) -> String? {
        var title: String?
        for case .item(let t, let enabled, let v) in entries where v == verb {
            if enabled { return nil }
            title = t
        }
        if let absent { return "Not run: " + (title ?? absent) }
        var note: String?
        for case .note(let why) in entries { note = why }
        return "Not run: " + (note ?? title ?? AgentWindowControls.unavailable)
    }

    static let unavailable = "not available for this session"

    /// A History verb the menu leaves out: its label with its gate's reason ("Pin (needs dch 1.25.0)").
    @MainActor
    static func historyOff(_ v: AgentWindowVerb, _ r: DchHistoryRecord, store: AgentIslandStore) -> String {
        let (label, gate): (String, DchCommand.Gate) = switch v {
        case .resumeNoMessage: (AgentIsland.resumeNoMessageLabel, store.reviveNoMessageGate)
        case .pin: (r.pinned ? AgentIsland.unpinLabel : AgentIsland.pinLabel, store.historyEditGate)
        case .remove: (AgentIsland.removeLabel, store.historyEditGate)
        default: (AgentIsland.resumeLabel, store.resumeGate)
        }
        return AgentIsland.label(label, needs: gate.refusal ?? unavailable)
    }

    /// G8: the strip's line for Remove from History, naming the record; its Claude id when it has one,
    /// so the conversation stays reachable by hand. QA #668 INFO-5: the forget also folds the name's
    /// older unpinned records (#743, the menu item's count), so the line says so.
    static func removeQuestion(_ r: DchHistoryRecord, in history: [DchHistoryRecord] = []) -> String {
        let sid = r.agent?.sessionID ?? ""
        let n = AgentIsland.older(r, in: history).filter { !$0.pinned }.count
        let what = n == 0 ? "\(r.title) from History? Resume won't be able to bring it back. Its Claude Code conversation stays"
            : "\(r.title) and its \(n) older record\(n == 1 ? "" : "s") from History? Resume won't be able to bring them back."
                + " Their Claude Code conversations stay"
        return "Remove \(what) on disk." + (sid.isEmpty ? "" : " (claude --resume \(sid))")
    }

    static let blockedSentence = " It's waiting on a prompt: answer it first."

    /// The strip's line, naming the session by title.
    /// #1289 (G5): a URL chip's accessibility name: the PR by its full name ("Open pull request acme/api#12").
    static func openPRLabel(_ c: AgentIsland.PRChip) -> String { "Open pull request \(c.fullName.isEmpty ? c.label : c.fullName)" }

    static func question(_ v: AgentWindowVerb, _ s: AgentSession) -> String {
        let blocked = s.state == .blocked ? blockedSentence : ""
        switch v {
        case .restart:
            return "Restart \(s.title)? Claude Code is paused, then relaunched on the same conversation. This can take minutes."
                + blocked
        case .stop:
            return "Stop \(s.title)? Claude Code is paused and the session ends. Resume it later from History." + blocked
        case .kill:
            return AgentIsland.killQuestion(s.title)
        case .resume, .resumeNoMessage, .pin, .remove, .rename, .switchTo:
            return ""   // History verbs: removeQuestion; the rest never ask
        }
    }

    static func confirmTitle(_ v: AgentWindowVerb) -> String {
        switch v {
        case .restart: "Restart"
        case .stop: "Stop"
        case .kill: "End"
        case .remove: "Remove"
        case .resume: AgentIsland.resumeLabel
        case .resumeNoMessage: AgentIsland.resumeNoMessageLabel
        case .pin: AgentIsland.pinLabel
        case .rename: AgentIsland.renameLabel
        case .switchTo(let c): c.text
        }
    }

    /// Spec 3.5: a row text that is a running text ("Restarting…", "Pausing…", "Stopping…"):
    /// dch is typing into Claude's composer, so the window's input waits. nil: no lock.
    static func lock(_ action: String?) -> String? {
        action.flatMap { AgentIsland.runningTexts.contains($0) ? $0 : nil }
    }

    /// "Restarting: wait for it to finish": the running text without its ellipsis.
    static func lockPlaceholder(_ running: String) -> String {
        "\(running.hasSuffix("…") ? String(running.dropLast()) : running): wait for it to finish"
    }

    /// G0: the island row's own rule: a notice ("Attach command copied") wins over the row's
    /// action text ("Stopping…", "Restarted", a failure).
    @MainActor
    static func notice(_ store: AgentIslandStore, _ key: AgentSessionKey) -> String? {
        store.notices[key] ?? store.actions[key]
    }

    /// The dir strip's fixed height (shown or not, the sidebar keeps its slot under the list).
    static var stripHeight: CGFloat { sz(24) }
}

// MARK: - The sidebar "..." (#897, spec G9)

/// What a sidebar "..." item runs: the island controller's own call (its gate re-checked there).
enum AgentSidebarVerb: Equatable {
    case newSession(String), chooseFolder
    case restartAll(force: Bool), stopAll, killAll
    case resumeInterrupted(noMessage: Bool), clearUnpinned
    case sort(AgentIslandSort), rowDetail(WritableKeyPath<AgentIslandRowDetails, Bool>), autoAllow
    case settings
    /// #923: the window's Diagnostics pane (AgentsWindow presents it; the island has nothing to run).
    case diagnostics
}

/// One sidebar "..." entry, a value (rows read the list; no menu is popped).
indirect enum AgentSidebarMenuEntry: Equatable {
    case item(String, enabled: Bool, checked: Bool?, verb: AgentSidebarVerb)
    case submenu(String, enabled: Bool, [AgentSidebarMenuEntry])
    case divider
    /// A disabled line: the gate's reason ("Controls <refusal>").
    case note(String)
}

/// The island's list-wide question, drawn by the window too (spec G9: one question state, the store's).
enum AgentStoreQuestion: Equatable { case restartAll, stopAll, killAll, clear }

extension AgentWindowControls {
    static let islandSettingsLabel = "Agent Island Settings\u{2026}"
    static let autoAllowLabel = "Always allow permission prompts"
    /// R897-q1: the question Always allow ON raises in the sidebar, and its confirming button.
    static let alwaysAllowQuestion = "Always allow: Claude Code's permission prompts will be answered Yes, so commands run without your review."
    static let alwaysAllowAction = "Turn on"
    static let sortLabel = "Sort"
    static let rowDetailsLabel = "Row details"
    /// The sidebar "\u{22EF}" button's help (a value, so a test pins it literally).
    static let sidebarMenuHelp = "New session, restart, stop or end all, History and Agent Island settings"
    /// Agent Island's Settings pane (Resources/extensions/agentisland/extension.toml: id and its sidebar section).
    static let islandExtensionID = "com.prosper.agentisland", islandSectionID = "agentisland"

    /// Spec G9: the sidebar "..." in the spec's order, with the island's gates (AgentIslandController.controlGates, the
    /// island menu's own rule) and titles. An item that asks carries an ellipsis while on; off, it reads the island's
    /// title with its reason. Resume interrupted and Clear unpinned show only while the island's History header shows
    /// their buttons. `autoAllow`: the setting now (Preferences.agentIslandAutoAllow).
    @MainActor
    static func sidebarMenu(store: AgentIslandStore, autoAllow: Bool) -> [AgentSidebarMenuEntry] {
        let g = AgentIslandController.controlGates(store), m = store.controlsMenu, needs = g.needs
        func ask(_ label: String, _ on: Bool, _ verb: AgentSidebarVerb) -> AgentSidebarMenuEntry {
            let asks = label.hasSuffix("\u{2026}") ? label : label + "\u{2026}"
            return .item(on ? asks : AgentIsland.label(label, needs: needs), enabled: on, checked: nil, verb: verb)
        }
        let recent: [AgentSidebarMenuEntry] = m.recent.map {
            .item(($0 as NSString).abbreviatingWithTildeInPath, enabled: true, checked: nil, verb: .newSession($0))
        }
        var out: [AgentSidebarMenuEntry] = [
            .submenu(AgentIsland.newSessionLabel, enabled: g.on, recent + (recent.isEmpty ? [] : [.divider])
                     + [.item(AgentIsland.chooseFolderLabel, enabled: true, checked: nil, verb: .chooseFolder)]),
            .divider,
            ask(AgentIsland.restartAllLabel, g.restart, .restartAll(force: false)),
            ask(AgentIsland.restartAllForceLabel, g.restart, .restartAll(force: true)),
            ask(AgentIsland.stopAllGlobalLabel, g.stop(global: true), .stopAll),
            .item(AgentIsland.killAllGlobalLabel, enabled: g.kill(global: true), checked: nil, verb: .killAll),
        ]
        var history: [AgentSidebarMenuEntry] = []
        if let label = store.resumeAllButton {
            history.append(.item(label, enabled: true, checked: nil, verb: .resumeInterrupted(noMessage: false)))
            if store.reviveNoMessageGate.isOK {   // #669: the island's "(no message)" shows only then
                history.append(.item(AgentIsland.resumeAllNoMessageAccessibility(store.resumableCount), enabled: true,
                                     checked: nil, verb: .resumeInterrupted(noMessage: true)))
            }
        }
        if store.clearUnpinnedButton != nil {
            history.append(.item(AgentIsland.clearUnpinnedLabel + "\u{2026}", enabled: true, checked: nil, verb: .clearUnpinned))
        }
        if !history.isEmpty { out += [.divider] + history }
        out += [
            .divider,
            .submenu(sortLabel, enabled: true, AgentIslandSort.allCases.map {
                .item($0.label, enabled: true, checked: store.sort == $0, verb: .sort($0))
            }),
            .submenu(rowDetailsLabel, enabled: true, AgentIslandRowDetailsSection.toggles.map {
                .item($0.label, enabled: true, checked: store.details[keyPath: $0.path], verb: .rowDetail($0.path))
            }),
            .item(autoAllowLabel, enabled: true, checked: autoAllow, verb: .autoAllow),
            .item(islandSettingsLabel, enabled: true, checked: nil, verb: .settings),
            .item(AgentDiagnostics.menuLabel, enabled: true, checked: nil, verb: .diagnostics),
        ]
        if let why = m.refused { out += [.divider, .note("Controls \(why)")] }
        return out
    }

    /// The item's run: the island's own call. The list-wide verbs only ask (the store's question); the settings
    /// items write the setting as Settings does and tell the island. `openSettings`: the Settings pane seam.
    @MainActor
    static func runSidebar(_ v: AgentSidebarVerb, island c: AgentIslandController, openSettings: () -> Void) {
        switch v {
        case .newSession(let folder): c.newSession(in: folder)
        case .chooseFolder: c.chooseNewSessionFolder()
        case .restartAll(let force): c.askRestartAll(force: force)
        case .stopAll: c.askStopAll(global: true)
        case .killAll: c.askKillAll(global: true)
        case .resumeInterrupted(let noMessage): c.resumeCrashed(noMessage: noMessage)
        case .clearUnpinned: c.askClearUnpinned()
        case .sort(let s):
            Preferences.agentIslandSort = s
            c.rowDetailsChanged()
        case .rowDetail(let path):
            Preferences.agentIslandRowDetails[keyPath: path].toggle()
            c.rowDetailsChanged()
        case .autoAllow: AgentIslandPane.autoAllowToggled(!Preferences.agentIslandAutoAllow, c)
        case .settings: openSettings()
        case .diagnostics: break   // the window's own pane (AgentSidebarTitleRow)
        }
    }

    /// The store's list-wide question up now (one at a time: store.dropQuestions), its line and its answer's verb.
    @MainActor
    static func storeQuestion(_ store: AgentIslandStore) -> (kind: AgentStoreQuestion, text: String, action: String)? {
        if store.confirmingRestartAll {
            return (.restartAll, store.restartAllForce ? AgentIsland.restartAllForceQuestion : AgentIsland.restartAllQuestion,
                    "Restart")
        }
        if store.confirmingStopAll { return (.stopAll, store.stopAllQuestion, "Stop") }
        if store.confirmingKillAll { return (.killAll, store.killAllQuestion, "End") }
        if store.confirmingClear { return (.clear, AgentIsland.clearQuestion(store.unpinnedCount), "Clear") }
        return nil
    }

    /// The strip's answer: the island's own confirm call, which re-checks that its question is still up.
    @MainActor
    static func answer(_ q: AgentStoreQuestion, _ yes: Bool, island c: AgentIslandController) {
        switch q {
        case .restartAll: c.confirmRestartAll(yes)
        case .stopAll: c.confirmStopAll(yes)
        case .killAll: c.confirmKillAll(yes)
        case .clear: c.confirmClearUnpinned(yes)
        }
    }
}

// MARK: - Menus

/// The menu's items, for a SwiftUI Menu or a context menu. Observes the store, so a gate
/// that changes while the menu's row is drawn is read afresh.
struct AgentSessionMenuItems: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var store: AgentIslandStore
    let session: AgentSession
    let ask: (AgentWindowVerb) -> Void
    /// #1103: Open in terminal's action and the session's end (the item is off).
    var open: () -> Void = {}
    var ended = false
    /// #900 B2 step 6a: the header's pane items (AgentWindowControls.paneMenu; empty with the gate off) and their run.
    var panes: [AgentWindowMenuEntry] = []
    var pane: (AgentPaneVerb) -> Void = { _ in }
    /// #900 B2 step 6b1: a sidebar row's model (its list is rowMenu: Open to the Side with the gate on) and the item's run.
    var row: AgentWindowModel? = nil
    var side: () -> Void = {}

    var body: some View {
        let base = row.map { AgentWindowControls.rowMenu(session, store: store, in: $0) }
            ?? AgentWindowControls.sessionMenu(session, store: store, ended: ended)
        AgentMenuEntries(entries: base + panes, act: ask, open: open, pane: pane, side: side)
        // #1469: Model and Effort for a live session (#627: never for a name dch would read as a flag).
        if !ended, AgentIsland.passable(session.name) {
            Divider()
            AgentSwitchMenus(menus: AgentModelSwitch.menus(session, requested: row?.interaction.requested[session.key]?.level),
                             act: ask)
        }
    }
}

/// #1469: the Model and Effort submenus from AgentModelSwitch.menus (a value, tested without a menu); an item runs
/// `.switchTo` through the row's `ask`.
struct AgentSwitchMenus: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let menus: [AgentModelSwitch.Submenu]
    let act: (AgentWindowVerb) -> Void

    var body: some View {
        ForEach(menus, id: \.title) { m in
            SwiftUI.Menu {
                ForEach(m.items, id: \.title) { i in
                    Toggle(i.title, isOn: Binding(get: { i.checked }, set: { _ in act(.switchTo(i.command)) }))
                }
                Divider()
                ForEach(m.notes, id: \.self) { Text(verbatim: $0) }
            } label: {
                Label(m.title, systemImage: m.title == AgentModelSwitch.modelLabel ? AgentMenuSymbol.model : AgentMenuSymbol.effort)
            }
        }
    }
}

/// #829 Phase 2: a History row's context menu.
struct AgentHistoryMenuItems: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var store: AgentIslandStore
    let record: DchHistoryRecord
    let act: (AgentWindowVerb) -> Void

    var body: some View {
        AgentMenuEntries(entries: AgentWindowControls.historyMenu(record, store: store), act: act)
    }
}

struct AgentMenuEntries: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let entries: [AgentWindowMenuEntry]
    let act: (AgentWindowVerb) -> Void
    var open: () -> Void = {}
    var pane: (AgentPaneVerb) -> Void = { _ in }
    var side: () -> Void = {}

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
            switch e {
            case .open(let enabled):
                Button(action: open) { Label(AgentWindowControls.openLabel, systemImage: e.symbol ?? "") }.disabled(!enabled)
            case .item(let title, let enabled, let verb):
                Button { act(verb) } label: { Label(title, systemImage: e.symbol ?? "") }.disabled(!enabled)
            case .divider:
                Divider()
            case .note(let text):
                Text(verbatim: text)
            case .pane(let title, let enabled, let verb):
                Button { pane(verb) } label: { Label(title, systemImage: e.symbol ?? "") }.disabled(!enabled)
            case .side(let title, let enabled):
                Button(action: side) { Label(title, systemImage: e.symbol ?? "") }.disabled(!enabled)
            case .xray(let pane):
                Button { AgentsNSWindow.xrayChosen(pane: pane) } label: {
                    Label(AgentWindowControls.xrayLabel, systemImage: e.symbol ?? "")
                }
            }
        }
    }
}

/// The header's "⋯": always there, one fixed size, the title line's last control. #1103: Open in terminal is its
/// first item, so it is off only for an ended session (whose item is off too).
struct AgentSessionMenuButton: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let store: AgentIslandStore?
    let session: AgentSession
    let ask: (AgentWindowVerb) -> Void
    var open: () -> Void = {}
    var ended = false
    /// #900 B2 step 6a: the pane items after the session's (empty with the gate off: the menu is today's).
    var panes: [AgentWindowMenuEntry] = []
    var pane: (AgentPaneVerb) -> Void = { _ in }

    /// StableMenuProbe.bodies key.
    static let menuID = "agent.paneHeader"

    /// #1540: what the "⋯" draws: the session's and pane items, then Model and Effort (#1469: a live session's only,
    /// #627: never for a name dch would read as a flag; none without a store, as before).
    struct Snapshot: Equatable {
        var entries: [AgentWindowMenuEntry]
        var switches: [AgentModelSwitch.Submenu]
    }

    /// #1540: a menu item's verb, run through the newest closures of the header's draw.
    enum Verb {
        case ask(AgentWindowVerb), open, pane(AgentPaneVerb)
    }

    @MainActor
    static func snapshot(_ s: AgentSession, store: AgentIslandStore?, ended: Bool,
                         panes: [AgentWindowMenuEntry]) -> Snapshot {
        Snapshot(entries: AgentWindowControls.sessionMenu(s, store: store, ended: ended) + panes,
                 switches: store != nil && !ended && AgentIsland.passable(s.name) ? AgentModelSwitch.menus(s) : [])
    }

    var body: some View {
        // #1540: the store publishes about every second; the open "⋯" (its Model and Effort submenus) is rebuilt only
        // when what it draws changes. With a store, an observing reader re-reads the gates as they change.
        Group {
            if let store {
                AgentSessionMenuReader(store: store) { menu(Self.snapshot(session, store: store, ended: ended, panes: panes)) }
            } else {
                menu(Self.snapshot(session, store: nil, ended: ended, panes: panes))
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        // A borderless Menu's own minimum is 20 pt at every UI scale; framed, it scales with the
        // header and leaves the narrowest title line its room (#822's pill included).
        .frame(width: sz(18), height: sz(18))
        .disabled(Self.disabled(ended: ended, entries: panes))
        .help(help)
        .accessibilityLabel("Session actions")
    }

    /// R900-6a-2: an ended session's "⋯" is off, unless the split gate is on and it holds pane items: then it opens, its
    /// Open in terminal stays off by its own entry (sessionMenu(ended: true)) and each pane item by its own rule.
    static func disabled(ended: Bool, entries: [AgentWindowMenuEntry],
                         splits: Bool = AgentPaneLayout.splitsEnabled) -> Bool {
        ended && !(splits && entries.contains { if case .pane = $0 { true } else { false } })
    }

    /// QA #672 #4 (the button's, before #1103): an ended session's says why.
    var help: String { Self.help(session, ended: ended, panes: panes) }

    /// R900-6a-3: today's text, and with the split gate on and pane items present the pane verbs after it (an ended
    /// session's too, whose menu then opens for them). Gate off or no pane items: today's three texts exactly.
    static func help(_ s: AgentSession, ended: Bool, panes: [AgentWindowMenuEntry],
                     splits: Bool = AgentPaneLayout.splitsEnabled) -> String {
        let today = ended ? AgentWindowControls.endedReason : help(s)
        let verbs = panes.compactMap { (e: AgentWindowMenuEntry) -> AgentPaneVerb? in
            if case let .pane(_, _, v) = e { v } else { nil }
        }
        guard splits, !verbs.isEmpty else { return today }
        return today + (verbs.contains(.equalize) ? "; split, zoom, equalize or close this pane" : "; split this pane")
    }

    private func menu(_ snap: Snapshot) -> some View {
        let ask = ask, open = open, pane = pane
        return StableMenu(Self.menuID, entries: snap, run: { (v: Verb) in
            switch v {
            case .ask(let a): ask(a)
            case .open: open()
            case .pane(let p): pane(p)
            }
        }) { snap, run in
            AgentMenuEntries(entries: snap.entries, act: { run(.ask($0)) }, open: { run(.open) }, pane: { run(.pane($0)) })
            if !snap.switches.isEmpty {
                Divider()
                AgentSwitchMenus(menus: snap.switches, act: { run(.ask($0)) })
            }
        } label: { _ in
            Image(systemName: "ellipsis").font(Neon.font(11, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                .contentShape(Rectangle())
        }
    }

    /// The list the menu is built from (the snapshot re-reads it as the store changes).
    var entries: [AgentWindowMenuEntry] { AgentWindowControls.sessionMenu(session, store: store, ended: ended) + panes }

    /// QA #693 INFO-6: what the menu holds: Rename alone for a name dch would read as a flag (#627).
    static func help(_ s: AgentSession) -> String {
        AgentIsland.passable(s.name) ? "Open in terminal, rename, restart, stop or end this session"
            : "Open in terminal or rename this session"
    }
}

/// #1540: redraws its content whenever the store publishes (a gate the "⋯" reads may have changed); the StableMenu
/// inside decides whether the menu itself is rebuilt.
struct AgentSessionMenuReader<Content: View>: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var store: AgentIslandStore
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

// MARK: - Strips

/// R5: the inline question at the top of the detail pane. Drawn over the conversation's top,
/// so it never moves the header, the transcript or the input box. #1361: when the question fits on one line beside
/// its buttons it is ONE row (symbol, question, Cancel, verb; the buttons a fixed sz(8) after the text, all on one
/// vertical centre); when it does not, the question wraps whole on its own lines and the buttons sit under it,
/// left-aligned with its start (ViewThatFits): nothing is squeezed at the narrowest pane.
struct AgentConfirmStrip: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let text: String
    let action: String
    let confirm: () -> Void
    let cancel: () -> Void
    /// Tests only: (part, frame in the strip) as "text", "cancel" and "verb" are laid out (nil in the product). Main actor.
    static var probe: ((String, CGRect) -> Void)?

    private var symbol: some View {
        Image(systemName: "exclamationmark.triangle.fill").font(Neon.font(11)).foregroundStyle(AgentState.blocked.color)
    }

    private func question(oneLine: Bool) -> some View {
        Text(text).font(Neon.font(11.5)).foregroundStyle(Neon.textPrimary)
            .textSelection(.enabled)   // G8: the "claude --resume <id>" can be copied
            .fixedSize(horizontal: oneLine, vertical: true)
            .modifier(AgentConfirmProbe(part: "text"))
            .frame(maxWidth: oneLine ? nil : .infinity, alignment: .leading)
    }

    /// Cancel, then the verb: the VoiceOver and Tab order.
    private var buttons: some View {
        HStack(spacing: sz(8)) {
            AgentPillButton(title: "Cancel", icon: "xmark", tint: Neon.textSecondary, action: cancel)
                .keyboardShortcut(.cancelAction)
                .modifier(AgentConfirmProbe(part: "cancel"))
            // QA #665 INFO-2: VoiceOver reads the verb; the question is the Text before.
            AgentPillButton(title: action, icon: "exclamationmark.octagon", tint: Neon.magenta, action: confirm)
                .modifier(AgentConfirmProbe(part: "verb"))
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: sz(8)) {
                symbol
                question(oneLine: true)
                buttons
            }
            HStack(alignment: .firstTextBaseline, spacing: sz(8)) {
                symbol
                VStack(alignment: .leading, spacing: sz(6)) {
                    question(oneLine: false)
                    buttons
                }
            }
        }
        .coordinateSpace(.named(agentConfirmSpace))
        .padding(.horizontal, sz(16)).padding(.vertical, sz(8))
        // minWidth 0: the strip is the pane's width exactly; a wrapped Text's fraction of a
        // point over (seen at 0.7) stays inside the padding, never past the window.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(Neon.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Neon.stroke).frame(height: 1) }
    }
}

let agentConfirmSpace = "agentConfirmStrip"

/// Tests: a strip part's frame in the strip, through `AgentConfirmStrip.probe` (nil in the product: no observer).
struct AgentConfirmProbe: ViewModifier {
    let part: String
    @ViewBuilder func body(content: Content) -> some View {
        if AgentConfirmStrip.probe != nil {
            content.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(agentConfirmSpace)) }) { r in
                agentProbeCalled()
                AgentConfirmStrip.probe?(part, r)
            }
        } else {
            content
        }
    }
}

/// #897 (G9): the store's list-wide question (Restart all, Stop all, Kill all, Clear unpinned) at the top of the
/// sidebar, the island's own line and verb; the answer goes through the island's confirm call. Nothing while none is up.
struct AgentStoreQuestionStrip: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var store: AgentIslandStore
    let answer: (Bool) -> Void

    var body: some View {
        if let q = AgentWindowControls.storeQuestion(store) {
            AgentConfirmStrip(text: q.text, action: q.action, confirm: { answer(true) }, cancel: { answer(false) })
        }
    }
}

/// R897-q1: the Always allow question (Turn on / Cancel) while the model asks; nothing otherwise.
struct AgentAlwaysAllowStrip: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var model: AgentWindowModel

    var body: some View {
        if model.askingAlwaysAllow {
            AgentConfirmStrip(text: AgentWindowControls.alwaysAllowQuestion, action: AgentWindowControls.alwaysAllowAction,
                              confirm: { model.answerAlwaysAllow(true) }, cancel: { model.answerAlwaysAllow(false) })
        }
    }
}

/// #897 (G9): the sidebar title row's "...": AgentWindowControls.sidebarMenu, re-read as the store changes.
struct AgentSidebarMenuButton: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var store: AgentIslandStore
    let run: (AgentSidebarVerb) -> Void
    /// StableMenuProbe.bodies key.
    static let menuID = "agent.sidebar"

    var body: some View {
        // #1466/#1540: the store publishes about every second (ages, History); an equal list must not rebuild the open
        // menu (that closes an open submenu such as Row details): StableMenu rebuilds it only on a real change.
        StableMenu(Self.menuID, entries: AgentWindowControls.sidebarMenu(store: store,
                                                                         autoAllow: Preferences.agentIslandAutoAllow),
                   run: run) { entries, run in
            AgentSidebarMenuEntries(entries: entries, run: run)
        } label: { _ in
            Image(systemName: "ellipsis").font(Neon.font(11, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: sz(18), height: sz(18))
        .help(AgentWindowControls.sidebarMenuHelp)
        .accessibilityLabel("Session list actions")
    }
}

struct AgentSidebarMenuEntries: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let entries: [AgentSidebarMenuEntry]
    let run: (AgentSidebarVerb) -> Void

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
            switch e {
            case .item(let title, let enabled, let checked, let verb):
                if let checked {
                    Toggle(isOn: Binding(get: { checked }, set: { _ in run(verb) })) { Label(title, systemImage: verb.symbol) }
                        .disabled(!enabled)
                } else {
                    Button { run(verb) } label: { Label(title, systemImage: verb.symbol) }.disabled(!enabled)
                }
            case .submenu(let title, let enabled, let items):
                Menu { AgentSidebarMenuEntries(entries: items, run: run) } label: { Label(title, systemImage: e.symbol ?? "") }
                    .disabled(!enabled)
            case .divider:
                Divider()
            case .note(let text):
                Text(verbatim: text)
            }
        }
    }
}

/// G0: every dir's last dir-wide line (Restart all, Stop all, Kill all tallies, edit failures,
/// a failed New session) at the bottom of the sidebar; nothing while there is none. One line in
/// a fixed slot under the list (QA #665 INFO-4/5: not over it, so the last row and a row the
/// keys scroll to stay above it); shown or not, the slot is the same height, so no row moves.
struct AgentDirStatusStrip: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var store: AgentIslandStore

    var body: some View {
        let text = store.dirStatus
        ZStack {
            if !text.isEmpty {
                HStack(spacing: sz(6)) {
                    Image(systemName: "info.circle").foregroundStyle(Neon.blue)
                    Text(text).foregroundStyle(Neon.textSecondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(Neon.font(10.5))
                .padding(.horizontal, sz(14))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { Rectangle().fill(Neon.stroke).frame(height: 1) }
                .help(text)
            }
        }
        .frame(height: AgentWindowControls.stripHeight)
        .frame(maxWidth: .infinity)
    }
}

/// The island's inline note for the row ("Attach command copied", "Attached in tmux/ssh…"),
/// #829 G0: else the row's action text ("Stopping…", "Restarted", a failure), as the island row;
/// QA #665 INFO-6: an answer the window refused wins. QA #665 INFO-1: drawn over the
/// conversation's top (with the confirm strip), never in the column, so it moves nothing.
struct AgentNoticeLine: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var store: AgentIslandStore
    let key: AgentSessionKey
    var refusal: String?
    /// #1103: a line that says "Open in terminal" (the island's Message refusals) gets the button beside it: the
    /// header's moved into the "⋯".
    var open: (() -> Void)?
    var ended = false
    var body: some View {
        if let text = refusal ?? AgentWindowControls.notice(store, key) {
            HStack(alignment: .firstTextBaseline, spacing: sz(6)) {
                Image(systemName: "info.circle").foregroundStyle(Neon.blue)
                Text(text).foregroundStyle(Neon.textSecondary).lineLimit(3)
                Spacer(minLength: 0)
                if let open, Self.offersOpen(text) { OpenInTerminalButton(action: open, compact: true, ended: ended) }
            }
            .font(Neon.font(11))
            .padding(.horizontal, sz(16)).padding(.vertical, sz(6))
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background(Neon.card)
            .overlay(alignment: .bottom) { Rectangle().fill(Neon.stroke).frame(height: 1) }
            .help(text)
        }
    }

    static func offersOpen(_ text: String) -> Bool { text.contains(AgentWindowControls.openLabel) }
}

/// #847 D2.3, #1471 b (R1471a-m1): a first message the island could not send, over the focused pane's terminal in the
/// notice line's look: the text cut for display only (Copy and Send take the raw text), Copy, Send (one bracketed
/// paste, no Return) and Dismiss. Nothing reaches the terminal before Send.
struct AgentUnsentFirstLine: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let text: String
    let copy: () -> Void
    let send: () -> Void
    let dismiss: () -> Void
    /// R1471b-m1: false while the terminal has no live client for this session: Send is off and says so.
    var canSend = true

    static let title = "Your first message was not sent"
    static let notConnected = "Not connected yet"
    static let maxShown = 80

    /// One line: newlines folded to spaces, cut by Characters (a grapheme stays whole) to `maxShown` with an ellipsis, then
    /// OutsideText's rule for what may be drawn (controls, bidi and invisibles dropped) with no second cut: it may split
    /// a ZWJ emoji into its parts, and a cut after that could keep only some of them.
    static func shown(_ raw: String) -> String {
        let one = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " ")
        let cut = one.count <= maxShown ? one : String(one.prefix(maxShown - 1)) + "\u{2026}"
        return OutsideText.shown(cut, max: Int.max)
    }

    var body: some View {
        let line = Self.shown(text)
        HStack(alignment: .firstTextBaseline, spacing: sz(6)) {
            HStack(alignment: .firstTextBaseline, spacing: sz(6)) {
                Image(systemName: "info.circle").foregroundStyle(Neon.blue)
                Text(verbatim: Self.title + ": ").foregroundStyle(Neon.textPrimary)
                Text(verbatim: line).foregroundStyle(Neon.textSecondary).lineLimit(1).truncationMode(.tail)
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(Self.title).accessibilityValue(line)
            Spacer(minLength: 0)
            Button("Copy", action: copy).accessibilityLabel("Copy first message")
            Button("Send", action: send).disabled(!canSend).help(canSend ? "" : Self.notConnected)
                .accessibilityLabel("Send first message to the terminal")
                .accessibilityHint(canSend ? "" : Self.notConnected)
            Button("Dismiss", action: dismiss).accessibilityLabel("Dismiss")
        }
        .buttonStyle(.link)
        .font(Neon.font(11))
        .padding(.horizontal, sz(16)).padding(.vertical, sz(6))
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(Neon.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Neon.stroke).frame(height: 1) }
        .modifier(AgentPaneProbe(kind: "unsentFirst"))
    }
}

/// Reads the terminal's phase so Send enables when the client comes up (the pane's overlay does not observe it).
struct AgentUnsentFirstHost: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    @ObservedObject var model: AgentWindowModel
    @ObservedObject var terminal: AgentTerminalController

    var body: some View {
        if let u = model.unsentFirst {
            AgentUnsentFirstLine(text: u.text, copy: { model.copyUnsentFirst() }, send: { model.sendUnsentFirst() },
                                 dismiss: { model.dismissUnsentFirst() }, canSend: model.canSendUnsentFirst)
        }
    }
}

// MARK: - Rename (G4)

/// #853 (QA #693 INFO-1): one Rename edit: its session, the text typed so far and the field that has
/// it. A field the header builds anew (a resize or a UI-scale change swaps its ViewThatFits variant)
/// reads the text back and takes the edit over; the field it replaced ends nothing.
@MainActor
final class AgentRenameEdit {
    let key: AgentSessionKey
    var text: String
    /// The field that ends the edit: the last one built for it.
    weak var field: NSTextField?

    init(key: AgentSessionKey, text: String) {
        self.key = key
        self.text = text
    }
}

/// #829 G4: the header title as a text field, prefilled with the alias (empty when there is none,
/// the dch name as its placeholder). Return saves, Esc cancels, the focus leaving cancels; each
/// ends it once. An NSTextField, so the keys are its own: the window's shortcuts stand down while
/// the field editor has them (AgentsNSWindow.route), and nothing reaches the terminal or the composer.
struct AgentRenameField: NSViewRepresentable {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let name: String
    let edit: AgentRenameEdit
    /// The edit and Return's text or nil (Esc, the focus left); true: the edit goes on (a Return refused while a job runs).
    let end: (AgentRenameEdit, String?) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(edit, end) }

    func makeNSView(context: Context) -> AgentRenameTextField {
        let f = AgentRenameTextField(string: edit.text)
        edit.field = f
        context.coordinator.field = f
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.cell?.wraps = false
        f.delegate = context.coordinator
        f.toolTip = AgentIsland.renameHelp(name)
        f.setAccessibilityLabel("Session title")
        f.setAccessibilityHelp(AgentIsland.renameHelp(name))
        return f
    }

    func updateNSView(_ f: AgentRenameTextField, context: Context) {
        context.coordinator.end = end
        let font = NSFont.systemFont(ofSize: sz(15), weight: .semibold)
        f.font = font
        f.textColor = NSColor(Neon.textPrimary)
        f.placeholderAttributedString = NSAttributedString(string: name, attributes: [
            .font: font, .foregroundColor: NSColor(Neon.textSecondary),
        ])
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let edit: AgentRenameEdit
        var end: (AgentRenameEdit, String?) -> Bool
        weak var field: NSTextField?
        private(set) var ended = false
        init(_ edit: AgentRenameEdit, _ end: @escaping (AgentRenameEdit, String?) -> Bool) {
            self.edit = edit
            self.end = end
        }

        /// Once: Return's text, or nil (Esc, the focus leaving, the field going away). Only from the
        /// edit's own field; a refused Return leaves it open for another.
        func finish(_ text: String?) {
            guard !ended, let field, edit.field === field else { return }   // #853 r2: a freed field never matches
            ended = !end(edit, text)
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field, edit.field === field { edit.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): finish(textView.string)
            case #selector(NSResponder.cancelOperation(_:)): finish(nil)
            default: return false
            }
            return true
        }

        /// The focus left. #853 (QA #693 INFO-1): held one turn. A field leaving its window (the header swapped
        /// ViewThatFits variants) ends editing before it learns it is leaving, and the field built in its place
        /// may come after; only a field still the edit's own then ends it.
        /// r2: the field is held until then, so a field freed meanwhile still ends its edit (finish needs it).
        /// #1585: a field editing again by then never lost the focus (a makeFirstResponder on the field that already had it
        /// resigns its field editor and takes a new one at once): the edit goes on.
        func controlTextDidEndEditing(_ obj: Notification) {
            DispatchQueue.main.async { [self, field] in MainActor.assumeIsolated { withExtendedLifetime(field) {
                if field?.currentEditor() != nil { return }
                finish(nil)
            } } }
        }
    }
}

final class AgentRenameTextField: NSTextField {
    /// Takes the keys as soon as it is in the window: first responder within the window only
    /// (never ordering it front or making it key).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}
// MARK: - Pieces

/// #797: the one "Open in terminal" look (the terminal-first state, the failed-attach card, a notice that names it;
/// #1103: the header's moved into its "..." menu, AgentWindowControls.sessionMenu).
struct OpenInTerminalButton: View {
    @ObservedObject var liveTheme = ThemeStore.shared   // #891: re-themes in place (Themed keepsViews)
    let action: () -> Void
    /// Icon only (beside a notice or a card's other button).
    var compact = false
    /// QA #668 F1: the session ended: off and dimmed in its slot; QA #672 #4: its help says why.
    var ended = false
    static let help = "Open this session in the terminal app"
    var help: String { ended ? AgentWindowControls.endedReason : Self.help }
    var body: some View {
        Button(action: action) {
            Label(AgentWindowControls.openLabel, systemImage: "terminal")
                .labelStyle(OpenInTerminalLabelStyle(compact: compact))
                .font(Neon.font(11, weight: .semibold))
                .foregroundStyle(Neon.terminal)
                .padding(.horizontal, sz(10)).padding(.vertical, sz(5))
                .background(Capsule().fill(Neon.terminal.opacity(0.12)))
                .overlay(Capsule().stroke(Neon.terminal.opacity(0.45), lineWidth: 1))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(ended).opacity(ended ? 0.45 : 1)
        .help(help)
        .accessibilityLabel(AgentWindowControls.openLabel)
    }
}

private struct OpenInTerminalLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact { configuration.icon } else { Label(configuration) }
    }
}


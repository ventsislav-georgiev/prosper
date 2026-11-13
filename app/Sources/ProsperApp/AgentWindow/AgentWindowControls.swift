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
}

enum AgentWindowControls {
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

    /// #1103: the header "⋯" and a live row's context menu: Open in terminal first, then `menu`. An ended session's
    /// (a held row; the header passes no store) offers Open in terminal, off, and nothing else.
    @MainActor
    static func sessionMenu(_ s: AgentSession, store: AgentIslandStore?, ended: Bool) -> [AgentWindowMenuEntry] {
        let rest: [AgentWindowMenuEntry] = ended ? [] : store.map { menu(s, store: $0) } ?? []
        return [.open(enabled: !ended)] + (rest.isEmpty ? [] : [.divider] + rest)
    }

    /// #829 G6-G8: a History row's context menu and its detail buttons: the island row's items and
    /// gates (AgentIslandView.historyDrawn: absent while a gate refuses, nothing for a name dch
    /// would read as a flag). Remove asks, so it carries an ellipsis; on a pinned record it stays,
    /// off, saying why (the island hides its X).
    @MainActor
    static func historyMenu(_ r: DchHistoryRecord, store: AgentIslandStore) -> [AgentWindowMenuEntry] {
        var out: [AgentWindowMenuEntry] = []
        let ok = AgentIsland.passable(r.name)
        if ok, store.resumeGate.isOK { out.append(.item(AgentIsland.resumeLabel, enabled: true, verb: .resume)) }
        if ok, store.reviveNoMessageGate.isOK { out.append(.item(AgentIsland.resumeNoMessageLabel, enabled: true, verb: .resumeNoMessage)) }
        if ok, store.historyEditGate.isOK {
            let older = AgentIsland.older(r, in: store.history)
            if !out.isEmpty { out.append(.divider) }
            out.append(.item(AgentIsland.editLabel(r.pinned ? AgentIsland.unpinLabel : AgentIsland.pinLabel, older: older.count),
                             enabled: true, verb: .pin))
            out.append(r.pinned ? .item(removePinnedTitle, enabled: false, verb: .remove)
                : .item(AgentIsland.editLabel(AgentIsland.removeLabel, older: older.filter { !$0.pinned }.count) + "…",
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
        case .resume, .resumeNoMessage, .pin, .remove, .rename:
            return ""   // History verbs: removeQuestion; the rest never ask
        }
    }

    static func confirmTitle(_ v: AgentWindowVerb) -> String {
        switch v {
        case .restart: "Restart"
        case .stop: "Stop"
        case .kill: "Kill"
        case .remove: "Remove"
        case .resume: AgentIsland.resumeLabel
        case .resumeNoMessage: AgentIsland.resumeNoMessageLabel
        case .pin: AgentIsland.pinLabel
        case .rename: AgentIsland.renameLabel
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

// MARK: - Menus

/// The menu's items, for a SwiftUI Menu or a context menu. Observes the store, so a gate
/// that changes while the menu's row is drawn is read afresh.
struct AgentSessionMenuItems: View {
    @ObservedObject var store: AgentIslandStore
    let session: AgentSession
    let ask: (AgentWindowVerb) -> Void
    /// #1103: Open in terminal's action and the session's end (the item is off).
    var open: () -> Void = {}
    var ended = false

    var body: some View {
        AgentMenuEntries(entries: AgentWindowControls.sessionMenu(session, store: store, ended: ended), act: ask, open: open)
    }
}

/// #829 Phase 2: a History row's context menu.
struct AgentHistoryMenuItems: View {
    @ObservedObject var store: AgentIslandStore
    let record: DchHistoryRecord
    let act: (AgentWindowVerb) -> Void

    var body: some View { AgentMenuEntries(entries: AgentWindowControls.historyMenu(record, store: store), act: act) }
}

struct AgentMenuEntries: View {
    let entries: [AgentWindowMenuEntry]
    let act: (AgentWindowVerb) -> Void
    var open: () -> Void = {}

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
            switch e {
            case .open(let enabled):
                Button(AgentWindowControls.openLabel, action: open).disabled(!enabled)
            case .item(let title, let enabled, let verb):
                Button(title) { act(verb) }.disabled(!enabled)
            case .divider:
                Divider()
            case .note(let text):
                Text(verbatim: text)
            }
        }
    }
}

/// The header's "⋯": always there, one fixed size, the title line's last control. #1103: Open in terminal is its
/// first item, so it is off only for an ended session (whose item is off too).
struct AgentSessionMenuButton: View {
    let store: AgentIslandStore?
    let session: AgentSession
    let ask: (AgentWindowVerb) -> Void
    var open: () -> Void = {}
    var ended = false

    var body: some View {
        Menu {
            if let store {
                AgentSessionMenuItems(store: store, session: session, ask: ask, open: open, ended: ended)
            } else {
                AgentMenuEntries(entries: entries, act: ask, open: open)
            }
        } label: {
            Image(systemName: "ellipsis").font(Neon.font(11, weight: .semibold)).foregroundStyle(Neon.textPrimary)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        // A borderless Menu's own minimum is 20 pt at every UI scale; framed, it scales with the
        // header and leaves the narrowest title line its room (#822's pill included).
        .frame(width: sz(18), height: sz(18))
        .disabled(ended)
        .help(help)
        .accessibilityLabel("Session actions")
    }

    /// QA #672 #4 (the button's, before #1103): an ended session's says why.
    var help: String { ended ? AgentPaneModeToggle.endedReason : Self.help(session) }

    /// The list the menu is built from (AgentSessionMenuItems re-reads it as the store changes).
    var entries: [AgentWindowMenuEntry] { AgentWindowControls.sessionMenu(session, store: store, ended: ended) }

    /// QA #693 INFO-6: what the menu holds: Rename alone for a name dch would read as a flag (#627).
    static func help(_ s: AgentSession) -> String {
        AgentIsland.passable(s.name) ? "Open in terminal, rename, restart, stop or kill this session"
            : "Open in terminal or rename this session"
    }
}

// MARK: - Strips

/// R5: the inline question at the top of the detail pane. Drawn over the conversation's top,
/// so it never moves the header, the transcript or the input box. The question wraps whole on
/// its own lines and the buttons sit under it: nothing is squeezed at the narrowest pane.
struct AgentConfirmStrip: View {
    let text: String
    let action: String
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: sz(6)) {
            HStack(alignment: .firstTextBaseline, spacing: sz(8)) {
                Image(systemName: "exclamationmark.triangle.fill").font(Neon.font(11)).foregroundStyle(AgentState.blocked.color)
                Text(text).font(Neon.font(11.5)).foregroundStyle(Neon.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)   // G8: the "claude --resume <id>" can be copied
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: sz(8)) {
                AgentPillButton(title: "Cancel", icon: "xmark", tint: Neon.textSecondary, action: cancel)
                    .keyboardShortcut(.cancelAction)
                // QA #665 INFO-2: VoiceOver reads the verb; the question is the Text above.
                AgentPillButton(title: action, icon: "exclamationmark.octagon", tint: Neon.magenta, action: confirm)
            }
        }
        .padding(.horizontal, sz(16)).padding(.vertical, sz(8))
        // minWidth 0: the strip is the pane's width exactly; a wrapped Text's fraction of a
        // point over (seen at 0.7) stays inside the padding, never past the window.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(Neon.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Neon.stroke).frame(height: 1) }
    }
}

/// G0: every dir's last dir-wide line (Restart all, Stop all, Kill all tallies, edit failures,
/// a failed New session) at the bottom of the sidebar; nothing while there is none. One line in
/// a fixed slot under the list (QA #665 INFO-4/5: not over it, so the last row and a row the
/// keys scroll to stay above it); shown or not, the slot is the same height, so no row moves.
struct AgentDirStatusStrip: View {
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

/// Spec 3.5: the input box under the store's eye: while a Restart or Stop's running text shows
/// on the session, Send, Interrupt and the prompt's answers are off and the box says why.
struct AgentLockedInteraction: View {
    @ObservedObject var store: AgentIslandStore
    let model: AgentWindowInteraction
    let session: AgentSession
    let open: () -> Void

    var body: some View {
        AgentInteractionPane(model: model, session: session, open: open,
                             lock: AgentWindowControls.lock(store.actions[session.key]))
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
        func controlTextDidEndEditing(_ obj: Notification) {
            DispatchQueue.main.async { [self, field] in MainActor.assumeIsolated { withExtendedLifetime(field) { finish(nil) } } }
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

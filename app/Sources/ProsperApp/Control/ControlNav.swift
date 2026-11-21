import Foundation

/// #1862: window.nextNeedsYou, the window's own ⌘J (AgentWindowModel.nextNeedsYou) over the control channel: the next
/// session that needs you (blocked before done, after the focused pane's session, wrapping) is shown and focused, in the
/// active layout or another layout, as the key does, but the keys stay where they are (#1862 n170: as sessions.focus;
/// the person may be typing in a pane). n180: when no pane in any layout shows it, refused and nothing changed (the key's
/// fall-through into the focused pane swaps that pane's terminal, which takes the keys). Only an open window is used:
/// with no model nothing is opened (unlike sessions.focus, which shows the window). Pane changes only, never a session
/// verb. Undo puts the layout, the focused pane and the selected row back (never by retargeting the focused pane), keys
/// left too, and does nothing while a New session form is open (n171: a row's select would close it). On demand only: no
/// observer, no poll.
@MainActor
enum ControlNav {
    static let notOpen = "Agent Sessions is not open"
    static let nobody = "no other session needs you"
    static let noPane = "no pane shows the next session that needs you: press ⌘J yourself"

    static func nextNeedsYou() throws -> ControlChange {
        guard AgentPaneLayout.splitsEnabled else { throw ControlError(ControlLayouts.off) }
        guard let m = ControlSessions.model(), !m.closed else { throw ControlError(notOpen) }
        // A jump selects a row, which closes an open New session form: refused, as sessions.focus does.
        guard m.newSession == nil else { throw ControlError(ControlSessions.formOpen) }
        let layout = m.layout.id, pane = m.layout.focused, selection = m.selection
        guard m.nextNeedingYou() != nil else { throw ControlError(nobody) }
        // n180: false here is the refused fall-through: no pane in any layout shows it, nothing changed.
        guard m.keepingKeys({ m.nextNeedsYou() }) else { throw ControlError(noPane) }
        var title = "a session"
        if case .live(let k)? = m.selection, let s = m.store?.sessions.first(where: { $0.key == k }) { title = s.title }
        return ControlChange(summary: "jump to \(title)", result: .string(title), verb: "jumped", undo: { [weak m] in
            guard let m, !m.closed, m.newSession == nil else { return }
            m.keepingKeys {
                if m.layout.id != layout {
                    guard m.switchLayout(layout, focus: pane) == nil else { return }
                } else if m.layout.panes.contains(where: { $0.id == pane }) {
                    m.focusPane(pane)
                }
                // Put the row back while it is listed, but never by retargeting the focused pane (n180: its new terminal
                // view would take the person's keys).
                if let selection, selection != m.selection, !m.wouldRetargetFocusedPane(selection) {
                    if case .live(let k) = selection, m.store?.sessions.contains(where: { $0.key == k }) != true { return }
                    m.select(selection)
                }
            }
        })
    }
}

extension ControlRegistry {
    /// #1862: wired in ControlRegistry.standard().
    static func registerNav(_ r: inout ControlRegistry) {
        r.register(.change(name: "window.nextNeedsYou",
                           summary: "Show and focus the next session that needs you in Agent Sessions, as its ⌘J does (blocked before done). Opens nothing when the window is not open; refused when no pane shows that session (it never replaces what the focused pane shows).",
                           args: [:]) { _, _ in try ControlNav.nextNeedsYou() })
    }
}

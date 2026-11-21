import Foundation

/// #1862: window.nextNeedsYou, the window's own ⌘J (AgentWindowModel.nextNeedsYou) over the control channel: the next
/// session that needs you (blocked before done, after the focused pane's session, wrapping) is shown and focused, in the
/// active layout, another layout or the focused pane, as the key does. Only an open window is used: with no model
/// nothing is opened (unlike sessions.focus, which shows the window). Pane changes only, never a session verb. Undo puts
/// the layout, the focused pane, the selected row and the key focus back. On demand only: no observer, no poll.
@MainActor
enum ControlNav {
    static let notOpen = "Agent Sessions is not open"
    static let nobody = "no other session needs you"

    static func nextNeedsYou() throws -> ControlChange {
        guard AgentPaneLayout.splitsEnabled else { throw ControlError(ControlLayouts.off) }
        guard let m = ControlSessions.model(), !m.closed else { throw ControlError(notOpen) }
        // A jump selects a row, which closes an open New session form: refused, as sessions.focus does.
        guard m.newSession == nil else { throw ControlError(ControlSessions.formOpen) }
        let layout = m.layout.id, pane = m.layout.focused, selection = m.selection, keys = m.keyFocus
        guard m.nextNeedsYou() else { throw ControlError(nobody) }
        var title = "a session"
        if case .live(let k)? = m.selection, let s = m.store?.sessions.first(where: { $0.key == k }) { title = s.title }
        return ControlChange(summary: "jump to \(title)", result: .string(title), verb: "jumped", undo: { [weak m] in
            guard let m, !m.closed else { return }
            if m.layout.id != layout {
                guard m.switchLayout(layout, focus: pane) == nil else { return }
            } else if m.layout.panes.contains(where: { $0.id == pane }) {
                m.focusPane(pane)
            }
            // A jump into the focused pane (no pane showed the session) changed the row: put it back, while it is listed.
            if let selection, selection != m.selection {
                if case .live(let k) = selection, m.store?.sessions.contains(where: { $0.key == k }) != true { return }
                m.select(selection)
            }
            m.keyFocus = keys
        })
    }
}

extension ControlRegistry {
    /// #1862: wired in ControlRegistry.standard().
    static func registerNav(_ r: inout ControlRegistry) {
        r.register(.change(name: "window.nextNeedsYou",
                           summary: "Show and focus the next session that needs you in Agent Sessions, as its ⌘J does (blocked before done). Opens nothing when the window is not open.",
                           args: [:]) { _, _ in try ControlNav.nextNeedsYou() })
    }
}

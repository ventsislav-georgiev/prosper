import Foundation

/// #1842: sessions.rename / sessions.model / sessions.effort over the control channel. Rename is the window's Rename
/// (the model's `renameSession`, else the island controller's `rename`: `dch -m`); model and effort are the window's
/// Model and Effort menu items (`switchSession`, typed into Claude Code), only while the session is idle or done. Both
/// run on demand, nothing observes or polls. dch answers later: a late failure shows on the session's row, as in the window.
@MainActor
enum ControlSessionsEdit {
    /// Seam: starts the rename; false when nothing ran. The window model's own seam when a window exists.
    static var rename: @MainActor (AgentSession, String) -> Bool = { s, to in
        if let m = ControlSessions.model() { return m.renameSession(s, to) }
        return AgentIslandController.shared.rename(s, alias: to)
    }
    /// Seam: starts the switch on the window's model; the refusal the window gave at once (its lock, a busy window), else nil.
    static var switchTo: @MainActor (AgentWindowModel, AgentModelSwitch.Command, AgentSession) -> String? = { m, c, s in
        guard m.interaction.controller != nil else { return ControlSessions.islandOff }
        guard !m.interaction.busy else { return AgentWindowText.busy }
        let was = m.refusal
        m.switchSession(c, s)
        // shortcut: the same refusal text twice in a row reads as none (refusal is read-only here); then the reply says started.
        return m.refusal != was ? m.refusal.flatMap { $0.id == .live(s.key) ? $0.text : nil } : nil
    }

    // MARK: - sessions.rename

    /// Undo puts the alias before back (empty: dch's own name again).
    static func renameSession(_ args: [String: ControlJSON]) throws -> ControlChange {
        let st = try ControlSessions.store(), s = try ControlSessions.session(try ControlSessions.required(args, "name"), in: st)
        let raw = try ControlSessions.required(args, "to")
        // A title is one line of outside text: a control character (tab and LF too) or an unseen scalar refuses it whole.
        if ControlSessionsTalk.hasUnseen(raw) { throw ControlError("to has a control or hidden character") }
        let to = AgentIsland.renameText(raw), old = s.alias, key = s.key
        guard AgentIsland.renameArgs(s.name, to, current: old) != nil else { throw ControlError("\(s.title) is already named \(to)") }
        guard rename(s, to) else { throw ControlError(st.actions[key] ?? "\(s.title) can't be renamed now: dch is unavailable or the session is busy") }
        return ControlChange(summary: "\(s.title) to \(to)", result: .string(s.name), verb: "renamed", undo: {
            guard let live = st.sessions.first(where: { $0.key == key }) else { return }
            _ = rename(live, old)
        })
    }

    // MARK: - sessions.model / sessions.effort

    /// Undo switches back to the value the row showed before (model: its alias by the id's family, as the menu checks it);
    /// none when the row did not know it.
    static func switchSession(_ args: [String: ControlJSON], model isModel: Bool) throws -> ControlChange {
        let (m, st) = try ControlSessions.window()
        let s = try ControlSessions.session(try ControlSessions.required(args, "name"), in: st)
        let key = isModel ? "model" : "effort", value = try ControlSessions.required(args, key)
        guard let c = isModel ? AgentModelSwitch.Command.model(value) : AgentModelSwitch.Command.effort(value) else {
            throw ControlError("unknown \(key) \(value)")
        }
        guard s.state == .idle || s.state == .done else {
            throw ControlError(s.state == .blocked ? AgentWindowText.blocked : AgentModelSwitch.working)
        }
        guard s.claudeForeground == true else { throw ControlError(AgentWindowText.notForeground) }
        var before: String? = s.effort
        if isModel {
            let family = (s.model ?? "").split(separator: "-").map(String.init)
            before = family.count > 1 ? family[1] : nil
        }
        if let why = switchTo(m, c, s) { throw ControlError(why) }
        var back: AgentModelSwitch.Command?
        if let before { back = isModel ? AgentModelSwitch.Command.model(before) : AgentModelSwitch.Command.effort(before) }
        var undo: (@MainActor () -> Void)?
        if let back {
            undo = { [weak m] in
                guard let m, let live = m.store?.sessions.first(where: { $0.key == s.key }) else { return }
                _ = switchTo(m, back, live)
            }
        }
        return ControlChange(summary: "\(s.title) \(key) \(value)", result: .string(value), verb: "switched", undo: undo)
    }
}

extension ControlRegistry {
    /// #1842: wired in ControlRegistry.standard().
    static func registerSessionsEdit(_ r: inout ControlRegistry) {
        let name = ControlArg(type: "string", required: true, summary: "the session's dch name or shown title")
        r.register(.change(name: "sessions.rename", summary: "Rename a session (its shown title; undo puts the old title back).", args: [
            "name": name, "to": ControlArg(type: "string", required: true, summary: "the new title"),
        ]) { _, a in try ControlSessionsEdit.renameSession(a) })
        r.register(.change(name: "sessions.model", summary: "Switch a Claude session's model (only while idle or done; undo switches back).", args: [
            "name": name, "model": ControlArg(type: "string", required: true, allowed: AgentModelEffort.aliases),
        ]) { _, a in try ControlSessionsEdit.switchSession(a, model: true) })
        r.register(.change(name: "sessions.effort", summary: "Switch a Claude session's effort (only while idle or done; undo switches back).", args: [
            "name": name, "effort": ControlArg(type: "string", required: true, allowed: AgentModelEffort.levelOrder),
        ]) { _, a in try ControlSessionsEdit.switchSession(a, model: false) })
    }
}

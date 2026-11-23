import Foundation

/// #1841: saved layouts over the control channel: layouts.list/switch/new/rename/delete. Every command goes through the
/// window model's own ops (switchLayout, previousLayout, newLayout, renameLayout, deleteLayout), so the 9-layout cap, the
/// split gate and the store's refusals are the window's. Pane changes only: no session is started, stopped or attached.
/// The lock (#1817/#1826/#1832) only gates picks into the focused pane and structural pane edits, none of which these
/// commands do. Deleting is final (no undo: the model cannot restore a layout's panes; operator 2026-11-21 over QA n148);
/// the undo of `layouts.new` removes only the layout it made. None of them closes an open New session form (adopt never clears it, unlike select(manual:)). On demand only: no observer, no poll.
@MainActor
enum ControlLayouts {
    static let off = "split panes are off in this build"

    /// The window's model; the window is never opened by a read.
    static func openModel() throws -> AgentWindowModel {
        guard AgentPaneLayout.splitsEnabled else { throw ControlError(off) }
        guard let m = ControlSessions.model() else { throw ControlError("Agent Sessions is not open") }
        return m
    }

    /// The rows the Layouts section draws; a lone one-pane layout (no section) as one row.
    static func rows(_ m: AgentWindowModel) -> [AgentWindowModel.LayoutRow] {
        m.layoutRows ?? [.init(id: m.layout.id, number: 1, name: OutsideText.shown(m.layout.name ?? "Layout 1"), active: true)]
    }

    static func message(_ r: PaneRefusal) -> String {
        if let n = r.notice { return n }
        switch r {
        case .lastLayout: return "the only layout cannot be deleted"
        case .noSuchLayout: return "no such layout (layouts.list lists them)"
        case .layoutsOff: return off
        default: return "refused: \(r)"
        }
    }

    /// A layout by id (its UUID), else by its shown name (exact, else case folded). Two matches: ambiguous.
    static func find(id: String?, name: String?, in m: AgentWindowModel) throws -> AgentWindowModel.LayoutRow {
        let all = rows(m)
        if let id {
            guard let u = UUID(uuidString: id), let r = all.first(where: { $0.id == u }) else {
                throw ControlError("no layout with id \(OutsideText.shown(id, max: 64)) (layouts.list lists them)")
            }
            return r
        }
        let want = name ?? ""
        var hits = all.filter { $0.name == want }
        if hits.isEmpty { hits = all.filter { $0.name.lowercased() == want.lowercased() } }
        guard hits.count < 2 else { throw ControlError("\(hits.count) layouts are named \(want): use the id") }
        guard let r = hits.first else { throw ControlError("no layout named \(want) (layouts.list lists them)") }
        return r
    }

    // MARK: - layouts.list

    /// {"layouts": [{id, number, name, active, panes, blocked, working}]} in the stored order (the ⌃N numbers).
    static func list() throws -> ControlJSON {
        let m = try openModel()
        return .object(["layouts": .array(rows(m).map { r -> ControlJSON in
            let l = r.active ? m.layout : m.layouts?.layouts.first { $0.id == r.id }
            return .object(["id": .string(r.id.uuidString), "number": .number(Double(r.number)), "name": .string(r.name),
                            "active": .bool(r.active), "panes": .number(Double(l?.panes.count ?? 1)),
                            "blocked": .number(Double(r.blocked)), "working": .bool(r.working)])
        })])
    }

    // MARK: - layouts.switch

    /// Exactly one of `id`, `name`, `previous` (⌃Tab's layout). Undo switches back to the layout shown before.
    static func switchTo(_ args: [String: ControlJSON]) throws -> ControlChange {
        let m = try openModel()
        let id = ControlSessions.string(args, "id"), name = ControlSessions.string(args, "name")
        let prev = args["previous"] == .bool(true)
        guard [id != nil, name != nil, prev].filter({ $0 }).count == 1 else {
            throw ControlError("give exactly one of id, name or previous")
        }
        let before = (m.parked ?? m.layout).id
        let target: AgentWindowModel.LayoutRow
        if prev {
            guard let p = m.layouts?.previous, let r = rows(m).first(where: { $0.id == p }) else { throw ControlError(message(.noSuchLayout)) }
            target = r
        } else {
            target = try find(id: id, name: name, in: m)
        }
        guard m.parked != nil || target.id != m.layout.id else { throw ControlError("\(target.name) is already the active layout") }
        if let r = m.switchLayout(target.id) { throw ControlError(message(r)) }
        return ControlChange(summary: "switch to \(target.name)", result: .string(target.id.uuidString), verb: "switched layout",
                             undo: { [weak m] in _ = m?.switchLayout(before) })
    }

    // MARK: - layouts.new

    /// The Layouts "+": one empty pane, appended, active. `name` set after. Undo deletes it (the layout
    /// before comes back, the MRU's next).
    static func new(_ args: [String: ControlJSON]) throws -> ControlChange {
        let m = try openModel()
        if case .string(_)? = args["name"], ControlSessions.string(args, "name") == nil { throw ControlError("argument 'name' is empty") }
        if let r = m.newLayout() { throw ControlError(message(r)) }
        let made = m.layout.id
        if let n = ControlSessions.string(args, "name") { m.renameLayout(made, to: n) }
        let shown = rows(m).first { $0.id == made }?.name ?? "new layout"
        return ControlChange(summary: "new layout \(shown)", result: .string(made.uuidString), verb: "made a layout",
                             undo: { [weak m] in _ = m?.deleteLayout(made) })
    }

    // MARK: - layouts.rename

    /// A name cleaned and bounded by the store; empty returns to the automatic name. Undo puts the old name back.
    static func rename(_ args: [String: ControlJSON]) throws -> ControlChange {
        let m = try openModel()
        guard case .string(let raw)? = args["name"] else { throw ControlError("missing argument 'name' for layouts.rename") }
        let r = try find(id: try ControlSessions.required(args, "id"), name: nil, in: m)
        let old = r.active ? m.layout.name : m.layouts?.layouts.first { $0.id == r.id }?.name
        if let why = m.renameLayout(r.id, to: raw) { throw ControlError(message(why)) }
        let now = rows(m).first { $0.id == r.id }?.name ?? raw
        return ControlChange(summary: "\(r.name) to \(now)", result: .string(r.id.uuidString), verb: "renamed a layout",
                             undo: { [weak m] in _ = m?.renameLayout(r.id, to: old) })
    }

    // MARK: - layouts.delete

    /// The store's delete: refused on the last layout; a deleted active layout hands over to the MRU's next.
    /// No undo: the model has no public way to put a deleted layout (its panes) back.
    static func delete(_ args: [String: ControlJSON]) throws -> ControlChange {
        let m = try openModel()
        let r = try find(id: try ControlSessions.required(args, "id"), name: nil, in: m)
        if let why = m.deleteLayout(r.id) { throw ControlError(message(why)) }
        return ControlChange(summary: "\(r.name) (final: it cannot be undone)", result: .string(r.id.uuidString), verb: "deleted a layout")
    }
}

extension ControlRegistry {
    /// #1841: wired in ControlRegistry.standard().
    static func registerLayouts(_ r: inout ControlRegistry) {
        let id = ControlArg(type: "string", required: true, summary: "the layout's id (layouts.list)")
        r.register(ControlCommand(name: "layouts.list", summary: "List saved layouts: id, number, name, active, panes, blocked, working.",
                                  args: [:], mutates: false) { _, _ in try ControlLayouts.list() })
        r.register(.change(name: "layouts.switch", summary: "Switch Agent Sessions to a saved layout, by id, name or the previous one.", args: [
            "id": ControlArg(type: "string", summary: "the layout's id"),
            "name": ControlArg(type: "string", summary: "the layout's shown name"),
            "previous": ControlArg(type: "boolean", summary: "true: the layout shown before this one"),
        ]) { _, a in try ControlLayouts.switchTo(a) })
        r.register(.change(name: "layouts.new", summary: "Make a new empty layout (9 at most) and switch to it.", args: [
            "name": ControlArg(type: "string", summary: "its name; automatic when absent"),
        ]) { _, a in try ControlLayouts.new(a) })
        r.register(.change(name: "layouts.rename", summary: "Rename a saved layout (empty name: automatic).", args: [
            "id": id, "name": ControlArg(type: "string", required: true, summary: "the new name"),
        ]) { _, a in try ControlLayouts.rename(a) })
        r.register(.change(name: "layouts.delete", summary: "Delete a saved layout (not the last one). Final: it cannot be undone.",
                           args: ["id": id]) { _, a in try ControlLayouts.delete(a) })
    }
}

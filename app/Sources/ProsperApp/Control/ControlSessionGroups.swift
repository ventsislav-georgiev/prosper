import Foundation

/// #1856: session groups and History pins over the control channel: sessions.groups.list/set, island.showGroup,
/// history.pin/unpin. Groups are stored the way the Settings editor stores them (SessionGroupsEditor's rules, then
/// Preferences.editSessionGroups and the controller's rowDetailsChanged, which regroups the island and syncs dch's
/// config); a group tab is the island's own showGroup; a pin is the History row's own pin toggle (the controller's
/// `pin`, on the History menu's gate). Forget and Clear unpinned stay human-only: nothing here registers them.
/// On demand only: no observer, no poll.
@MainActor
enum ControlSessionGroups {
    /// Seam: stores a list (Settings' save path). Tests replace it.
    static var store: @MainActor ([SessionGroup]) -> Void = {
        Preferences.editSessionGroups($0)
        AgentIslandController.shared.rowDetailsChanged()
    }
    /// Seams: a group tab click (nil: Sessions) and the History tab click.
    static var showGroup: @MainActor (String?) -> Void = { AgentIslandController.shared.showGroup($0) }
    static var showHistory: @MainActor () -> Void = { AgentIslandController.shared.showHistory() }
    /// Seam: a History row's pin toggle (the island that owns the window's store, as resumeRecord does).
    static var pinRecord: @MainActor (DchHistoryRecord) -> Void = {
        (ControlSessions.model()?.island() ?? AgentIslandController.shared).pin($0)
    }

    static let sessionsTab = "sessions"
    /// The clock for a record's idle days (sessions.history's own "now"). Tests replace it.
    static var now: @MainActor () -> TimeInterval = { ControlSessions.model()?.now() ?? Date().timeIntervalSince1970 }
    /// #1856 n167: dch v1.143.0 rec_prune (master.c:843-877, run on every non-resumed start) deletes an unpinned record idle over 30 days.
    static let dchPruneDays = 30
    /// An agent may not unpin a record within a day of that prune: the next start could delete it and the undo with it.
    static let unpinRefusedFromDays = dchPruneDays - 1

    // MARK: - sessions.groups.list

    /// {"tabs": Bool, "groups": [{id, name, pattern, color, colorPicked}]} in the stored order. #2061 r2: `color` is the
    /// "#RRGGBB" the island shows (Preferences.sessionGroupColors), `colorPicked` false when it is Automatic. `tabs` false: the list is kept but the island
    /// shows no group tabs (Settings' toggle). Names and patterns are outside text (a phone or dch's file may have set them).
    static func list() -> ControlJSON {
        let colors = Preferences.sessionGroupColors()
        return .object(["tabs": .bool(Preferences.agentIslandSidekickTabs),
                 "groups": .array(Preferences.agentIslandSessionGroups.filter { !$0.isOff }.map {   // #2069
                     .object(["id": .string(OutsideText.shown($0.id, max: 64)),
                              "name": .string(OutsideText.shown($0.name, max: ControlSessionsTalk.maxLine)),
                              "pattern": .string(OutsideText.shown($0.pattern, max: ControlSessionsTalk.maxLine)),
                              "color": colors[$0.id].map(ControlJSON.string) ?? .null,
                              "colorPicked": .bool($0.color != nil)])
                 })])
    }

    // MARK: - sessions.groups.set

    /// The whole list, replaced: [{name, pattern, id?, color?}]. A row is stored only as the Settings editor would store it (a
    /// valid 1-32 byte name, not dch's own tab name, a valid regex that does not match everything or a blank pattern (a
    /// manual-only group, #2062), at most 8 rows, no duplicate name): else the whole call is refused with the row's reason and nothing is stored. Agent text
    /// is outside text: a control or hidden scalar anywhere is refused. A row without an id keeps the id of the stored group
    /// of the same name (its tab stays chosen; a blank Sidekicks, isOff, is not matched: #2069), else gets a new one. [] clears the list. Undo stores the old list back.
    /// #2061 r2: `color` "#rrggbb" is the group's pick, "" sets it back to Automatic, absent or null keeps the stored
    /// group's pick for a kept id (Automatic for a new one); anything else refuses the call.
    /// shortcut: an old list that was never stored (the migrated Sidekicks default) is stored by the undo, run it once.
    static func set(_ args: [String: ControlJSON]) throws -> ControlChange {
        guard case .array(let items)? = args["groups"] else { throw ControlError("argument 'groups' must be a list") }
        guard items.count <= SessionGroup.maxCount else { throw ControlError("at most \(SessionGroup.maxCount) groups") }
        let old = Preferences.agentIslandSessionGroups
        var rows: [SessionGroup] = []
        for (i, item) in items.enumerated() {
            guard case .object(let o) = item, case .string(let name)? = o["name"], case .string(let pattern)? = o["pattern"] else {
                throw ControlError("group \(i + 1) needs a string name and a string pattern")
            }
            var id = ""
            if let raw = o["id"] {
                guard case .string(let s) = raw, !s.isEmpty, s.utf8.count <= 64 else { throw ControlError("group \(i + 1): id must be 1-64 bytes") }
                id = s
            }
            for text in [name, pattern, id] where ControlSessionsTalk.hasUnseen(text) {
                throw ControlError("group \(i + 1) has a control or hidden character")
            }
            if id.isEmpty {
                id = old.first { !$0.isOff && SessionGroup.nameKey($0.name) == SessionGroup.nameKey(name) }?.id
                    ?? String(UUID().uuidString.prefix(8)).lowercased()
            }
            var color = old.first { $0.id == id }?.color
            switch o["color"] {
            case nil, .null?: break
            case .string("")?: color = nil
            case .string(let c)?:
                guard let v = SessionGroup.validColor(c) else { throw ControlError("group \(i + 1): color must be \"#rrggbb\" or \"\" for Automatic") }
                color = v
            default: throw ControlError("group \(i + 1): color must be \"#rrggbb\" or \"\" for Automatic")
            }
            rows.append(SessionGroup(id: id, name: name, pattern: pattern, color: color))
        }
        let editor = SessionGroupsEditor(rows)
        for (i, g) in rows.enumerated() {
            if let why = editor.reason(g, stored: []) { throw ControlError("group \(i + 1): \(why)") }
        }
        let list = SessionGroup.normalized(rows)
        guard list.count == rows.count else { throw ControlError("two groups have the same id") }
        guard list != old else { throw ControlError("these are already the groups") }
        store(list)
        return ControlChange(summary: list.isEmpty ? "no session groups" : "groups " + list.map(\.name).joined(separator: ", "),
                             result: .number(Double(list.count)), verb: "set session groups", undo: {
            // n168: only while the groups are still what this call stored (Settings or a phone may have changed them).
            guard Preferences.agentIslandSessionGroups == list else { return }
            store(old)
        })
    }

    // MARK: - island.showGroup

    /// A group tab by id or name (case folded), or "sessions": the island's list tabs, as a click picks it. Only a group
    /// with a session has a tab. Undo shows the tab shown before (History included).
    static func show(_ args: [String: ControlJSON]) throws -> ControlChange {
        let st = try ControlSessions.store(), want = try ControlSessions.required(args, "group")
        let shown = st.split.shownGroups.map(\.group)
        guard !shown.isEmpty else { throw ControlError("the island has no group tabs (sessions.groups.list; the tabs may be off in Settings)") }
        let target: String?
        if want.lowercased() == sessionsTab { target = nil }
        else if let g = shown.first(where: { $0.id == want }) ?? shown.first(where: { SessionGroup.nameKey($0.name) == SessionGroup.nameKey(want) }) {
            target = g.id
        } else {
            throw ControlError("no group tab \(OutsideText.shown(want, max: 64)): a group has a tab only while it has a session")
        }
        // n169: the controller's showGroup drops History's pending question; the person answers it first.
        guard !st.confirmingClear else { throw ControlError("History is asking \"Clear unpinned?\": answer it first") }
        let (wasHistory, was) = (st.historyTab, st.groupTab)
        guard wasHistory || was != target else { throw ControlError("that tab is already shown") }
        showGroup(target)
        let name = target.flatMap { id in shown.first { $0.id == id }?.name } ?? "Sessions"
        return ControlChange(summary: name, result: .string(target ?? sessionsTab), verb: "showed a tab", undo: {
            if wasHistory { showHistory() } else { showGroup(was) }
        })
    }

    // MARK: - history.pin / history.unpin

    /// The History row's pin toggle for the id sessions.history lists, on the History menu's own gate (the dch version,
    /// a name dch could read as a flag). This Mac's records only. dch runs the edit off main; the row shows it once the
    /// history is re-read. Undo toggles back while the record is still in the state this call left it.
    static func pin(_ args: [String: ControlJSON], pinned: Bool) throws -> ControlChange {
        let st = try ControlSessions.store(), id = try ControlSessions.required(args, "id")
        let hits = ControlSessions.records(st).filter { ControlSessions.recordID($0) == id }
        guard hits.count < 2 else { throw ControlError("\(hits.count) History records are \(id): pin it from Agent Sessions") }
        guard let r = hits.first else { throw ControlError("no History record \(id) (sessions.history lists them)") }
        guard !AgentWindowModel.isRemote(r) else { throw ControlError("pins are for this Mac's records only") }
        guard r.pinned != pinned else { throw ControlError("\(r.title) is already \(pinned ? "pinned" : "unpinned")") }
        if let why = ControlSessions.historyRefusal(r, .pin, in: st) { throw ControlError(why) }
        // n167: idle as the History row shows it (lastSeen; none known reads as idle for ever).
        if !pinned, now() - r.lastSeen >= Double(unpinRefusedFromDays) * 86400 {
            throw ControlError("\(r.title) has been idle \(unpinRefusedFromDays) days or more: dch may delete it once unpinned, so unpin it yourself in History")
        }
        pinRecord(r)
        return ControlChange(summary: r.title, result: .string(ControlSessions.recordID(r)), verb: pinned ? "pinned" : "unpinned", undo: {
            // Re-read at the click: the record may have moved or been edited meanwhile.
            guard let now = try? ControlSessions.store(),
                  let back = ControlSessions.records(now).first(where: { ControlSessions.recordID($0) == id }), back.pinned == pinned else { return }
            pinRecord(back)
        })
    }
}

extension ControlRegistry {
    /// #1856: wired in ControlRegistry.standard().
    static func registerSessionGroups(_ r: inout ControlRegistry) {
        r.register(ControlCommand(name: "sessions.groups.list", summary: "The session groups (id, name, pattern, color, colorPicked) and whether the island shows their tabs.",
                                  args: [:], mutates: false) { _, _ in ControlSessionGroups.list() })
        r.register(.change(name: "sessions.groups.set", summary: "Replace the session groups with [{name, pattern, id?, color?}] (8 at most; [] clears). Refused whole if a row is not one Settings would save.", args: [
            "groups": ControlArg(type: "array", required: true, summary: "[{name, pattern, id?, color?}]: name 1-32 bytes, pattern a regex that does not match everything; color \"#rrggbb\", \"\" for Automatic, absent keeps the group's colour"),
        ]) { _, a in try ControlSessionGroups.set(a) })
        r.register(.change(name: "island.showGroup", summary: "Show a group tab of the island (by id or name; \"sessions\" for the Sessions tab).", args: [
            "group": ControlArg(type: "string", required: true, summary: "the group's id or name, or sessions"),
        ]) { _, a in try ControlSessionGroups.show(a) })
        let id = ControlArg(type: "string", required: true, summary: "the History record's id (sessions.history)")
        r.register(.change(name: "history.pin", summary: "Pin a History record: dch's prune and Clear unpinned keep it.", args: ["id": id]) { _, a in
            try ControlSessionGroups.pin(a, pinned: true)
        })
        r.register(.change(name: "history.unpin", summary: "Unpin a History record.", args: ["id": id]) { _, a in
            try ControlSessionGroups.pin(a, pinned: false)
        })
    }
}

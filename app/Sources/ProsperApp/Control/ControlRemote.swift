import Foundation

/// #1863: other machines over the control channel: remote.list (the hosts and their sessions and History records as
/// the Agent Sessions sidebar lists them: "Other machines" and History's host rows) and remote.resume (a remote History
/// row's Resume, through sessions.resume: the History menu's gate, then the window's resumeRemote). Both read the
/// window model's last remote answer: nothing here calls dch or dials a host, and the window is never opened by a read
/// (the remote list is refreshed only while the window is shown). On demand only: no observer, no poll.
@MainActor
enum ControlRemote {
    static let notOpen = "Agent Sessions is not open: other machines are listed only while it is (sessions.focus opens it)"

    static func model() throws -> AgentWindowModel {
        guard let m = ControlSessions.model() else { throw ControlError(notOpen) }
        guard m.store != nil else { throw ControlError(ControlSessions.islandOff) }
        return m
    }

    // MARK: - remote.list

    /// {"listing", "hosts": [{host, canStart, sessions: [{name, title, cwd, stale}], history: [sessions.history rows]}]}:
    /// every host the sidebar names, sorted; `canStart` when sessions.new can start there (the form's host picker);
    /// `listing` false while the window is hidden (its remote list is not refreshed then). Hosts and names are raw (dch
    /// already passed AgentSidebar.remoteOK on them: they are argv); a title is outside text (the sidebar's).
    static func list() throws -> ControlJSON {
        let m = try model(), rows = m.rows
        let sessions = rows.compactMap { r in r.remote.map { (r, $0) } }
        var history: [String: [ControlJSON]] = [:]
        if case .object(let o) = try ControlSessions.history(), case .array(let all)? = o["history"] {
            for case .object(let h) in all { if case .string(let host)? = h["host"] { history[host, default: []].append(.object(h)) } }
        }
        let hosts = Set(sessions.map { $0.1.host }).union(history.keys).sorted()
        let canStart = Set(m.newSessionHosts)
        return .object(["listing": .bool(m.visible), "hosts": .array(hosts.map { h -> ControlJSON in
            .object([
                "host": .string(h), "canStart": .bool(canStart.contains(h)),
                "sessions": .array(sessions.filter { $0.1.host == h }.map { p -> ControlJSON in
                    let (row, x) = p
                    return .object(["name": .string(x.name), "title": .string(row.title),
                             "cwd": x.cwd.flatMap { $0.isEmpty ? nil : ControlJSON.string(OutsideText.shown($0)) } ?? .null,
                             "stale": .bool(x.stale)])
                }),
                "history": .array(history[h] ?? []),
            ])
        })])
    }

    // MARK: - remote.resume

    /// A remote History row's Resume, by host and the record's name (or its file id): sessions.resume with the
    /// record's id, so the History menu's gate, the busy check and resumeRemote are that command's. No undo.
    static func resume(_ args: [String: ControlJSON]) throws -> ControlChange {
        _ = try model()
        let host = try ControlSessions.required(args, "host"), name = try ControlSessions.required(args, "name")
        let st = try ControlSessions.store()
        let onHost = ControlSessions.records(st).filter { AgentWindowModel.isRemote($0) && $0.key.dir.dropFirst() == host }
        guard !onHost.isEmpty else { throw ControlError("no History records from \(host) (remote.list lists them)") }
        var hits = onHost.filter { $0.name == name }
        if hits.isEmpty { hits = onHost.filter { $0.id.name == name } }
        guard hits.count < 2 else { throw ControlError("\(hits.count) History records on \(host) are named \(name): use sessions.resume with its id") }
        guard let r = hits.first else { throw ControlError("no History record \(name) from \(host) (remote.list lists them)") }
        return try ControlSessions.resume(["id": .string(ControlSessions.recordID(r))])
    }
}

extension ControlRegistry {
    /// #1863: wired in ControlRegistry.standard().
    static func registerRemote(_ r: inout ControlRegistry) {
        r.register(ControlCommand(name: "remote.list",
                                  summary: "List other machines as Agent Sessions does: each host, its sessions and its History records, and whether sessions.new can start there.",
                                  args: [:], mutates: false) { _, _ in try ControlRemote.list() })
        r.register(.change(name: "remote.resume", summary: "Resume another machine's History record on that machine, as its Resume does (no undo).", args: [
            "host": ControlArg(type: "string", required: true, summary: "the host, from remote.list"),
            "name": ControlArg(type: "string", required: true, summary: "the record's name on that host, from remote.list's history"),
        ]) { _, a in try ControlRemote.resume(a) })
    }
}

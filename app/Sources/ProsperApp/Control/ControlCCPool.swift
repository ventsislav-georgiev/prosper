import Foundation

extension ControlRegistry {
    /// #1843: ccpool.status, ccpool.usage and ccpool.pin, reads only and labels only (CCPoolControl builds
    /// the replies); wired in ControlRegistry.standard().
    static func registerCCPool(_ r: inout ControlRegistry) {
        r.register(ControlCommand(name: "ccpool.status",
                                  summary: "The ccpool proxy (running, stopped, busy, port held, failed; port), the current account for requests without a session, live sessions, and every account alphabetically: state, sessions, held, benched, 5h/7d utilization percent and reset epoch. Labels only.",
                                  args: [:], mutates: false) { _, _ in try CCPoolControl.status() })
        r.register(ControlCommand(name: "ccpool.usage",
                                  summary: "Tokens through ccpool per account label and per session (short id, the 50 biggest) since `since` (epoch seconds, default 24 h ago, at most 14 days).",
                                  args: ["since": ControlArg(type: "number", summary: "epoch seconds; default 24 h ago, at most 14 days ago")],
                                  mutates: false, run: { _, _ in throw ControlError("ccpool.usage reads files: send it through the control channel") },
                                  runAsync: { _, args in
            guard case .number(let s)? = args["since"] else { return try await CCPoolControl.usage(since: nil) }
            return try await CCPoolControl.usage(since: s)
        }))
        r.register(ControlCommand(name: "ccpool.pin",
                                  summary: "The account a session is pinned to (its main agent's, else its latest agent's) with that account's 5h/7d utilization, and each agent's pin; {\"pinned\": false} when none.",
                                  args: ["session": ControlArg(type: "string", required: true, summary: "the Claude session id (1-128 of A-Z a-z 0-9 - _)")],
                                  mutates: false) { _, args in
            guard case .string(let s)? = args["session"] else { throw ControlError(CCPoolControl.badSession) }
            return try CCPoolControl.pin(s)
        })
    }
}

extension ControlRegistry {
    /// #1862: ccpool.hold and ccpool.release through the pane's own hold and release (CCPoolControl); wired in
    /// ControlRegistry.standard().
    static func registerCCPoolHold(_ r: inout ControlRegistry) {
        let label = ControlArg(type: "string", required: true, summary: "the account's label (ccpool.status)")
        r.register(.change(name: "ccpool.hold", summary: "Hold a ccpool account out of rotation for some hours, as the pane's Hold does. Undo releases it as it was.",
                           args: ["label": label,
                                  "hours": ControlArg(type: "number", required: true, summary: "above 0, at most 192")]) { _, a in
            guard case .string(let l)? = a["label"] else { throw ControlError("argument 'label' is empty") }
            guard case .number(let h)? = a["hours"] else { throw ControlError(CCPoolControl.badHours) }
            return try CCPoolControl.hold(label: l, hours: h)
        })
        r.register(.change(name: "ccpool.release", summary: "Release a ccpool account: every limit and hold on it, as the pane's Release does. Undo puts them back.",
                           args: ["label": label]) { _, a in
            guard case .string(let l)? = a["label"] else { throw ControlError("argument 'label' is empty") }
            return try CCPoolControl.release(label: l)
        })
    }
}

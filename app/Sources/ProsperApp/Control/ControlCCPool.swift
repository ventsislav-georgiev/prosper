import Foundation

extension ControlRegistry {
    /// #1843: ccpool.status, ccpool.usage and ccpool.pin, reads only and labels only (CCPool/CCPoolControl.swift builds
    /// the replies). The supervisor adds `ControlRegistry.registerCCPool(&r)` to `standard()` on landing.
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

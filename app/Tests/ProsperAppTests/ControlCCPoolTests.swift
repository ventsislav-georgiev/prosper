import XCTest
@testable import ProsperApp

/// #1843: ccpool.status / ccpool.usage / ccpool.pin over a pane rig (temp store, memory secrets, fake labels, the
/// service never started). Labels only: no reply carries a token or a Keychain id.
@MainActor
final class ControlCCPoolTests: XCTestCase {
    private let t0 = 1_800_000_000.0   // Fri 2027-01-15 08:00 UTC

    private func rig() throws -> CCPoolPaneRig {
        let r = try ccpoolPaneRig(t0: t0)
        addTeardownBlock { @MainActor in CCPoolControl.model = { CCPoolRuntime.shared?.model } }
        CCPoolControl.model = { r.model }
        return r
    }

    private func registry() -> ControlRegistry {
        var r = ControlRegistry()
        ControlRegistry.registerCCPool(&r)
        return r
    }

    private func call(_ cmd: String, _ args: [String: ControlJSON] = [:]) async -> ControlReply {
        await registry().reply(to: try! JSONEncoder().encode(ControlRequest(cmd: cmd, args: args)))
    }

    private func obj(_ r: ControlReply) -> [String: ControlJSON] {
        guard case .object(let o)? = r.result else { return [:] }
        return o
    }

    private func list(_ v: ControlJSON?) -> [[String: ControlJSON]] {
        guard case .array(let a)? = v else { return [] }
        return a.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }

    private func id(_ r: CCPoolPaneRig, _ label: String) -> String { r.store.snapshot.accounts[label]?.id ?? "missing-\(label)" }

    private func claim(_ o: [String: ControlJSON], _ name: String) -> [String: ControlJSON] {
        guard case .object(let c)? = o[name] else { return [:] }
        return c
    }

    func testCCPoolCommandsAreReadsWithTheirArgs() {
        let reg = registry()
        XCTAssertEqual(reg.commands.keys.sorted(), ["ccpool.pin", "ccpool.status", "ccpool.usage", "pool.pin", "pool.status", "pool.usage"])  // #2012
        XCTAssertTrue(reg.commands.values.allSatisfy { !$0.mutates })
        XCTAssertEqual(reg.commands["ccpool.pin"]?.args["session"], ControlArg(type: "string", required: true,
                                                                               summary: "the Claude session id (1-128 of A-Z a-z 0-9 - _)"))
        XCTAssertEqual(reg.commands["ccpool.usage"]?.args["since"]?.type, "number")
        XCTAssertEqual(reg.commands["ccpool.usage"]?.args["since"]?.required, false)
        XCTAssertTrue(reg.commands["ccpool.usage"]?.runAsync != nil)
    }

    /// #2012: pool.* is the name, ccpool.* its alias for one release: the same reply, an alias summary, both in describe.
    func testPoolCommandsAndTheirCcpoolAliasesAnswerTheSame() async throws {
        _ = try pool()
        let new = await call("pool.status"), old = await call("ccpool.status")
        XCTAssertTrue(new.ok, new.error ?? "")
        XCTAssertEqual(new.result, old.result, "the alias answers as pool.status")
        XCTAssertTrue(list(obj(new)["accounts"]).allSatisfy { $0["harness"] != nil }, "each row names its harness (#2042)")
        let reg = registry()
        for verb in ["status", "usage", "pin"] {
            XCTAssertEqual(reg.commands["ccpool.\(verb)"]?.summary, "Alias of pool.\(verb); removed after the next release.")
            XCTAssertEqual(reg.commands["ccpool.\(verb)"]?.args, reg.commands["pool.\(verb)"]?.args)
        }
        guard case .object(let d) = ControlRegistry.standard().describe, case .array(let rows)? = d["commands"] else { return XCTFail("describe lists commands") }
        let names = rows.compactMap { row -> String? in
            if case .object(let o) = row, case .string(let n)? = o["name"] { return n } else { return nil }
        }
        for name in ["pool.status", "ccpool.status", "pool.hold", "ccpool.hold", "pool.release", "ccpool.release"] {
            XCTAssertTrue(names.contains(name), name)
        }
    }

    func testCCPoolOffIsAPlainError() async {
        CCPoolControl.model = { nil }
        addTeardownBlock { @MainActor in CCPoolControl.model = { CCPoolRuntime.shared?.model } }
        let calls: [(String, [String: ControlJSON])] = [("ccpool.status", [:]), ("ccpool.usage", [:]), ("ccpool.pin", ["session": .string("api")])]
        for (cmd, args) in calls {
            let r = await call(cmd, args)
            XCTAssertFalse(r.ok, cmd)
            XCTAssertEqual(r.error, "the Agent Account Pool is off", cmd)
        }
    }

    /// The pool the status and pin rows read: five labels, a hold, a bench, a sample, a reset, three sessions.
    private func pool() throws -> CCPoolPaneRig {
        let r = try rig()
        try r.add(["delta", "alpha", "Charlie", "bravo", "echo"])
        let now = t0
        r.store.mutate { st in
            _ = st.hold("bravo", hours: 2, now: now)
            st.accounts["delta"]?.cooldown["five_hour"] = Int(now) + 3600
            st.accounts["alpha"]?.reset["five_hour"] = Int(now) + 7200
            st.accounts["alpha"]?.reset["seven_day"] = Int(now) - 10   // past: not reported
            st.current = "echo"
            st.pin("s1/", to: "alpha", now: now - 60)
            st.pin("s1/agent-a", to: "bravo", now: now - 30)
            st.pin("s2/", to: "alpha", now: now - 20)
            st.pin("s3/agent-x", to: "Charlie", now: now - 50)
            st.pin("s3/agent-y", to: "delta", now: now - 10)
            st.pin("old/", to: "echo", now: now - 4000)   // idle past pinIdle: not live
            st.accounts["delta"]?.harness = CCPoolCodexHarness.id   // #2042: the others are claude (absent)
        }
        r.store.recordUsage(id: id(r, "alpha"), limits: ["five_hour": CCPoolLimit(status: "allowed", utilization: "0.42", reset: nil)])
        return r
    }

    func testCCPoolStatusKeysOrderAndStates() async throws {
        let r = try pool()
        let reply = await call("ccpool.status")
        XCTAssertTrue(reply.ok, reply.error ?? "")
        let o = obj(reply)
        XCTAssertEqual(o.keys.sorted(), ["accounts", "current", "detail", "port", "proxy", "sessions"])
        XCTAssertEqual(o["proxy"], .string("stopped"))
        XCTAssertEqual(o["detail"], .string("Stopped"))
        XCTAssertEqual(o["port"], .number(Double(r.service.config.port)))
        XCTAssertEqual(o["current"], .string("echo"))
        XCTAssertEqual(o["sessions"], .number(3), "s1, s2, s3; the idle pin is not live")
        let rows = list(o["accounts"])
        XCTAssertEqual(rows.map { $0["label"] }, ["alpha", "bravo", "Charlie", "delta", "echo"].map { .string($0) })
        XCTAssertEqual(rows.first?.keys.sorted(), ["benched", "five_hour", "harness", "held", "label", "sessions", "seven_day", "state"])
        let by = Dictionary(rows.map { row -> (String, [String: ControlJSON]) in
            guard case .string(let l)? = row["label"] else { return ("", row) }
            return (l, row)
        }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(by["alpha"]?["sessions"], .number(2))
        XCTAssertEqual(by["alpha"]?["state"], .string("ready"))
        XCTAssertEqual(by["alpha"]?["harness"], .string("claude"))
        XCTAssertEqual(by["delta"]?["harness"], .string("codex"))
        XCTAssertEqual(by["echo"]?["state"], .string("active"))
        XCTAssertEqual(by["echo"]?["sessions"], .number(0))
        XCTAssertEqual(by["bravo"]?["held"], .bool(true))
        XCTAssertEqual(by["bravo"]?["benched"], .bool(false))
        XCTAssertEqual(by["bravo"]?["state"], .string("held until Fri 10:00"))
        XCTAssertEqual(by["delta"]?["benched"], .bool(true))
        XCTAssertEqual(by["delta"]?["held"], .bool(false))
        let alpha = by["alpha"] ?? [:]
        XCTAssertEqual(claim(alpha, "five_hour"), ["percent": .number(42), "resets": .number(t0 + 7200)])
        XCTAssertEqual(claim(alpha, "seven_day"), ["percent": .null, "resets": .null], "a past reset is not reported")
    }

    func testCCPoolPinMainAgentThenLatestAndNotPinned() async throws {
        _ = try pool()
        let s1 = obj(await call("ccpool.pin", ["session": .string("s1")]))
        XCTAssertEqual(s1.keys.sorted(), ["agents", "five_hour", "harness", "label", "pinned", "seven_day"])
        XCTAssertEqual(s1["pinned"], .bool(true))
        XCTAssertEqual(s1["label"], .string("alpha"), "the main agent's pin wins over a later agent's")
        XCTAssertEqual(claim(s1, "five_hour"), ["percent": .number(42), "resets": .number(t0 + 7200)])
        XCTAssertEqual(s1["agents"], .array([.object(["agent": .string(""), "label": .string("alpha"), "harness": .string("claude")]),
                                             .object(["agent": .string("agent-a"), "label": .string("bravo"), "harness": .string("claude")])]))
        XCTAssertEqual(s1["harness"], .string("claude"))
        let s3 = obj(await call("ccpool.pin", ["session": .string("s3")]))
        XCTAssertEqual(s3["label"], .string("delta"), "no main pin: the most recently seen agent's")
        XCTAssertEqual(s3["harness"], .string("codex"))
        XCTAssertEqual(claim(s3, "five_hour"), ["percent": .null, "resets": .null])
        for none in ["nobody", "old", "s"] {
            let r = await call("ccpool.pin", ["session": .string(none)])
            XCTAssertTrue(r.ok, none)
            XCTAssertEqual(r.result, .object(["pinned": .bool(false)]), none)
        }
    }

    func testCCPoolPinRefusesABadSession() async throws {
        _ = try pool()
        for bad in ["", "s1/", "s1/agent-a", "a b", "s\u{00E9}", "s1\n", String(repeating: "a", count: 129), "../s1"] {
            let r = await call("ccpool.pin", ["session": .string(bad)])
            XCTAssertFalse(r.ok, bad)
            XCTAssertEqual(r.error, CCPoolControl.badSession, bad)
        }
        let longest = await call("ccpool.pin", ["session": .string(String(repeating: "a", count: 128))])
        XCTAssertTrue(longest.ok)
        let dashed = await call("ccpool.pin", ["session": .string("api-qa_2")])
        XCTAssertTrue(dashed.ok)
        let number = await call("ccpool.pin", ["session": .number(1)])
        XCTAssertFalse(number.ok, "the type is checked first")
        let missing = await call("ccpool.pin")
        XCTAssertFalse(missing.ok, "session is required")
    }

    // MARK: usage

    private func line(_ t: Double, _ acct: String, sess: String? = nil, tok: [Int], qc: Bool = false, harness: String? = nil) -> String {
        var o: [String: Any] = ["v": 1, "t": t, "acct": acct, "model": "claude-opus-5", "path": "messages", "st": 200, "ms": 1000,
                                "done": true, "qc": qc, "att": 1, "thr": 0, "mv": false, "routed": "pin"]
        if let harness { o["harness"] = harness }
        if let sess { o["sess"] = sess; o["agent"] = "" }
        for (k, v) in zip(["in", "out", "cr", "cw5", "cw1"], tok) { o[k] = v }
        let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    private func write(_ r: CCPoolPaneRig, _ files: [String: [String]]) throws {
        let dir = r.store.usageDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, lines) in files { try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent(name)) }
    }

    private func totals(_ o: [String: ControlJSON]) -> [Double] {
        ["requests", "input", "output", "cache_read", "cache_write_5m", "cache_write_1h", "total"].map {
            if case .number(let n)? = o[$0] { return n } else { return -1 }
        }
    }

    func testCCPoolUsagePerLabelAndSessionSinceAFilter() async throws {
        let r = try rig()
        try r.add(["delta", "alpha", "Charlie", "bravo"])
        try write(r, [
            "usage-2027-01-14.jsonl": [line(t0 - 20 * 3600, id(r, "delta"), tok: [7, 0, 0, 0, 0])],
            "usage-2027-01-15.jsonl": [
                line(t0 - 5 * 3600, id(r, "alpha"), sess: "0123456789abcdef", tok: [1000, 0, 0, 0, 0]),   // before since
                line(t0 - 3600, id(r, "alpha"), sess: "0123456789abcdef", tok: [100, 50, 0, 900, 0]),
                line(t0 - 1800, id(r, "bravo"), sess: "fedcba9876543210", tok: [10, 20, 0, 0, 0]),
                line(t0 - 1750, id(r, "Charlie"), sess: "fedcba9876543210", tok: [3, 0, 0, 0, 0], harness: "codex"),
                line(t0 - 1700, "id-removed", tok: [1, 1, 1, 1, 1]),
                line(t0 - 1600, id(r, "alpha"), tok: [0, 1, 0, 0, 0], qc: true),   // a quota check: no tokens counted
            ],
        ])
        let reply = await call("ccpool.usage", ["since": .number(t0 - 2 * 3600)])
        XCTAssertTrue(reply.ok, reply.error ?? "")
        let o = obj(reply)
        XCTAssertEqual(o.keys.sorted(), ["accounts", "more_sessions", "rows", "sessions", "since", "skipped", "truncated", "until"])
        XCTAssertEqual(o["since"], .number(t0 - 2 * 3600))
        XCTAssertEqual(o["until"], .number(t0))
        XCTAssertEqual(o["rows"], .number(5))
        XCTAssertEqual(o["more_sessions"], .bool(false))
        let accts = list(o["accounts"])
        XCTAssertEqual(accts.map { $0["label"] }, ["alpha", "bravo", "Charlie", "removed account"].map { .string($0) })
        XCTAssertEqual(accts.first?.keys.sorted(), ["cache_read", "cache_write_1h", "cache_write_5m", "harness", "input", "label", "output", "requests", "total"])
        XCTAssertEqual(accts.first.map(totals), [1, 100, 50, 0, 900, 0, 1050], "the row before since is not counted")
        XCTAssertEqual(accts.last.map(totals), [1, 1, 1, 1, 1, 1, 5])
        // #2042: a row without the key (every old file) is claude; a written one is the account's.
        XCTAssertEqual(accts.map { $0["harness"] }, ["claude", "claude", "codex", "claude"].map { .string($0) })
        let sessions = list(o["sessions"])
        XCTAssertEqual(sessions.map { $0["session"] }, [.string("01234567\u{2026}"), .string("fedcba98\u{2026}")])
        XCTAssertEqual(sessions.last?["accounts"], .array([.string("bravo"), .string("Charlie")]))
        XCTAssertEqual(sessions.last.map(totals), [2, 13, 20, 0, 0, 0, 33])

        // Default: the last 24 h (the row 5 h ago counts, yesterday's file row too; nothing older than a day).
        let day = obj(await call("ccpool.usage"))
        XCTAssertEqual(day["since"], .number(t0 - 86_400))
        XCTAssertEqual(list(day["accounts"]).first.map(totals), [2, 1100, 50, 0, 900, 0, 2050])
        XCTAssertEqual(list(day["accounts"]).map { $0["label"] }, ["alpha", "bravo", "Charlie", "delta", "removed account"].map { .string($0) })
    }

    func testCCPoolUsageRefusesASinceOutOfRange() async throws {
        _ = try rig()
        for bad in [t0 - 15 * 86_400, t0 + 10, -1] {
            let r = await call("ccpool.usage", ["since": .number(bad)])
            XCTAssertEqual(r.error, CCPoolControl.badSince, "\(bad)")
        }
        let fortnight = await call("ccpool.usage", ["since": .number(t0 - 14 * 86_400)])
        XCTAssertTrue(fortnight.ok, fortnight.error ?? "")
        let word = await call("ccpool.usage", ["since": .string("yesterday")])
        XCTAssertFalse(word.ok)
    }

    func testCCPoolUsageCapsSessionsAtFifty() async throws {
        let r = try rig()
        try r.add(["alpha"])
        let a = id(r, "alpha")
        try write(r, ["usage-2027-01-15.jsonl": (0..<52).map { line(t0 - 100 - Double($0), a, sess: String(format: "%04d-session", $0), tok: [$0 + 1, 0, 0, 0, 0]) }])
        let o = obj(await call("ccpool.usage"))
        XCTAssertEqual(list(o["sessions"]).count, 50)
        XCTAssertEqual(o["more_sessions"], .bool(true))
        XCTAssertEqual(list(o["sessions"]).first?["session"], .string("0051-ses\u{2026}"), "biggest first")
    }

    // Labels only: no reply names a token or a Keychain id, whatever is asked.
    func testCCPoolRepliesCarryNoTokenOrKeychainID() async throws {
        let r = try pool()
        try write(r, ["usage-2027-01-15.jsonl": [line(t0 - 60, id(r, "alpha"), sess: "s1", tok: [1, 1, 1, 1, 1]),
                                                 line(t0 - 50, "id-removed", sess: "s2", tok: [1, 0, 0, 0, 0])]])
        var text = ""
        let calls: [(String, [String: ControlJSON])] = [("ccpool.status", [:]), ("ccpool.usage", [:]),
                                                        ("ccpool.pin", ["session": .string("s1")]), ("ccpool.pin", ["session": .string("s3")])]
        for (cmd, args) in calls {
            let reply = await call(cmd, args)
            XCTAssertTrue(reply.ok, "\(cmd): \(reply.error ?? "")")
            text += String(decoding: reply.line, as: UTF8.self)
        }
        XCTAssertTrue(text.contains("alpha"), "the scan read real replies")
        let ids = r.store.snapshot.accounts.values.map(\.id)
        XCTAssertEqual(ids.count, 5)
        for needle in ["tok-", "id-removed"] + ids { XCTAssertFalse(text.contains(needle), needle) }
    }
}

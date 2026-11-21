import Foundation

/// #1843: the agent-control reads ccpool.status, ccpool.usage and ccpool.pin (registered by Control/ControlCCPool.swift).
/// Labels only: never a token, a Keychain id, the vault path or a header value. Built from the pane's own model (rows,
/// proxy state) and store, per call; nothing is kept and nothing is written (pin lookups read an expired copy).
@MainActor
enum CCPoolControl {
    /// Seam: the running app's pane model; nil while ccpool is off (never built). Rows put a rig's model here.
    static var model: () -> CCPoolPaneModel? = { CCPoolRuntime.shared?.model }

    static let off = "ccpool is off"
    static let badSession = "session must be 1 to 128 characters of A-Z, a-z, 0-9, - and _"
    static let badSince = "since must be an epoch in seconds within the last 14 days"
    /// Per-session rows in a usage reply, biggest first.
    nonisolated static let sessionsMax = 50

    static func loaded() throws -> CCPoolPaneModel {
        guard let m = model() else { throw ControlError(off) }
        return m
    }

    // MARK: ccpool.status

    static func status() throws -> ControlJSON {
        let m = try loaded()
        let now = m.clock()
        let st = m.store.snapshot
        let live = st.liveSessions(now: now)
        let proxy: String
        switch m.service.status {
        case _ where m.proxyBusy: proxy = "busy"
        case .running: proxy = "running"
        case .stopped: proxy = "stopped"
        case .heldByCCPool, .heldByOther: proxy = "port held"
        case .failed: proxy = "failed"
        }
        // Rows are the pane's (alphabetical, #1838), Refresh-only states included.
        let accounts = m.rows.map { row -> ControlJSON in
            var o = usage(row.label, st, m.store, now: now)
            o["label"] = .string(row.label)
            o["state"] = .string(row.stateText)
            o["sessions"] = .number(Double(row.sessions))
            if case .held = row.state { o["held"] = .bool(true) } else { o["held"] = .bool(false) }
            if case .limited = row.state { o["benched"] = .bool(true) } else { o["benched"] = .bool(false) }
            return .object(o)
        }
        return .object(["proxy": .string(proxy), "detail": .string(m.proxyText), "port": .number(Double(m.port)),
                        "current": st.current.map { .string($0) } ?? .null,
                        "sessions": .number(Double(live.values.reduce(into: Set<String>()) { $0.formUnion($1) }.count)),
                        "accounts": .array(accounts)])
    }

    /// {"five_hour": {"percent", "resets"}, "seven_day": {...}}: the last sample's whole percent and the window's reset
    /// epoch while it is ahead; null when not seen.
    static func usage(_ label: String, _ st: CCPoolState, _ store: CCPoolStore, now: Double) -> [String: ControlJSON] {
        let sample = store.usageSample(label)
        var out: [String: ControlJSON] = [:]
        for claim in ["five_hour", "seven_day"] {
            // utils bounds each value to 0...100 (finite), so the product cannot trap.
            let pct = sample?.util[claim].map { ControlJSON.number(Double(Int(($0 * 100).rounded()))) } ?? .null
            let reset = st.accounts[label]?.reset[claim].flatMap { Double($0) > now ? ControlJSON.number(Double($0)) : nil } ?? .null
            out[claim] = .object(["percent": pct, "resets": reset])
        }
        return out
    }

    // MARK: ccpool.pin

    nonisolated static func validSession(_ s: String) -> Bool {
        (1...128).contains(s.unicodeScalars.count) && s.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    /// The label pinned for "<session>/" (the main agent), else the session's most recently seen agent pin (ties: the
    /// smaller key), with that account's 5h/7d utilization, and every live "<session>/<agent>" pin. {"pinned": false}
    /// when none is live.
    static func pin(_ session: String) throws -> ControlJSON {
        guard validSession(session) else { throw ControlError(badSession) }
        let m = try loaded()
        let now = m.clock()
        let st = m.store.snapshot
        var live = st
        live.expirePins(now: now)   // a copy: a lookup never changes the file
        let prefix = session + "/"
        let mine = live.pins.filter { $0.key.hasPrefix(prefix) && st.accounts[$0.value.account] != nil }
        guard !mine.isEmpty else { return .object(["pinned": .bool(false)]) }
        let label = mine[prefix]?.account
            ?? mine.max { ($0.value.seen, $1.key) < ($1.value.seen, $0.key) }?.value.account ?? ""
        var o = usage(label, st, m.store, now: now)
        o["pinned"] = .bool(true)
        o["label"] = .string(label)
        o["agents"] = .array(mine.sorted { $0.key < $1.key }.map {
            .object(["agent": .string(String($0.key.dropFirst(prefix.count))), "label": .string($0.value.account)])
        })
        return .object(o)
    }

    // MARK: ccpool.usage

    /// Token totals per account label and per session (short id, the biggest `sessionsMax`) since `since` (default 24 h
    /// ago, at most 14 days). The day files are read and summed off main, bounded by the reader's own caps.
    static func usage(since: Double?) async throws -> ControlJSON {
        let m = try loaded()
        let now = m.clock()
        let from = since ?? now - CCPoolUsageRange.day.seconds
        guard from.isFinite, now.isFinite, from <= now, now - from <= CCPoolUsageRange.fortnight.seconds else { throw ControlError(badSince) }
        let range: CCPoolUsageRange = now - from <= CCPoolUsageRange.day.seconds ? .day
            : now - from <= CCPoolUsageRange.week.seconds ? .week : .fortnight
        let dir = m.store.usageDirectory
        let labels = CCPoolUsageStatsModel.labels(m.store.snapshot)
        return await Task.detached {
            CCPoolControl.usageJSON(CCPoolUsageReader.readNow(directory: dir, range: range, now: now), since: from, now: now, labels: labels)
        }.value
    }

    /// Pure, off main. A Keychain id no account holds now reads "removed account"; ids never reach the reply.
    nonisolated static func usageJSON(_ r: CCPoolUsageReadResult, since: Double, now: Double, labels: [String: String]) -> ControlJSON {
        let rows = r.rows.filter { $0.t >= since }
        func label(_ id: String) -> String { labels[id] ?? "removed account" }
        func totals(_ t: CCPoolUsageTotals) -> [String: ControlJSON] {
            ["requests": .number(Double(t.requests)), "input": .number(Double(t.input)), "output": .number(Double(t.output)),
             "cache_read": .number(Double(t.cacheRead)), "cache_write_5m": .number(Double(t.cacheWrite5m)),
             "cache_write_1h": .number(Double(t.cacheWrite1h)), "total": .number(Double(t.total))]
        }
        var byLabel: [String: CCPoolUsageTotals] = [:]
        for (id, t) in CCPoolUsageStats.tokens(rows, by: .account) {
            var sum = byLabel[label(id), default: CCPoolUsageTotals()]
            sum.input += t.input; sum.output += t.output; sum.cacheRead += t.cacheRead
            sum.cacheWrite5m += t.cacheWrite5m; sum.cacheWrite1h += t.cacheWrite1h; sum.requests += t.requests
            byLabel[label(id)] = sum
        }
        let accounts = byLabel.keys.sorted(by: CCPoolCore.labelFirst).map { l -> ControlJSON in
            var o = totals(byLabel[l] ?? CCPoolUsageTotals())
            o["label"] = .string(l)
            return .object(o)
        }
        let top = CCPoolUsageStats.topSessions(rows, limit: sessionsMax + 1)
        let sessions = top.prefix(sessionsMax).map { s -> ControlJSON in
            var o = totals(s.totals)
            o["session"] = .string(CCPoolUsageStatsModel.shortSession(s.sess))
            o["accounts"] = .array(Array(Set(s.accounts.map(label))).sorted(by: CCPoolCore.labelFirst).map { .string($0) })
            return .object(o)
        }
        return .object(["since": .number(since), "until": .number(now), "rows": .number(Double(rows.count)),
                        "skipped": .number(Double(r.skippedTotal)), "truncated": .bool(r.truncated),
                        "more_sessions": .bool(top.count > sessionsMax),
                        "accounts": .array(accounts), "sessions": .array(Array(sessions))])
    }
}

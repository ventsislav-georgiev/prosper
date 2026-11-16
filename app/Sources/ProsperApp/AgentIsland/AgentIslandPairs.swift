// #847 P1e "Pairs": sessions X and X<suffix> in one socket dir are a pair, so Stop and
// Resume can offer both. Pure: names in, pairs and texts out; no dch, no view.

import Foundation

/// #1116: the sessions of one stem in one socket dir, by folded names, in group order (`AgentIsland.groups`):
/// at least one main and one sidekick. A pair is the group of one main and one sidekick (#909: Step A's two-member
/// pairs() is gone; groups() alone decides).
struct AgentGroup: Hashable {
    let dir: String
    let stem: String
    let mains: [String]
    let sidekicks: [String]
}

/// One member's end of a Stop both or Resume both, for `pairLine`.
enum AgentPairOutcome: Equatable, Sendable {
    /// Its job ran: the result its row reads too.
    case result(DchActionResult)
    /// Stop both: no live row at the click (it ended, a poll gap, a suffix edit: never "ended", A1).
    case notListed
    /// Its job was refused: another job holds its key (a phone verb since the check).
    case refused
    /// Resume both: the sidekick is live by the time the main is up; not revived (no `--as`).
    case running
    /// Resume both: the sidekick's record went while the main ran.
    case noRecord
    /// Resume both: the main is not up, so the sidekick was not started.
    case notStarted
}

extension AgentIsland {
    // MARK: - Pairs (#847 P1e)

    /// The pair suffix is usable: 1 to 16 bytes, each ASCII [A-Za-z0-9._-], the bytes a name
    /// Prosper makes may hold, so main + suffix is a name dch takes when the main is.
    /// R909-2: and at least one letter: with "-" (or "1", "-2", "_") every numbered name x-N would read as a sidekick of x.
    static func suffixOK(_ s: String) -> Bool {
        (1...16).contains(s.utf8.count) && s.utf8.contains { (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0) }
            && s.utf8.allSatisfy {
                switch $0 {
                case 0x30...0x39, 0x41...0x5a, 0x61...0x7a, 0x2d, 0x2e, 0x5f: true
                default: false
                }
            }
    }

    // MARK: - Groups (#1116)

    /// Every group in `keys` (live keys and History record keys, never a record's id), by dir then stem. Per dir, on
    /// the folded passable names, each name in one group at most:
    /// 1. a stored link (m, k), both listed, puts k as a sidekick in m's group; k is linked once and is never a
    ///    linked main, m is never a linked sidekick; link roles win over the name;
    /// 2. when `suffixOK`, a name b + suffix + ("" | digits | "-" digits), b not empty, is a sidekick of stem b;
    /// 3. any other name is a main: of stem `name` when a sidekick has that stem, else of stem `name` minus a
    ///    trailing "-digits" or "digits" when a sidekick has that one, else of its own name (links only);
    /// 4. a stem with a main and a sidekick is a group: mains, then sidekicks, bare names first, then by number.
    static func groups(_ keys: [AgentSessionKey], suffix: String,
                       links: [(main: AgentSessionKey, sidekick: AgentSessionKey)] = []) -> [AgentGroup] {
        var index: [String: Set<String>] = [:]
        for k in keys where passable(k.name) { index[k.dir, default: []].insert(k.name.lowercased()) }
        let s = suffix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let byName = suffixOK(s)
        var out: [AgentGroup] = []
        for (dir, names) in index {
            var linked: [String: String] = [:]   // linked sidekick -> its main
            for l in links where l.main.dir == dir && l.sidekick.dir == dir {
                let m = l.main.name.lowercased(), k = l.sidekick.name.lowercased()
                guard m != k, names.contains(m), names.contains(k), linked[k] == nil, linked[m] == nil,
                      !linked.values.contains(k) else { continue }
                linked[k] = m
            }
            let linkedMains = Set(linked.values)
            var sidekicks: [String: (stem: String, num: String?)] = [:]
            if byName {
                for n in names where linked[n] == nil && !linkedMains.contains(n) {
                    if let t = sidekickTail(n, s) { sidekicks[n] = t }
                }
            }
            let stems = Set(sidekicks.values.map(\.stem))
            var mains: [String: (stem: String, num: String?)] = [:]
            for n in names where linked[n] == nil && sidekicks[n] == nil {
                var stem = n, num: String?
                if !stems.contains(n), let t = trailingDigits(n) {   // the exact stem wins over a worker number
                    let w = String(t.rest.hasSuffix("-") ? t.rest.dropLast() : t.rest)
                    if stems.contains(w) { (stem, num) = (w, t.digits) }
                }
                mains[n] = (stem, num)
            }
            for (k, m) in linked { sidekicks[k] = (mains[m]?.stem ?? m, nil) }
            var byStem: [String: (mains: [(String, String?)], sidekicks: [(String, String?)])] = [:]
            for (n, m) in mains { byStem[m.stem, default: ([], [])].mains.append((n, m.num)) }
            for (n, k) in sidekicks { byStem[k.stem, default: ([], [])].sidekicks.append((n, k.num)) }
            for (stem, g) in byStem where !g.mains.isEmpty && !g.sidekicks.isEmpty {
                out.append(AgentGroup(dir: dir, stem: stem, mains: groupOrder(g.mains), sidekicks: groupOrder(g.sidekicks)))
            }
        }
        return out.sorted { ($0.dir, $0.stem) < ($1.dir, $1.stem) }
    }

    /// `n` = b + `s` + ("" | digits | "-" digits) with b not empty: (b, the digits). Digits are read greedily, so a
    /// suffix ending in a digit ("-r2") takes a number only after a dash ("x-r2-3"; "x-r23" is no sidekick of x).
    static func sidekickTail(_ n: String, _ s: String) -> (stem: String, num: String?)? {
        var rest = Substring(n), num: String?
        if !n.hasSuffix(s), let t = trailingDigits(n) {
            rest = t.rest.hasSuffix(s) || !t.rest.hasSuffix("-") ? t.rest : t.rest.dropLast()
            num = t.digits
        }
        guard rest.hasSuffix(s), rest.count > s.count else { return nil }
        return (String(rest.dropLast(s.count)), num)
    }

    /// `n` split before its trailing ASCII digits; nil when it has none. The digits stay text: never an Int.
    static func trailingDigits(_ n: String) -> (rest: Substring, digits: String)? {
        let c = n.reversed().prefix { $0.isASCII && $0.isNumber }.count
        return c == 0 ? nil : (n.dropLast(c), String(n.suffix(c)))
    }

    /// Bare names first, then by number (leading zeros dropped, shorter first, then text), then by name.
    static func groupOrder(_ members: [(String, String?)]) -> [String] {
        func key(_ m: (String, String?)) -> (Int, Int, String, String) {
            let d = m.1.map { String($0.drop(while: { c in c == "0" })) }
            return (d == nil ? 0 : 1, d?.count ?? 0, d ?? "", m.0)
        }
        return members.sorted { key($0) < key($1) }.map(\.0)
    }

    static func stopBothLabel(partner: String) -> String { groupLabel(.stop, others: [partner]) }
    static func resumeBothLabel(partner: String) -> String { groupLabel(.resume, others: [partner]) }

    /// #908: "Stop both (with api-qa)", "Resume all 3 (with feat-2, feat-qa)": the other members, group order.
    static func groupLabel(_ verb: Verb, others: [String]) -> String {
        "\(pairTitle(verb, count: others.count + 1)) (with \(others.joined(separator: ", ")))"
    }

    /// "Stop both" / "Resume both"; #908: a group of more than two, "Stop all 3" / "Resume all 3".
    static func pairTitle(_ verb: Verb, count: Int = 2) -> String {
        (verb == .stop ? "Stop" : "Resume") + (count > 2 ? " all \(count)" : " both")
    }

    /// The dir line when nothing ran: "Stop both not run: api-qa is busy".
    static func pairNotRun(_ verb: Verb, _ why: String, count: Int = 2) -> String { "\(pairTitle(verb, count: count)) not run: \(why)" }

    /// The dir line while the main's revive runs.
    static func pairFirstText(main: String, sidekick: String) -> String { pairFirstText([main, sidekick]) }

    /// #908: "Resume all 3: feat-1 first, then feat-2, feat-qa...", the members in the order they start.
    static func pairFirstText(_ names: [String]) -> String {
        "\(pairTitle(.resume, count: names.count)): \(names.first ?? "") first, then \(names.dropFirst().joined(separator: ", "))\u{2026}"
    }

    /// The pair's one dir line, main first: "Stop both: api stopped, api-qa had already ended",
    /// "Resume both: api: <why>; api-qa not started".
    static func pairLine(_ verb: Verb, _ members: [(name: String, outcome: AgentPairOutcome)]) -> String {
        let parts = members.map { pairPart(verb, $0.name, $0.outcome) }
        var line = ""
        for (i, p) in parts.enumerated() {
            if i > 0 { line += members[i].outcome == .notStarted ? "; " : ", " }
            line += p
        }
        return "\(pairTitle(verb, count: members.count)): \(line)"
    }

    /// One member's words in `pairLine`.
    static func pairPart(_ verb: Verb, _ name: String, _ o: AgentPairOutcome) -> String {
        switch o {
        case .result(let r):
            // Step A INFO: dch --stop's no_session; a revive never reads as ended.
            if verb == .stop, !r.stopped, r.json.last(where: { $0.name == name && $0.isFinal })?.reason == "no_session" {
                return "\(name) had already ended"
            }
            let t = rowText(r, name: name, verb)
            return t == verb.done ? "\(name) \(verb.done.lowercased())" : "\(name): \(t)"
        case .notListed: return "\(name) is not listed any more"
        case .refused: return "\(name): \(verb.rawValue) not run: another job is running"
        case .running: return "\(name) is running"
        case .noRecord: return "\(name) has no record left"
        case .notStarted: return "\(name) not started"
        }
    }

    /// Resume both's "main up": its last final line for `name` is ok, a revive whose message
    /// only was not sent (withdrawn, draft_left), or "live" (it runs). #886 adds dch's "running" here.
    static func revivedOrLive(_ r: DchActionResult, name: String) -> Bool {
        guard !r.stopped, let f = r.json.last(where: { $0.name == name && $0.isFinal }) else { return false }
        return f.result == "ok" || resumedUnsent(f, .resume) || f.reason == "live"
    }
}

/// Stop both's and Resume both's join: each member's `then` fills its outcome; when both are
/// in, `done` gets the pair line once. Main-actor only, as the runner's `done` is (F9).
@MainActor
final class AgentPairJoin {
    let verb: AgentIsland.Verb
    let names: [String]
    private var outcomes: [String: AgentPairOutcome] = [:]
    private let done: @MainActor (String) -> Void

    convenience init(_ verb: AgentIsland.Verb, main: String, sidekick: String, done: @escaping @MainActor (String) -> Void) {
        self.init(verb, names: [main, sidekick], done: done)
    }

    /// #908: any count, in line order. QA 791 (2): a name given twice is one member, so the join still ends.
    init(_ verb: AgentIsland.Verb, names: [String], done: @escaping @MainActor (String) -> Void) {
        self.verb = verb
        var seen = Set<String>()
        self.names = names.filter { seen.insert($0).inserted }
        self.done = done
    }

    /// A member's outcome; a name not in the pair, or a second fill, is ignored.
    func fill(_ name: String, _ o: AgentPairOutcome) {
        guard names.contains(name), outcomes[name] == nil else { return }
        outcomes[name] = o
        guard outcomes.count == names.count else { return }
        done(AgentIsland.pairLine(verb, names.compactMap { n in outcomes[n].map { (name: n, outcome: $0) } }))
    }
}

extension AgentIslandStore {
    /// #908: every group of the live sessions and the History records under `pairSuffix`, once per draw or click.
    var groups: [AgentGroup] {
        AgentIsland.groups(sessions.map(\.key) + history.map(\.key), suffix: pairSuffix)
    }

    /// #908: `s`'s group's live sessions in group order, `s` itself in its place; nil when `s` is in no group.
    /// A folded member maps back to its live session by a folded compare in `s`'s dir (the first one: the fold limit).
    func liveGroup(_ s: AgentSession, _ groups: [AgentGroup]) -> [AgentSession]? {
        let me = s.name.lowercased()
        guard let g = groups.first(where: { $0.dir == s.key.dir && ($0.mains + $0.sidekicks).contains(me) }) else { return nil }
        return (g.mains + g.sidekicks).compactMap { n in
            n == me ? s : sessions.first { $0.key.dir == g.dir && $0.name.lowercased() == n }
        }
    }

    /// #908: `r`'s group for Resume both: each member not live by its newest record, mains then sidekicks in
    /// group order, and the names of the members live in `r`'s dir; nil when `r` is in no group.
    func historyGroup(_ r: DchHistoryRecord, _ groups: [AgentGroup])
        -> (mains: [DchHistoryRecord], sidekicks: [DchHistoryRecord], live: [String])? {
        let me = r.name.lowercased()
        guard let g = groups.first(where: { $0.dir == r.key.dir && ($0.mains + $0.sidekicks).contains(me) }) else { return nil }
        var live: [String] = []
        func records(_ names: [String]) -> [DchHistoryRecord] {
            names.compactMap { n in
                if let s = sessions.first(where: { $0.key.dir == g.dir && $0.name.lowercased() == n }) {
                    live.append(s.name)
                    return nil
                }
                return n == me ? r : history.first { $0.key.dir == g.dir && $0.name.lowercased() == n }
            }
        }
        let mains = records(g.mains), sidekicks = records(g.sidekicks)
        return (mains, sidekicks, live)
    }
}

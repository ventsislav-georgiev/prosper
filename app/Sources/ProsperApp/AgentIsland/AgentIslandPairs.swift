// #847 P1e "Pairs": sessions X and X<suffix> in one socket dir are a pair, so Stop and
// Resume can offer both. Pure: names in, pairs and texts out; no dch, no view.

import Foundation

/// A pair's two members by their folded (lowercased) names, in one socket dir.
struct AgentPair: Hashable {
    let dir: String
    let main: String
    let sidekick: String

    /// `name` (any case) is the main.
    func isMain(_ name: String) -> Bool { name.lowercased() == main }
    /// The other member's folded name; nil when `name` is not a member.
    func partner(of name: String) -> String? {
        switch name.lowercased() {
        case main: sidekick
        case sidekick: main
        default: nil
        }
    }
}

/// #1116: the sessions of one stem in one socket dir, by folded names, in group order (`AgentIsland.groups`):
/// at least one main and one sidekick. A pair is the group of one main and one sidekick.
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

    /// Each member's folded key `(dir, name.lowercased())` -> its pair. `keys`: live keys and
    /// History record keys (never a record's id). `links` (P1d's stored pairs) win over inference.
    /// Rules, in order: 1. per dir, the folded passable names; 2. a link takes both members when
    /// both are listed in its dir and neither is taken; 3. inferred, when `suffixOK`: n = m + suffix
    /// with m listed in n's dir, one suffix stripped; 4. shortest main first, each name taken once.
    static func pairs(_ keys: [AgentSessionKey], suffix: String,
                      links: [(main: AgentSessionKey, sidekick: AgentSessionKey)] = []) -> [AgentSessionKey: AgentPair] {
        var index: [String: Set<String>] = [:]
        for k in keys where passable(k.name) { index[k.dir, default: []].insert(k.name.lowercased()) }
        var out: [AgentSessionKey: AgentPair] = [:]
        func take(_ dir: String, _ m: String, _ s: String) {
            let a = AgentSessionKey(dir: dir, name: m), b = AgentSessionKey(dir: dir, name: s)
            guard m != s, out[a] == nil, out[b] == nil else { return }
            let p = AgentPair(dir: dir, main: m, sidekick: s)
            out[a] = p
            out[b] = p
        }
        for l in links where l.main.dir == l.sidekick.dir {
            let lm = l.main.name.lowercased(), ls = l.sidekick.name.lowercased(), names = index[l.main.dir] ?? []
            if names.contains(lm), names.contains(ls) { take(l.main.dir, lm, ls) }
        }
        let s = suffix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard suffixOK(s) else { return out }
        for (dir, names) in index {
            let mains = names.compactMap { n -> String? in
                guard n.hasSuffix(s), n.count > s.count else { return nil }
                let m = String(n.dropLast(s.count))
                return names.contains(m) ? m : nil
            }
            for m in mains.sorted(by: { ($0.utf8.count, $0) < ($1.utf8.count, $1) }) { take(dir, m, m + s) }
        }
        return out
    }

    /// The pair suffix is usable: 1 to 16 bytes, each ASCII [A-Za-z0-9._-], the bytes a name
    /// Prosper makes may hold, so main + suffix is a name dch takes when the main is.
    static func suffixOK(_ s: String) -> Bool {
        (1...16).contains(s.utf8.count) && s.utf8.allSatisfy {
            switch $0 {
            case 0x30...0x39, 0x41...0x5a, 0x61...0x7a, 0x2d, 0x2e, 0x5f: true
            default: false
            }
        }
    }

    // MARK: - Groups (#1116)

    /// Every group in `keys` (live keys and History record keys, as `pairs`), by dir then stem. Per dir, on
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

    static func stopBothLabel(partner: String) -> String { "Stop both (with \(partner))" }
    static func resumeBothLabel(partner: String) -> String { "Resume both (with \(partner))" }

    /// "Stop both" / "Resume both".
    static func pairTitle(_ verb: Verb) -> String { (verb == .stop ? "Stop" : "Resume") + " both" }

    /// The dir line when nothing ran: "Stop both not run: api-qa is busy".
    static func pairNotRun(_ verb: Verb, _ why: String) -> String { "\(pairTitle(verb)) not run: \(why)" }

    /// The dir line while the main's revive runs.
    static func pairFirstText(main: String, sidekick: String) -> String { "Resume both: \(main) first, then \(sidekick)…" }

    /// The pair's one dir line, main first: "Stop both: api stopped, api-qa had already ended",
    /// "Resume both: api: <why>; api-qa not started".
    static func pairLine(_ verb: Verb, _ members: [(name: String, outcome: AgentPairOutcome)]) -> String {
        let parts = members.map { pairPart(verb, $0.name, $0.outcome) }
        var line = ""
        for (i, p) in parts.enumerated() {
            if i > 0 { line += members[i].outcome == .notStarted ? "; " : ", " }
            line += p
        }
        return "\(pairTitle(verb)): \(line)"
    }

    /// One member's words in `pairLine`.
    static func pairPart(_ verb: Verb, _ name: String, _ o: AgentPairOutcome) -> String {
        switch o {
        case .result(let r):
            if !r.stopped, r.json.last(where: { $0.name == name && $0.isFinal })?.reason == "no_session" {
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

    init(_ verb: AgentIsland.Verb, main: String, sidekick: String, done: @escaping @MainActor (String) -> Void) {
        self.verb = verb
        names = [main, sidekick]
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
    /// Live sessions and every History record, paired once per draw (never per row).
    func pairs(suffix: String) -> [AgentSessionKey: AgentPair] {
        AgentIsland.pairs(sessions.map(\.key) + history.map(\.key), suffix: suffix)
    }

    /// `s`'s partner, live in its dir; nil when unpaired or not live.
    func livePartner(_ s: AgentSession, pairs: [AgentSessionKey: AgentPair]) -> AgentSession? {
        guard let p = pairs[AgentSessionKey(dir: s.key.dir, name: s.name.lowercased())], let o = p.partner(of: s.name)
        else { return nil }
        return sessions.first { $0.key.dir == p.dir && $0.name.lowercased() == o }
    }

    /// `r`'s partner's newest record (`history` is newest first); nil when unpaired or none.
    func historyPartner(_ r: DchHistoryRecord, pairs: [AgentSessionKey: AgentPair]) -> DchHistoryRecord? {
        guard let p = pairs[AgentSessionKey(dir: r.key.dir, name: r.name.lowercased())], let o = p.partner(of: r.name)
        else { return nil }
        return history.first { $0.key.dir == p.dir && $0.name.lowercased() == o }
    }
}

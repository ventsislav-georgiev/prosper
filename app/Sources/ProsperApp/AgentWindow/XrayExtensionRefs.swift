import AppKit
import SwiftUI

/// #1564 (X7 b, spec v2.1 2.6): one live `[[contributes.xrefs]]` rule, its template compiled into literals and typed
/// placeholders. No regex: the matcher below walks the pieces, so one attempt is bounded by the template's longest match.
struct XrayExtensionRule: Equatable, Sendable {
    /// The placeholders an extension may use (v2.1 2.2); `{sha}`, `{path}` and `{url}` are the built-ins' own.
    enum Slot: String, Equatable, Sendable { case n, id, KEY, repo }
    enum Piece: Equatable, Sendable { case literal([Unicode.Scalar]), slot(Slot) }
    enum InCode: String, Equatable, Sendable { case never, whole }

    let extensionID: String
    let id: String
    let template: String
    /// The card's source line, as shown (OutsideText).
    let label: String
    let inCode: InCode
    /// A Lua global, run only on hover or pin (X7 c); nil = no card.
    let handler: String?
    let timeout: Int
    let pieces: [Piece]
}

enum XrayExtensionRefs {
    static let maxPerExtension = 16, maxTotal = 64, maxTemplate = 64, maxSlots = 3
    static let timeouts = 1...10, defaultTimeout = 3
    static let shownMax = 80

    struct Compiled: Equatable {
        var rules: [XrayExtensionRule] = []
        /// One load-log line per refused rule; the extension itself still loads.
        var refusals: [String] = []
    }

    struct Refusal: Error { let why: String }

    /// The live extensions' rows, in registry order, into rules. A refused row is skipped with one line; the first of
    /// two rules with the same template wins; past 16 kept per extension or 64 in all, a row is refused.
    static func compile(_ extensions: [(id: String, xrefs: XrefList?)]) -> Compiled {
        var out = Compiled()
        for (extID, list) in extensions {
            guard let list else { continue }
            let ext = OutsideText.shown(extID, max: shownMax)
            if list.notAList { out.refusals.append("extension \(ext): xrefs ignored (not an array of tables)"); continue }
            var kept = 0
            for (k, row) in list.rows.enumerated() {
                let name = row.id.map { OutsideText.shown($0.stringValue, max: shownMax) } ?? "#\(k + 1)"
                func refuse(_ why: String) { out.refusals.append("extension \(ext): xref \(name) refused (\(why))") }
                do {
                    let rule = try self.rule(row, extensionID: extID)
                    if out.rules.contains(where: { $0.template == rule.template }) { refuse("duplicate of a loaded rule"); continue }
                    if kept >= maxPerExtension { refuse("more than \(maxPerExtension) rules in this extension"); continue }
                    if out.rules.count >= maxTotal { refuse("more than \(maxTotal) rules in total"); continue }
                    out.rules.append(rule)
                    kept += 1
                } catch let r as Refusal {
                    refuse(r.why)
                } catch {
                    refuse("unreadable")
                }
            }
        }
        return out
    }

    static func rule(_ row: XrefContribution, extensionID: String) throws -> XrayExtensionRule {
        if row.notATable { throw Refusal(why: "not a table") }
        if !row.unreadable.isEmpty { throw Refusal(why: "unreadable " + row.unreadable.joined(separator: ", ")) }
        func string(_ v: TOMLValue?, _ key: String) throws -> String? {
            guard let v else { return nil }
            guard case .string(let s) = v, !s.isEmpty else { throw Refusal(why: "\(key) must be a non-empty string") }
            return s
        }
        guard let id = try string(row.id, "id") else { throw Refusal(why: "no id") }
        guard let template = try string(row.template, "template") else { throw Refusal(why: "no template") }
        let label = try string(row.label, "label") ?? id
        let handler = try string(row.handler, "handler")
        guard let inCode = XrayExtensionRule.InCode(rawValue: try string(row.in_code, "in_code") ?? "never") else {
            throw Refusal(why: "in_code must be \"never\" or \"whole\"")
        }
        var timeout = defaultTimeout
        if let t = row.timeout {
            guard case .int(let i) = t, timeouts.contains(i) else { throw Refusal(why: "timeout must be 1..10") }
            timeout = i
        }
        return XrayExtensionRule(extensionID: extensionID, id: id, template: template,
                                 label: OutsideText.shown(label, max: shownMax), inCode: inCode, handler: handler,
                                 timeout: timeout, pieces: try pieces(template))
    }

    /// The template's pieces, or the refusal (v2.1 2.6): over 64 chars, an unknown or unclosed placeholder, two
    /// placeholders with no literal between them, a literal whose first char the placeholder before it could take
    /// (the matcher relies on this: a placeholder followed by a literal has one possible end), more than 3
    /// placeholders, or no placeholder at all.
    static func pieces(_ template: String) throws -> [XrayExtensionRule.Piece] {
        guard template.count <= maxTemplate else { throw Refusal(why: "template over \(maxTemplate) chars") }
        var out: [XrayExtensionRule.Piece] = [], literal: [Unicode.Scalar] = []
        var rest = Array(template.unicodeScalars)[...]
        while let c = rest.popFirst() {
            if c == "}" { throw Refusal(why: "a } with no {") }
            guard c == "{" else { literal.append(c); continue }
            guard let close = rest.firstIndex(of: "}") else { throw Refusal(why: "an unclosed {") }
            let name = String(String.UnicodeScalarView(rest[..<close]))
            guard let slot = XrayExtensionRule.Slot(rawValue: name) else {
                throw Refusal(why: "unknown placeholder {\(OutsideText.shown(name, max: 16))}")
            }
            if !literal.isEmpty {
                if case .slot(let before) = out.last, let first = literal.first, before.mayHold(first) {
                    throw Refusal(why: "a literal after {\(before.rawValue)} starts with a char it takes")
                }
                out.append(.literal(literal)); literal = []
            } else if case .slot = out.last {
                throw Refusal(why: "two placeholders with no literal between them")
            }
            out.append(.slot(slot))
            rest = rest[(close + 1)...]
        }
        if !literal.isEmpty {
            if case .slot(let before) = out.last, let first = literal.first, before.mayHold(first) {
                throw Refusal(why: "a literal after {\(before.rawValue)} starts with a char it takes")
            }
            out.append(.literal(literal))
        }
        let slots = out.filter { if case .slot = $0 { return true } else { return false } }.count
        if slots == 0 { throw Refusal(why: "literals only") }
        if slots > maxSlots { throw Refusal(why: "more than \(maxSlots) placeholders") }
        return out
    }

    // MARK: - The matcher

    struct Match: Equatable {
        let rule: XrayExtensionRule
        let range: Range<String.Index>
        let text: String
        /// Each placeholder's text, in template order.
        let parts: [String]
    }

    /// The rule's spans in one grid line, left to right, never overlapping. A span starts and ends at a word boundary
    /// (no letter, number or `_` on either side). In a code line an `in_code = "never"` rule finds nothing and a
    /// `"whole"` rule only a span that is the whole trimmed line.
    static func matches(of rule: XrayExtensionRule, in line: String, isCode: Bool = false) -> [Match] {
        if isCode && rule.inCode == .never { return [] }
        let cs = Array(line.unicodeScalars)
        let at = Array(line.unicodeScalars.indices) + [line.unicodeScalars.endIndex]
        var out: [Match] = [], i = 0
        while i < cs.count {
            if i == 0 || !isWord(cs[i - 1]), case let (end, parts)? = match(rule.pieces, cs, at: i) {
                out.append(Match(rule: rule, range: at[i]..<at[end], text: String(String.UnicodeScalarView(cs[i..<end])),
                                 parts: parts))
                i = end   // every piece takes at least one scalar, so end > i
            } else {
                i += 1
            }
        }
        if isCode {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return out.filter { $0.text == trimmed }
        }
        return out
    }

    /// One attempt at `start`: the end and the placeholders' texts, or nil. A placeholder before a literal has one
    /// viable end, its longest (`pieces` refused the rest); only the last placeholder backs off to a word boundary.
    static func match(_ pieces: [XrayExtensionRule.Piece], _ cs: [Unicode.Scalar], at start: Int) -> (Int, [String])? {
        var i = start, parts: [String] = []
        for (k, piece) in pieces.enumerated() {
            switch piece {
            case .literal(let lit):
                guard cs.count - i >= lit.count, zip(lit, cs[i...]).allSatisfy(sameFolded) else { return nil }
                i += lit.count
            case .slot(let slot):
                let ends = slot.ends(cs, from: i)
                let last = k == pieces.count - 1
                guard let end = last ? ends.lazy.flatMap({ $0.reversed() }).first(where: { $0 == cs.count || !isWord(cs[$0]) })
                                     : ends.first?.upperBound else { return nil }
                parts.append(String(String.UnicodeScalarView(cs[i..<end])))
                i = end
            }
        }
        guard i == cs.count || !isWord(cs[i]) else { return nil }
        return (i, parts)
    }

    /// `\p{L}`, `\p{N}` or `_`: what a span may not touch.
    static func isWord(_ u: Unicode.Scalar) -> Bool {
        if u == "_" { return true }
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    /// Template literals match ignoring ASCII case ("oq-245" matches `OQ-{n}`).
    static func sameFolded(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
        a == b || (a.isASCII && b.isASCII && lower(a) == lower(b))
    }

    static func lower(_ u: Unicode.Scalar) -> Unicode.Scalar {
        (65...90).contains(u.value) ? Unicode.Scalar(u.value + 32)! : u
    }
}

extension XrayExtensionRule.Slot {
    private static func digit(_ u: Unicode.Scalar) -> Bool { (48...57).contains(u.value) }
    private static func upper(_ u: Unicode.Scalar) -> Bool { (65...90).contains(u.value) }
    private static func alnum(_ u: Unicode.Scalar) -> Bool { digit(u) || upper(u) || (97...122).contains(u.value) }
    private static func idChar(_ u: Unicode.Scalar) -> Bool { alnum(u) || u == "_" || u == "." || u == "-" }

    /// True when the placeholder could take `u` in either ASCII case (a literal matches either case).
    func mayHold(_ u: Unicode.Scalar) -> Bool {
        let folded = XrayExtensionRefs.lower(u), upped = (97...122).contains(u.value) ? Unicode.Scalar(u.value - 32)! : u
        return [u, folded, upped].contains { c in
            switch self {
            case .n: return Self.digit(c)
            case .id: return Self.idChar(c)
            case .KEY: return Self.digit(c) || Self.upper(c)
            case .repo: return Self.idChar(c) || c == "/"
            }
        }
    }

    /// The ends this placeholder can reach from `i`, as ranges in the order a regex would try them, each tried from its
    /// upper bound down. Empty when it cannot start at `i`.
    /// `{n}` [0-9]{1,7}; `{id}` [A-Za-z0-9][A-Za-z0-9_.-]{0,63}; `{KEY}` [A-Z][A-Z0-9]{1,9};
    /// `{repo}` ([A-Za-z0-9-]{1,39}/)?[A-Za-z0-9_.-]{1,100}.
    func ends(_ cs: [Unicode.Scalar], from i: Int) -> [ClosedRange<Int>] {
        func run(_ from: Int, max: Int, _ ok: (Unicode.Scalar) -> Bool) -> Int {
            var j = from
            while j < cs.count, j - from < max, ok(cs[j]) { j += 1 }
            return j - from
        }
        switch self {
        case .n:
            let r = run(i, max: 7, Self.digit)
            return r >= 1 ? [(i + 1)...(i + r)] : []
        case .id:
            guard i < cs.count, Self.alnum(cs[i]) else { return [] }
            return [(i + 1)...(i + 1 + run(i + 1, max: 63, Self.idChar))]
        case .KEY:
            guard i < cs.count, Self.upper(cs[i]) else { return [] }
            let r = run(i + 1, max: 9) { Self.upper($0) || Self.digit($0) }
            return r >= 1 ? [(i + 2)...(i + 1 + r)] : []
        case .repo:
            var out: [ClosedRange<Int>] = []
            let owner = run(i, max: 39) { Self.alnum($0) || $0 == "-" }
            let slash = i + owner
            if owner >= 1, slash < cs.count, cs[slash] == "/" {
                let name = run(slash + 1, max: 100, Self.idChar)
                if name >= 1 { out.append((slash + 2)...(slash + 1 + name)) }
            }
            let name = run(i, max: 100, Self.idChar)
            if name >= 1 { out.append((i + 1)...(i + name)) }
            return out
        }
    }
}

// MARK: - #1569 (X7 c, spec 5.6, v2.1 7.3): the handler call and its card

extension XrayExtensionRefs {
    /// The handler's result as the card shows it: a card, nothing (nil or empty), a failure, or the extension went.
    enum Outcome: Equatable, Sendable {
        case card(Card)
        case nothing
        case failed(String)
        case unavailable
    }

    /// An action is data the host runs: open an http(s) url, or copy a text. Never Lua run on the click.
    struct Action: Equatable, Sendable {
        let label: String
        let url: URL?
        let copy: String?
    }

    struct Card: Equatable, Sendable {
        let title: String
        let subtitle: String
        let body: String
        let actions: [Action]
    }

    static let titleCap = 120, subtitleCap = 200, bodyBytes = 8 * 1024, maxActions = 4, labelCap = 40
    /// What the lane may hand back at all; past it the result is refused unread.
    static let resultBytes = 64 * 1024
    static let notIndexed = "Extension ref \u{00B7} not indexed"
    static let unavailable = "Extension unavailable: it was reloaded or turned off"
    static let unreadable = "The extension's answer was unreadable"
    static let timedOut = "The extension did not answer in time"
    static let dropped = "Dropped for a newer card"

    /// The mark's key: never a dch key (those are "<shape>:<text>"), one per rule and text.
    static func key(_ m: Match) -> String { "xref:\(m.rule.extensionID)/\(m.rule.id):\(m.text)" }

    /// The handler's one argument, JSON {text, parts, dir, session}: the match and where it is, never a line of the screen
    /// or of the transcript.
    static func arg(_ m: Match, dir: String?, session: String?) -> String {
        let o: [String: Any] = ["text": m.text, "parts": m.parts, "dir": dir ?? "", "session": session ?? ""]
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    /// The card's row (the hover and the popover take an XrayRefs.Entry): the rule's label as its title, no count.
    static func entry(_ m: Match) -> XrayRefs.Entry {
        XrayRefs.Entry(key: key(m), shape: nil, text: OutsideText.shown(m.text, max: XrayRefs.maxRefBytes), full: nil, count: 0,
                       lastOffset: nil, defined: false, definitions: 0, title: m.rule.label, underline: true, index: 0)
    }

    /// The handler's string, capped (v2.1 7.3): nil or an empty card is nothing; `{error}` a failure; else title 120,
    /// subtitle 200, body 8 KB (each line through OutsideText), the first 4 usable actions. Every string is outside text.
    static func outcome(_ raw: String?) -> Outcome {
        guard let raw else { return .nothing }
        guard raw.utf8.count <= resultBytes,
              let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return .failed(unreadable) }
        if let e = o["error"] {
            let why = OutsideText.shown(e as? String ?? "", max: subtitleCap)
            return .failed(why.isEmpty ? "The extension failed" : why)
        }
        let body = capBytes(((o["body"] as? String) ?? "").prefix(bodyBytes * 2).components(separatedBy: "\n")
            .map { OutsideText.shown($0, max: bodyBytes) }.joined(separator: "\n"), bodyBytes)
        let actions = ((o["actions"] as? [Any]) ?? []).prefix(64).compactMap(action).prefix(maxActions)
        let c = Card(title: OutsideText.shown(o["title"] as? String ?? "", max: titleCap),
                     subtitle: OutsideText.shown(o["subtitle"] as? String ?? "", max: subtitleCap),
                     body: body.trimmingCharacters(in: .newlines), actions: Array(actions))
        return c.title.isEmpty && c.subtitle.isEmpty && c.body.isEmpty && c.actions.isEmpty ? .nothing : .card(c)
    }

    /// {label, url} (http or https with a host) or {label, copy}; anything else is dropped.
    static func action(_ v: Any) -> Action? {
        guard let a = v as? [String: Any], let raw = a["label"] as? String else { return nil }
        let label = OutsideText.shown(raw, max: labelCap)
        guard !label.isEmpty else { return nil }
        if let raw = a["url"] as? String, let u = XrayRefContext.openable(raw, shape: .url) { return Action(label: label, url: u, copy: nil) }
        if let c = a["copy"] as? String, !c.isEmpty { return Action(label: label, url: nil, copy: capBytes(String(c.prefix(bodyBytes)), bodyBytes)) }
        return nil
    }

    /// At most `n` UTF-8 bytes, cut at a character.
    static func capBytes(_ s: String, _ n: Int) -> String {
        guard s.utf8.count > n else { return s }
        var out = "", used = 0
        for c in s {
            let b = c.utf8.count
            if used + b > n { break }
            out.append(c)
            used += b
        }
        return out
    }
}

/// #1569: a window's handler calls (5.6): at most 2 in flight, the oldest dropped (LaneCall.drop: its host waits go,
/// process.run's group with them), the same request joined; answers kept in an LRU of 256, 60 s (a failure 10 s).
@MainActor
final class XrayExtensionCalls {
    struct Key: Hashable {
        let ext: String
        let rule: String
        let arg: String
    }

    static let maxInFlight = 2, maxKept = 256
    static let keep: TimeInterval = 60, keepFailed: TimeInterval = 10

    var now: () -> Date = Date.init
    /// The lane (ExtensionRegistry.callXref); rows answer.
    var call: @MainActor (XrayExtensionRule, String, LaneCall) async -> String? = { rule, arg, lane in
        await SettingsHooks.shared.extensionRegistry?.callXref(rule, arg: arg, call: lane)
    }
    /// The registry's rulesVersion; a change while a call ran (reload, disable) makes its answer "unavailable".
    var version: @MainActor () -> Int? = { SettingsHooks.shared.extensionRegistry?.rulesVersion }
    /// Sleeps the rule's timeout (rows answer at once or never).
    var sleep: @MainActor (Int) async -> Void = { s in try? await Task.sleep(nanoseconds: UInt64(s) * 1_000_000_000) }

    private(set) var flying: [(key: Key, lane: LaneCall, task: Task<XrayExtensionRefs.Outcome, Never>)] = []
    private var kept: [Key: (at: Date, outcome: XrayExtensionRefs.Outcome)] = [:]
    private var order: [Key] = []
    var keptCount: Int { kept.count }

    private static let windows = NSMapTable<NSWindow, XrayExtensionCalls>.weakToStrongObjects()

    /// The window's calls, made on first use; nil with no window.
    static func of(_ w: NSWindow?) -> XrayExtensionCalls? {
        guard let w else { return nil }
        if let c = windows.object(forKey: w) { return c }
        let c = XrayExtensionCalls()
        windows.setObject(c, forKey: w)
        return c
    }

    /// The answer for `m`: kept, joined, or a new call on the lane.
    func outcome(_ m: XrayExtensionRefs.Match, dir: String?, session: String?) -> Task<XrayExtensionRefs.Outcome, Never> {
        let arg = XrayExtensionRefs.arg(m, dir: dir, session: session)
        let key = Key(ext: m.rule.extensionID, rule: m.rule.id, arg: arg)
        if let k = kept[key] {
            if now().timeIntervalSince(k.at) < (k.outcome.isFailure ? Self.keepFailed : Self.keep) {
                order.removeAll { $0 == key }
                order.append(key)
                let o = k.outcome
                return Task { o }
            }
            forget(key)
        }
        if let f = flying.first(where: { $0.key == key }) { return f.task }
        if flying.count >= Self.maxInFlight, let old = flying.first {
            flying.removeFirst()
            old.lane.drop()
        }
        let lane = LaneCall(), rule = m.rule, started = version()
        let task = Task { @MainActor [weak self] () -> XrayExtensionRefs.Outcome in
            guard let self else { return .unavailable }
            let raw = await self.race(rule, arg, lane)
            self.flying.removeAll { $0.lane === lane }
            let o: XrayExtensionRefs.Outcome
            if self.version() != started || started == nil {
                o = .unavailable
            } else if let why = lane.failed {
                o = .failed(why == XrayExtensionRefs.timedOut ? why : "The extension failed: " + OutsideText.shown(why, max: 160))
            } else if lane.isDropped {
                return .failed(XrayExtensionRefs.dropped)   // not kept: the next ask runs it again
            } else {
                o = XrayExtensionRefs.outcome(raw.flatMap { $0 })
            }
            if o != .unavailable { self.put(key, o) }
            return o
        }
        flying.append((key, lane, task))
        return task
    }

    /// The lane's answer, or nil past the rule's timeout (the call dropped, its failure "timed out"). Never waits on a
    /// lane busy past it: the first of the two to land resumes.
    private func race(_ rule: XrayExtensionRule, _ arg: String, _ lane: LaneCall) async -> String?? {
        @MainActor final class Once { var done = false }
        let once = Once()
        var timer: Task<Void, Never>?
        let r: String?? = await withCheckedContinuation { (k: CheckedContinuation<String??, Never>) in
            Task { @MainActor in
                let s = await self.call(rule, arg, lane)
                guard !once.done else { return }
                once.done = true
                k.resume(returning: .some(s))
            }
            timer = Task { @MainActor in
                await self.sleep(rule.timeout)
                guard !once.done, !Task.isCancelled else { return }
                once.done = true
                lane.fail(XrayExtensionRefs.timedOut)
                lane.drop()
                k.resume(returning: nil)
            }
        }
        timer?.cancel()
        return r
    }

    private func put(_ key: Key, _ o: XrayExtensionRefs.Outcome) {
        forget(key)
        kept[key] = (now(), o)
        order.append(key)
        while order.count > Self.maxKept { forget(order[0]) }
    }

    private func forget(_ key: Key) {
        kept[key] = nil
        order.removeAll { $0 == key }
    }
}

extension XrayExtensionRefs.Outcome {
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}

/// #1569: one extension card's answer, filled when the window's call lands.
@MainActor
final class XrayExtensionCard: ObservableObject {
    let match: XrayExtensionRefs.Match
    @Published private(set) var outcome: XrayExtensionRefs.Outcome?
    private(set) var task: Task<Void, Never>?

    init(_ m: XrayExtensionRefs.Match, calls: XrayExtensionCalls?, dir: String?, session: String?) {
        match = m
        guard let calls else { outcome = .unavailable; return }
        let asked = calls.outcome(m, dir: dir, session: session)
        task = Task { @MainActor [weak self] in
            let o = await asked.value
            self?.outcome = o
        }
    }

    /// The block's lines while reading, for nothing, a failure or a gone extension (a card draws its own fields).
    var note: String? {
        switch outcome {
        case nil: "Reading\u{2026}"
        case .card?: nil
        case .nothing?: "Nothing from \(match.rule.label)"
        case .failed(let why)?: why
        case .unavailable?: XrayExtensionRefs.unavailable
        }
    }
}

extension XrayPanelModel {
    /// #1569 (5.6): an extension ref's card, unpinned (`hover`) or pinned: its header and the handler block; no dch runs.
    func extRef(_ e: XrayRefs.Entry, _ m: XrayExtensionRefs.Match, calls: XrayExtensionCalls?, hover: XrayHover?,
                closed: @escaping @MainActor () -> Void = {}) {
        (refContext, refNote) = (nil, nil)
        let card = XrayExtensionCard(m, calls: calls, dir: cwd(), session: target.name)
        hovering = hover != nil   // #1760: an unpinned card is shown without key
        hoverPromote = { [weak hover] in hover?.promote() }
        defer { (hovering, hoverPromote) = (false, nil) }
        presentRef(AnyView(XrayRefPopover(panel: self, entry: e, complete: true, hover: hover, ext: card)), XrayRefPopover.size, closed)
    }
}

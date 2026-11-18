import Foundation

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

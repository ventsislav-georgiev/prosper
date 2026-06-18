import Foundation

/// One `{argument …}` input slot discovered in a template.
struct ArgumentSpec: Equatable {
    let name: String
    let defaultValue: String?
    /// An argument with no default value is required (the palette must collect it
    /// before insertion).
    var required: Bool { defaultValue == nil }
}

/// Everything the resolver needs from the outside world, injected so the engine
/// stays pure and unit-testable (deterministic clock, no global pasteboard).
struct PlaceholderContext {
    var clipboard: () -> String? = { nil }
    /// 0-based clipboard history accessor for `{clipboard:N}` (0 == most recent).
    var clipboardHistory: (Int) -> String? = { _ in nil }
    var now: () -> Date = { Date() }
    var locale: Locale = .current
    var timeZone: TimeZone = .current
    /// Resolved `{argument name=…}` values, keyed by argument name.
    var arguments: [String: String] = [:]
    /// `{snippet:keyword}` lookup → the embedded snippet's raw template, or nil.
    var snippetByKeyword: (String) -> String? = { _ in nil }
    /// Resolver for placeholders the engine doesn't know natively
    /// (extension-contributed). Returns nil to leave the token literal.
    var custom: (_ name: String, _ raw: String) -> String? = { _, _ in nil }

    init() {}
}

/// Resolves Alfred/Raycast-style dynamic placeholders in a snippet template.
///
/// Syntax: `{name[:spec]}` with optional ` | modifier | …` pipes. `{{` / `}}`
/// emit literal braces. Unknown tokens are routed to `context.custom`; if that
/// also declines, the token is left verbatim.
enum PlaceholderEngine {

    static let maxRecursionDepth = 8

    /// Resolves `template`, returning the expanded text and the caret offset for
    /// the first `{cursor}` token (a UTF-16-agnostic Character offset into the
    /// returned string), or nil when there is no `{cursor}`.
    static func render(_ template: String, _ context: PlaceholderContext)
        -> (text: String, cursorOffset: Int?) {
        var ctx = context
        var cursor: Int?
        let text = render(template, &ctx, depth: 0, cursor: &cursor)
        return (text, cursor)
    }

    /// The `{argument …}` slots a template declares, de-duplicated by name in
    /// first-seen order. Drives the palette's pre-insertion prompt.
    static func arguments(in template: String) -> [ArgumentSpec] {
        var seen = Set<String>()
        var specs: [ArgumentSpec] = []
        forEachToken(template) { raw in
            let (name, spec, _) = split(raw)
            guard name.lowercased() == "argument" else { return }
            let parsed = parseArgument(spec)
            guard !seen.contains(parsed.name) else { return }
            seen.insert(parsed.name)
            specs.append(parsed)
        }
        return specs
    }

    /// Set of built-in placeholder names (everything else is a candidate for an
    /// extension-contributed custom placeholder).
    static let builtinNames: Set<String> = [
        "cursor", "clipboard", "date", "time", "datetime", "uuid", "argument", "snippet",
    ]

    /// The non-built-in (`custom`) tokens a template references, de-duplicated by
    /// their raw body in first-seen order. The caller pre-resolves these (e.g. via
    /// the extension registry) and feeds the results back through `context.custom`.
    /// Each entry's `raw` matches what `render` passes to `context.custom`.
    static func customTokens(in template: String) -> [(name: String, raw: String)] {
        var out: [(name: String, raw: String)] = []
        var seen = Set<String>()
        forEachToken(template) { raw in
            let (name, _, _) = split(raw)
            guard !builtinNames.contains(name.lowercased()), !seen.contains(raw) else { return }
            seen.insert(raw)
            out.append((name, raw))
        }
        return out
    }

    // MARK: - Core

    private static func render(_ template: String, _ ctx: inout PlaceholderContext,
                               depth: Int, cursor: inout Int?) -> String {
        var out = ""
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{" {
                // Escaped literal brace.
                if i + 1 < chars.count, chars[i + 1] == "{" {
                    out.append("{"); i += 2; continue
                }
                // Find the closing brace.
                guard let close = chars[(i + 1)...].firstIndex(of: "}") else {
                    out.append(c); i += 1; continue
                }
                let raw = String(chars[(i + 1)..<close])
                resolve(raw, into: &out, &ctx, depth: depth, cursor: &cursor)
                i = close + 1
                continue
            }
            if c == "}", i + 1 < chars.count, chars[i + 1] == "}" {
                out.append("}"); i += 2; continue
            }
            out.append(c); i += 1
        }
        return out
    }

    private static func resolve(_ raw: String, into out: inout String,
                                _ ctx: inout PlaceholderContext, depth: Int,
                                cursor: inout Int?) {
        let (name, spec, modifiers) = split(raw)
        let lower = name.lowercased()

        // {cursor} carries no text; it marks the final caret position (first wins).
        if lower == "cursor" {
            if cursor == nil { cursor = out.count }
            return
        }

        guard var value = baseValue(name: lower, spec: spec, &ctx, depth: depth) else {
            // Not a built-in: try the custom resolver, else leave the token literal.
            if let custom = ctx.custom(name, raw) {
                out += applyModifiers(custom, modifiers)
            } else {
                out += "{\(raw)}"
            }
            return
        }
        value = applyModifiers(value, modifiers)
        out += value
    }

    /// Resolves a built-in placeholder to its (pre-modifier) string, or nil when
    /// the name is not a built-in.
    private static func baseValue(name: String, spec: String,
                                  _ ctx: inout PlaceholderContext, depth: Int) -> String? {
        switch name {
        case "clipboard":
            if let n = Int(spec.trimmingCharacters(in: .whitespaces)), n >= 0 {
                return ctx.clipboardHistory(n) ?? ""
            }
            return ctx.clipboard() ?? ""
        case "date":
            return formatDate(spec: spec, ctx: ctx, kind: .date)
        case "time":
            return formatDate(spec: spec, ctx: ctx, kind: .time)
        case "datetime":
            return formatDate(spec: spec, ctx: ctx, kind: .dateTime)
        case "uuid":
            return UUID().uuidString
        case "argument":
            let parsed = parseArgument(spec)
            return ctx.arguments[parsed.name] ?? parsed.defaultValue ?? ""
        case "snippet":
            return embeddedSnippet(keyword: spec.trimmingCharacters(in: .whitespaces),
                                   &ctx, depth: depth)
        default:
            return nil
        }
    }

    private static func embeddedSnippet(keyword: String, _ ctx: inout PlaceholderContext,
                                        depth: Int) -> String {
        guard depth < maxRecursionDepth, !keyword.isEmpty,
              let template = ctx.snippetByKeyword(keyword) else { return "" }
        var nestedCursor: Int? = nil  // an embedded snippet's {cursor} is ignored
        return render(template, &ctx, depth: depth + 1, cursor: &nestedCursor)
    }

    // MARK: - Token parsing

    /// Splits a raw token body into (name, spec, modifiers). `name:spec | a | b`.
    private static func split(_ raw: String) -> (name: String, spec: String, modifiers: [String]) {
        let segments = raw.components(separatedBy: "|")
        let head = segments[0]
        let modifiers = segments.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Name is up to the first ':'; the remainder is the spec.
        if let colon = head.firstIndex(of: ":") {
            let name = String(head[head.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let spec = String(head[head.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return (name, spec, modifiers)
        }
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        // A bare `date +1d` (no colon) still needs its offset treated as spec.
        if let space = trimmed.firstIndex(of: " ") {
            let name = String(trimmed[trimmed.startIndex..<space])
            let spec = String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            return (name, spec, modifiers)
        }
        return (trimmed, "", modifiers)
    }

    private static func parseArgument(_ spec: String) -> ArgumentSpec {
        // Supports: empty, `name="x"`, `default="y"`, `name="x" default="y"`.
        var name = "argument"
        var defaultValue: String?
        var sawName = false
        for (key, val) in keyValuePairs(spec) {
            switch key.lowercased() {
            case "name": name = val; sawName = true
            case "default": defaultValue = val
            default: break
            }
        }
        // A bare `{argument}` with no name is an unnamed required slot.
        if !sawName, defaultValue == nil, spec.trimmingCharacters(in: .whitespaces).isEmpty {
            return ArgumentSpec(name: "argument", defaultValue: nil)
        }
        return ArgumentSpec(name: name, defaultValue: defaultValue)
    }

    /// Parses `key="value"` (or `key=value`) pairs from a spec string.
    private static func keyValuePairs(_ spec: String) -> [(String, String)] {
        var pairs: [(String, String)] = []
        let chars = Array(spec)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i] == " " { i += 1 }
            var key = ""
            while i < chars.count, chars[i] != "=", chars[i] != " " { key.append(chars[i]); i += 1 }
            guard i < chars.count, chars[i] == "=" else { break }
            i += 1 // skip '='
            var value = ""
            if i < chars.count, chars[i] == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" { value.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 } // skip closing quote
            } else {
                while i < chars.count, chars[i] != " " { value.append(chars[i]); i += 1 }
            }
            if !key.isEmpty { pairs.append((key, value)) }
        }
        return pairs
    }

    // MARK: - Modifiers

    private static func applyModifiers(_ value: String, _ modifiers: [String]) -> String {
        var v = value
        for m in modifiers {
            switch m.lowercased() {
            case "uppercase": v = v.uppercased()
            case "lowercase": v = v.lowercased()
            case "capitalize": v = v.capitalized
            case "trim": v = v.trimmingCharacters(in: .whitespacesAndNewlines)
            case "percent-encode", "percentencode", "url-encode", "urlencode":
                var allowed = CharacterSet.alphanumerics
                allowed.insert(charactersIn: "-._~")
                v = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            default:
                break  // unknown modifier: leave the value unchanged
            }
        }
        return v
    }

    // MARK: - Dates

    private enum DateKind { case date, time, dateTime }

    private static func formatDate(spec: String, ctx: PlaceholderContext, kind: DateKind) -> String {
        let (style, offset) = parseDateSpec(spec)
        var date = ctx.now()
        if let offset { date = applyOffset(offset, to: date, timeZone: ctx.timeZone) }

        let df = DateFormatter()
        df.locale = ctx.locale
        df.timeZone = ctx.timeZone

        if let style {
            // Custom format string (anything that isn't a named style keyword).
            df.dateFormat = style
            return df.string(from: date)
        }
        switch kind {
        case .date:
            df.dateStyle = .medium; df.timeStyle = .none
        case .time:
            df.dateStyle = .none; df.timeStyle = .short
        case .dateTime:
            df.dateStyle = .medium; df.timeStyle = .short
        }
        return df.string(from: date)
    }

    /// Splits a date spec into (formatOrStyle, offset). Named styles map to a
    /// `dateFormat`-equivalent; an offset is any token matching `[+-]N[unit]`.
    private static func parseDateSpec(_ spec: String) -> (style: String?, offset: String?) {
        var styleTokens: [String] = []
        var offset: String?
        for token in spec.split(separator: " ").map(String.init) {
            if isOffsetToken(token) {
                offset = token
            } else {
                styleTokens.append(token)
            }
        }
        let styleRaw = styleTokens.joined(separator: " ")
        switch styleRaw.lowercased() {
        case "": return (nil, offset)
        case "short": return ("M/d/yy", offset)
        case "medium": return (nil, offset)            // default medium style
        case "long": return ("MMMM d, yyyy", offset)
        case "full": return ("EEEE, MMMM d, yyyy", offset)
        default: return (styleRaw, offset)             // treat as a custom format
        }
    }

    private static func isOffsetToken(_ token: String) -> Bool {
        guard token.count >= 3, let first = token.first, first == "+" || first == "-",
              let last = token.last, "smhdwMy".contains(last) else { return false }
        let middle = token.dropFirst().dropLast()
        return !middle.isEmpty && middle.allSatisfy { $0.isNumber }
    }

    private static func applyOffset(_ token: String, to date: Date, timeZone: TimeZone) -> Date {
        guard let unit = token.last, let sign = token.first else { return date }
        let magnitude = Int(token.dropFirst().dropLast()) ?? 0
        let amount = (sign == "-" ? -1 : 1) * magnitude
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var comps = DateComponents()
        switch unit {
        case "s": comps.second = amount
        case "m": comps.minute = amount
        case "h": comps.hour = amount
        case "d": comps.day = amount
        case "w": comps.day = amount * 7
        case "M": comps.month = amount
        case "y": comps.year = amount
        default: return date
        }
        return calendar.date(byAdding: comps, to: date) ?? date
    }

    // MARK: - Token iteration (for `arguments(in:)`)

    private static func forEachToken(_ template: String, _ body: (String) -> Void) {
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            if chars[i] == "{" {
                if i + 1 < chars.count, chars[i + 1] == "{" { i += 2; continue }
                if let close = chars[(i + 1)...].firstIndex(of: "}") {
                    body(String(chars[(i + 1)..<close]))
                    i = close + 1
                    continue
                }
            }
            i += 1
        }
    }
}

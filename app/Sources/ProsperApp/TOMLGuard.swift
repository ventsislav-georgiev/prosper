import Foundation
import TOMLDecoder

/// Pre-scan every TOML text runs before `TOMLDecoder` sees it. dduan/TOMLDecoder
/// recurses without a depth limit, so ~3000 nested inline tables or ~5000 nested
/// arrays / dotted-key segments overflow the stack and SIGSEGV Prosper (QA #107, #125).
/// One pass over the bytes, no TOML parsing: a rejected text takes each call
/// site's existing malformed-TOML path.
enum TOMLGuard {
    static let maxBytes = 1 << 20
    static let maxDepth = 64

    struct Rejected: Error, CustomStringConvertible {
        var description: String {
            "TOML rejected: over \(TOMLGuard.maxBytes) bytes, nested deeper than \(TOMLGuard.maxDepth), or an unterminated string"
        }
    }

    /// False when the text is over `maxBytes`, has a string the parser would call
    /// unterminated, or when its parser frames in flight exceed `maxDepth`. Frames are
    /// counted the way `Parser.parseKeyValue` recurses: one per open `[` / `{`, plus one
    /// per dot of every key whose value is still open (a dotted key's frames stay on the
    /// stack while its value nests), plus the dots of the key being read. Unclosed nesting
    /// counts. Dots after `=` and inside arrays are values (floats, dates) and cost nothing.
    /// Strings and comments end exactly where TOMLDecoder's lexer ends them, so the two
    /// never disagree about which brackets are code (QA #125).
    static func accepts(_ text: String) -> Bool {
        let bytes = text.utf8
        guard bytes.count <= maxBytes else { return false }
        let b = Array(bytes)
        let n = b.count
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), newline = UInt8(ascii: "\n")
        // `base`: frames at the start of the innermost open container, what `,` and a
        // newline fall back to. `open` keeps the enclosing base and whether it is an array.
        var frames = 0, base = 0, inValue = false, i = 0
        var open: [(base: Int, isArray: Bool)] = []

        /// End (exclusive) of the string starting at `s`, nil when unterminated.
        /// Mirrors TOMLDecoder Parser.scanString (Parsing/Parser.swift :170-299).
        func stringEnd(_ s: Int) -> Int? {
            let q = b[s], basic = q == quote
            if basic ? s + 3 < n : s + 3 <= n, b[s + 1] == q, b[s + 2] == q {
                // Ends at the last `"""` of a quote run; for basic strings only when the byte
                // before it is not a backslash. No escape pairs: `x\\"""` does not close.
                var k = s + 3
                while k < n {
                    if k + 3 <= n, b[k] == q, b[k + 1] == q, b[k + 2] == q, k + 3 == n || b[k + 3] != q {
                        if basic && b[k - 1] == backslash { k += 1; continue }
                        return k + 3
                    }
                    k += 1
                }
                return nil
            }
            var k = s + 1
            while k < n && b[k] != q && b[k] != newline {
                k += (basic && b[k] == backslash) ? 2 : 1
            }
            return k < n && b[k] == q ? k + 1 : nil
        }

        while i < n {
            let c = b[i]
            switch c {
            case UInt8(ascii: "#"):
                while i < n && b[i] != newline { i += 1 }
                continue
            case quote, UInt8(ascii: "'"):
                guard let end = stringEnd(i) else { return false }
                i = end
                continue
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                open.append((base, c == UInt8(ascii: "[")))
                frames += 1
                if frames > maxDepth { return false }
                base = frames
                inValue = c == UInt8(ascii: "[")
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                if let outer = open.popLast() { frames = outer.base; base = outer.base }
                inValue = true
            case UInt8(ascii: "."):
                if !inValue {
                    frames += 1
                    if frames > maxDepth { return false }
                }
            case UInt8(ascii: "="):
                inValue = true
            case newline, UInt8(ascii: ","):
                frames = base
                inValue = open.last?.isArray ?? false
            default:
                break
            }
            i += 1
        }
        return true
    }
}

extension TOMLDecoder {
    /// `decode(_:from:)` behind `TOMLGuard`: a rejected text throws like a parse error.
    func decodeGuarded<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard TOMLGuard.accepts(text) else { throw TOMLGuard.Rejected() }
        return try decode(type, from: text)
    }
}

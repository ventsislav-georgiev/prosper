import Foundation
import TOMLDecoder

/// Pre-scan every TOML text runs before `TOMLDecoder` sees it. dduan/TOMLDecoder
/// recurses without a depth limit, so ~3000 nested inline tables or ~5000 nested
/// arrays / dotted-key segments overflow the stack and SIGSEGV Prosper (QA #107).
/// One pass over the bytes, no TOML parsing: a rejected text takes each call
/// site's existing malformed-TOML path.
enum TOMLGuard {
    static let maxBytes = 1 << 20
    static let maxDepth = 64

    struct Rejected: Error, CustomStringConvertible {
        var description: String {
            "TOML rejected: over \(TOMLGuard.maxBytes) bytes or nested deeper than \(TOMLGuard.maxDepth)"
        }
    }

    /// False when the text is over `maxBytes`, when the running nesting of `[` / `{`
    /// outside strings and comments exceeds `maxDepth` (unclosed nesting counts), or
    /// when one key has more than `maxDepth` dots outside strings (dotted keys nest
    /// tables too). The dot count resets at newline, `=`, and `,`, so a float or a
    /// date value contributes at most one or two.
    static func accepts(_ text: String) -> Bool {
        let bytes = text.utf8
        guard bytes.count <= maxBytes else { return false }
        let b = Array(bytes)
        let n = b.count
        let quote = UInt8(ascii: "\""), apos = UInt8(ascii: "'"), backslash = UInt8(ascii: "\\")
        let newline = UInt8(ascii: "\n")
        var depth = 0, dots = 0, i = 0

        func hasTriple(_ q: UInt8, at k: Int) -> Bool {
            k + 2 < n && b[k] == q && b[k + 1] == q && b[k + 2] == q
        }

        while i < n {
            let c = b[i]
            switch c {
            case UInt8(ascii: "#"):
                while i < n && b[i] != newline { i += 1 }
                continue
            case quote, apos:
                let basic = c == quote
                if hasTriple(c, at: i) {
                    // Multi-line string: runs to the next triple quote (up to two
                    // extra quotes before it belong to the content).
                    i += 3
                    while i < n && !hasTriple(c, at: i) {
                        i += (basic && b[i] == backslash) ? 2 : 1
                    }
                    i += 3
                    while i < n && b[i] == c { i += 1 }
                } else {
                    // Single-line string: ends at its quote or the line end.
                    i += 1
                    while i < n && b[i] != c && b[i] != newline {
                        i += (basic && b[i] == backslash) ? 2 : 1
                    }
                    if i < n && b[i] == c { i += 1 }
                }
                continue
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > maxDepth { return false }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth = max(0, depth - 1)
            case UInt8(ascii: "."):
                dots += 1
                if dots > maxDepth { return false }
            case newline, UInt8(ascii: "="), UInt8(ascii: ","):
                dots = 0
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

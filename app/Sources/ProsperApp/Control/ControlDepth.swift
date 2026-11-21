import Foundation

/// #1819: ControlJSON decodes recursively, one stack frame chain per nesting level, and requests decode on a small
/// cooperative-pool stack; a few KB of `[[[[...` overflowed it. Callers refuse anything deeper than `limit` before
/// any decoder sees it.
enum ControlDepth {
    static let limit = 32

    /// Whether `bytes` nest `[` and `{` deeper than `limit`, counting only outside JSON strings (backslash escapes
    /// honoured). One pass, no allocation, no recursion. A stray closer never takes the count below zero, so it
    /// cannot buy extra depth for what follows.
    static func exceeds<C: Collection>(_ bytes: C, limit: Int = limit) -> Bool where C.Element == UInt8 {
        var depth = 0, inString = false, escaped = false
        for b in bytes {
            if inString {
                if escaped { escaped = false } else if b == UInt8(ascii: "\\") { escaped = true } else if b == UInt8(ascii: "\"") { inString = false }
            } else if b == UInt8(ascii: "\"") {
                inString = true
            } else if b == UInt8(ascii: "[") || b == UInt8(ascii: "{") {
                depth += 1
                if depth > limit { return true }
            } else if (b == UInt8(ascii: "]") || b == UInt8(ascii: "}")) && depth > 0 {
                depth -= 1
            }
        }
        return false
    }

    static var message: String { "bad request: JSON nested deeper than \(limit) levels" }
}

import CryptoKit
import Foundation

/// #870: an order- and format-preserving JSON document for Claude Code's `settings.json`.
///
/// Edits are byte splices on the original text: every byte outside the touched span stays exactly
/// as the user (or Claude Code) wrote it. Foundation's `JSONSerialization` reorders keys and would
/// turn each apply into a whole-file diff in the user's dotfiles. Strict RFC 8259 only: comments,
/// trailing commas and duplicate keys are refused with a reason, never "fixed" on rewrite.
/// Plain value type, no isolation.
struct OrderedJSON: Sendable {
    indirect enum Value: Sendable {
        case object([Member])
        case array([Node])
        case string(String)
        case number(String) // the lexeme as written, so an untouched number keeps its text
        case bool(Bool)
        case null
    }

    struct Node: Sendable {
        var value: Value
        var range: Range<Int>
    }

    struct Member: Sendable {
        var key: String
        var start: Int // offset of the key's opening quote
        var value: Node
        var range: Range<Int> { start..<value.range.upperBound }
    }

    /// Never carries document content: a reason and a line number only.
    struct ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        var line: Int
        var reason: String
        var description: String { "\(reason) (line \(line))" }
    }

    let bytes: [UInt8]
    let root: Node

    init(_ text: String) throws(ParseError) {
        try self.init(bytes: Array(text.utf8))
    }

    init(bytes: [UInt8]) throws(ParseError) {
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw ParseError(line: 1, reason: "the file is not UTF-8 text")
        }
        var parser = Parser(b: bytes)
        let root = try parser.value(depth: 0)
        try parser.skipWhitespace()
        if parser.i < bytes.count { throw parser.fail("unexpected text after the JSON value") }
        self.bytes = bytes
        self.root = root
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }
    var newline: String { OrderedJSON.newline(of: bytes) }

    static func newline(of bytes: [UInt8]) -> String {
        for i in bytes.indices.dropFirst() where bytes[i] == 0x0A && bytes[i - 1] == 0x0D { return "\r\n" }
        return "\n"
    }

    // MARK: lookup

    func node(at path: [String]) -> Node? {
        var node = root
        for key in path {
            guard case .object(let members) = node.value, let m = members.first(where: { $0.key == key }) else { return nil }
            node = m.value
        }
        return node
    }

    func raw(_ node: Node) -> String { String(decoding: bytes[node.range], as: UTF8.self) }

    // MARK: edits (each returns the new document text; the caller re-parses)

    /// Adds `key: value` as the last member of the object at `path`.
    func insertingMember(_ key: String, value: Value, intoObjectAt path: [String]) -> [UInt8] {
        guard let container = node(at: path) else { return bytes }
        return insertingChild(into: container) { indent, pretty in
            OrderedJSON.quote(key) + ": " + render(value, indent: indent, pretty: pretty)
        }
    }

    /// Adds `value` as the last element of the array at `path`.
    func appendingElement(_ value: Value, toArrayAt path: [String]) -> [UInt8] {
        guard let container = node(at: path) else { return bytes }
        return insertingChild(into: container) { indent, pretty in render(value, indent: indent, pretty: pretty) }
    }

    /// Replaces the value at `path` with `value`, rendered at that member's indentation.
    func replacingValue(at path: [String], with value: Value) -> [UInt8] {
        guard let old = node(at: path) else { return bytes }
        let pretty = bytes.contains(0x0A)
        return splice(old.range, with: render(value, indent: lineIndent(old.range.lowerBound), pretty: pretty))
    }

    /// Replaces the value at `path` with raw text recorded earlier (restores it byte for byte).
    func replacingValue(at path: [String], withRaw raw: String) -> [UInt8] {
        guard let old = node(at: path) else { return bytes }
        return splice(old.range, with: raw)
    }

    /// Removes the member `path.last` from the object at `path.dropLast()`.
    func removingMember(at path: [String]) -> [UInt8] {
        guard let key = path.last, let container = node(at: Array(path.dropLast())),
              case .object(let members) = container.value,
              let index = members.firstIndex(where: { $0.key == key }) else { return bytes }
        return removingChild(index, of: container)
    }

    func removingElement(_ index: Int, fromArrayAt path: [String]) -> [UInt8] {
        guard let container = node(at: path) else { return bytes }
        return removingChild(index, of: container)
    }

    // MARK: splice machinery

    private func childRanges(_ node: Node) -> [Range<Int>] {
        switch node.value {
        case .object(let members): return members.map(\.range)
        case .array(let elements): return elements.map(\.range)
        default: return []
        }
    }

    /// Insert after the last child, re-using the separator whitespace that precedes it, so the
    /// removal of exactly that span (see `removingChild`) restores the input byte for byte.
    private func insertingChild(into container: Node, _ make: (_ indent: String, _ pretty: Bool) -> String) -> [UInt8] {
        let kids = childRanges(container)
        if let last = kids.last {
            var sep = kids.count == 1 ? container.range.lowerBound + 1 : kids[kids.count - 2].upperBound
            if kids.count > 1 {
                while sep < last.lowerBound, bytes[sep] != UInt8(ascii: ",") { sep += 1 }
                sep += 1
            }
            let ws = String(decoding: bytes[sep..<last.lowerBound], as: UTF8.self)
            let pretty = ws.contains("\n")
            let indent = pretty ? lineIndent(last.lowerBound) : ""
            return splice(last.upperBound..<last.upperBound, with: "," + ws + make(indent, pretty))
        }
        let inner = container.range.lowerBound + 1..<container.range.upperBound - 1
        guard bytes.contains(0x0A) else { return splice(inner, with: make("", false)) }
        let nl = newline
        let parent = lineIndent(container.range.lowerBound)
        let child = parent + indentUnit
        return splice(inner, with: nl + child + make(child, true) + nl + parent)
    }

    /// Inverse of `insertingChild`. A container emptied by a removal is written `{}` / `[]`.
    /// shortcut: inner whitespace of an emptied container is not restored, so a user's `[ ]`
    /// round-trips as `[]`; upgrade by recording the inner text if a fixture ever needs it.
    private func removingChild(_ index: Int, of container: Node) -> [UInt8] {
        let kids = childRanges(container)
        guard kids.indices.contains(index) else { return bytes }
        if kids.count == 1 { return splice(container.range.lowerBound + 1..<container.range.upperBound - 1, with: "") }
        if index == 0 { return splice(kids[0].lowerBound..<kids[1].lowerBound, with: "") }
        return splice(kids[index - 1].upperBound..<kids[index].upperBound, with: "")
    }

    private func splice(_ range: Range<Int>, with text: String) -> [UInt8] {
        Array(bytes[..<range.lowerBound]) + Array(text.utf8) + Array(bytes[range.upperBound...])
    }

    /// Leading spaces/tabs of the line that holds `offset`.
    func lineIndent(_ offset: Int) -> String {
        var start = min(offset, bytes.count)
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// The file's own indent step, read off the root's first member; 2 spaces when it has none.
    var indentUnit: String {
        if case .object(let members) = root.value, let first = members.first {
            let indent = lineIndent(first.start)
            if !indent.isEmpty { return indent }
        }
        return "  "
    }

    private func render(_ value: Value, indent: String, pretty: Bool) -> String {
        OrderedJSON.render(value, indent: indent, unit: indentUnit, newline: newline, pretty: pretty)
    }

    // MARK: rendering, equality, hashing

    static func render(_ value: Value, indent: String = "", unit: String = "  ", newline nl: String = "\n", pretty: Bool = true) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let lexeme): return lexeme
        case .string(let s): return quote(s)
        case .array(let elements):
            if elements.isEmpty { return "[]" }
            let items = elements.map { render($0.value, indent: indent + unit, unit: unit, newline: nl, pretty: pretty) }
            return pretty
                ? "[" + nl + items.map { indent + unit + $0 }.joined(separator: "," + nl) + nl + indent + "]"
                : "[" + items.joined(separator: ", ") + "]"
        case .object(let members):
            if members.isEmpty { return "{}" }
            let items = members.map { quote($0.key) + ": " + render($0.value.value, indent: indent + unit, unit: unit, newline: nl, pretty: pretty) }
            return pretty
                ? "{" + nl + items.map { indent + unit + $0 }.joined(separator: "," + nl) + nl + indent + "}"
                : "{" + items.joined(separator: ", ") + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    /// Sorted keys, compact, numbers by value: two values are deep-equal iff their canonical
    /// forms are equal. Ownership in Prosper's state is this form's SHA-256 (errata A10).
    static func canonical(_ value: Value) -> String {
        switch value {
        case .null, .bool, .string: return render(value, pretty: false)
        case .number(let lexeme):
            guard let d = Double(lexeme) else { return lexeme }
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case .array(let elements): return "[" + elements.map { canonical($0.value) }.joined(separator: ",") + "]"
        case .object(let members):
            return "{" + members.sorted { $0.key < $1.key }.map { quote($0.key) + ":" + canonical($0.value.value) }.joined(separator: ",") + "}"
        }
    }

    static func hash(_ value: Value) -> String { sha256(Array(canonical(value).utf8)) }

    static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Parser

private struct Parser {
    let b: [UInt8]
    var i = 0
    static let maxDepth = 256

    func fail(_ reason: String, at offset: Int? = nil) -> OrderedJSON.ParseError {
        let end = min(offset ?? i, b.count)
        return OrderedJSON.ParseError(line: b[..<end].reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) }, reason: reason)
    }

    mutating func skipWhitespace() throws(OrderedJSON.ParseError) {
        while i < b.count {
            switch b[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            case UInt8(ascii: "/"): throw fail("comments are not allowed in JSON; Prosper will not rewrite this file")
            default: return
            }
        }
    }

    mutating func value(depth: Int) throws(OrderedJSON.ParseError) -> OrderedJSON.Node {
        guard depth < Parser.maxDepth else { throw fail("nesting is too deep") }
        try skipWhitespace()
        guard i < b.count else { throw fail("unexpected end of file") }
        let start = i
        switch b[i] {
        case UInt8(ascii: "{"):
            i += 1
            var members: [OrderedJSON.Member] = []
            var keys = Set<String>()
            try skipWhitespace()
            if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .init(value: .object([]), range: start..<i) }
            while true {
                try skipWhitespace()
                guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw fail("expected a key (a trailing comma is not allowed)") }
                let keyStart = i
                let key = try string()
                guard keys.insert(key).inserted else { throw fail("duplicate key in one object; Prosper will not rewrite this file", at: keyStart) }
                try skipWhitespace()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                i += 1
                members.append(.init(key: key, start: keyStart, value: try value(depth: depth + 1)))
                try skipWhitespace()
                guard i < b.count else { throw fail("unexpected end of file") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "}") { i += 1; break }
                throw fail("expected ',' or '}'")
            }
            return .init(value: .object(members), range: start..<i)
        case UInt8(ascii: "["):
            i += 1
            var elements: [OrderedJSON.Node] = []
            try skipWhitespace()
            if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .init(value: .array([]), range: start..<i) }
            while true {
                try skipWhitespace()
                if i < b.count, b[i] == UInt8(ascii: "]") { throw fail("a trailing comma is not allowed") }
                elements.append(try value(depth: depth + 1))
                try skipWhitespace()
                guard i < b.count else { throw fail("unexpected end of file") }
                if b[i] == UInt8(ascii: ",") { i += 1; continue }
                if b[i] == UInt8(ascii: "]") { i += 1; break }
                throw fail("expected ',' or ']'")
            }
            return .init(value: .array(elements), range: start..<i)
        case UInt8(ascii: "\""):
            return .init(value: .string(try string()), range: start..<i)
        case UInt8(ascii: "t"): try literal("true"); return .init(value: .bool(true), range: start..<i)
        case UInt8(ascii: "f"): try literal("false"); return .init(value: .bool(false), range: start..<i)
        case UInt8(ascii: "n"): try literal("null"); return .init(value: .null, range: start..<i)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            try number()
            return .init(value: .number(String(decoding: b[start..<i], as: UTF8.self)), range: start..<i)
        default:
            throw fail("invalid JSON")
        }
    }

    private mutating func literal(_ word: String) throws(OrderedJSON.ParseError) {
        let w = Array(word.utf8)
        guard i + w.count <= b.count, Array(b[i..<i + w.count]) == w else { throw fail("invalid JSON") }
        i += w.count
    }

    private func isDigit(_ at: Int) -> Bool { at < b.count && b[at] >= 0x30 && b[at] <= 0x39 }

    private mutating func number() throws(OrderedJSON.ParseError) {
        if b[i] == UInt8(ascii: "-") { i += 1 }
        guard isDigit(i) else { throw fail("invalid number") }
        if b[i] == UInt8(ascii: "0") { i += 1 } else { while isDigit(i) { i += 1 } }
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1
            guard isDigit(i) else { throw fail("invalid number") }
            while isDigit(i) { i += 1 }
        }
        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            i += 1
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            guard isDigit(i) else { throw fail("invalid number") }
            while isDigit(i) { i += 1 }
        }
    }

    private mutating func hex4() throws(OrderedJSON.ParseError) -> UInt32 {
        guard i + 4 <= b.count, let v = UInt32(String(decoding: b[i..<i + 4], as: UTF8.self), radix: 16) else {
            throw fail("invalid \\u escape")
        }
        i += 4
        return v
    }

    private mutating func string() throws(OrderedJSON.ParseError) -> String {
        i += 1 // opening quote
        var out: [UInt8] = []
        while true {
            guard i < b.count else { throw fail("unterminated string") }
            let c = b[i]
            if c == UInt8(ascii: "\"") { i += 1; break }
            if c < 0x20 { throw fail("control character in a string") }
            if c != UInt8(ascii: "\\") { out.append(c); i += 1; continue }
            i += 1
            guard i < b.count else { throw fail("unterminated string") }
            let e = b[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var v = try hex4()
                if (0xD800...0xDBFF).contains(v), i + 1 < b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                    i += 2
                    let low = try hex4()
                    guard (0xDC00...0xDFFF).contains(low) else { throw fail("invalid surrogate pair") }
                    v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)
                }
                guard let scalar = Unicode.Scalar(v) else { throw fail("invalid \\u escape") }
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            default:
                throw fail("invalid escape")
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

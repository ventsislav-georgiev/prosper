import Foundation

/// #870 (spec 2.2): a marker-delimited text block owned by one (extension, piece).
/// Insert and remove are exact inverses, so a removal leaves the file byte-identical to what it
/// was before the insert. The file's own line ending (LF or CRLF) and a missing final newline are
/// kept as found. Plain value type, no isolation.
enum ManagedTextBlock {
    enum Syntax: Sendable { case markdown, hash }

    /// B-INFO-7: the file types whose comment syntax a block's markers use. Every other type is
    /// refused at plan time: a `#` marker would break a .json, .lua or .html file.
    static let markdownExtensions: Set<String> = ["md", "markdown"]
    static let hashExtensions: Set<String> = ["sh", "bash", "zsh", "fish", "conf", "toml", "yaml", "yml"]

    static func syntax(for url: URL) -> Syntax? {
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }
        return hashExtensions.contains(ext) ? .hash : nil
    }

    static func begin(owner: String, piece: String, version: String, syntax: Syntax) -> String {
        let core = ">>> prosper:\(owner):\(piece) v\(version) · managed by Prosper, edits show as drift >>>"
        return syntax == .markdown ? "<!-- \(core) -->" : "# \(core)"
    }

    static func end(owner: String, piece: String, syntax: Syntax) -> String {
        let core = "<<< prosper:\(owner):\(piece) <<<"
        return syntax == .markdown ? "<!-- \(core) -->" : "# \(core)"
    }

    /// The block as "\n"-joined lines with no final newline. Trailing newlines of the body are dropped.
    static func render(owner: String, piece: String, version: String, body: String, syntax: Syntax) -> String {
        var body = body.replacingOccurrences(of: "\r\n", with: "\n")
        while body.hasSuffix("\n") { body.removeLast() }
        return [begin(owner: owner, piece: piece, version: version, syntax: syntax), body, end(owner: owner, piece: piece, syntax: syntax)]
            .joined(separator: "\n")
    }

    /// A body that could forge or break another block's markers is refused.
    static func bodyIsValid(_ body: String) -> Bool {
        !body.contains(">>> prosper:") && !body.contains("<<< prosper:")
    }

    enum Found: Equatable, Sendable {
        case absent
        case present(begin: Int, end: Int) // line indexes, inclusive
        case corrupt(lines: [Int]) // 1-based line numbers of the stray markers
    }

    static func find(owner: String, piece: String, in bytes: [UInt8]) -> Found {
        let lines = Lines(bytes)
        let beginTag = ">>> prosper:\(owner):\(piece) "
        let endTag = "<<< prosper:\(owner):\(piece) <<<"
        var begins: [Int] = []
        var ends: [Int] = []
        for n in 0..<lines.count {
            let text = lines.text(n)
            guard text.hasPrefix("<!--") || text.hasPrefix("#") else { continue }
            if text.contains(beginTag) { begins.append(n) }
            if text.contains(endTag) { ends.append(n) }
        }
        if begins.isEmpty, ends.isEmpty { return .absent }
        if begins.count == 1, ends.count == 1, ends[0] > begins[0] { return .present(begin: begins[0], end: ends[0]) }
        return .corrupt(lines: (begins + ends).sorted().map { $0 + 1 })
    }

    /// The on-disk block text, "\n"-joined, for comparison with the recorded one.
    static func text(of bytes: [UInt8], begin: Int, end: Int) -> String {
        let lines = Lines(bytes)
        return (begin...end).map { lines.text($0) }.joined(separator: "\n")
    }

    /// Lines of the block body (between the markers).
    static func bodyLines(of block: String) -> [Substring] {
        Array(block.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().dropLast())
    }

    static func inserting(_ block: String, position: ManagedConfigPiece.Position, into t: [UInt8]) -> [UInt8] {
        let nl = OrderedJSON.newline(of: t)
        let b = Array(block.replacingOccurrences(of: "\n", with: nl).utf8)
        let n = Array(nl.utf8)
        // #1025: a byte order mark stays at byte 0; the block goes after it
        let bom = t.starts(with: Lines.bom) ? Lines.bom : []
        if t.count == bom.count { return bom + b + n }
        if position == .top { return bom + b + n + n + Array(t.dropFirst(bom.count)) }
        if t.last == 0x0A { return t + n + b + n }
        return t + n + n + b // the file had no final newline: keep it that way
    }

    static func replacing(begin: Int, end: Int, with block: String, in t: [UInt8]) -> [UInt8] {
        let lines = Lines(t)
        let b = Array(block.replacingOccurrences(of: "\n", with: OrderedJSON.newline(of: t)).utf8)
        return Array(t[..<lines.start(begin)]) + b + Array(t[lines.contentEnd(end)...])
    }

    /// Begin line to end line inclusive, plus the one blank separator line `inserting` added.
    static func removing(begin: Int, end: Int, from t: [UInt8]) -> [UInt8] {
        let lines = Lines(t)
        var lower = lines.start(begin)
        var upper = lines.contentEnd(end)
        if lines.terminatorLength(end) == 0 {
            // Block at EOF with no final newline: drop the blank line and the newline before it.
            if begin >= 2, lines.isBlank(begin - 1) { lower = lines.contentEnd(begin - 2) }
            else if begin >= 1 { lower = lines.contentEnd(begin - 1) }
        } else {
            upper = lines.lineEnd(end)
            if begin >= 1, lines.isBlank(begin - 1) { lower = lines.start(begin - 1) }
            else if begin == 0, end + 1 < lines.count, lines.isBlank(end + 1) { upper = lines.lineEnd(end + 1) }
        }
        return Array(t[..<lower]) + Array(t[upper...])
    }
}

/// Line ranges of a byte buffer. A line ends at "\n"; a "\r" before it belongs to the terminator.
/// A UTF-8 byte order mark at byte 0 belongs to no line (#1025): line 0 starts after it, so a
/// marker behind it is found and a splice at line 0 keeps it. Plain value type, no isolation.
struct Lines {
    static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    let bytes: [UInt8]
    private(set) var starts: [Int] = []

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        var s = bytes.starts(with: Lines.bom) ? Lines.bom.count : 0
        for (i, c) in bytes.enumerated() where c == 0x0A {
            starts.append(s)
            s = i + 1
        }
        if s < bytes.count { starts.append(s) }
    }

    var count: Int { starts.count }
    func start(_ n: Int) -> Int { starts[n] }
    /// Offset just past the line's terminator.
    func lineEnd(_ n: Int) -> Int { n + 1 < count ? starts[n + 1] : bytes.count }
    func terminatorLength(_ n: Int) -> Int {
        let end = lineEnd(n)
        guard end > starts[n], bytes[end - 1] == 0x0A else { return 0 }
        return end - 1 > starts[n] && bytes[end - 2] == 0x0D ? 2 : 1
    }
    /// Offset of the line's last content byte + 1 (terminator excluded).
    func contentEnd(_ n: Int) -> Int { lineEnd(n) - terminatorLength(n) }
    func range(_ n: Int) -> Range<Int> { starts[n]..<contentEnd(n) }
    func text(_ n: Int) -> String { String(decoding: bytes[range(n)], as: UTF8.self) }
    func isBlank(_ n: Int) -> Bool { range(n).isEmpty }
}

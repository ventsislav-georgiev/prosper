import Foundation

/// #1389 (X-ray P6 step B, dch README "Chapters"): `dch --xray <n> --json`'s chapters as the rows Prompts and Responses
/// draw. dch's `auto` (true) is an automatic row and its `peer` the sender's name, so step A's hide and mark rules apply
/// unchanged. Every string is outside data: OutsideText.shown cleans it where it is drawn (XrayPromptRow).
enum XrayChapters {
    /// Caps: dch's own (at most 5000 chapters, the newest; a title, summary or sender 120 scalars; a response 2048
    /// bytes) held here against a host that sends more; the whole answer at most 16 MiB (dch: "under 16 MB").
    static let maxRows = 5000
    static let maxBytes = 16 << 20
    static let responseCap = 2048
    static let toolsCap = 240

    /// #1487: an outside count is a JSON integer (not a boolean, not a string) in 1...10_000_000, else nil.
    static func count(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), let i = n as? Int, (1...10_000_000).contains(i) else { return nil }
        return i
    }

    /// #1487: exactly the JSON boolean true (a number 1 is not one).
    static func isTrue(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID() && n.boolValue
    }

    /// #1487: `s` cut at the line "\n<line>\n" (the occurrence nearest the middle: a head may hold the same line);
    /// nil when it is not there. Scalar-exact.
    static func split(_ s: String, line: String) -> (head: String, tail: String)? {
        let a = Array(s.unicodeScalars), m = Array(("\n" + line + "\n").unicodeScalars)
        guard a.count >= m.count else { return nil }
        var best: Int?
        for i in 0...(a.count - m.count) where a[i] == m[0] && Array(a[i..<(i + m.count)]) == m {
            if best.map({ abs(2 * i - a.count) < abs(2 * $0 - a.count) }) ?? true { best = i }
        }
        guard let i = best else { return nil }
        func str(_ r: ArraySlice<Unicode.Scalar>) -> String { var v = String.UnicodeScalarView(); v.append(contentsOf: r); return String(v) }
        return (str(a[..<i]), str(a[(i + m.count)...]))
    }

    /// #1487: dch's note for a cut middle: "\u{2026} N characters cut \u{2026}".
    static func cutLine(_ n: Int) -> String { "\u{2026} \(n) characters cut \u{2026}" }

    /// The parse: bytes in, never throws; nil (no tab) unless one object with schema 1 and a chapters array. A row that
    /// is not an object is skipped; a missing key reads as absent.
    static func parse(_ data: Data) -> [TranscriptOutline.Chapter]? {
        guard data.count <= maxBytes, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(o)
    }

    /// #1475: the same parse of an object in hand (a follow's snapshot with its deltas applied, XrayFollow.swift).
    static func parse(_ o: [String: Any]) -> [TranscriptOutline.Chapter]? {
        guard o["schema"] as? Int == 1, let list = o["chapters"] as? [Any] else { return nil }
        let cap = TranscriptOutline.titleCap
        return list.suffix(maxRows).compactMap { $0 as? [String: Any] }.enumerated().map { (k, c) -> TranscriptOutline.Chapter in
            func text(_ key: String, _ max: Int) -> String? { (c[key] as? String).map { String($0.unicodeScalars.prefix(max)) } }
            let auto = c["auto"] as? Bool == true, peer = text("peer", cap), kind = c["kind"] as? String
            // dch README: an auto prompt is titled by its summary, by its title when it has none (a hand-back: its title)
            let summary = auto && peer == nil ? text("summary", cap).flatMap { $0.isEmpty ? nil : $0 } : nil
            // dch's 1-based `i` when it is one; else the place in the list
            let n = (c["i"] as? Int).flatMap { (1...Int(Int32.max)).contains($0) ? $0 : nil } ?? k + 1
            var ch = TranscriptOutline.Chapter(id: k, ordinal: n, title: summary ?? text("title", cap) ?? "",
                                               kind: kind == "compact" ? .compaction : .prompt,
                                               hasError: c["error"] as? Bool == true)
            ch.auto = auto || kind == "compact"   // dch xview.c xv_hid: a compaction is automatic too
            ch.peer = peer
            // dch keeps 1024 B + "\n\u{2026}\n" + 1024 B when it cut: 3 scalars past the cap, so the tail stays whole
            ch.response = text("response", isTrue(c["response_cut"]) ? responseCap + 3 : responseCap)
            ch.tools = text("tools", toolsCap)
            // dch 1.93.0: `response_cut` stays true; the count is its own field, never read from the text
            if isTrue(c["response_cut"]) { ch.responseCutChars = count(c["response_cut_chars"]) }
            return ch
        }
    }
}

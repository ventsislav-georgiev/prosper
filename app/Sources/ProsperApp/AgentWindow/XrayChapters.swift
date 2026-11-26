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

    /// #1566 (dch README v1.99.0:1444-1464): the snapshot's corpus fields, for the panel header's label and Cmd-K's
    /// `--clear`. Every value is outside data; the label is drawn through OutsideText.shown (XrayPanelModel.corpusLine).
    struct Corpus: Equatable {
        /// dch's `session_id` when it is a plain id (letters, digits, "-", "_", "."); nil otherwise (it goes to argv).
        var sessionID: String?
        var corpus: String
        var reason = ""
        var mentionsOnly = false
        var lines = 0
        var complete = true
        var why = ""
        /// -1: not said (dch xview.c:194).
        var claudes = -1

        static let dot = " \u{00B7} "
        static let clearNote = "a terminal's own clear-screen key may not clear X-ray; run `clear`"

        /// dch's view words (xview.c xv_label, v1.100.0:2430-2481); nil where dch shows none (a lone Claude).
        var label: String? {
            let d = Self.dot
            switch corpus {
            case "claude" where claudes < 2: return nil
            case "codex": return mentionsOnly ? "Codex\(d)mentions only" : "Codex"
            case "shell":
                let head = mentionsOnly ? "Shell\(d)no shell integration\(d)mentions only" : "Shell\(d)last \(lines) rows"
                return head + (why == "alt" ? d + "waiting for the shell prompt" : "") + d + Self.clearNote
            case "screen": return "Screen\(d)last \(lines) lines\(d)mentions only"
            case "none", "claude":
                if claudes > 1 { return "\(claudes) Claude sessions run here; X-ray reads one" }
                if reason == "ended" { return "Shell\(d)ended\(d)not kept" }
                if reason.isEmpty && claudes == 0 { return "No Claude session found here" }
                // #1991 (dch 1.174.0 README "Codex"): a .zst rollout this dch cannot decode, or one that decodes to nothing
                if reason == "compressed" { return "Codex rollout is compressed: X-ray needs a dch built with libzstd" }
                if reason == "corrupt" { return "Codex rollout is corrupt: nothing could be read" }
                return reason == "lite" ? "X-ray needs the full dch build"
                    : reason == "off" ? "X-ray is off for shells (xray_ring = 0)" : "No X-ray corpus for this session"
            default: return "X-ray corpus not supported by this dch"
            }
        }

        /// Design 3.9 / 5.5 (QA677 S16): a shell's counts while dch read only part of its ring.
        /// #1991 (dch 1.174.0): a Codex rollout cut by a bad frame: what decoded before it.
        var rangeNote: String? {
            guard !complete else { return nil }
            if corpus == "shell" && why == "range" { return "counts in the last \(lines) rows" }
            return corpus == "codex" && why == "corrupt" ? "rollout corrupt: read up to the damage" : nil
        }

        /// #1991: why a Codex rollout gave no corpus, in dch's --ref/--search stderr words ("the Codex rollout is <reason>");
        /// nil for any other answer.
        var rolloutWhy: String? { corpus == "none" && ["compressed", "corrupt"].contains(reason) ? "the Codex rollout is \(reason)" : nil }
    }

    /// #1566: nil without schema 1 and a string `corpus` (an older dch, a reset's empty object).
    static func corpus(_ o: [String: Any]) -> Corpus? {
        guard o["schema"] as? Int == 1, let c = o["corpus"] as? String else { return nil }
        // a JSON integer, not a boolean; a non-negative one for `lines` (dch: `lines > 0 ? lines : 0`)
        func int(_ v: Any?) -> Int? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n as? Int
        }
        let sid = (o["session_id"] as? String).flatMap { s in
            !s.isEmpty && s.utf8.count <= 128 && !s.hasPrefix("-")
                && s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) } ? s : nil
        }
        return Corpus(sessionID: sid, corpus: c, reason: o["reason"] as? String ?? "", mentionsOnly: isTrue(o["mentions_only"]),
                      lines: max(0, int(o["lines"]) ?? 0), complete: o["complete"] as? Bool != false,
                      why: o["why"] as? String ?? "", claudes: int(o["claudes"]) ?? -1)
    }

    static func corpus(_ data: Data) -> Corpus? {
        guard data.count <= maxBytes, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return corpus(o)
    }

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

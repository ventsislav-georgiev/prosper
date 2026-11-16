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

    /// The parse: bytes in, never throws; nil (no tab) unless one object with schema 1 and a chapters array. A row that
    /// is not an object is skipped; a missing key reads as absent.
    static func parse(_ data: Data) -> [TranscriptOutline.Chapter]? {
        guard data.count <= maxBytes, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["schema"] as? Int == 1, let list = o["chapters"] as? [Any] else { return nil }
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
            ch.response = text("response", responseCap)
            ch.tools = text("tools", toolsCap)
            return ch
        }
    }
}

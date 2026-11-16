import Foundation

// #904 (#832 X1 step A, spec v2.1 8.1): the transcript's chapters, one per turn of
// `TranscriptVerbosity.turns`, and where a jump to a block lands. Pure: no IO, no state.

enum TranscriptOutline {
    /// Ruling R3 (spec v3.2.6): a title holds at most this many Unicode scalars.
    static let titleCap = 120

    struct Chapter: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable { case prompt, slash, compaction, partial }
        /// The turn's first block id: stable across polls and paging (ids never change once given).
        let id: Int
        /// 1-based, in transcript order.
        let ordinal: Int
        let title: String
        let kind: Kind
        /// A step of the turn failed: what Focused's summary counts as an error.
        let hasError: Bool
    }

    /// Every turn is a chapter, and so is every further prompt in a turn's lead (v1 OQ-A, no merge: a compaction and
    /// the prompt right after it are two chapters); `turns()` is unchanged. A subagent thread is a block inside its
    /// turn, never a chapter of its own.
    static func chapters(_ blocks: [TranscriptBlock]) -> [Chapter] {
        var out: [Chapter] = []
        for t in TranscriptVerbosity.turns(blocks) {
            for part in prompts(t) {
                // A pasted image leads its prompt; the first other block says what the chapter starts with.
                let (kind, title) = head(part.first { $0.body != .image })
                out.append(Chapter(id: part[part.startIndex].id, ordinal: out.count + 1, title: title, kind: kind,
                                   hasError: part.contains { !TranscriptVerbosity.errorBlocks($0).isEmpty }))
            }
        }
        return out
    }

    /// The turn cut at each prompt of its lead after the first; images before a prompt go with it. The last part
    /// holds the turn's steps.
    private static func prompts(_ t: [TranscriptBlock]) -> [ArraySlice<TranscriptBlock>] {
        var cuts = [0], seen = false, images: Int?
        for (i, b) in t.enumerated() {
            if b.body == .image { images = images ?? i; continue }
            guard isPrompt(b) else { break }
            if seen { cuts.append(images ?? i) }
            (seen, images) = (true, nil)
        }
        return cuts.indices.map { k in t[cuts[k]..<(k + 1 < cuts.count ? cuts[k + 1] : t.count)] }
    }

    private static func isPrompt(_ b: TranscriptBlock) -> Bool {
        switch b.body {
        case .user, .command, .compaction: true
        default: false
        }
    }

    private static func head(_ b: TranscriptBlock?) -> (Chapter.Kind, String) {
        switch b?.body {
        case .user(let c): return (.prompt, title(c.text, or: "Prompt"))
        case .command(let name, let args): return (.slash, title(args.map { name + " " + $0 } ?? name, or: name))
        case .compaction: return (.compaction, "Conversation compacted")
        default: return (.partial, "Earlier part of a turn")
        }
    }

    /// The first non-blank line, whitespace collapsed, cut to `titleCap` scalars on a character boundary
    /// (a multi-scalar emoji at the edge is left out whole, never split).
    static func title(_ s: String, or blank: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) } ?? ""
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var out = "", n = 0
        for ch in collapsed {
            n += ch.unicodeScalars.count
            if n > titleCap { break }
            out.append(ch)
        }
        return out.isEmpty ? blank : out
    }

    /// Where a jump to `block` lands at `level`: the turn holding it (the LazyVStack's own child, found even undrawn)
    /// and the row that shows it. nil when no row shows it (not loaded, or hidden at this level).
    static func target(_ block: Int, in blocks: [TranscriptBlock], level: AgentVerbosity) -> (turn: Int, row: String)? {
        guard let row = TranscriptVerbosity.rowID(containing: block, in: blocks, level: level),
              let turn = TranscriptVerbosity.turns(blocks).first(where: { $0.contains { holds($0, block) } }) else { return nil }
        return (turn[0].id, row)
    }

    /// `b` is the block or one of its subagent steps.
    static func holds(_ b: TranscriptBlock, _ id: Int) -> Bool {
        b.id == id || b.children.contains { holds($0, id) }
    }
}

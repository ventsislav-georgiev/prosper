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
        var ordinal: Int   // #1633: a front drop renumbers the kept chapters
        let title: String
        let kind: Kind
        /// A step of the turn failed: what Focused's summary counts as an error.
        var hasError: Bool
        /// #1354 (X-ray P6, dch xview.c xv_hid): an automatic row: a task notification, a subagent's hand-back, a compaction.
        var auto = false
        /// #1354: the sender when another agent session wrote it ("" unnamed; a hand-back too); nil: not a peer.
        var peer: String? = nil
        /// #1354: the turn's answer (its last reply) and its tools on one line ("Bash 2, Read 1"), for X-ray's Responses.
        var response: String? = nil
        var tools: String? = nil
        /// #1487 (dch 1.93.0): scalars dch left out of the middle of `response` (its "\n\u{2026}\n" line); nil: not cut, or no count.
        var responseCutChars: Int? = nil

        enum From: Equatable, Sendable { case own, auto, peer }
        /// dch's row kinds: auto (hidden until shown), peer (dch xv_xs: a peer that is not auto; shown, can be hidden), own.
        var from: From { auto ? .auto : peer != nil ? .peer : .own }
    }

    /// Every turn is a chapter, and so is every further prompt in a turn's lead (v1 OQ-A, no merge: a compaction and
    /// the prompt right after it are two chapters); `turns()` is unchanged. A subagent thread is a block inside its
    /// turn, never a chapter of its own.
    static func chapters(_ blocks: [TranscriptBlock]) -> [Chapter] {
        var out: [Chapter] = []
        for t in TranscriptVerbosity.turns(blocks) { out += chapters(turn: t, from: out.count + 1) }
        return out
    }

    /// One turn's chapters (`t` is one turn of `TranscriptVerbosity.turns`), ordinals from `ordinal`.
    static func chapters(turn t: [TranscriptBlock], from ordinal: Int) -> [Chapter] {
        var out: [Chapter] = []
        for part in prompts(t) {
            // A pasted image leads its prompt; the first other block says what the chapter starts with.
            let lead = part.first { $0.body != .image }
            let (kind, title) = head(lead)
            var origin: PromptOrigin?
            if case .user(let c)? = lead?.body { origin = c.origin }
            // dch README: an auto prompt is titled by its summary, by its title when it has none (a hand-back: its title)
            let shown = origin.flatMap { $0.auto && $0.peer == nil ? $0.summary : nil }.map { Self.title($0, or: title) }
            // a peer's own block is never drawn: its chapter lands on the first drawn block of its part (the answer)
            let first = part.first { !chapterOnly($0.body) } ?? part[part.startIndex]
            var c = Chapter(id: first.id, ordinal: ordinal + out.count, title: shown ?? title, kind: kind,
                            hasError: part.contains { !TranscriptVerbosity.errorBlocks($0).isEmpty })
            c.auto = kind == .compaction || origin?.auto == true
            c.peer = origin?.peer
            if case .assistant(let a)? = part.last(where: { if case .assistant = $0.body { true } else { false } })?.body {
                c.response = a.text
            }
            c.tools = tools(part)
            out.append(c)
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

    /// #1354: another session's message: the transcript hides it (as at TIP), only the outline and X-ray see it.
    static func chapterOnly(_ b: BlockBody) -> Bool {
        if case .user(let c) = b { c.origin?.peer != nil } else { false }
    }

    /// #1354 (dch README Responses): the part's tool calls by name, in the order first called: "Bash 2, Read 1".
    static func tools(_ part: ArraySlice<TranscriptBlock>) -> String? {
        var names: [String] = [], n: [String: Int] = [:]
        for b in part {
            guard let name = toolName(b.body) else { continue }
            if n[name] == nil { names.append(name) }
            n[name, default: 0] += 1
        }
        return line(names, n)
    }

    private static func line(_ names: [String], _ n: [String: Int]) -> String? {
        names.isEmpty ? nil : names.map { "\($0) \(n[$0, default: 0])" }.joined(separator: ", ")
    }

    private static func toolName(_ b: BlockBody) -> String? {
        switch b {
        case .bash: "Bash"
        case .read: "Read"
        case .thread: "Agent"
        case .diff(let tool, _, _, _, _), .search(let tool, _, _, _, _): tool
        case .card(let title, _, _, let raw, _): raw == nil ? title : nil   // raw: an unrecognized entry
        default: nil
        }
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

    /// `b` is the block or one of its subagent steps.
    static func holds(_ b: TranscriptBlock, _ id: Int) -> Bool {
        b.id == id || b.children.contains { holds($0, id) }
    }

    /// #1633: the chapters kept between polls, so a poll folds in only what it changed (built in the IO read, off main).
    /// Always equal to `chapters` over `blocks` and the asides at or after the first block, sorted by id. New steps of
    /// the last turn are tallied into its last chapter; a block changed in place re-folds its turn (a step of the last
    /// part only re-tallies itself); a front drop re-folds the cut turn and renumbers the rest. A new assembler (open,
    /// reopen, stop, reset) holds a new Builder: a full build.
    struct Builder: Sendable {
        private(set) var chapters: [Chapter] = []
        /// Top-level blocks (asides too) read so far: the work the rows count.
        private(set) var examined = 0
        /// Each turn's first id and the index of its first chapter.
        private var turns: [(id: Int, chapter: Int)] = []
        private var floor: Int?
        private var seen = Int.min
        /// The last turn has a step: its parts are fixed, new steps join its last part.
        private var closed = false
        private var lastPart = Int.min
        private var tally = Tally()

        /// The last part's hasError, response and tools, kept per block so a step re-tallies alone.
        private struct Tally: Sendable {
            var errors: Set<Int> = []
            var names: [String] = []
            var n: [String: Int] = [:]
            var nameOf: [Int: String] = [:]
            var response: String?

            mutating func add(_ b: TranscriptBlock) {
                if !TranscriptVerbosity.errorBlocks(b).isEmpty { errors.insert(b.id) }
                if case .assistant(let a) = b.body { response = a.text }
                guard let name = TranscriptOutline.toolName(b.body) else { return }
                nameOf[b.id] = name
                if n[name] == nil { names.append(name) }
                n[name, default: 0] += 1
            }
        }

        /// A new Builder that keeps the count (the assembler's bound on changed ids ran over).
        mutating func restart() { let e = examined; self = Builder(); examined = e }

        /// `dirty`: top-level ids changed in place since the last update.
        mutating func update(blocks: [TranscriptBlock], asides: [TranscriptBlock], dirty: Set<Int>) {
            let f = blocks.first?.id ?? Int.min
            if let old = floor, f < old { restart() }   // blocks only leave from the front: never in one assembler
            guard let old = floor else {
                floor = f
                refold(0, at: f, blocks, asides)
                return
            }
            if f > old { drop(to: f, blocks, asides) }
            var from: Int?, spliced = Set<Int>()
            for id in dirty where id >= f && id <= seen {
                let k = turn(of: id)
                guard k >= 0 else { continue }
                if k < turns.count - 1 {
                    if spliced.insert(k).inserted, !splice(k, blocks, asides) { from = min(from ?? k, k) }
                } else if !(closed && id >= lastPart && retally(id, blocks)) {
                    from = min(from ?? k, k)
                }
            }
            if let k = from { return refold(k, at: turns[k].id, blocks, asides) }
            let new = Self.merged(blocks, asides, from: seen + 1)
            guard !new.isEmpty else { return syncLast() }
            guard closed, !turns.isEmpty else {
                return refold(max(turns.count - 1, 0), at: turns.last?.id ?? f, blocks, asides)
            }
            let p = new.firstIndex(where: TranscriptOutline.isPrompt) ?? new.endIndex
            for b in new[..<p] { tally.add(b) }
            examined += p
            seen = max(seen, new[..<p].last?.id ?? seen)
            syncLast()
            if p < new.endIndex { refold(turns.count, at: new[p].id, blocks, asides) }
        }

        /// Turns `k`... are folded again from id `s` to the end; the last part's tally starts over.
        private mutating func refold(_ k: Int, at s: Int, _ blocks: [TranscriptBlock], _ asides: [TranscriptBlock]) {
            chapters.removeSubrange((k < turns.count ? turns[k].chapter : chapters.count)...)
            turns.removeSubrange(min(k, turns.count)...)
            let seg = Self.merged(blocks, asides, from: s)
            examined += seg.count
            var last: [TranscriptBlock] = []
            for t in TranscriptVerbosity.turns(seg) {
                turns.append((t[0].id, chapters.count))
                chapters += TranscriptOutline.chapters(turn: t, from: chapters.count + 1)
                last = t
            }
            seen = max(seen, seg.last?.id ?? seen)
            guard !last.isEmpty else { return }
            closed = last.contains { !TranscriptOutline.isPrompt($0) && $0.body != .image }
            tally = Tally()
            let part = TranscriptOutline.prompts(last).last ?? last[...]
            lastPart = part.first?.id ?? Int.min
            for b in part { tally.add(b) }
            examined += part.count
        }

        /// A closed turn folded again in place (its parts hang on block kinds, which never change). False: the
        /// chapter count moved, the caller re-folds from it.
        private mutating func splice(_ k: Int, _ blocks: [TranscriptBlock], _ asides: [TranscriptBlock]) -> Bool {
            let seg = Self.merged(blocks, asides, from: turns[k].id, below: turns[k + 1].id)
            examined += seg.count
            let range = turns[k].chapter..<turns[k + 1].chapter
            let c = TranscriptOutline.chapters(turn: seg, from: range.lowerBound + 1)
            guard c.count == range.count else { return false }
            chapters.replaceSubrange(range, with: c)
            return true
        }

        /// A step of the last part changed in place (a tool result, a subagent step): only its error counts again.
        /// False when it is gone, is an answer or changed tool: the caller re-folds the turn.
        private mutating func retally(_ id: Int, _ blocks: [TranscriptBlock]) -> Bool {
            let i = Self.lower(blocks, id)
            guard i < blocks.count, blocks[i].id == id else { return false }
            let b = blocks[i]
            if case .assistant = b.body { return false }
            guard TranscriptOutline.toolName(b.body) == tally.nameOf[id] else { return false }
            examined += 1
            if TranscriptVerbosity.errorBlocks(b).isEmpty { tally.errors.remove(id) } else { tally.errors.insert(id) }
            syncLast()
            return true
        }

        /// The first block now is `f`: turns before it go, the cut turn is folded again, the rest renumbered.
        private mutating func drop(to f: Int, _ blocks: [TranscriptBlock], _ asides: [TranscriptBlock]) {
            floor = f
            let k = turn(of: f)
            guard k >= 0, k < turns.count - 1 else {
                chapters = []
                turns = []
                return refold(0, at: f, blocks, asides)
            }
            let seg = Self.merged(blocks, asides, from: f, below: turns[k + 1].id)
            examined += seg.count
            var head: [Chapter] = [], ts: [(id: Int, chapter: Int)] = []
            for t in TranscriptVerbosity.turns(seg) {
                ts.append((t[0].id, head.count))
                head += TranscriptOutline.chapters(turn: t, from: head.count + 1)
            }
            let cut = turns[k + 1].chapter, shift = head.count - cut
            chapters = head + chapters[cut...].map { var c = $0; c.ordinal += shift; return c }
            turns = ts + turns[(k + 1)...].map { (id: $0.id, chapter: $0.chapter + shift) }
        }

        private mutating func syncLast() {
            guard closed, let i = chapters.indices.last else { return }
            chapters[i].hasError = !tally.errors.isEmpty
            chapters[i].response = tally.response
            chapters[i].tools = TranscriptOutline.line(tally.names, tally.n)
        }

        /// The last turn starting at or before `id`, -1 when none.
        private func turn(of id: Int) -> Int {
            var lo = 0, hi = turns.count
            while lo < hi { let m = (lo + hi) / 2; if turns[m].id <= id { lo = m + 1 } else { hi = m } }
            return lo - 1
        }

        /// The first index of `x` (sorted by id) at or after `id`.
        private static func lower(_ x: [TranscriptBlock], _ id: Int) -> Int {
            var lo = 0, hi = x.count
            while lo < hi { let m = (lo + hi) / 2; if x[m].id < id { lo = m + 1 } else { hi = m } }
            return lo
        }

        /// `blocks` and `asides` (each sorted by id) with ids in from..<below, merged by id.
        private static func merged(_ blocks: [TranscriptBlock], _ asides: [TranscriptBlock], from: Int,
                                   below: Int = .max) -> [TranscriptBlock] {
            var a = lower(blocks, from), b = lower(asides, from)
            let ae = lower(blocks, below), be = lower(asides, below)
            var out: [TranscriptBlock] = []
            out.reserveCapacity(max(0, ae - a) + max(0, be - b))
            while a < ae || b < be {
                if b >= be || (a < ae && blocks[a].id < asides[b].id) { out.append(blocks[a]); a += 1 }
                else { out.append(asides[b]); b += 1 }
            }
            return out
        }
    }
}

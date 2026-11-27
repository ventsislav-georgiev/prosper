import Combine
import Foundation
import os

// #1475 (dch #445 phase 1): X-ray's Prompts, Responses and Refs come from one long-lived `dch --xray <n> --follow --json`
// per session target instead of the open's chapters read and the 5 s / 30 s chapters and Refs polls. dch README "X-ray
// queries": NDJSON lines with schema 1: `snapshot` (the `--json` object), then deltas `chapter` (a known anchor
// replaces), `ref` (whole ref by key; count 0 removes), `evict` (drop chapters below seq) and `reset` (drop everything,
// a snapshot follows). The state is the cache: a panel opened on a target that has one draws it on the first frame.
// The follow keeps running while the window or drawer is hidden (an idle follow costs dch no CPU); it ends when dch
// ends it (the session ended), or when the LRU evicts it. Tasks and Memory keep their polls (phase 2 is dch #446).
// #1475 c (dch #446, 1.91.0): `--tasks --memory` on the same follow: after every snapshot and reset a tasks block, then a
// memory block (the one-shot lines: header, rows, done line; the tasks header has `session`, memory's never), then deltas
// `task` / `memory` by id (`gone` removes); a whole block again replaces the kept one. The Tasks and Memory polls stop
// while such a follow runs. An older host refuses the form with exit 2: the follow starts again without it, once.
// #2014 (dch #686, 1.188.0): `--schedules` adds a third block (header "block":"schedules", rows `schedule` by id, `gone`
// removes); headers route on "block" first (a schedules header carries `source` and `session` too). An exit 2 before any
// snapshot of a run that carried it (a host's older dch) starts the follow again without it, once.

/// One target's follow and the state its lines built.
@MainActor
final class XrayFollow: ObservableObject {
    struct State {
        var chapters: [TranscriptOutline.Chapter]?
        var refs: XrayRefs?
        var anchors: [String: Int]
        /// #1475 c: the stream's tasks and memory blocks, parsed as the one-shot reads; nil: no block (yet).
        var tasks: XrayTasks? = nil
        var memory: XrayMemory? = nil
        /// #2014: the stream's schedules block; nil: none (yet).
        var schedules: XraySchedules? = nil
        /// #1566: the snapshot's corpus fields (the panel header's label, Cmd-K's session_id).
        var corpus: XrayChapters.Corpus? = nil
    }

    /// #1475 c: one tasks or memory block as dch's one-shot lines (header, rows with their ids, done line).
    struct Block {
        var head: Data
        var rows: [(id: String?, line: Data)] = []
        var done: Data?
        var bytes: Int

        init(_ head: Data) { (self.head, bytes) = (head, head.count) }
        /// What XrayTasks.parse / XrayMemory.parse read: the lines in order.
        var data: Data {
            var out = head
            for l in lines.dropFirst() { out.append(0x0A); out.append(l) }
            return out
        }
        /// #1787: the lines themselves (no copy of their bytes), for XrayTasks.parse(_:reusing:).
        var lines: [Data] { [head] + rows.map { $0.line } + (done.map { [$0] } ?? []) }

        /// #1631: the same lines (a whole block dch sent again): the byte count first, then each line's bytes.
        func same(_ o: Block) -> Bool {
            bytes == o.bytes && head == o.head && done == o.done && rows.count == o.rows.count
                && zip(rows, o.rows).allSatisfy { $0.id == $1.id && $0.line == $1.line }
        }
    }

    let target: XrayTarget
    /// nil until the first snapshot; a reset leaves an empty state until the snapshot after it.
    @Published private(set) var state: State?
    /// The stream ended before any snapshot (exit 2 from a dch without the form, no session, unreachable), or its object
    /// grew past maxKept (#1475 a2).
    @Published private(set) var failed = false
    /// #1475 a2 (QA r1436 s1): the bytes the object holds (the snapshot line, plus each delta line, less what a delta
    /// replaced or dropped), bounded as XrayChapters.parse bounds one read. #1638: read on the follow's queue; rows set
    /// it and restore it between lines, the product never writes it.
    nonisolated(unsafe) static var maxKept = XrayChapters.maxBytes
    /// #1475 c2 (QA r1451 s1): the most rows one block keeps, as the one-shot parsers (XrayTasks.maxRows, memory's too);
    /// past it the follow ends like pastCap. Rows set it and restore it (as maxKept).
    nonisolated(unsafe) static var maxBlockRows = XrayTasks.maxRows
    /// #1631, #1638: the object model (line decode, deltas, cap accounting) and the state builds run here, in order, on
    /// its queue; main gets each take's result (XrayStateBuilder.Taken) and swaps the finished state in.
    private let builder = XrayStateBuilder()
    /// #1638: the last landed take left a snapshot in the object (`ended` reads it after every line before it landed).
    private var hasSnapshot = false
    /// #1631: takes go to the builder's queue. Off under XCTest so the rows that read the state right after a line keep
    /// reading it there (the take runs on main); the rows that prove the hop set it and restore it. Set it only between
    /// follows: the builder is used on one thread at a time.
    static var buildOffMain: @MainActor () -> Bool = { NSClassFromString("XCTestCase") == nil }
    /// #1638: this run's lines go to the queue (buildOffMain at its start).
    private var offMain = false
    /// #1475 c: this run carries `--tasks --memory` (the probed dch is 1.91.0 or newer and the host did not refuse it).
    private(set) var withTasks = false
    private var tasksRefused = false
    /// #2014: this run carries `--schedules` (the probed dch is 1.188.0 or newer and the host did not refuse it).
    private(set) var withSchedules = false
    /// #2014: the host answered `--follow --schedules` with exit 2 (its dch is older): the Schedules tab says so.
    private(set) var schedulesRefused = false
    private var dch = ""
    /// While it runs, the Tasks and Memory polls stay off (XrayPoller tick, select).
    var carriesTasks: Bool { running && withTasks }
    /// The process's stop (SIGTERM); nil once it ended.
    private var stopProcess: (() -> Void)?
    var running: Bool { stopProcess != nil }
    /// Panels showing this target now; the LRU evicts only a follow no panel shows.
    var users = 0
    var onEnd: (XrayFollow) -> Void = { _ in }

    init(target: XrayTarget) { self.target = target }

    func start(_ dch: String) {
        guard stopProcess == nil else { return }
        failed = false
        self.dch = dch
        withTasks = !tasksRefused && XrayPanels.followTasksOK()
        withSchedules = !schedulesRefused && XrayPanels.followSchedulesOK()
        offMain = Self.buildOffMain()
        stopProcess = XrayPanels.follow(dch, target.followArgs(tasks: withTasks, schedules: withSchedules), target.env,
                                        Self.sink(builder, offMain, self), { [weak self] in self?.ended($0) })
    }

    /// #1638: the follow's line sink, called on the reader's thread (the product) or on main (rows' fakes). With the hop
    /// on, lines wait in `pending` and one drain per wait runs on the queue (#1629: one take per wait, not per read; main
    /// is not woken per batch); off, the take runs here on main.
    private nonisolated static func sink(_ b: XrayStateBuilder, _ offMain: Bool, _ f: XrayFollow) -> @Sendable ([Data]) -> Void {
        { [weak f] ls in
            guard offMain else { return MainActor.assumeIsolated { f?.land(b.take(ls, b.next())) } }
            guard b.pending.add(ls) else { return }
            let g = f   // a weak var cannot be captured by the queue's closure; this holds the follow for one wait at most
            b.queue.asyncAfter(deadline: .now() + XrayPendingLines.wait) { XrayFollow.onQueue(b, b.pending.drain(), nil, g) }
        }
    }

    /// #1638: on the queue: take `lines` as take `n` (nil: numbered now; no lines: only the hop), then land the result
    /// and run `then` on main, in order.
    private nonisolated static func onQueue(_ b: XrayStateBuilder, _ lines: [Data], _ n: Int?, _ f: XrayFollow?,
                                            _ then: (@MainActor @Sendable () -> Void)? = nil) {
        let t = lines.isEmpty ? nil : b.take(lines, n ?? b.next())
        guard t != nil || then != nil else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { if let t { f?.land(t) }; then?() } }
    }

    /// #1638: `then` on main after every take sent so far landed; `drain`: the lines still waiting are taken first.
    private nonisolated static func after(_ b: XrayStateBuilder, drain: Bool, _ f: XrayFollow?,
                                          _ then: @escaping @MainActor @Sendable () -> Void) {
        b.queue.async { XrayFollow.onQueue(b, drain ? b.pending.drain() : [], nil, f, then) }
    }

    /// #1638: rows wait here for every take and end sent so far to land (the queue, then main). Nothing is drained.
    func settled() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in Self.after(builder, drain: false, nil) { c.resume() } }
    }

    /// SIGTERM (the LRU's eviction); the state goes with the follow.
    func stop() {
        let s = stopProcess
        stopProcess = nil
        s?()
    }

    /// #1638: with the hop on, the lines still waiting are taken and landed first (the queue, then main), then the end.
    private func ended(_ status: Int32) {
        guard offMain else { return finish(status) }
        Self.after(builder, drain: true, self) { [weak self] in self?.finish(status) }
    }

    private func finish(_ status: Int32) {
        guard stopProcess != nil else { return }   // stopped by us: not news
        stopProcess = nil
        // #2014: a host's dch before 1.188.0 exits 2 on `--follow --schedules` (dch README): again without it, once
        if status == 2 || status == XrayPanels.followTasksRefused, withSchedules, !hasSnapshot { schedulesRefused = true; return start(dch) }
        // #1475 c: an older host's "bad usage: --tasks and --follow": the same follow without them, once; polls for those
        if status == XrayPanels.followTasksRefused, withTasks, !hasSnapshot { tasksRefused = true; return start(dch) }
        if !hasSnapshot { failed = true; onEnd(self) }   // never a snapshot: the panels go back to today's reads
    }

    /// One batch of lines, in order; the state is built once per batch. #1638: the batch goes to the queue whole (no
    /// line is decoded on main) unless buildOffMain is off. Rows only (QA r-df387acf n1): it numbers its take on main while
    /// the reader sink numbers its drains on the queue; never feed one follow from both, or the newer build may stay held.
    func take(_ lines: [Data]) {
        guard Self.buildOffMain() else { return land(builder.take(lines, builder.next())) }
        Self.takeOnQueue(builder, lines, builder.next(), self)   // numbered now: a take sent after it is newer
    }

    /// #1631: the hop, nonisolated so the closure that runs on `queue` is not main's.
    private nonisolated static func takeOnQueue(_ b: XrayStateBuilder, _ lines: [Data], _ n: Int, _ f: XrayFollow) {
        b.queue.async { [weak f] in XrayFollow.onQueue(b, lines, n, f) }
    }

    /// #1631, #1638: main's part of a take, in the order they were sent: count its work, replay its #1567 lines, hold
    /// its build, and swap the held state in once no newer take is on its way (a newer one lands after it, with or
    /// without a build of its own). Past the cap the follow ends and nothing held lands.
    private func land(_ t: XrayStateBuilder.Taken) {
        decoded += t.decoded
        if t.onMain { decodedOnMain += t.decoded }
        for o in t.followed { XrayRefResults.followed(target, o) }   // #1567: a ref, evict or reset drops cached --ref answers
        hasSnapshot = t.snapshot
        if let b = t.built {
            applies += 1
            if b.chapters { parsed.chapters += 1 }
            if b.refs { parsed.refs += 1 }
            refRows += b.refRows
            blockParses += b.blocks
            taskRowParses &+= b.taskRows
            if b.onMain { builtOnMain += 1 }
            held = b.state
        }
        if t.pastCap { held = nil; failed = true; return onEnd(self) }
        guard t.take == builder.sent.withLock({ $0 }), let s = held else { return }
        held = nil
        swapped += 1
        state = s
    }

    /// #1631: a build that landed while a newer take was on its way.
    private var held: State?

    /// #1629: state builds so far and the parts parsed in them (the cost rows count them: a burst of lines is one
    /// build, a repeated line none, a ref line parses no chapters). Counters only: they never reach Int.max.
    private(set) var applies = 0
    private(set) var parsed = (refs: 0, chapters: 0)
    /// #1631: ref rows parsed (OutsideText) in those builds (one changed ref: 1), the builds that ran on main, and the
    /// states swapped in (a build overtaken by a newer one swaps none). Counters only, as above.
    private(set) var refRows = 0
    /// #1631: tasks and memory blocks parsed (XrayTasks.parse, XrayMemory.parse), one per changed block per build.
    private(set) var blockParses = 0
    /// #1787: task rows decoded and dated in those parses (a build parses only the rows whose bytes changed). A counter.
    private(set) var taskRowParses = 0
    private(set) var builtOnMain = 0
    private(set) var swapped = 0
    /// #1638: lines decoded (JSONSerialization) so far, and those decoded on main (0 with the hop on). Counters only.
    private(set) var decoded = 0
    private(set) var decodedOnMain = 0
}

/// #1631, #1638: a follow's object model and state builds, run in order on its queue (or on main where
/// XrayFollow.buildOffMain is off): each line's decode, the deltas, the cap accounting, then one build per take that
/// starts from the one before, so a ref line parses that ref alone and the parts no line changed are kept.
final class XrayStateBuilder: @unchecked Sendable {   // its vars are read and written by one take at a time
    let queue = DispatchQueue(label: "eu.illegible.prosper.xray-follow", qos: .utility)
    /// #1629, #1638: the lines read and not yet taken (the reader adds, a drain on `queue` takes them).
    let pending = XrayPendingLines()
    /// #1631, #1638: the takes numbered so far (main's take numbers its own as it sends it; a drain on `queue`, as it
    /// runs): a landing whose number is below it has a newer take on its way.
    let sent = OSAllocatedUnfairLock(initialState: 0)
    func next() -> Int { sent.withLock { $0 &+= 1; return $0 } }   // a counter only: wrapping is harmless

    /// What one build reads. The object is JSONSerialization's values (immutable Foundation objects, Swift values).
    struct Job {
        var object: [String: Any]
        var dirty: Set<String>
        var refKeys: Set<String>
        var task: XrayFollow.Block?
        var memory: XrayFollow.Block?
        var schedule: XrayFollow.Block? = nil
    }

    /// The finished state and the work it took: the parts parsed, the ref rows parsed, whether it ran on main.
    struct Built {
        var state: XrayFollow.State
        var chapters: Bool
        var refs: Bool
        var refRows: Int
        var blocks: Int
        var taskRows = 0
        var onMain: Bool
    }

    /// #1638: one take's result for main: its build (nil: nothing changed), the take's number, the #1567 lines to replay,
    /// whether a snapshot is held after it, whether it passed the cap, the lines it decoded and where.
    struct Taken: @unchecked Sendable {   // State's parts are values; `followed` is JSONSerialization's values
        var built: Built?
        var take: Int
        var followed: [[String: Any]] = []
        var snapshot = false
        var pastCap = false
        var decoded = 0
        var onMain: Bool
    }

    /// The snapshot with every delta since applied: dch's `--json` object of this moment (README "X-ray queries").
    private var object: [String: Any]?
    private var kept = 0
    /// #1638: each kept chapter's and ref's own line bytes, at its place in the object's lists (0: it came in a snapshot,
    /// whose line is counted whole). shortcut: a snapshot element replaced or dropped frees 0 bytes, so `kept` may run
    /// up to one snapshot's bytes high until the next snapshot or reset; split the snapshot line per element if that
    /// ever ends a big follow early.
    private var chapterBytes: [Int] = [], refBytes: [Int] = []
    /// #1475 c: the kept blocks by row key ("task", "memory"), the one whose done line has not come, the ones changed.
    private var blocks: [String: XrayFollow.Block] = [:]
    private var openBlock: String?
    /// #1631: the block a new header replaces, held until the new one's done line: an equal block changes nothing.
    private var replaced: [String: XrayFollow.Block] = [:]
    private var dirty: Set<String> = []
    /// #1631: the keys of the ref lines since the last build (only those refs are parsed again).
    private var refKeys: Set<String> = []
    /// #1638: past the cap the follow is over: later lines are not read and nothing is built.
    private var capped = false
    private var last: XrayFollow.State?
    private var refCache = XrayRefs.Cache()
    /// #1787: the last tasks parse's rows by their bytes (XrayTasks.Cache): only changed rows are decoded and dated.
    private var taskCache = XrayTasks.Cache()

    /// #1629: what a snapshot or reset makes stale (every part of the object); a delta marks only its own part.
    private static let whole: Set<String> = ["snapshot", "chapters", "refs"]

    /// One batch of lines, in order: decoded, applied, then built once.
    func take(_ lines: [Data], _ n: Int) -> Taken {
        var t = Taken(take: n, onMain: Thread.isMainThread)
        guard !capped else { return t }
        for d in lines {
            t.decoded += 1   // a counter only: at most the lines in hand
            guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            // #1475 c: a block's rows and done line carry no schema (the one-shot lines); a delta may
            if takeBlockLine(o, d) {
                if pastCap() { return ended(t) }
                continue
            }
            guard o["schema"] as? Int == 1 else { continue }
            if o["ref"] != nil || o["evict"] != nil || o["reset"] != nil { t.followed.append(o) }   // #1567, replayed on main
            // d.count is at most XrayLineSplit's cap and kept at most maxKept after each line: the sum cannot overflow
            if let s = o["snapshot"] as? [String: Any] {
                object = s; kept = d.count; dirty.formUnion(Self.whole)
                chapterBytes = Array(repeating: 0, count: (s["chapters"] as? [Any])?.count ?? 0)
                refBytes = Array(repeating: 0, count: (s["refs"] as? [Any])?.count ?? 0)
                continue
            }
            if o["reset"] != nil {
                object = ["schema": 1, "chapters": [Any](), "refs": [Any]()]; kept = 0; (chapterBytes, refBytes) = ([], [])
                (blocks, openBlock, replaced) = ([:], nil, [:]); dirty = Self.whole.union(Self.blockKeys)   // #1475 c: the blocks come again after it
                taskCache.rows = [:]   // #1787: the rows' bytes go with their block
                continue
            }
            if o["source"] != nil || o["block"] != nil {   // #1475 c: a tasks (with `session`) or memory header starts its block again
                // #2014: "block" first (1.187.0+: a schedules header has `session` too); the old rule for a header without it
                guard let k = Self.blockKey(o) else {   // a block Prosper does not read: the open one ends here (partial)
                    if let cut = openBlock { dirty.insert(cut); replaced[cut] = nil; openBlock = nil }
                    continue
                }
                if let cut = openBlock, cut != k { dirty.insert(cut); replaced[cut] = nil }   // a block with no done line ends here (partial)
                replaced[k] = blocks[k]
                blocks[k] = XrayFollow.Block(d); openBlock = k   // shown at its done line, not row by row
                if pastCap() { return ended(t) }
                continue
            }
            guard var obj = object else { continue }   // a delta before any snapshot has nothing to apply to
            // #1638: each list and its bytes change together (same places), from the line's own bytes, never re-serialised
            if let c = o["chapter"] as? [String: Any] {
                var list = obj["chapters"] as? [Any] ?? []
                if let a = c["anchor"] as? String, let k = list.lastIndex(where: { ($0 as? [String: Any])?["anchor"] as? String == a }) {
                    kept -= chapterBytes[k]
                    list[k] = c; chapterBytes[k] = d.count
                } else {
                    list.append(c); chapterBytes.append(d.count)
                    if list.count > XrayChapters.maxRows {   // the newest, as parse
                        let n = list.count - XrayChapters.maxRows
                        kept -= chapterBytes.prefix(n).reduce(0, +)
                        list.removeFirst(n); chapterBytes.removeFirst(n)
                    }
                }
                obj["chapters"] = list
                dirty.insert("chapters")
            } else if let r = o["ref"] as? [String: Any], let key = r["key"] as? String {
                var list = obj["refs"] as? [Any] ?? []
                let k = list.firstIndex { ($0 as? [String: Any])?["key"] as? String == key }
                // #1629: a ref line equal to the kept ref changes nothing: no parse, no $state, no redraw
                if let k, (r["count"] as? Int).map({ $0 <= 0 }) != true, (list[k] as? NSDictionary)?.isEqual(to: r) == true { continue }
                dirty.insert("refs"); refKeys.insert(key)
                if let k { kept -= refBytes[k] }
                if (r["count"] as? Int).map({ $0 <= 0 }) == true { if let k { list.remove(at: k); refBytes.remove(at: k) } }
                else if let k { list[k] = r; refBytes[k] = d.count }
                // shortcut: a new key past dch's 2000 is not held (no dropped_keys bump), until the next snapshot
                else if list.count < XrayRefs.maxRows { list.append(r); refBytes.append(d.count) }
                obj["refs"] = list
            } else if let e = o["evict"] as? [String: Any], let seq = e["seq"] as? Int {
                var keep: [Any] = [], keepBytes: [Int] = []
                for (c, n) in zip(obj["chapters"] as? [Any] ?? [], chapterBytes) {
                    if (((c as? [String: Any])?["offset"] as? Int).map { $0 >= seq } ?? true) { keep.append(c); keepBytes.append(n) }
                    else { kept -= n }
                }
                obj["chapters"] = keep; chapterBytes = keepBytes
                dirty.insert("chapters")
            } else { continue }
            kept += d.count   // a removal (count 0, evict) adds its own small line too
            object = obj
            if pastCap() { return ended(t) }
        }
        t.snapshot = object != nil
        guard !dirty.isEmpty, let object else { return t }
        let job = Job(object: object, dirty: dirty, refKeys: refKeys,
                      task: dirty.contains("task") ? blocks["task"] : nil,
                      memory: dirty.contains("memory") ? blocks["memory"] : nil,
                      schedule: dirty.contains("schedule") ? blocks["schedule"] : nil)
        (dirty, refKeys) = ([], [])
        t.built = build(job)
        return t
    }

    /// #1475 a2: past the cap the object goes and later lines are not read (main drops what it holds).
    private func ended(_ t: Taken) -> Taken {
        var t = t
        object = nil; capped = true
        t.pastCap = true
        return t
    }

    /// #1475 a2 (QA r1436 s1): past the whole-object cap the follow ends and the panels read as today (giveUpFollow);
    /// #1475 c: the blocks' bytes count too (each sum at most maxKept plus one line after the check per line: no overflow).
    /// #1475 c2: so does a block's row count (about 20-byte rows fit 800k in 16 MiB; parse keeps 50,000 and every delta
    /// scans the rows). shortcut: the per-delta firstIndex over the rows stays linear, now bounded by maxBlockRows; an
    /// id index would need re-numbering on every removal.
    private func pastCap() -> Bool {
        kept + blocks.values.reduce(0, { $0 + $1.bytes }) > XrayFollow.maxKept
            || blocks.values.contains(where: { $0.rows.count > XrayFollow.maxBlockRows })
    }

    /// #1475 c: a block's row or done line, or a `task` / `memory` delta (by id; `gone` removes; a delta for no block
    /// yet has nothing to apply to). false: not one of these lines.
    /// #2014: the row keys of the blocks the follow keeps (a row line's own key, as the one-shot rows).
    static let blockKeys = ["task", "memory", "schedule"]

    /// #2014: a header's block: its "block" (dch 1.187.0+), else the #1475 c rule (`session`: tasks; none: memory); nil: a
    /// block Prosper does not read.
    static func blockKey(_ o: [String: Any]) -> String? {
        guard let b = o["block"] else { return o["session"] != nil ? "task" : "memory" }
        return ["tasks": "task", "memory": "memory", "schedules": "schedule"][b as? String ?? ""]
    }

    private func takeBlockLine(_ o: [String: Any], _ d: Data) -> Bool {
        if o["done"] != nil, let k = openBlock {
            blocks[k]?.done = d; blocks[k]?.bytes += d.count; openBlock = nil
            // #1631: dch (before #532) sends the whole block again; the same lines as the held one: no parse, no $state
            if let was = replaced.removeValue(forKey: k), let now = blocks[k], now.same(was) { return true }
            dirty.insert(k)
            return true
        }
        guard let k = Self.blockKeys.first(where: { o[$0] != nil }), let row = o[k] as? [String: Any] else { return false }
        guard var b = blocks[k] else { return true }
        let id = row["id"] as? String, gone = row["gone"] as? Bool == true
        if openBlock == k {
            b.rows.append((id, d)); b.bytes += d.count   // the block's own row, as parse reads it
        } else if let id, let i = b.rows.firstIndex(where: { $0.id == id }) {
            if !gone, b.rows[i].line == d { return true }   // #1631: the held row's own bytes again: nothing changed
            b.bytes -= b.rows[i].line.count
            if gone { b.rows.remove(at: i) } else { b.rows[i].line = d; b.bytes += d.count }
        } else if id != nil, !gone {
            b.rows.append((id, d)); b.bytes += d.count
        } else { return true }   // gone for a row not kept, or no id: nothing to apply
        blocks[k] = b
        if openBlock != k { dirty.insert(k) }   // an open block shows at its done line
        return true
    }

    private func build(_ j: Job) -> Built {
        // #1475 c: a block is parsed again only when it changed (up to 50000 rows); #1629: so are refs and chapters (a
        // delta changes only its own part; the top-level fields and the corpus change only with a snapshot or reset)
        let all = last == nil || j.dirty.contains("snapshot")
        let chapters = all || j.dirty.contains("chapters"), refs = all || j.dirty.contains("refs")
        if all { refCache.rows = [:] }   // #1631: a snapshot or reset parses every ref again
        let (before, taskBefore) = (refCache.parses, taskCache.parses)
        let s = XrayFollow.State(
            chapters: chapters ? XrayChapters.parse(j.object) : last?.chapters,
            refs: refs ? XrayRefs.parse(j.object, reusing: &refCache, changed: j.refKeys) : last?.refs,
            anchors: chapters ? XrayPanelModel.anchors(j.object) : last?.anchors ?? [:],
            tasks: j.dirty.contains("task") ? j.task.map { XrayTasks.parse($0.lines, reusing: &taskCache) } : last?.tasks,
            memory: j.dirty.contains("memory") ? j.memory.map { XrayMemory.parse($0.data) } : last?.memory,
            schedules: j.dirty.contains("schedule") ? j.schedule.map { XraySchedules.parse($0.lines) } : last?.schedules,
            corpus: all ? XrayChapters.corpus(j.object) : last?.corpus)
        last = s
        let blocks = (j.dirty.contains("task") && j.task != nil ? 1 : 0) + (j.dirty.contains("memory") && j.memory != nil ? 1 : 0)
            + (j.dirty.contains("schedule") && j.schedule != nil ? 1 : 0)
        return Built(state: s, chapters: chapters, refs: refs, refRows: refCache.parses &- before, blocks: blocks,
                     taskRows: taskCache.parses &- taskBefore, onMain: Thread.isMainThread)
    }
}

/// The follows by target, oldest use first. At most `limit` (dch's master has 4 follower slots: one stays for the
/// person's own `dch --xray` view) and `remoteLimit` remote ones (dch serve runs 2 per device: Prosper never opens a
/// third). A new target over a limit evicts the oldest follow no panel shows (SIGTERM); with none, it gets no follow.
@MainActor
final class XrayFollows {
    static let limit = 3
    static let remoteLimit = 2
    private(set) var follows: [XrayFollow] = []

    /// The target's follow for one more panel, started (or restarted when it ended) with `dch`; nil: the gate is closed
    /// (XrayPanels.followOK) or there is no room.
    func attach(_ target: XrayTarget, dch: String) -> XrayFollow? {
        guard XrayPanels.followOK() else { return nil }
        if let k = follows.firstIndex(where: { $0.target == target }) {
            let f = follows.remove(at: k)
            follows.append(f)
            f.users += 1
            f.start(dch)   // no-op while it runs; an ended one is read again (its rows show until the new snapshot)
            return f
        }
        if target.dir == nil, !room({ $0.target.dir == nil }, Self.remoteLimit) { return nil }
        guard room({ _ in true }, Self.limit) else { return nil }
        let f = XrayFollow(target: target)
        f.users = 1
        f.onEnd = { [weak self] in self?.drop($0) }
        follows.append(f)
        f.start(dch)
        return f
    }

    func detach(_ f: XrayFollow) { f.users = max(0, f.users - 1) }

    /// #1559 (X-T a): each window's focused pane's follow, by the window's identity.
    private var held: [ObjectIdentifier: XrayFollow] = [:]

    /// #1559: pane focus. The window's focused live local pane holds its target's follow (one attach); another target,
    /// nil (the focused pane is not live, the window hid) or no dch detaches the one it held. A follow that ended and
    /// left the LRU is attached again. nil: none held (gate closed, no room, no target).
    @discardableResult
    func focus(_ target: XrayTarget?, window: ObjectIdentifier, dch: String?) -> XrayFollow? {
        if let f = held[window], f.target == target, follows.contains(where: { $0 === f }) { return f }
        if let f = held.removeValue(forKey: window) { detach(f) }
        guard let target, let dch, let f = attach(target, dch: dch) else { return nil }
        held[window] = f
        return f
    }

    /// #1559: the follow the window's focused pane holds (its refs mark the grid and answer a Cmd-click).
    func focused(in window: ObjectIdentifier) -> XrayFollow? { held[window] }

    /// Below `cap` follows matching `pool`, after evicting the oldest one no panel shows if needed.
    private func room(_ pool: (XrayFollow) -> Bool, _ cap: Int) -> Bool {
        guard follows.filter(pool).count >= cap else { return true }
        guard let old = follows.first(where: { pool($0) && $0.users == 0 }) else { return false }
        drop(old)
        return true
    }

    /// Ends `f` (SIGTERM) and forgets it: an eviction, a follow that ended unread, or one with no snapshot in time.
    func drop(_ f: XrayFollow) {
        follows.removeAll { $0 === f }
        f.stop()
    }
}

extension XrayTarget {
    /// #1475: dch README "dch --xray <n> --follow --json  # the same object, then its deltas as NDJSON"; #1475 c: with
    /// `tasks`, dch 1.91.0's `--xray <n> --follow --tasks --memory --json`; #2014: `schedules`, 1.188.0's `--schedules`.
    func followArgs(tasks: Bool, schedules: Bool = false) -> [String] {
        ["--xray", name, "--follow"] + (tasks ? ["--tasks", "--memory"] : []) + (schedules ? ["--schedules"] : []) + ["--json"]
    }
}

extension XrayFollow {
    /// The dch that has `--xray <n> --follow --json` with `reset` (it predates 1.66.0, README "X-ray queries"): every
    /// dch XrayTabs.gate lets in. A remote host's older dch exits before a snapshot: that target falls back (`failed`).
    static let minimumDch = XrayTabs.minimumDch
    /// #1475 c: `--follow --tasks --memory` (dch #446).
    static let tasksDch = [1, 91, 0]
    /// #2014: `--follow --schedules` (dch #686).
    static let schedulesDch = [1, 188, 0]
}

extension XrayPanels {
    /// One follow: (path, argv, env, lines, ended) -> its stop (SIGTERM). `lines` gets each batch of whole lines in
    /// order, on one thread at a time (#1638: the reader's in the product, main in rows); `ended` the exit status once,
    /// on main, after the last batch was handed to `lines`.
    typealias Follow = @MainActor (_ path: String, _ args: [String], _ env: [String: String],
                                   _ lines: @escaping @Sendable ([Data]) -> Void,
                                   _ ended: @escaping @MainActor @Sendable (Int32) -> Void) -> () -> Void

    /// #1475: the gate for follows (XrayFollow.minimumDch on the probed dch). Off under XCTest as searchTab is, so the
    /// rows that count chapters reads keep them; rows set it and restore it.
    static var followOK: @MainActor () -> Bool = {
        NSClassFromString("XCTestCase") == nil && probed.map { DchCommand.isAtLeast($0.version, XrayFollow.minimumDch) } == true
    }

    /// #1475 c: a follow carries Tasks and Memory on the probed dch 1.91.0 or newer (rows set `probed`).
    static var followTasksOK: @MainActor () -> Bool = { probed.map { DchCommand.isAtLeast($0.version, XrayFollow.tasksDch) } == true }

    /// #2014: a follow carries Schedules on the probed dch 1.188.0 or newer (rows set `probed`).
    static var followSchedulesOK: @MainActor () -> Bool = { probed.map { DchCommand.isAtLeast($0.version, XrayFollow.schedulesDch) } == true }

    /// #1475 c: streamLines' answer for exit 2 with "bad usage: --tasks and --follow" on stderr (an older host).
    nonisolated static let followTasksRefused = Int32.min + 1

    /// The product's: a dch child whose stdout is read line by line. Never under XCTest (rows put a fake here).
    static var follow: Follow = { path, args, env, lines, ended in
        guard NSClassFromString("XCTestCase") == nil else { return {} }
        let child = XrayChild()
        DispatchQueue.global(qos: .utility).async {
            // #1638: each batch straight to the follow's sink, off main (it coalesces them on its queue, #1629)
            let status = streamLines(child, path, args, env) { lines($0) }
            DispatchQueue.main.async { MainActor.assumeIsolated { ended(status) } }   // the follow drains what waits first
        }
        return { child.cancel() }
    }

    /// The follow's blocking body: spawn, split stdout into lines (each at most XrayChapters.maxBytes: a longer one ends
    /// the stream), wait. The exit is marked on the child before it can be signalled again (as runBounded). `cap`: rows'.
    nonisolated static func streamLines(_ child: XrayChild, _ path: String, _ args: [String], _ env: [String: String],
                                        cap: Int = XrayChapters.maxBytes,
                                        _ batch: @escaping @Sendable ([Data]) -> Void) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in child.reaped(); exited.signal() }
        do { try p.run() } catch { return -1 }
        child.started(p.processIdentifier)
        // #1475 c: stderr drained beside stdout (a full pipe would stall dch); its first 4 KB kept for the refusal check
        let errHead = OSAllocatedUnfairLock(initialState: Data()), drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while case let c = err.fileHandleForReading.availableData, !c.isEmpty {
                errHead.withLock { if $0.count < 4096 { $0.append(c.prefix(4096 - $0.count)) } }
            }
            drained.signal()
        }
        var split = XrayLineSplit()
        split.cap = cap
        while case let chunk = out.fileHandleForReading.availableData, !chunk.isEmpty {
            guard let ls = split.take(chunk) else { child.cancel(); break }
            if !ls.isEmpty { batch(ls) }
        }
        exited.wait()
        if p.terminationStatus == 2, drained.wait(timeout: .now() + 2) == .success,
           String(decoding: errHead.withLock { $0 }, as: UTF8.self).contains("bad usage: --tasks and --follow") { return followTasksRefused }
        return p.terminationStatus
    }
}

/// NDJSON framing: whole lines out, the partial tail kept; nil once the tail passes `cap` (no line is that long).
struct XrayLineSplit {
    var cap = XrayChapters.maxBytes
    private var tail = Data()
    /// #1629: bytes searched for a newline or copied to keep the tail, so far (the cost row: each byte about once,
    /// not once per chunk or per line).
    private(set) var touched = 0

    mutating func take(_ chunk: Data) -> [Data]? {
        // #1629: only the new bytes are searched (the kept tail has no newline); the rest is copied once per chunk
        var from = tail.endIndex, start = tail.startIndex
        tail.append(chunk)
        var out: [Data] = []
        while let nl = tail[from...].firstIndex(of: 0x0A) {
            touched &+= nl + 1 - from   // a counter only: wrapping is harmless
            if nl > start { out.append(Data(tail[start..<nl])) }
            (start, from) = (nl + 1, nl + 1)
        }
        touched &+= tail.endIndex - from
        if start > tail.startIndex { tail = Data(tail[start...]); touched &+= tail.count }
        return tail.count > cap ? nil : out
    }
}

/// #1629: a follow's lines read but not yet taken (#1638: on its queue). `add` is true for the first lines since the last drain:
/// the reader schedules one drain for them and the lines after join it. Bounded as the main queue's blocks were: by
/// what dch writes while main is busy (each line at most XrayLineSplit's cap).
final class XrayPendingLines: Sendable {
    /// At most one take per follow per 100 ms (dch batches its deltas every 250 ms).
    static let wait = 0.1
    private let lines = OSAllocatedUnfairLock(initialState: [Data]())

    func add(_ ls: [Data]) -> Bool {
        lines.withLock { held in
            let first = held.isEmpty
            held += ls
            return first && !ls.isEmpty
        }
    }

    func drain() -> [Data] { lines.withLock { held in defer { held = [] }; return held } }
}

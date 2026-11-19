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
            for l in rows.map({ $0.line }) + (done.map { [$0] } ?? []) { out.append(0x0A); out.append(l) }
            return out
        }
    }

    let target: XrayTarget
    /// nil until the first snapshot; a reset leaves an empty state until the snapshot after it.
    @Published private(set) var state: State?
    /// The stream ended before any snapshot (exit 2 from a dch without the form, no session, unreachable), or its object
    /// grew past maxKept (#1475 a2).
    @Published private(set) var failed = false
    /// The snapshot with every delta since applied: dch's `--json` object of this moment (README "X-ray queries").
    private var object: [String: Any]?
    /// #1475 a2 (QA r1436 s1): the bytes `object` holds (the snapshot line, plus each delta line, less what a delta
    /// replaced or dropped), bounded as XrayChapters.parse bounds one read; rows set it and restore it.
    static var maxKept = XrayChapters.maxBytes
    private var kept = 0
    /// #1475 c2 (QA r1451 s1): the most rows one block keeps, as the one-shot parsers (XrayTasks.maxRows, memory's too);
    /// past it the follow ends like pastCap. Rows set it and restore it.
    static var maxBlockRows = XrayTasks.maxRows
    /// #1475 c: the kept blocks by row key ("task", "memory"), the one whose done line has not come, the ones changed.
    private var blocks: [String: Block] = [:]
    private var openBlock: String?
    private var dirty: Set<String> = []
    /// #1475 c: this run carries `--tasks --memory` (the probed dch is 1.91.0 or newer and the host did not refuse it).
    private(set) var withTasks = false
    private var tasksRefused = false
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
        stopProcess = XrayPanels.follow(dch, target.followArgs(tasks: withTasks), target.env,
                                        { [weak self] in self?.take($0) }, { [weak self] in self?.ended($0) })
    }

    /// SIGTERM (the LRU's eviction); the state goes with the follow.
    func stop() {
        let s = stopProcess
        stopProcess = nil
        s?()
    }

    private func ended(_ status: Int32) {
        guard stopProcess != nil else { return }   // stopped by us: not news
        stopProcess = nil
        // #1475 c: an older host's "bad usage: --tasks and --follow": the same follow without them, once; polls for those
        if status == XrayPanels.followTasksRefused, withTasks, object == nil { tasksRefused = true; return start(dch) }
        if object == nil { failed = true; onEnd(self) }   // never a snapshot: the panels go back to today's reads
    }

    /// One batch of lines, in order; the state is built once per batch.
    func take(_ lines: [Data]) {
        for d in lines {
            guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            // #1475 c: a block's rows and done line carry no schema (the one-shot lines); a delta may
            if takeBlockLine(o, d) {
                if pastCap() { return }
                continue
            }
            guard o["schema"] as? Int == 1 else { continue }
            XrayRefResults.followed(target, o)   // #1567: a ref, evict or reset drops the windows' cached --ref answers
            // d.count is at most XrayLineSplit's cap and kept at most maxKept after each line: the sum cannot overflow
            if let s = o["snapshot"] as? [String: Any] { object = s; kept = d.count; dirty.formUnion(Self.whole); continue }
            if o["reset"] != nil {
                object = ["schema": 1, "chapters": [Any](), "refs": [Any]()]; kept = 0
                (blocks, openBlock) = ([:], nil); dirty = Self.whole.union(["task", "memory"])   // #1475 c: the blocks come again after it
                continue
            }
            if o["source"] != nil {   // #1475 c: a tasks (with `session`) or memory header starts its block again
                let k = o["session"] != nil ? "task" : "memory"
                if let cut = openBlock, cut != k { dirty.insert(cut) }   // a block with no done line ends here (partial)
                blocks[k] = Block(d); openBlock = k   // shown at its done line, not row by row
                if pastCap() { return }
                continue
            }
            guard var obj = object else { continue }   // a delta before any snapshot has nothing to apply to
            if let c = o["chapter"] as? [String: Any] {
                var list = obj["chapters"] as? [Any] ?? []
                if let a = c["anchor"] as? String, let k = list.lastIndex(where: { ($0 as? [String: Any])?["anchor"] as? String == a }) {
                    kept -= Self.bytes(list[k])
                    list[k] = c
                } else {
                    list.append(c)
                    if list.count > XrayChapters.maxRows {   // the newest, as parse
                        let n = list.count - XrayChapters.maxRows
                        kept -= list.prefix(n).reduce(0) { $0 + Self.bytes($1) }
                        list.removeFirst(n)
                    }
                }
                obj["chapters"] = list
                dirty.insert("chapters")
            } else if let r = o["ref"] as? [String: Any], let key = r["key"] as? String {
                var list = obj["refs"] as? [Any] ?? []
                let k = list.firstIndex { ($0 as? [String: Any])?["key"] as? String == key }
                // #1629: a ref line equal to the kept ref changes nothing: no parse, no $state, no redraw
                if let k, (r["count"] as? Int).map({ $0 <= 0 }) != true, (list[k] as? NSDictionary)?.isEqual(to: r) == true { continue }
                dirty.insert("refs")
                if let k { kept -= Self.bytes(list[k]) }
                if (r["count"] as? Int).map({ $0 <= 0 }) == true { if let k { list.remove(at: k) } }
                else if let k { list[k] = r }
                // shortcut: a new key past dch's 2000 is not held (no dropped_keys bump), until the next snapshot
                else if list.count < XrayRefs.maxRows { list.append(r) }
                obj["refs"] = list
            } else if let e = o["evict"] as? [String: Any], let seq = e["seq"] as? Int {
                let all = obj["chapters"] as? [Any] ?? []
                let keep = all.filter { (($0 as? [String: Any])?["offset"] as? Int).map { $0 >= seq } ?? true }
                kept -= all.reduce(0) { $0 + Self.bytes($1) } - keep.reduce(0) { $0 + Self.bytes($1) }
                obj["chapters"] = keep
                dirty.insert("chapters")
            } else { continue }
            kept += d.count   // a removal (count 0, evict) adds its own small line too
            object = obj
            if pastCap() { return }
        }
        guard !dirty.isEmpty, let object else { return }
        // #1475 c: a block is parsed again only when it changed (up to 50000 rows); #1629: so are refs and chapters (a
        // delta changes only its own part; the top-level fields and the corpus change only with a snapshot or reset)
        let all = state == nil || dirty.contains("snapshot")
        let tasks = dirty.contains("task") ? blocks["task"].map { XrayTasks.parse($0.data) } : state?.tasks
        let memory = dirty.contains("memory") ? blocks["memory"].map { XrayMemory.parse($0.data) } : state?.memory
        let chapters = all || dirty.contains("chapters"), refs = all || dirty.contains("refs")
        dirty = []
        applies += 1
        if chapters { parsed.chapters += 1 }
        if refs { parsed.refs += 1 }
        state = State(chapters: chapters ? XrayChapters.parse(object) : state?.chapters,
                      refs: refs ? XrayRefs.parse(object) : state?.refs,
                      anchors: chapters ? XrayPanelModel.anchors(object) : state?.anchors ?? [:],
                      tasks: tasks, memory: memory, corpus: all ? XrayChapters.corpus(object) : state?.corpus)
    }

    /// #1629: what a snapshot or reset makes stale (every part of the object); a delta marks only its own part.
    private static let whole: Set<String> = ["snapshot", "chapters", "refs"]
    /// #1629: state builds so far and the parts parsed in them (the cost rows count them: a burst of lines is one
    /// build, a repeated line none, a ref line parses no chapters). Counters only: they never reach Int.max.
    private(set) var applies = 0
    private(set) var parsed = (refs: 0, chapters: 0)

    /// #1475 a2 (QA r1436 s1): past the whole-object cap the follow ends and the panels read as today (giveUpFollow);
    /// #1475 c: the blocks' bytes count too (each sum at most maxKept plus one line after the check per line: no overflow).
    /// #1475 c2: so does a block's row count (about 20-byte rows fit 800k in 16 MiB; parse keeps 50,000 and every delta
    /// scans the rows). shortcut: the per-delta firstIndex over the rows stays linear, now bounded by maxBlockRows; an
    /// id index would need re-numbering on every removal.
    private func pastCap() -> Bool {
        guard kept + blocks.values.reduce(0, { $0 + $1.bytes }) > Self.maxKept
                || blocks.values.contains(where: { $0.rows.count > Self.maxBlockRows }) else { return false }
        object = nil; failed = true; onEnd(self)
        return true
    }

    /// #1475 c: a block's row or done line, or a `task` / `memory` delta (by id; `gone` removes; a delta for no block
    /// yet has nothing to apply to). false: not one of these lines.
    private func takeBlockLine(_ o: [String: Any], _ d: Data) -> Bool {
        if o["done"] != nil, let k = openBlock {
            blocks[k]?.done = d; blocks[k]?.bytes += d.count; openBlock = nil; dirty.insert(k)
            return true
        }
        guard let k = ["task", "memory"].first(where: { o[$0] != nil }), let row = o[k] as? [String: Any] else { return false }
        guard var b = blocks[k] else { return true }
        let id = row["id"] as? String, gone = row["gone"] as? Bool == true
        if openBlock == k {
            b.rows.append((id, d)); b.bytes += d.count   // the block's own row, as parse reads it
        } else if let id, let i = b.rows.firstIndex(where: { $0.id == id }) {
            b.bytes -= b.rows[i].line.count
            if gone { b.rows.remove(at: i) } else { b.rows[i].line = d; b.bytes += d.count }
        } else if id != nil, !gone {
            b.rows.append((id, d)); b.bytes += d.count
        } else { return true }   // gone for a row not kept, or no id: nothing to apply
        blocks[k] = b
        if openBlock != k { dirty.insert(k) }   // an open block shows at its done line
        return true
    }

    /// One kept element's size as JSON (its line's, give or take the wrapper and escapes); 0 for what is not a JSON
    /// object or array (data(withJSONObject:) raises on those).
    private static func bytes(_ e: Any) -> Int {
        guard JSONSerialization.isValidJSONObject(e) else { return 0 }
        return (try? JSONSerialization.data(withJSONObject: e, options: .withoutEscapingSlashes).count) ?? 0
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
    /// `tasks`, dch 1.91.0's `--xray <n> --follow --tasks --memory --json`.
    func followArgs(tasks: Bool) -> [String] { ["--xray", name, "--follow"] + (tasks ? ["--tasks", "--memory"] : []) + ["--json"] }
}

extension XrayFollow {
    /// The dch that has `--xray <n> --follow --json` with `reset` (it predates 1.66.0, README "X-ray queries"): every
    /// dch XrayTabs.gate lets in. A remote host's older dch exits before a snapshot: that target falls back (`failed`).
    static let minimumDch = XrayTabs.minimumDch
    /// #1475 c: `--follow --tasks --memory` (dch #446).
    static let tasksDch = [1, 91, 0]
}

extension XrayPanels {
    /// One follow: (path, argv, env, lines, ended) -> its stop (SIGTERM). `lines` gets each batch of whole lines in
    /// order, `ended` the exit status once, after the last batch; both on main.
    typealias Follow = @MainActor (_ path: String, _ args: [String], _ env: [String: String],
                                   _ lines: @escaping @MainActor @Sendable ([Data]) -> Void,
                                   _ ended: @escaping @MainActor @Sendable (Int32) -> Void) -> () -> Void

    /// #1475: the gate for follows (XrayFollow.minimumDch on the probed dch). Off under XCTest as searchTab is, so the
    /// rows that count chapters reads keep them; rows set it and restore it.
    static var followOK: @MainActor () -> Bool = {
        NSClassFromString("XCTestCase") == nil && probed.map { DchCommand.isAtLeast($0.version, XrayFollow.minimumDch) } == true
    }

    /// #1475 c: a follow carries Tasks and Memory on the probed dch 1.91.0 or newer (rows set `probed`).
    static var followTasksOK: @MainActor () -> Bool = { probed.map { DchCommand.isAtLeast($0.version, XrayFollow.tasksDch) } == true }

    /// #1475 c: streamLines' answer for exit 2 with "bad usage: --tasks and --follow" on stderr (an older host).
    nonisolated static let followTasksRefused = Int32.min + 1

    /// The product's: a dch child whose stdout is read line by line. Never under XCTest (rows put a fake here).
    static var follow: Follow = { path, args, env, lines, ended in
        guard NSClassFromString("XCTestCase") == nil else { return {} }
        let child = XrayChild(), pending = XrayPendingLines()
        DispatchQueue.global(qos: .utility).async {
            let status = streamLines(child, path, args, env) { batch in
                // #1629: one main hop per wait, not per read: a burst of batches is one take (one state build)
                guard pending.add(batch) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + XrayPendingLines.wait) {
                    MainActor.assumeIsolated { let ls = pending.drain(); if !ls.isEmpty { lines(ls) } }
                }
            }
            DispatchQueue.main.async {   // after every batch: what still waits goes first
                MainActor.assumeIsolated { let ls = pending.drain(); if !ls.isEmpty { lines(ls) }; ended(status) }
            }
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

/// #1629: a follow's lines read but not yet taken on main. `add` is true for the first lines since the last drain:
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

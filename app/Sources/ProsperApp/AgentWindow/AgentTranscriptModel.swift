import Foundation
import os

// #786 Agent window, spike A: one session's conversation model. Rules 4 (version
// banner), 5 (health → terminal-first), 6 (session ↔ transcript mapping), 9
// (bounded cost) and 11 (canary). No app wiring yet: a caller supplies
// `AgentTranscriptSource` from dch's --ls-json row and shows `AgentTranscriptView`.

/// The Claude Code versions the decoder was tested on (fixtures under
/// Tests/Fixtures/claude-code/). Above `upper`, the window shows a quiet banner.
enum ClaudeCodeCompat {
    static let lower = "2.1.223"
    static let upper = "2.1.318"
    static let newerBanner = "Newer Claude Code: some details may show simplified"

    static func parts(_ v: String) -> [Int] { DchCommand.masterVersion(v) }
    /// True when `v` is a plain version above the tested range.
    static func isNewer(_ v: String) -> Bool {
        let p = parts(v)
        return !p.isEmpty && p != parts(upper) && DchCommand.isAtLeast(p, parts(upper))
    }
    /// Version strings come from a file: digits and dots only, short, or "unknown".
    static func sanitized(_ v: String?) -> String {
        guard let v, !v.isEmpty, v.count <= 24, v.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else {
            return "unknown"
        }
        return v
    }
}

// MARK: - Assembler: entries → blocks (pairs tools, nests sidechains, bounds memory)

struct TranscriptAssembler {
    var maxBlocks = 2_000
    var maxChildren = 300
    var maxPending = 256

    private(set) var blocks: [TranscriptBlock] = []
    /// Top-level blocks dropped for the memory bound (their tiers stay counted).
    private(set) var dropped = 0
    private(set) var droppedCounts: [String: TierCounts] = [:]
    private(set) var hiddenCounts: [String: Int] = [:]
    private(set) var latestVersion: String?
    /// The newest entry's working directory: the header's project line.
    private(set) var cwd: String?
    private var lastVersion = "unknown"
    private(set) var nextID = 0

    private struct Pending { var block: Int; var thread: Int?; var name: String; var input: [String: Any] }
    private var pending: [String: Pending] = [:]
    private var pendingOrder: [String] = []
    /// Results whose call is on an earlier page; bounded by `maxPending` (tests read the count).
    private(set) var orphans: [String: (block: Int, thread: Int?, result: ToolResultInfo)] = [:]
    private var threads: [String: Int] = [:]
    private var agentTitles: [String: String] = [:]

    var hiddenTotal: Int { hiddenCounts.values.reduce(0, +) }

    mutating func add(_ e: DecodedEntry, source: Range<UInt64>?) {
        let v = e.version.map { ClaudeCodeCompat.sanitized($0) } ?? lastVersion
        lastVersion = v
        if let c = e.cwd { cwd = c }
        if v != "unknown", latestVersion.map({ !DchCommand.isAtLeast(ClaudeCodeCompat.parts($0), ClaudeCodeCompat.parts(v)) }) ?? true {
            latestVersion = v
        }
        for item in e.items {
            switch item {
            case .hidden:
                hiddenCounts[v, default: 0] += 1
            case .block(let body, let tier):
                if case .compaction(nil, nil, let summary?) = body, mergeSummary(summary, sidechain: e.sidechain) { continue }
                append(TranscriptBlock(id: take(), body: body, tier: tier, version: v, source: source), sidechain: e.sidechain)
            case .toolUse(let id, let name, let input):
                let (body, tier) = ToolRenderer.render(name: name, input: input, result: nil)
                let loc = append(TranscriptBlock(id: take(), body: body, tier: tier, version: v, source: source),
                                 sidechain: e.sidechain)
                guard let id else { continue }
                pending[id] = Pending(block: loc.block, thread: loc.thread, name: name, input: input)
                pendingOrder.append(id)
                if pendingOrder.count > maxPending { pending[pendingOrder.removeFirst()] = nil }
            case .toolResult(let id, let r):
                if let id, let p = pending.removeValue(forKey: id) {
                    let (body, tier) = ToolRenderer.render(name: p.name, input: p.input, result: r)
                    update(p.block, thread: p.thread) { $0.body = body; $0.tier = tier }
                    if let agent = TranscriptKeys.str(r.extra as? [String: Any], "agentId") {
                        let title = TranscriptKeys.str(p.input, "description") ?? p.name
                        agentTitles[agent] = title
                        // Its sidechain usually streams in before this result: retitle the thread.
                        if let t = threads[agent], let i = index(t) { blocks[i].body = .thread(agentId: agent, title: title) }
                    }
                } else {
                    let body = ToolRenderer.generic(name: "Tool result", input: [:], result: r)
                    let loc = append(TranscriptBlock(id: take(), body: body, tier: .generic, version: v, source: source),
                                     sidechain: e.sidechain)
                    if let id { orphans[id] = (loc.block, loc.thread, r) }
                    // ponytail: evicts an arbitrary orphan past the bound; only paging uses them.
                    if orphans.count > maxPending { orphans.remove(at: orphans.startIndex) }
                }
            }
        }
    }

    /// Per-version tier counts: live blocks, dropped blocks and hidden noise.
    func counts() -> [String: TierCounts] {
        var c = droppedCounts
        func walk(_ bs: [TranscriptBlock]) {
            for b in bs {
                if case .thread = b.body { walk(b.children); continue }
                if b.failed { c[b.version, default: .init()].failed += 1 }
                else if b.tier == .specific { c[b.version, default: .init()].specific += 1 }
                else { c[b.version, default: .init()].generic += 1 }
                if b.degraded { c[b.version, default: .init()].degraded += 1 }
            }
        }
        walk(blocks)
        for (v, n) in hiddenCounts { c[v, default: .init()].hidden += n }
        return c
    }

    /// Live blocks only, all versions: the health check's input.
    func liveCounts() -> TierCounts {
        var a = TranscriptAssembler()
        a.blocks = blocks
        return a.counts().values.reduce(TierCounts(), +)
    }

    /// The last block still waits on a tool (a long Bash, a subagent at work): a quiet
    /// file then is expected, not stale. A subagent counts while its Agent/Task call
    /// is open or one of its own steps is.
    var toolPending: Bool {
        guard let last = blocks.last else { return false }
        let isThread = if case .thread = last.body { true } else { false }
        return pending.values.contains { p in
            if p.thread == nil && p.block == last.id { return true }
            return isThread && (p.thread == last.id || (p.thread == nil && (p.name == "Agent" || p.name == "Task")))
        }
    }

    /// Paging: put an earlier page's blocks in front, pairing its tool calls with
    /// results that arrived here as orphans; the page's own orphans carry over for
    /// the page before it.
    mutating func prepend(_ page: TranscriptAssembler) {
        // Below every id here, children included (a thread's first child takes its id before the thread).
        let floor = blocks.first.map { min($0.id, $0.children.first?.id ?? $0.id) } ?? nextID
        let shift = floor - page.nextID
        func renumber(_ b: TranscriptBlock) -> TranscriptBlock {
            var b = TranscriptBlock(id: b.id + shift, body: b.body, tier: b.tier, version: b.version,
                                    source: b.source, children: b.children, droppedChildren: b.droppedChildren)
            b.children = b.children.map(renumber)
            return b
        }
        var front = page.blocks.map(renumber)
        for (id, p) in page.pending {
            guard let o = orphans.removeValue(forKey: id) else { continue }
            let (body, tier) = ToolRenderer.render(name: p.name, input: p.input, result: o.result)
            if let i = front.firstIndex(where: { $0.id == (p.thread ?? p.block) + shift }) {
                if p.thread != nil, let j = front[i].children.firstIndex(where: { $0.id == p.block + shift }) {
                    front[i].children[j].body = body
                    front[i].children[j].tier = tier
                } else if p.thread == nil {
                    front[i].body = body
                    front[i].tier = tier
                }
            }
            remove(o.block, thread: o.thread)
        }
        blocks = front + blocks
        for (id, o) in page.orphans where orphans[id] == nil {
            orphans[id] = (o.block + shift, o.thread.map { $0 + shift }, o.result)
        }
        // ponytail: same arbitrary eviction as add(); only paging uses orphans.
        while orphans.count > maxPending { orphans.remove(at: orphans.startIndex) }
        for (v, n) in page.hiddenCounts { hiddenCounts[v, default: 0] += n }
    }

    // MARK: private

    private mutating func take() -> Int { defer { nextID += 1 }; return nextID }

    @discardableResult
    private mutating func append(_ b: TranscriptBlock, sidechain: String?) -> (block: Int, thread: Int?) {
        guard let agent = sidechain else {
            blocks.append(b)
            trim()
            return (b.id, nil)
        }
        let tid: Int
        if let t = threads[agent], index(t) != nil { tid = t } else {
            tid = take()
            threads[agent] = tid
            // Before the Agent call's result names it, the newest open Agent call is the best guess.
            let open = pendingOrder.reversed().compactMap { pending[$0] }.first { $0.name == "Agent" || $0.name == "Task" }
            let title = agentTitles[agent] ?? open.flatMap { TranscriptKeys.str($0.input, "description") } ?? "Subagent"
            blocks.append(TranscriptBlock(id: tid, body: .thread(agentId: agent, title: title),
                                          tier: .specific, version: b.version, source: nil))
            trim()
        }
        guard let ti = index(tid) else { return (b.id, nil) }
        blocks[ti].children.append(b)
        if blocks[ti].children.count > maxChildren {
            let gone = blocks[ti].children.removeFirst()
            blocks[ti].droppedChildren += 1
            account(gone)
        }
        return (b.id, tid)
    }

    private mutating func trim() {
        while blocks.count > maxBlocks {
            let gone = blocks.removeFirst()
            dropped += 1
            account(gone)
            if case .thread(let agent, _) = gone.body { threads[agent] = nil }
        }
    }

    private mutating func account(_ b: TranscriptBlock) {
        var a = TranscriptAssembler()
        a.blocks = [b]
        for (v, c) in a.counts() { droppedCounts[v] = (droppedCounts[v] ?? .init()) + c }
    }

    private mutating func mergeSummary(_ s: Clip, sidechain: String?) -> Bool {
        guard sidechain == nil, let i = blocks.indices.last,
              case .compaction(let trig, let pre, nil) = blocks[i].body else { return false }
        blocks[i].body = .compaction(trigger: trig, preTokens: pre, summary: s)
        return true
    }

    private func index(_ id: Int) -> Int? {
        var lo = 0, hi = blocks.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if blocks[mid].id == id { return mid }
            if blocks[mid].id < id { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    private mutating func update(_ id: Int, thread: Int?, _ f: (inout TranscriptBlock) -> Void) {
        if let thread {
            guard let t = index(thread), let c = blocks[t].children.firstIndex(where: { $0.id == id }) else { return }
            f(&blocks[t].children[c])
        } else if let i = index(id) {
            f(&blocks[i])
        }
    }

    private mutating func remove(_ id: Int, thread: Int?) {
        if let thread, let t = index(thread) { blocks[t].children.removeAll { $0.id == id } }
        else if let i = index(id) { blocks.remove(at: i) }
    }
}

// MARK: - The session model

/// What a caller supplies per session (from dch --ls-json, dch ≥ 1.30.0).
struct AgentTranscriptSource: Equatable {
    let key: AgentSessionKey
    /// The serving master's dch version ("" when too old to say).
    var dchVersion: String
    /// dch's state ("working", "blocked", "done", "idle", "").
    var dchState: String
    var sessionId: String?
    var transcriptPath: String?
}

enum AgentWindowMode: Equatable {
    case conversation
    /// A brief null after /clear: the last view stays, with this hint.
    case waiting(String)
    /// The terminal is the better view; the one-line reason says why.
    case terminalFirst(String)
}

/// #797: a value handed once between the IO queue and main. The assembler and the
/// decoded entries hold JSON (`[String: Any]`), which is not Sendable; each box is
/// filled on one side and read on the other after the hop, never shared.
struct TranscriptHandoff<T>: @unchecked Sendable {
    var value: T
}

@MainActor
final class AgentTranscriptModel: ObservableObject {
    nonisolated static let minimumDch = [1, 30, 0]
    nonisolated static let nullGrace: TimeInterval = 30
    nonisolated static let staleAfter: TimeInterval = 180
    nonisolated static let healthMinBlocks = 12
    nonisolated static let healthThreshold = 0.5

    @Published private(set) var blocks: [TranscriptBlock] = []
    @Published private(set) var mode: AgentWindowMode = .terminalFirst("No session selected")
    @Published private(set) var banner: String?
    @Published private(set) var hiddenCount = 0
    @Published private(set) var olderAvailable = false
    /// The newest entry's working directory (the window header's project line).
    @Published private(set) var cwd: String?
    /// "Show the conversation anyway" over a terminal-first reason. Per session:
    /// #797 (c) resets it when another session is selected.
    @Published var showAnyway = false

    private(set) var source: AgentTranscriptSource?
    private(set) var running = false
    private(set) var tail: TranscriptTail?
    private(set) var assembler = TranscriptAssembler()
    private var watch: AnyObject?
    private var timer: Timer?
    private var nullSince: Date?
    private var lastGrowth: Date?
    private var missing = false

    /// #797 (a): file reads, decoding, assembly and paging run on this serial queue;
    /// every result is applied on main.
    nonisolated static let io = DispatchQueue(label: "eu.illegible.prosper.agent-transcript", qos: .userInitiated)
    /// Where that work runs. Tests that step the model synchronously run it inline.
    var offMain: (@escaping @Sendable () -> Void) -> Void = { AgentTranscriptModel.io.async(execute: $0) }
    /// Bumped whenever the tail or the assembler is replaced (open, close, stop): a
    /// result started before is dropped, never applied to another file or session.
    private(set) var generation = 0
    /// One read in flight per generation; a poll asked for meanwhile runs after it.
    private(set) var busy = false
    private var pollAgain = false

    // Seams.
    var now: () -> Date = Date.init
    var makeWatch: (String, @escaping @MainActor () -> Void) -> AnyObject? = { TranscriptWatch(path: $0, onChange: $1) }
    var pageBytes: UInt64 = 1 << 20
    var maxBlocks = 2_000
    var tickInterval: TimeInterval = 2
    private(set) var watchArms = 0

    var counts: [String: TierCounts] { assembler.counts() }
    var latestVersion: String? { assembler.latestVersion }

    /// Rule 6: follow dch's mapping. Never guesses a path.
    func update(_ s: AgentTranscriptSource) {
        let old = source
        source = s
        // Another session: never keep (or keep polling) the previous one's transcript.
        if let old, old.key != s.key {
            close()
            nullSince = nil
            showAnyway = false
        }
        if !Self.dchSupportsMapping(s.dchVersion) {
            close()
        } else if let path = s.transcriptPath, !path.isEmpty, s.sessionId != nil {
            nullSince = nil
            // /clear and resume rotate the id (and the file): a new conversation.
            if path != tail?.path || s.sessionId != old?.sessionId { open(path) }
        } else if nullSince == nil {
            nullSince = now()   // keep the last view for now; evaluate() decides
        }
        evaluate()
    }

    nonisolated static func dchSupportsMapping(_ v: String) -> Bool {
        let p = DchCommand.masterVersion(v)
        return !p.isEmpty && DchCommand.isAtLeast(p, minimumDch)
    }

    /// The view appeared: tail and watch. Nothing runs before this or after `stop`.
    func start() {
        guard !running else { return }
        running = true
        if let path = tail?.path { open(path) }
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The view closed: stop the watch and timer and free the blocks (per-session
    /// memory is zero while closed; reopening re-reads only the last page). A read
    /// still in flight is dropped when it lands.
    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        watch = nil
        if let path = tail?.path { tail = TranscriptTail(path: path, pageBytes: pageBytes) }
        assembler = fresh()
        bump()
        publish()
    }

    /// Timer / test hook: catch up on the file and re-check null grace and staleness.
    func tick() {
        guard running else { return }
        if watch == nil, let path = tail?.path { arm(path) }
        poll()
    }

    /// Reads and decodes the next chunk off main, then applies it on main.
    func poll() {
        guard running, let t = tail else { evaluate(); return }
        guard !busy else { pollAgain = true; return }
        busy = true
        let gen = generation, pageBytes = pageBytes
        let job = TranscriptHandoff(value: (t, assembler, fresh()))
        offMain { [weak self] in
            let r = Self.read(job.value.0, into: job.value.1, fresh: job.value.2, pageBytes: pageBytes)
            Self.onMain { self?.finishPoll(r, gen) }
        }
    }

    struct PollResult {
        var tail: TranscriptTail
        var assembler: TranscriptAssembler
        /// nil: unchanged (two reopens in a row).
        var missing: Bool?
        var grew = false
        /// Replaced or shrunk: the watch re-arms on the new file.
        var reopened = false
        var more = false
    }

    /// The IO half of `poll`: no main-actor state, only the values handed in.
    nonisolated static func read(_ t0: TranscriptTail, into a0: TranscriptAssembler, fresh: TranscriptAssembler,
                                 pageBytes: UInt64) -> TranscriptHandoff<PollResult> {
        var r = PollResult(tail: t0, assembler: a0)
        var reopens = 0
        loop: while true {
            switch r.tail.poll() {
            case .missing:
                r.missing = true
                break loop
            case .reopened:
                // Rule 6: inode change or shrink → start over on the same path.
                reopens += 1
                r.reopened = true
                r.assembler = fresh
                r.tail = TranscriptTail(path: r.tail.path, pageBytes: pageBytes)
                if reopens > 1 { break loop }
            case .lines(let lines, let more):
                r.missing = false
                r.grew = !lines.isEmpty
                for l in lines { r.assembler.add(TranscriptDecoder.decode(l), source: l.range) }
                r.more = more
                break loop
            }
        }
        return TranscriptHandoff(value: r)
    }

    private func finishPoll(_ h: TranscriptHandoff<PollResult>, _ gen: Int) {
        guard gen == generation else { return }
        busy = false
        let r = h.value
        tail = r.tail
        assembler = r.assembler
        if r.reopened { watch = nil }
        if let m = r.missing { missing = m }
        if r.grew { lastGrowth = now() }
        if running, watch == nil, !missing { arm(r.tail.path) }
        publish()
        if let v = assembler.latestVersion { TranscriptCanary.runIfNew(version: v, path: r.tail.path) }
        if r.more || pollAgain {
            pollAgain = false
            poll()
        }
    }

    /// Rule 9 paging: decode the page before the earliest loaded line, while the
    /// per-session block bound has room. Read, decoded and prepended off main.
    func loadEarlier() {
        guard running, let t = tail, !atHistoryCap, !busy else { return }
        busy = true
        let gen = generation
        let job = TranscriptHandoff(value: (t, assembler, fresh()))
        offMain { [weak self] in
            var (t, a, page) = job.value
            for l in t.previousPage() { page.add(TranscriptDecoder.decode(l), source: l.range) }
            a.prepend(page)
            let done = TranscriptHandoff(value: (t, a))
            Self.onMain { self?.finishEarlier(done, gen) }
        }
    }

    private func finishEarlier(_ h: TranscriptHandoff<(TranscriptTail, TranscriptAssembler)>, _ gen: Int) {
        guard gen == generation else { return }
        busy = false
        (tail, assembler) = (h.value.0, h.value.1)
        publish()
        if pollAgain {
            pollAgain = false
            poll()
        }
    }

    /// Lazy expand: the full text of a capped clip, re-read from its line off main.
    func fullText(_ c: Clip) async -> String? {
        guard c.capped, let r = c.source, let t = tail else { return nil }
        let run = offMain
        return await withCheckedContinuation { k in
            run { k.resume(returning: t.read(r).flatMap { TranscriptDecoder.fullText(line: $0, clip: c) }) }
        }
    }

    /// The block bound is full: older history stays in the terminal.
    var atHistoryCap: Bool { assembler.blocks.count >= maxBlocks }

    /// Runs `f` on main: inline when already there (the inline test seam), else queued.
    nonisolated static func onMain(_ f: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { f() } }
        else { DispatchQueue.main.async { MainActor.assumeIsolated { f() } } }
    }

    // MARK: private

    private func fresh() -> TranscriptAssembler {
        var a = TranscriptAssembler()
        a.maxBlocks = maxBlocks
        return a
    }

    /// A new tail or assembler: whatever is in flight belongs to the old one.
    private func bump() {
        generation += 1
        busy = false
        pollAgain = false
    }

    private func open(_ path: String) {
        bump()
        assembler = fresh()
        tail = TranscriptTail(path: path, pageBytes: pageBytes)
        missing = false
        lastGrowth = now()
        watch = nil
        publish()
        if running { poll() }
    }

    private func close() {
        bump()
        tail = nil
        watch = nil
        missing = false
        assembler = fresh()
        publish()
    }

    private func arm(_ path: String) {
        guard running else { return }
        watchArms += 1
        watch = makeWatch(path) { [weak self] in self?.poll() }
    }

    private func publish() {
        blocks = assembler.blocks
        hiddenCount = assembler.hiddenTotal
        cwd = assembler.cwd
        olderAvailable = (tail?.earliestLoaded ?? 0) > 0 || assembler.dropped > 0
        banner = assembler.latestVersion.map(ClaudeCodeCompat.isNewer) == true ? ClaudeCodeCompat.newerBanner : nil
        evaluate()
    }

    private func evaluate() {
        let m = Self.mode(source: source, hasView: tail != nil, nullSince: nullSince, missing: missing,
                          live: assembler.liveCounts(), lastGrowth: lastGrowth, toolPending: assembler.toolPending,
                          now: now())
        if m != mode { mode = m }
    }

    /// Rules 5 and 6 as one pure decision.
    nonisolated static func mode(source: AgentTranscriptSource?, hasView: Bool, nullSince: Date?, missing: Bool,
                     live: TierCounts, lastGrowth: Date?, toolPending: Bool, now: Date) -> AgentWindowMode {
        guard let s = source else { return .terminalFirst("No session selected") }
        guard dchSupportsMapping(s.dchVersion) else {
            return .terminalFirst(s.dchVersion.isEmpty ? "This dch cannot name the transcript (needs 1.30.0)"
                                                      : "dch \(s.dchVersion) cannot name the transcript (needs 1.30.0)")
        }
        if let since = nullSince {
            if hasView && now.timeIntervalSince(since) < nullGrace { return .waiting("Waiting for the next turn") }
            return .terminalFirst("No transcript matched this session")
        }
        if missing { return .terminalFirst("The transcript file is missing") }
        let simplified = live.degraded + live.failed
        if live.visible >= healthMinBlocks, Double(simplified) / Double(live.visible) >= healthThreshold {
            return .terminalFirst("Most entries show simplified (\(simplified * 100 / live.visible)%): "
                                  + "this transcript format is not recognized")
        }
        if s.dchState == "working", !toolPending, let g = lastGrowth, now.timeIntervalSince(g) > staleAfter {
            return .terminalFirst("The transcript stopped updating while the agent works")
        }
        return .conversation
    }
}

// MARK: - Canary (rule 11)

/// When a new Claude Code version first shows up, decode that session once and log
/// its tier counts (numbers and the version only, never content) for QA.
enum TranscriptCanary {
    static let log = Logger(subsystem: "eu.illegible.prosper", category: "agent-window-compat")
    @MainActor private static var logged: Set<String> = []

    /// Tier counts per version for the whole file, decoded in bounded chunks and
    /// a bounded block window (dropped blocks stay counted).
    static func scan(path: String, maxBytes: UInt64 = 256 << 20) -> [String: TierCounts] {
        var t = TranscriptTail(path: path, pageBytes: .max)
        var a = TranscriptAssembler()
        a.maxBlocks = 200
        var read: UInt64 = 0
        while read < maxBytes, case .lines(let lines, let more) = t.poll() {
            for l in lines { a.add(TranscriptDecoder.decode(l), source: l.range) }
            read = t.offset
            if !more { break }
        }
        return a.counts()
    }

    /// The logged line: counts for `v` (else all versions) and the tested range.
    static func line(version v: String, _ counts: [String: TierCounts]) -> String {
        let c = counts[v] ?? counts.values.reduce(TierCounts(), +)
        return "claude-code \(v)\(ClaudeCodeCompat.isNewer(v) ? " (newer than tested)" : ""): "
            + "specific=\(c.specific) generic=\(c.generic) degraded=\(c.degraded) failed=\(c.failed) hidden=\(c.hidden) "
            + "tested=\(ClaudeCodeCompat.lower)-\(ClaudeCodeCompat.upper)"
    }

    /// Once per version per process: scans `path` on `queue` (#797 (a): never on
    /// main) and hands the line to `emit` there. False when this version was already
    /// logged or is not a version.
    @MainActor @discardableResult
    static func runIfNew(version: String, path: String, queue: DispatchQueue = .global(qos: .utility),
                         emit: @escaping @Sendable (String) -> Void = { TranscriptCanary.log.notice("\($0, privacy: .public)") })
        -> Bool {
        let v = ClaudeCodeCompat.sanitized(version)
        guard v != "unknown", !logged.contains(v) else { return false }
        logged.insert(v)
        queue.async { emit(line(version: v, scan(path: path))) }
        return true
    }

    @MainActor static func resetForTests() { logged = [] }
}

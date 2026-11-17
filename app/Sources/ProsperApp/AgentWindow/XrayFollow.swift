import Combine
import Foundation

// #1475 (dch #445 phase 1): X-ray's Prompts, Responses and Refs come from one long-lived `dch --xray <n> --follow --json`
// per session target instead of the open's chapters read and the 5 s / 30 s chapters and Refs polls. dch README "X-ray
// queries": NDJSON lines with schema 1: `snapshot` (the `--json` object), then deltas `chapter` (a known anchor
// replaces), `ref` (whole ref by key; count 0 removes), `evict` (drop chapters below seq) and `reset` (drop everything,
// a snapshot follows). The state is the cache: a panel opened on a target that has one draws it on the first frame.
// The follow keeps running while the window or drawer is hidden (an idle follow costs dch no CPU); it ends when dch
// ends it (the session ended), or when the LRU evicts it. Tasks and Memory keep their polls (phase 2 is dch #446).

/// One target's follow and the state its lines built.
@MainActor
final class XrayFollow: ObservableObject {
    struct State {
        var chapters: [TranscriptOutline.Chapter]?
        var refs: XrayRefs?
        var anchors: [String: Int]
    }

    let target: XrayTarget
    /// nil until the first snapshot; a reset leaves an empty state until the snapshot after it.
    @Published private(set) var state: State?
    /// The stream ended before any snapshot (exit 2 from a dch without the form, no session, unreachable).
    @Published private(set) var failed = false
    /// The snapshot with every delta since applied: dch's `--json` object of this moment (README "X-ray queries").
    private var object: [String: Any]?
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
        stopProcess = XrayPanels.follow(dch, target.followArgs, target.env,
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
        if object == nil { failed = true; onEnd(self) }   // never a snapshot: the panels go back to today's reads
    }

    /// One batch of lines, in order; the state is built once per batch.
    func take(_ lines: [Data]) {
        var changed = false
        for d in lines {
            guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], o["schema"] as? Int == 1 else { continue }
            if let s = o["snapshot"] as? [String: Any] { object = s; changed = true; continue }
            if o["reset"] != nil { object = ["schema": 1, "chapters": [Any](), "refs": [Any]()]; changed = true; continue }
            guard var obj = object else { continue }   // a delta before any snapshot has nothing to apply to
            if let c = o["chapter"] as? [String: Any] {
                var list = obj["chapters"] as? [Any] ?? []
                if let a = c["anchor"] as? String, let k = list.lastIndex(where: { ($0 as? [String: Any])?["anchor"] as? String == a }) {
                    list[k] = c
                } else {
                    list.append(c)
                    if list.count > XrayChapters.maxRows { list.removeFirst(list.count - XrayChapters.maxRows) }   // the newest, as parse
                }
                obj["chapters"] = list
            } else if let r = o["ref"] as? [String: Any], let key = r["key"] as? String {
                var list = obj["refs"] as? [Any] ?? []
                let k = list.firstIndex { ($0 as? [String: Any])?["key"] as? String == key }
                if (r["count"] as? Int).map({ $0 <= 0 }) == true { if let k { list.remove(at: k) } }
                else if let k { list[k] = r }
                // shortcut: a new key past dch's 2000 is not held (no dropped_keys bump), until the next snapshot
                else if list.count < XrayRefs.maxRows { list.append(r) }
                obj["refs"] = list
            } else if let e = o["evict"] as? [String: Any], let seq = e["seq"] as? Int {
                obj["chapters"] = (obj["chapters"] as? [Any] ?? []).filter {
                    (($0 as? [String: Any])?["offset"] as? Int).map { $0 >= seq } ?? true
                }
            } else { continue }
            object = obj
            changed = true
        }
        guard changed, let object else { return }
        state = State(chapters: XrayChapters.parse(object), refs: XrayRefs.parse(object), anchors: XrayPanelModel.anchors(object))
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
    /// #1475: dch README "dch --xray <n> --follow --json  # the same object, then its deltas as NDJSON".
    var followArgs: [String] { ["--xray", name, "--follow", "--json"] }
}

extension XrayFollow {
    /// The dch that has `--xray <n> --follow --json` with `reset` (it predates 1.66.0, README "X-ray queries"): every
    /// dch XrayTabs.gate lets in. A remote host's older dch exits before a snapshot: that target falls back (`failed`).
    static let minimumDch = XrayTabs.minimumDch
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

    /// The product's: a dch child whose stdout is read line by line. Never under XCTest (rows put a fake here).
    static var follow: Follow = { path, args, env, lines, ended in
        guard NSClassFromString("XCTestCase") == nil else { return {} }
        let child = XrayChild()
        DispatchQueue.global(qos: .utility).async {
            let status = streamLines(child, path, args, env) { batch in
                DispatchQueue.main.async { MainActor.assumeIsolated { lines(batch) } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { ended(status) } }   // after every batch: main is FIFO
        }
        return { child.cancel() }
    }

    /// The follow's blocking body: spawn, split stdout into lines (each at most XrayChapters.maxBytes: a longer one ends
    /// the stream), wait. The exit is marked on the child before it can be signalled again (as runBounded).
    nonisolated static func streamLines(_ child: XrayChild, _ path: String, _ args: [String], _ env: [String: String],
                                        _ batch: @escaping @Sendable ([Data]) -> Void) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in child.reaped(); exited.signal() }
        do { try p.run() } catch { return -1 }
        child.started(p.processIdentifier)
        var split = XrayLineSplit()
        while case let chunk = out.fileHandleForReading.availableData, !chunk.isEmpty {
            guard let ls = split.take(chunk) else { child.cancel(); break }
            if !ls.isEmpty { batch(ls) }
        }
        exited.wait()
        return p.terminationStatus
    }
}

/// NDJSON framing: whole lines out, the partial tail kept; nil once the tail passes `cap` (no line is that long).
struct XrayLineSplit {
    var cap = XrayChapters.maxBytes
    private var tail = Data()

    mutating func take(_ chunk: Data) -> [Data]? {
        tail.append(chunk)
        var out: [Data] = []
        while let nl = tail.firstIndex(of: 0x0A) {
            let line = tail[tail.startIndex..<nl]
            if !line.isEmpty { out.append(Data(line)) }
            tail = Data(tail[tail.index(after: nl)...])
        }
        return tail.count > cap ? nil : out
    }
}

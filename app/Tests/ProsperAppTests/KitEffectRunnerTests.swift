import Darwin
import Foundation
import XCTest
@testable import ProsperApp

/// #1393 (#917 S5b-2c): the ordered effect runner over a REAL KitStore whose config home is <tempDir>/config. A kit source
/// is a dir under the row's tempDir() whose only file `marker` holds its version; it is copied and read as bytes, never run.
/// Every handler is a fake that records its call.
final class KitEffectRunnerTests: XCTestCase {
    static let ext = "com.example.kit"
    static let slug = "example-kit"

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func note(_ s: String) { lock.withLock { all.append(s) } }
        var log: [String] { lock.withLock { all } }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        func now() -> Date { lock.withLock { reads += 1 }; return Date() }
        var count: Int { lock.withLock { reads } }
    }

    private struct Scene {
        let root: URL
        let home: URL
        let store: KitStore
    }

    private func scene(_ ext: String = KitEffectRunnerTests.ext, _ label: String = #function) throws -> Scene {
        let root = tempDir(label)
        let home = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return Scene(root: root, home: home, store: try KitStore(configHome: home, extID: ext))
    }

    /// the source of `v` (created once) and its ref with the real tree hash
    private func ref(_ sc: Scene, _ v: String) throws -> KitRef {
        let dir = sc.root.appendingPathComponent("src-" + v, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(v.utf8).write(to: dir.appendingPathComponent("marker"))
        }
        return KitRef(version: v, treeHash: try sc.store.treeHash(of: dir.path), slug: Self.slug)
    }

    /// stage + swap straight through the store (the set-up before the row's runner)
    @discardableResult
    private func install(_ sc: Scene, _ store: KitStore, _ v: String) throws -> KitRef {
        let r = try ref(sc, v)
        _ = try store.stageCopy(from: sc.root.path + "/src-" + v, version: v, tree: r.treeHash, byteCap: 1024)
        try store.swap(version: v, tree: r.treeHash)
        return r
    }

    private func handlers(_ sc: Scene, _ calls: Calls, failShims: Set<String> = [], consent: Bool = true,
                          wiring: @escaping @Sendable (KitRef) -> Void = { _ in }) -> KitEffectHandlers {
        let (root, home, live) = (sc.root, sc.home, sc.store.layout.live)
        return KitEffectHandlers(
            source: { calls.note("source " + $0.version); return (root.path + "/src-" + $0.version, 1024) },
            validate: { calls.note("validate " + $0.version); return true },
            renderContext: {
                calls.note("render " + $0.version)
                return KitRenderContext.standard(extensionID: KitEffectRunnerTests.ext, slug: KitEffectRunnerTests.slug,
                                                 kitDir: URL(fileURLWithPath: live), home: URL(fileURLWithPath: "/Users/example"), configHome: home)
            },
            consent: { calls.note("consent " + $0.version); return consent },
            shims: {
                calls.note("shims " + $0.version)
                if failShims.contains($0.version) { throw KitStoreError.io("shims", EIO) }
                return []
            },
            applyWiring: { calls.note("wiring " + $0.version); wiring($0) })
    }

    /// Feeds every answer back to the machine in order until none is left (bounded: the machine's lists are short).
    private func drive(_ runner: KitEffectRunner, _ s: KitUpdateState, _ e: KitUpdateEvent) -> (KitUpdateState, [KitEffectResult]) {
        var state = s
        var results: [KitEffectResult] = []
        var pending = [e]
        while let next = pending.first, results.count < 20 {
            pending.removeFirst()
            let (n, r) = runner.step(state, next)
            state = n
            results.append(r)
            pending += r.events
        }
        return (state, results)
    }

    private func marker(_ dir: String) -> String? { try? String(contentsOfFile: dir + "/marker", encoding: .utf8) }
    private func kind(_ path: String) -> KitFileKind { KitPOSIXFS().kind(path) }
    private func list(_ dir: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() }

    private func staged(_ r: KitRef) -> KitUpdateEvent { .staged(version: r.version, treeHash: r.treeHash, slug: Self.slug, publisher: nil) }

    /// A full update A -> B with consent, then wiringApplied: live = B, previous = A, the older previous (retiring) dropped,
    /// nothing staged, every handler called once in the machine's order.
    func testFullUpdateWithConsentThenWiring() throws {
        let sc = try scene()
        let z = try install(sc, sc.store, "0.9.0")
        let a = try install(sc, sc.store, "1.0.0")
        let b = try ref(sc, "1.1.0")
        let calls = Calls()
        let runner = KitEffectRunner(store: sc.store, handlers: handlers(sc, calls))
        let (end, results) = drive(runner, KitUpdateState(live: a, previous: z), staged(b))
        XCTAssertTrue(results.allSatisfy { $0.failure == nil }, "\(results.compactMap(\.failure))")
        XCTAssertEqual(end, KitUpdateState(live: b, previous: a))
        XCTAssertEqual(calls.log, ["source 1.1.0", "validate 1.1.0", "render 1.1.0", "consent 1.1.0", "shims 1.1.0", "wiring 1.1.0"])
        XCTAssertEqual(results.flatMap(\.events).last, .wiringApplied("1.1.0", tree: b.treeHash))
        XCTAssertEqual(marker(sc.store.layout.live), "1.1.0")
        XCTAssertEqual(marker(sc.store.layout.previous), "1.0.0")
        XCTAssertEqual(kind(sc.store.layout.root + "/retiring"), .missing, "dropPrevious removed the older previous")
        XCTAssertEqual(kind(sc.store.layout.root + "/incoming"), .missing)
        XCTAssertEqual(kind(sc.store.layout.root + "/" + KitStore.swapStamp), .missing)
        XCTAssertEqual(list(sc.store.layout.staged), [])
    }

    /// R917-s4b-b: a rollback whose shim write fails stops there: applyWiring is never called and the shims failure is the
    /// last answer; fed back, the machine swaps back once more and lands idle with .shims.
    func testRollbackWhoseShimWriteFailsNeverAppliesWiring() throws {
        let sc = try scene()
        let a = try install(sc, sc.store, "1.0.0")
        let b = try install(sc, sc.store, "1.1.0")
        let calls = Calls()
        let runner = KitEffectRunner(store: sc.store, handlers: handlers(sc, calls, failShims: ["1.0.0"]))
        let start = KitUpdateState(live: b, previous: a)
        let (rolling, r) = runner.step(start, .rollbackRequested)
        XCTAssertEqual(r.events, [.shimsFailed("1.0.0", tree: a.treeHash)])
        XCTAssertTrue(r.failure?.hasPrefix("writeShims") == true, r.failure ?? "no failure")
        XCTAssertEqual(calls.log, ["shims 1.0.0"], "nothing after the failed shim write runs")
        XCTAssertEqual(marker(sc.store.layout.live), "1.0.0", "the swapBack before it ran")
        let (end, r2) = runner.step(rolling, .shimsFailed("1.0.0", tree: a.treeHash))
        XCTAssertEqual(end.phase, .idle)
        XCTAssertEqual(end.lastRefusal, .shims)
        XCTAssertEqual(end.live, b)
        XCTAssertEqual(r2.failure, nil)
        XCTAssertEqual(calls.log, ["shims 1.0.0", "shims 1.1.0"])
        XCTAssertFalse(calls.log.contains { $0.hasPrefix("wiring") })
        XCTAssertEqual(marker(sc.store.layout.live), "1.1.0")
        XCTAssertEqual(marker(sc.store.layout.previous), "1.0.0")
    }

    /// kit917k L2': each rename of the swap failing (live + previous present: s2 staged -> incoming, s4 previous -> retiring,
    /// s5 RENAME_SWAP, s6 incoming -> previous; 5 = the runner's one retry of s6) maps as report.txt's table, and live is never
    /// missing: before the RENAME_SWAP swapFailed with live and previous as they were; after it swapped with live = new.
    func testEachSwapThrowPointMapsAsTheTable() throws {
        let cases: [(fails: Set<Int>, swapped: Bool, live: String, previous: String?, incoming: String?, note: String?)] = [
            ([1], false, "1.0.1", "1.0.0", nil, nil),
            ([2], false, "1.0.1", "1.0.0", "1.0.2", nil),
            ([3], false, "1.0.1", "1.0.0", "1.0.2", nil),
            ([4], true, "1.0.2", "1.0.1", nil, "retried once"),
            ([4, 5], true, "1.0.2", nil, "1.0.1", "stays at incoming"),
        ]
        let base = try scene()
        for c in cases {
            let label = "fails \(c.fails.sorted())"
            let ext = "com.example.swap\(c.fails.sorted().map(String.init).joined())"
            let sc = Scene(root: base.root, home: base.home, store: try KitStore(configHome: base.home, extID: ext))
            let z = try install(sc, sc.store, "1.0.0")
            let a = try install(sc, sc.store, "1.0.1")
            let b = try ref(sc, "1.0.2")
            let failing = try KitStore(configHome: base.home, extID: ext, fs: KitEffectFailRenames(c.fails))
            let calls = Calls()
            let runner = KitEffectRunner(store: failing, handlers: handlers(sc, calls))
            let (end, results) = drive(runner, KitUpdateState(live: a, previous: z), staged(b))
            let events = results.flatMap(\.events)
            XCTAssertEqual(events.contains(.swapped("1.0.2", tree: b.treeHash)), c.swapped, label)
            XCTAssertEqual(events.contains(.swapFailed("1.0.2", tree: b.treeHash)), !c.swapped, label)
            XCTAssertEqual(marker(sc.store.layout.live), c.live, label + ": live is never missing")
            XCTAssertEqual(end.live.version, c.live, label + ": the machine agrees with the disk")
            XCTAssertEqual(marker(sc.store.layout.previous), c.previous, label)
            XCTAssertEqual(marker(sc.store.layout.root + "/incoming"), c.incoming, label)
            XCTAssertEqual(kind(sc.store.layout.root + "/retiring"), .missing, label + ": retiring restored or dropped")
            XCTAssertEqual(list(sc.store.layout.staged), [], label)
            XCTAssertEqual(end.phase, .idle, label)
            let notes = results.flatMap(\.notes)
            if let n = c.note { XCTAssertTrue(notes.contains { $0.contains(n) }, label + ": \(notes)") } else { XCTAssertEqual(notes, [], label) }
            XCTAssertEqual(calls.log.contains("wiring 1.0.2"), c.swapped, label)
            if c.incoming == "1.0.1" {
                // the old live left at incoming becomes previous before the next stage
                let plain = KitEffectRunner(store: sc.store, handlers: handlers(sc, calls, consent: false))
                _ = drive(plain, end, staged(try ref(sc, "1.0.3")))
                XCTAssertEqual(marker(sc.store.layout.previous), "1.0.1", label)
                XCTAssertEqual(kind(sc.store.layout.root + "/incoming"), .missing, label)
            }
        }
    }

    /// L2'' / QA r1252 rider (1): a crash after the RENAME_SWAP (no previous) left the old live at incoming: the runner makes
    /// it previous before the next stage, and the swap goes on from there. A crash BEFORE the RENAME_SWAP left the NEW copy at
    /// incoming: never made previous. swapBack with no previous fails with "the rollback copy is gone" and stops the list.
    func testCrashLeftIncomingIsRecoveredBeforeTheNextSwap() throws {
        let sc = try scene()
        // s2 = rename 1, s5 = 2, s6 = 3 (no previous: no s4)
        for (n, ext) in [(3, "com.example.after"), (2, "com.example.before")] {
            let one = Scene(root: sc.root, home: sc.home, store: try KitStore(configHome: sc.home, extID: ext))
            let a = try install(one, one.store, "1.0.0")
            let b = try ref(one, "1.0.1")
            _ = try one.store.stageCopy(from: one.root.path + "/src-1.0.1", version: "1.0.1", tree: b.treeHash, byteCap: 1024)
            let crashing = try KitStore(configHome: sc.home, extID: ext, fs: KitEffectFailRenames([n]))
            XCTAssertThrowsError(try crashing.swap(version: "1.0.1", tree: b.treeHash)) {
                XCTAssertEqual(($0 as? KitSwapError)?.step, n == 3 ? .keepOld : .exchange, ext)
            }
            let after = n == 3
            XCTAssertEqual(marker(one.store.layout.live), after ? "1.0.1" : "1.0.0", ext)
            XCTAssertEqual(marker(one.store.layout.root + "/incoming"), after ? "1.0.0" : "1.0.1", ext)
            XCTAssertEqual(kind(one.store.layout.previous), .missing, ext)
            let state = after ? KitUpdateState(live: b, previous: a) : KitUpdateState(live: a)
            let c = try ref(one, "1.0.2")
            let calls = Calls()
            let runner = KitEffectRunner(store: one.store, handlers: handlers(one, calls))
            let (validating, r) = runner.step(state, staged(c))
            XCTAssertEqual(r.events, [.validatedOk("1.0.2", tree: c.treeHash)], ext)
            XCTAssertEqual(marker(one.store.layout.previous), after ? "1.0.0" : nil, ext + ": only the old live becomes previous")
            XCTAssertEqual(marker(one.store.layout.root + "/incoming"), after ? nil : "1.0.1", ext)
            let (end, results) = drive(runner, validating, .validatedOk("1.0.2", tree: c.treeHash))
            XCTAssertTrue(results.allSatisfy { $0.failure == nil }, ext)
            XCTAssertEqual(end.live, c, ext)
            XCTAssertEqual(marker(one.store.layout.live), "1.0.2", ext)
            XCTAssertEqual(marker(one.store.layout.previous), after ? "1.0.1" : "1.0.0", ext)
            XCTAssertEqual(kind(one.store.layout.root + "/incoming"), .missing, ext)
            XCTAssertEqual(kind(one.store.layout.root + "/retiring"), .missing, ext)
        }
        // swapBack with no previous: a failure with the words, never a success; the shim write after it never runs
        let lone = Scene(root: sc.root, home: sc.home, store: try KitStore(configHome: sc.home, extID: "com.example.lone"))
        let a = try install(lone, lone.store, "1.0.0")
        let calls = Calls()
        let runner = KitEffectRunner(store: lone.store, handlers: handlers(lone, calls))
        let state = KitUpdateState(live: a)
        let r = runner.run([.swapBack, .writeShims("1.0.0")], state, prior: state)
        XCTAssertTrue(r.failure?.contains("the rollback copy is gone") == true, r.failure ?? "no failure")
        XCTAssertEqual(r.events, [])
        XCTAssertEqual(calls.log, [])
        XCTAssertEqual(marker(lone.store.layout.live), "1.0.0")
    }

    /// QA r1252 rider (2): the stale-temp sweep runs on the runner's queue before a stage (an aged tmp/<UUID> is gone after
    /// it), never at init, and never while an apply runs: a stage asked for during applyWiring waits for it, so the clock
    /// the sweep reads is not read during the apply.
    func testSweepRunsBeforeAStageAndNeverDuringAnApply() throws {
        let sc = try scene()
        let a = try install(sc, sc.store, "1.0.0")
        let b = try ref(sc, "1.1.0")
        let later = try ref(sc, "1.2.0")
        let temp = sc.store.layout.tmp + "/" + UUID().uuidString
        try Data("old".utf8).write(to: URL(fileURLWithPath: temp))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: temp)
        let clock = Clock()
        let calls = Calls()
        final class Box: @unchecked Sendable { var runner: KitEffectRunner? }
        let box = Box()
        let queued = DispatchSemaphore(value: 0)
        let laterState = KitUpdateState(live: b, staged: later, previous: a, phase: .validating)
        let wiring: @Sendable (KitRef) -> Void = { _ in
            let before = clock.count
            Thread {
                _ = box.runner?.run([.copyToStaged("1.2.0")], laterState, prior: laterState)
                queued.signal()
            }.start()
            Thread.sleep(forTimeInterval: 0.3)
            calls.note("sweeps during apply \(clock.count - before)")
        }
        let runner = KitEffectRunner(store: sc.store, handlers: handlers(sc, calls, wiring: wiring), now: { clock.now() })
        box.runner = runner
        XCTAssertEqual(clock.count, 0, "no sweep at init")
        XCTAssertNotEqual(kind(temp), .missing)
        let (validating, _) = runner.step(KitUpdateState(live: a), staged(b))
        XCTAssertEqual(clock.count, 1, "one sweep, before the stage")
        XCTAssertEqual(kind(temp), .missing, "the aged temp went before the stage")
        let (end, results) = drive(runner, validating, .validatedOk("1.1.0", tree: b.treeHash))
        XCTAssertTrue(results.allSatisfy { $0.failure == nil })
        XCTAssertEqual(end.live, b)
        XCTAssertEqual(queued.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(calls.log.contains("sweeps during apply 0"), "\(calls.log)")
        XCTAssertEqual(clock.count, 2, "the queued stage swept after the apply")
        XCTAssertEqual(list(sc.store.layout.staged), [KitStore.stagedName("1.2.0", later.treeHash)])
    }
}

/// A KitFS whose dirs fail the renames numbered in `fails` (counted over every KitDir rename of the store), as a crash
/// between the swap's steps leaves them; `identity` and `write` pass through, so the swap's stamp is real.
final class KitEffectFailRenames: KitFS, @unchecked Sendable {
    let fails: Set<Int>
    private let base = KitPOSIXFS()
    private let lock = NSLock()
    private var renames = 0
    init(_ fails: Set<Int>) { self.fails = fails }

    var writer: any ManagedConfigFileWriter { base.writer }
    func openDir(_ path: String) throws -> any KitDir { Dir(self, try base.openDir(path)) }
    func kind(_ path: String) -> KitFileKind { base.kind(path) }
    func names(_ dir: String) -> [String]? { base.names(dir) }
    func read(_ path: String, limit: Int) -> Data? { base.read(path, limit: limit) }
    func ensureDir(_ path: String, narrow: Bool) throws { try base.ensureDir(path, narrow: narrow) }
    func create(_ path: String, _ data: Data, mode: mode_t) throws { try base.create(path, data, mode: mode) }
    func rename(_ from: String, _ to: String) throws { try base.rename(from, to) }
    fileprivate func failsNow() -> Bool { lock.withLock { renames += 1; return fails.contains(renames) } }

    final class Dir: KitDir {
        let fs: KitEffectFailRenames
        let inner: any KitDir
        init(_ fs: KitEffectFailRenames, _ inner: any KitDir) { self.fs = fs; self.inner = inner }
        var path: String { inner.path }
        func names() -> [String]? { inner.names() }
        func kind(_ name: String) -> KitFileKind { inner.kind(name) }
        func modified(_ name: String) -> Date? { inner.modified(name) }
        func dir(_ name: String) throws -> any KitDir { Dir(fs, try inner.dir(name)) }
        func read(_ name: String, limit: Int) -> Data? { inner.read(name, limit: limit) }
        func remove(_ name: String, dir: Bool) throws { try inner.remove(name, dir: dir) }
        func rename(_ name: String, to other: any KitDir, _ newName: String, swap: Bool) throws {
            if fs.failsNow() { throw KitStoreError.io("rename", EIO) }
            try inner.rename(name, to: (other as? Dir)?.inner ?? other, newName, swap: swap)
        }
        func writable(_ name: String) -> Bool { inner.writable(name) }
        func identity(_ name: String) -> UInt64? { inner.identity(name) }
        func write(_ name: String, _ data: Data, mode: mode_t) throws { try inner.write(name, data, mode: mode) }
    }
}

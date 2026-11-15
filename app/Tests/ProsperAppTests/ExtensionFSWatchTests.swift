import Foundation
import XCTest
@testable import ProsperApp

/// Real FSEventStream round trip for `ExtensionFSWatch` (#373): the callback reads
/// `eventPaths` as a CFArray, which only holds with `kFSEventStreamCreateFlagUseCFTypes`
/// (without it the first event dereferences a `char **` as a CFArray and SIGSEGVs).
@MainActor
final class ExtensionFSWatchTests: XCTestCase {
    func testWatchDeliversChangedFilePathOnMain() throws {
        let fm = FileManager.default
        // A per-run directory under testTempRoot (not $TMPDIR's root, which is slow enough
        // to stretch FSEvents delivery); tempDir's teardown removes it (#381).
        let dir = tempDir("fsw").path
        let watcher = ExtensionFSWatch.shared
        let saved = watcher.invoke
        defer {
            watcher.unwatch(extensionID: "test.fsw", path: dir)
            watcher.invoke = saved
        }

        let fileName = "touched-\(UUID().uuidString).txt"
        let fired = expectation(description: "fs watch handler invoked")
        fired.assertForOverFulfill = false
        var got: (ext: String, handler: String, payload: String, onMain: Bool)?
        watcher.invoke = { ext, handler, payload in
            // Several batches may arrive (dir creation, coalescing): keep the first one
            // that names our file.
            guard got == nil, payload.contains(fileName) else { return }
            got = (ext, handler, payload, Thread.isMainThread)
            fired.fulfill()
        }

        watcher.watch(extensionID: "test.fsw", path: dir, handler: "onChange")
        try "hello".write(toFile: (dir as NSString).appendingPathComponent(fileName),
                          atomically: false, encoding: .utf8)
        wait(for: [fired], timeout: 5)

        let result = try XCTUnwrap(got)
        XCTAssertEqual(result.ext, "test.fsw")
        XCTAssertEqual(result.handler, "onChange")
        let obj = try JSONSerialization.jsonObject(with: Data(result.payload.utf8)) as? [String: Any]
        let paths = try XCTUnwrap(obj?["paths"] as? [String])
        XCTAssertTrue(paths.contains { $0.hasSuffix(fileName) }, "payload: \(result.payload)")
        XCTAssertTrue(result.onMain, "invoke must run on the main thread")
    }

    // MARK: #983 - rows drive events through `deliver` and run the recorded flush themselves (no wall clock).

    /// Records the scheduled flushes and the handler runs of the shared watcher; `restore` puts the hooks back.
    @MainActor
    private final class Harness {
        let watcher = ExtensionFSWatch.shared
        var works: [@MainActor @Sendable () -> Void] = []
        var runs: [(ext: String, handler: String, payload: String)] = []
        private let savedInvoke: ((String, String, String) -> Void)?
        private let savedSchedule: ((TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void)?
        var scheduled = 0

        init() {
            savedInvoke = watcher.invoke
            savedSchedule = watcher.schedule
            watcher.schedule = { [weak self] _, work in
                self?.scheduled += 1
                self?.works.append(work)
            }
            watcher.invoke = { [weak self] ext, handler, payload in self?.runs.append((ext, handler, payload)) }
        }

        func drain() {
            let pending = works
            works = []
            pending.forEach { $0() }
        }

        func restore() {
            watcher.invoke = savedInvoke
            watcher.schedule = savedSchedule
        }
    }

    /// The payload's paths and its "more" count (nil when absent).
    private func decode(_ payload: String?) -> (paths: [String], more: Int?) {
        let obj = (try? JSONSerialization.jsonObject(with: Data((payload ?? "").utf8))) as? [String: Any]
        return ((obj?["paths"] as? [String]) ?? [], obj?["more"] as? Int)
    }

    /// Item 2: an event queued before the unwatch never runs, and a watch re-made under the same key right
    /// after does not get it. Red on the mutant invoke-after-unwatch.
    func testQueuedEventIsDroppedByUnwatchAndNotGivenToTheReWatch() {
        let dir = tempDir("fsw983u").path, h = Harness()
        defer { h.watcher.unwatch(extensionID: "test.fsw983", path: dir); h.restore() }
        h.watcher.watch(extensionID: "test.fsw983", path: dir, handler: "onChange")
        XCTAssertTrue(h.watcher.deliver([dir + "/old.txt"], extensionID: "test.fsw983", path: dir))
        h.watcher.unwatch(extensionID: "test.fsw983", path: dir)
        h.watcher.watch(extensionID: "test.fsw983", path: dir, handler: "onChange")
        h.drain()
        XCTAssertEqual(h.runs.count, 0, "a run started after unwatch: \(h.runs.map { $0.payload })")

        // The re-made watch works, with only its own event.
        XCTAssertTrue(h.watcher.deliver([dir + "/new.txt"], extensionID: "test.fsw983", path: dir))
        h.drain()
        XCTAssertEqual(h.runs.count, 1)
        XCTAssertEqual(decode(h.runs.last?.payload).paths, [dir + "/new.txt"])
    }

    /// Item 2: host.fs.unwatch marks the key on the extension's lane before it returns; a run queued before
    /// it is dropped even though the main-actor teardown has not run yet. Red on the mutant invoke-after-unwatch.
    func testLaneMarkOfUnwatchDropsTheRunBeforeTheMainTeardown() {
        let dir = tempDir("fsw983m").path, h = Harness()
        defer { h.watcher.unwatch(extensionID: "test.fsw983", path: dir); h.restore() }
        let before = h.watcher.watchCount
        h.watcher.watch(extensionID: "test.fsw983", path: dir, handler: "onChange")
        XCTAssertTrue(h.watcher.deliver([dir + "/a.txt"], extensionID: "test.fsw983", path: dir))
        let key = ExtensionFSWatch.markUnwatch(extensionID: "test.fsw983", path: dir)
        h.drain()
        XCTAssertEqual(h.runs.count, 0, "a run started after host.fs.unwatch returned")
        h.watcher.finishUnwatch(key: key)
        XCTAssertEqual(h.watcher.watchCount, before)

        // The mark is cleared by the teardown: a later watch on the same folder runs.
        h.watcher.watch(extensionID: "test.fsw983", path: dir, handler: "onChange")
        XCTAssertTrue(h.watcher.deliver([dir + "/b.txt"], extensionID: "test.fsw983", path: dir))
        h.drain()
        XCTAssertEqual(h.runs.count, 1)
    }

    /// Item 2, unload: removeAll (teardown) drops a run already queued. Red on the mutant invoke-after-unwatch.
    func testRemoveAllDropsAQueuedRun() {
        let dir = tempDir("fsw983r").path, h = Harness()
        defer { h.watcher.removeAll(extensionID: "test.fsw983"); h.restore() }
        h.watcher.watch(extensionID: "test.fsw983", path: dir, handler: "onChange")
        XCTAssertTrue(h.watcher.deliver([dir + "/a.txt"], extensionID: "test.fsw983", path: dir))
        h.watcher.removeAll(extensionID: "test.fsw983")
        h.drain()
        XCTAssertEqual(h.runs.count, 0)
    }

    /// Item 3: callbacks inside one window are one run listing at most the cap, the rest counted in "more";
    /// a callback after the run starts a new window. Red on the mutant burst-not-coalesced.
    func testBurstInOneWindowIsOneRunWithCappedPathsAndMore() {
        let dir = tempDir("fsw983b").path, h = Harness()
        defer { h.watcher.unwatch(extensionID: "test.fsw983", path: dir); h.restore() }
        h.watcher.watch(extensionID: "test.fsw983", path: dir, handler: "onChange")
        for batch in 0..<3 {
            let paths = (0..<200).map { "\(dir)/f\(batch)-\($0).txt" }
            XCTAssertTrue(h.watcher.deliver(paths, extensionID: "test.fsw983", path: dir))
        }
        XCTAssertEqual(h.scheduled, 1, "one flush per window")
        h.drain()
        XCTAssertEqual(h.runs.count, 1)
        let first = decode(h.runs.last?.payload)
        XCTAssertEqual(first.paths.count, 256)
        XCTAssertEqual(first.paths.first, "\(dir)/f0-0.txt")
        XCTAssertEqual(first.more, 600 - 256)

        XCTAssertTrue(h.watcher.deliver([dir + "/later.txt"], extensionID: "test.fsw983", path: dir))
        XCTAssertEqual(h.scheduled, 2)
        h.drain()
        XCTAssertEqual(h.runs.count, 2)
        let second = decode(h.runs.last?.payload)
        XCTAssertEqual(second.paths, [dir + "/later.txt"])
        XCTAssertTrue(second.more == nil, "no overflow, no \"more\" key")
    }

    /// Item 3: the pending set stops at its cap however many callbacks a busy window gets; repeats are listed
    /// once. Red on the mutant pending-set-uncapped.
    func testPendingSetNeverExceedsItsCap() {
        XCTAssertEqual(ExtensionFSWatch.maxPathsPerRun, 256)
        let dir = tempDir("fsw983c").path, h = Harness()
        defer { h.watcher.unwatch(extensionID: "test.fsw983", path: dir); h.restore() }
        h.watcher.watch(extensionID: "test.fsw983", path: dir, handler: "onChange")
        XCTAssertTrue(h.watcher.deliver([dir + "/same.txt", dir + "/same.txt"], extensionID: "test.fsw983", path: dir))
        for batch in 0..<10 {
            let paths = (0..<1_000).map { "\(dir)/g\(batch)-\($0).txt" }
            XCTAssertTrue(h.watcher.deliver(paths, extensionID: "test.fsw983", path: dir))
        }
        h.drain()
        XCTAssertEqual(h.runs.count, 1)
        let run = decode(h.runs.last?.payload)
        XCTAssertEqual(run.paths.count, 256)
        XCTAssertEqual(run.paths.filter { $0 == dir + "/same.txt" }.count, 1)
        XCTAssertEqual(run.more, 10_000 - 255)
    }

    /// Item 4: a trailing slash, "/./", a symlinked parent and /private are one watch; the last watch call
    /// replaces the first (as the same spelling did); unwatch by another spelling removes it. Red on the
    /// mutant key-is-the-text.
    func testSpellingsOfOneFolderAreOneWatch() throws {
        let base = tempDir("fsw983k").path, h = Harness()
        let real = base + "/real", link = base + "/link"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: base)
        var spellings = [real, real + "/", base + "/./real", link + "/real"]
        if base.hasPrefix("/var/") { spellings.append("/private" + base + "/real") }
        defer { h.watcher.unwatch(extensionID: "test.fsw983", path: real); h.restore() }
        let before = h.watcher.watchCount
        for (i, s) in spellings.enumerated() {
            h.watcher.watch(extensionID: "test.fsw983", path: s, handler: "h\(i)")
            XCTAssertEqual(h.watcher.watchCount, before + 1, s)
            XCTAssertEqual(ExtensionFSWatch.key("test.fsw983", s), ExtensionFSWatch.key("test.fsw983", real), s)
        }
        XCTAssertTrue(h.watcher.deliver([real + "/x.txt"], extensionID: "test.fsw983", path: base + "/./real"))
        h.drain()
        XCTAssertEqual(h.runs.count, 1)
        XCTAssertEqual(h.runs.last?.handler, "h\(spellings.count - 1)")

        h.watcher.unwatch(extensionID: "test.fsw983", path: link + "/real/")
        XCTAssertEqual(h.watcher.watchCount, before)
        XCTAssertFalse(h.watcher.deliver([real + "/y.txt"], extensionID: "test.fsw983", path: real))
    }

    /// Item 4 / #921: a secret folder stays denied under every spelling of the table, at watch time and per
    /// event, and all its spellings are one key. Red on the mutant deny-list-checked-on-the-text.
    func testDeniedFolderStaysDeniedUnderEverySpelling() throws {
        let base = tempDir("fsw983d").path, home = base + "/home", alias = base + "/alias"
        try FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: home)
        let saved = SecretPaths.home
        SecretPaths.home = home
        defer { SecretPaths.home = saved }
        var spellings = [home + "/.ssh", home + "/.ssh/", home + "/./.ssh", alias + "/.ssh"]
        if home.hasPrefix("/var/") { spellings.append("/private" + home + "/.ssh") }
        for s in spellings {
            XCTAssertTrue(SecretPaths.denies(s), s)
            XCTAssertTrue(ExtensionFSWatch.visiblePaths([s + "/fake_key"], hideSecrets: true) == nil, s)
            XCTAssertEqual(ExtensionFSWatch.key("x", s), ExtensionFSWatch.key("x", home + "/.ssh"), s)
        }
    }

    /// Item 3 measurement (printed, not asserted): FSEvents callbacks for 5000 files made in a tempDir with the
    /// stream's latency and flags, and the handler runs the coalesced watch makes of the same burst.
    func testMeasureBurstOf5000Files() throws {
        try requireHeavyTests()
        let dir = tempDir("fsw983n").path, watcher = ExtensionFSWatch.shared
        let savedInvoke = watcher.invoke
        var runs = 0, listed = 0, more = 0
        watcher.invoke = { _, _, payload in
            let d = self.decode(payload)
            runs += 1; listed += d.paths.count; more += d.more ?? 0
        }
        defer { watcher.unwatch(extensionID: "test.fsw983", path: dir); watcher.invoke = savedInvoke }
        watcher.watch(extensionID: "test.fsw983", path: dir, handler: "onChange")

        let counter = FSW983Counter(XCTestExpectation(description: "5000 paths seen"))
        counter.done.assertForOverFulfill = false
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(counter).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, _, _, _ in
            guard let info else { return }
            let c = Unmanaged<FSW983Counter>.fromOpaque(info).takeUnretainedValue()
            c.callbacks += 1
            c.paths += count
            if c.paths >= 5_000 { c.done.fulfill() }
        }
        let stream = try XCTUnwrap(FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, [dir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), ExtensionFSWatch.latency, ExtensionFSWatch.streamFlags))
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        defer { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }

        for i in 0..<5_000 {
            FileManager.default.createFile(atPath: "\(dir)/m\(i).txt", contents: Data())
        }
        _ = XCTWaiter().wait(for: [counter.done], timeout: 30)
        // Let the last window's flush run (it is due `latency` after the burst's last window opened).
        let settle = XCTestExpectation(description: "settle")
        settle.isInverted = true
        _ = XCTWaiter().wait(for: [settle], timeout: ExtensionFSWatch.latency * 3)
        let upper = (dir as NSString).deletingLastPathComponent + "/" + (dir as NSString).lastPathComponent.uppercased()
        print("FSW983 MEASURE: 5000 files -> \(counter.callbacks) FSEvents callbacks, \(counter.paths) event paths;"
              + " coalesced watch: \(runs) handler runs, \(listed) listed paths, more=\(more);"
              + " case variant resolves to \(SecretPaths.canonical(upper) == SecretPaths.canonical(dir) ? "the same" : "a different") key")
    }
}

/// #983 measurement: a raw FSEvents stream's callbacks and paths, touched only on the main queue.
private final class FSW983Counter: @unchecked Sendable {
    var callbacks = 0, paths = 0
    let done: XCTestExpectation
    init(_ done: XCTestExpectation) { self.done = done }
}

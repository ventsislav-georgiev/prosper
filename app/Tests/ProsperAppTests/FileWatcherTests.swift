import Darwin
import Foundation
import XCTest
@testable import ProsperApp

/// #1130: a FileWatcher closes its descriptor once it is stopped and released (the text viewer
/// makes one per window), and still fires on a change and across an atomic replace (the app-long
/// watchers in AppDelegate and BunHarness). Rows run on the watcher's real private queue; every
/// wait polls a condition to a stated deadline. Descriptors counted are this process's own only.
final class FileWatcherTests: XCTestCase {

    /// Inodes of this process's open descriptors whose path lies under `dir` (fcntl F_GETPATH,
    /// fstat). /dev/fd lists this process's own table; the listing's own descriptor is skipped
    /// by the path filter.
    private func watchedInodes(under dir: URL) -> [ino_t] {
        let marker = "/" + dir.lastPathComponent + "/"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else { return [] }
        var found: [ino_t] = []
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for name in names {
            guard let fd = Int32(name), fd >= 0, fcntl(fd, F_GETPATH, &buf) != -1,
                  String(cString: buf).contains(marker) else { continue }
            var st = stat()
            if fstat(fd, &st) == 0 { found.append(st.st_ino) }
        }
        return found
    }

    private func inode(_ url: URL) -> ino_t? {
        var st = stat()
        return stat(url.path, &st) == 0 ? st.st_ino : nil
    }

    /// Polls `cond` until it holds or `seconds` pass, spinning the main run loop so the
    /// watcher's main-queue callbacks run. Returns whether it held.
    private func poll(_ seconds: TimeInterval, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !cond() {
            if Date() >= end { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    private func files(_ n: Int, in dir: URL) throws -> [URL] {
        try (0..<n).map { i in
            let url = dir.appendingPathComponent("f\(i).txt")
            try Data("x\n".utf8).write(to: url)
            return url
        }
    }

    /// The text viewer's teardown: stop() then drop the last reference in the same turn.
    func testStoppedAndReleasedWatchersCloseTheirDescriptors() throws {
        let dir = tempDir("fw-stop-release")
        let n = 20
        var watchers: [FileWatcher]? = try files(n, in: dir).map { FileWatcher(url: $0) {} }
        XCTAssertTrue(poll(10) { watchedInodes(under: dir).count == n }, "all \(n) armed within 10 s")
        watchers?.forEach { $0.stop() }
        watchers = nil
        XCTAssertTrue(poll(10) { watchedInodes(under: dir).isEmpty },
                      "descriptors still open 10 s after stop+release: \(watchedInodes(under: dir).count)")
    }

    /// Released with no stop(): deinit cancels the source in place.
    func testReleasedWithoutStopClosesDescriptors() throws {
        let dir = tempDir("fw-release")
        let n = 20
        var watchers: [FileWatcher]? = try files(n, in: dir).map { FileWatcher(url: $0) {} }
        XCTAssertTrue(poll(10) { watchedInodes(under: dir).count == n }, "all \(n) armed within 10 s")
        watchers = nil
        XCTAssertTrue(poll(10) { watchedInodes(under: dir).isEmpty },
                      "descriptors still open 10 s after release: \(watchedInodes(under: dir).count)")
    }

    /// stop() alone, the watcher still held: the cancel handler ran and closed the descriptor.
    func testStopClosesTheDescriptorWhileHeld() throws {
        let dir = tempDir("fw-stop-held")
        let file = try XCTUnwrap(try files(1, in: dir).first)
        let watcher = FileWatcher(url: file) {}
        XCTAssertTrue(poll(10) { watchedInodes(under: dir).count == 1 }, "armed within 10 s")
        watcher.stop()
        XCTAssertTrue(poll(10) { watchedInodes(under: dir).isEmpty }, "closed within 10 s of stop()")
        withExtendedLifetime(watcher) {}
    }

    /// Behaviour the app-long watchers rely on: a write fires onChange on main; an atomic replace
    /// fires and re-arms on the new inode, whose next write fires again.
    func testChangeAndAtomicReplaceStillFire() throws {
        let dir = tempDir("fw-fire")
        let file = try XCTUnwrap(try files(1, in: dir).first)
        final class Count: @unchecked Sendable { var n = 0; var offMain = false }   // touched on main only
        let count = Count()
        // @Sendable, called by the watcher on the main queue.
        let watcher = FileWatcher(url: file) {
            if !Thread.isMainThread { count.offMain = true }
            count.n += 1
        }
        defer { watcher.stop() }
        let first = try XCTUnwrap(inode(file))
        XCTAssertTrue(poll(10) { watchedInodes(under: dir) == [first] }, "armed within 10 s")

        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd(); try h.write(contentsOf: Data("y\n".utf8)); try h.close()
        XCTAssertTrue(poll(10) { count.n >= 1 }, "a write fires within 10 s")

        let before = count.n
        try Data("replaced\n".utf8).write(to: file, options: .atomic)
        let second = try XCTUnwrap(inode(file))
        XCTAssertNotEqual(first, second, "the atomic write made a new inode")
        XCTAssertTrue(poll(10) { count.n > before }, "the replace fires within 10 s")
        XCTAssertTrue(poll(10) { watchedInodes(under: dir) == [second] }, "re-armed on the new inode within 10 s")

        let afterReplace = count.n
        let h2 = try FileHandle(forWritingTo: file)
        try h2.seekToEnd(); try h2.write(contentsOf: Data("z\n".utf8)); try h2.close()
        XCTAssertTrue(poll(10) { count.n > afterReplace }, "a write after re-arm fires within 10 s")
        XCTAssertFalse(count.offMain, "onChange ran on main")
    }

    /// A FIFO at the watched path must not block the watcher's queue: without O_NONBLOCK the
    /// O_EVTONLY open waited for a writer (red on the tip). A writer-side open in teardown frees a
    /// blocked open, so a failing row cannot leave a thread stuck.
    func testArmOnAFIFODoesNotBlock() throws {
        let dir = tempDir("fw-fifo")
        let fifo = dir.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        defer {
            let fd = open(fifo.path, O_RDWR | O_NONBLOCK)
            if fd >= 0 { close(fd) }
        }
        var watcher: FileWatcher? = FileWatcher(url: fifo) {}
        XCTAssertTrue(poll(5) { watchedInodes(under: dir).count == 1 }, "the FIFO open returned within 5 s")
        watcher?.stop()
        watcher = nil
        XCTAssertTrue(poll(10) { watchedInodes(under: dir).isEmpty }, "closed within 10 s")
    }

    // MARK: #1147 one fire when the path appears after an absence

    /// Fires counted on main; `offMain` records a call off the main queue.
    final class Fires: @unchecked Sendable { var n = 0; var offMain = false }   // touched on main only

    /// @Sendable, made here (nonisolated test code) and called by the watcher on the main queue,
    /// after its debounce on the watcher's own queue.
    private func counting(_ fires: Fires) -> @Sendable () -> Void {
        { if !Thread.isMainThread { fires.offMain = true }; fires.n += 1 }
    }

    /// Watched before the file exists: the first arm (synced on the watcher's queue) finds nothing,
    /// the 1 s retry arms the created file and fires once. Waits: the fire, 10 s ceiling (one 1 s
    /// retry plus the 0.2 s debounce); then no second fire within 2 s (ten debounces); then a write
    /// to the armed file fires again, 10 s ceiling.
    func testArmAfterAbsenceFiresOnce() throws {
        let dir = tempDir("fw-appear")
        let file = dir.appendingPathComponent("late.txt")
        let fires = Fires()
        let watcher = FileWatcher(url: file, onChange: counting(fires))
        defer { watcher.stop() }
        watcher.queue.sync {}   // the first arm, queued by init, has looked and found nothing
        XCTAssertTrue(watchedInodes(under: dir).isEmpty, "nothing armed while the path is absent")
        try Data("x\n".utf8).write(to: file)
        XCTAssertTrue(poll(10) { fires.n == 1 }, "the appearance fires within 10 s: \(fires.n)")
        XCTAssertTrue(poll(10) { watchedInodes(under: dir) == [inode(file)].compactMap { $0 } }, "armed on the new file")
        XCTAssertFalse(poll(2) { fires.n > 1 }, "one fire for one appearance: \(fires.n)")
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd(); try h.write(contentsOf: Data("y\n".utf8)); try h.close()
        XCTAssertTrue(poll(10) { fires.n == 2 }, "a write after the arm fires within 10 s: \(fires.n)")
        XCTAssertFalse(fires.offMain, "onChange ran on main")
    }

    /// An existing file's first arm is not a change: armed, then no fire within 2 s (ten debounces).
    func testFirstArmOfAnExistingFileFiresNothing() throws {
        let dir = tempDir("fw-present")
        let file = try XCTUnwrap(try files(1, in: dir).first)
        let fires = Fires()
        let watcher = FileWatcher(url: file, onChange: counting(fires))
        defer { watcher.stop() }
        XCTAssertTrue(poll(10) { watchedInodes(under: dir).count == 1 }, "armed within 10 s")
        XCTAssertFalse(poll(2) { fires.n > 0 }, "the first arm of an existing file fired: \(fires.n)")
    }

    /// `absent: true` (the viewer's first load found nothing): a file there by the first arm was
    /// created since, so that arm fires once. Waits: the fire, 10 s; no second within 2 s.
    func testAbsentCallerFiresOnTheFirstArm() throws {
        let dir = tempDir("fw-absent")
        let file = try XCTUnwrap(try files(1, in: dir).first)
        let fires = Fires()
        let watcher = FileWatcher(url: file, absent: true, onChange: counting(fires))
        defer { watcher.stop() }
        XCTAssertTrue(poll(10) { fires.n == 1 }, "the first arm fires within 10 s: \(fires.n)")
        XCTAssertFalse(poll(2) { fires.n > 1 }, "one fire: \(fires.n)")
        XCTAssertFalse(fires.offMain, "onChange ran on main")
    }

    /// Deleted, then created again: the delete fires (as before #1147), the re-arm in that same
    /// debounced item finds nothing (it runs before onChange is queued to main, so it has looked
    /// by the time the fire is seen here), and the creation fires once more when the 1 s retry
    /// arms it. Waits: each fire 10 s; no third fire within 2 s.
    func testDeletedAndCreatedAgainFiresOnTheCreation() throws {
        let dir = tempDir("fw-recreate")
        let file = try XCTUnwrap(try files(1, in: dir).first)
        let fires = Fires()
        let watcher = FileWatcher(url: file, onChange: counting(fires))
        defer { watcher.stop() }
        XCTAssertTrue(poll(10) { watchedInodes(under: dir).count == 1 }, "armed within 10 s")
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(poll(10) { fires.n == 1 }, "the delete fires within 10 s: \(fires.n)")
        XCTAssertTrue(watchedInodes(under: dir).isEmpty, "nothing armed while the path is absent")
        try Data("again\n".utf8).write(to: file)
        XCTAssertTrue(poll(10) { fires.n == 2 }, "the creation fires within 10 s: \(fires.n)")
        XCTAssertTrue(poll(10) { watchedInodes(under: dir) == [inode(file)].compactMap { $0 } }, "armed on the new file")
        XCTAssertFalse(poll(2) { fires.n > 2 }, "one fire for the creation: \(fires.n)")
        XCTAssertFalse(fires.offMain, "onChange ran on main")
    }

    // MARK: R896-1 the retry, on an injected scheduler: no timer fires on its own; delays are values.

    /// Records what a watcher schedules (called on the watcher's queue); a row performs the newest item
    /// itself, on that queue.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(delay: TimeInterval, work: DispatchWorkItem)] = []
        func add(_ delay: TimeInterval, _ work: DispatchWorkItem) { lock.lock(); items.append((delay, work)); lock.unlock() }
        var delays: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return items.map(\.delay) }
        var last: (delay: TimeInterval, work: DispatchWorkItem)? { lock.lock(); defer { lock.unlock() }; return items.last }
        /// Performs the newest item on `queue` (it re-arms or debounces there, as a timer would).
        func runLast(on queue: DispatchQueue) {
            guard let work = last?.work else { return }
            queue.sync { work.perform() }
        }
    }

    /// A path that never appears: 1, 2, 4 ... seconds, then the ceiling, every retry. Then the bound for
    /// a whole day, on a virtual clock: each retry performed at its delay until 86,400 s pass.
    func testRetryBacksOffToTheCeiling() throws {
        let file = tempDir("fw-backoff").appendingPathComponent("never.txt")
        let clock = Clock()
        let watcher = FileWatcher(url: file, retryCeiling: 60, schedule: clock.add) {}
        defer { watcher.stop() }
        watcher.queue.sync {}   // the first arm (queued by init) looked and scheduled a retry
        for _ in 0..<8 { clock.runLast(on: watcher.queue) }
        XCTAssertEqual(clock.delays, [1, 2, 4, 8, 16, 32, 60, 60, 60])

        let day = Clock()
        let daylong = FileWatcher(url: file, retryCeiling: 60, schedule: day.add) {}
        defer { daylong.stop() }
        daylong.queue.sync {}
        var opens = 1, t: TimeInterval = 0
        while let d = day.last?.delay, t + d <= 86_400 {
            t += d
            day.runLast(on: daylong.queue)
            opens += 1
        }
        XCTAssertEqual(opens, 1_445, "a day on a missing path: the first look, 6 backing off, then one a minute")
        XCTAssertEqual(day.delays.max(), 60)
    }

    /// The app-long watchers pass no ceiling: a look every second, as before R896-1.
    func testDefaultRetryStaysOneSecond() throws {
        let file = tempDir("fw-default").appendingPathComponent("later.json")
        let clock = Clock()
        let watcher = FileWatcher(url: file, schedule: clock.add) {}
        defer { watcher.stop() }
        XCTAssertEqual(watcher.retryCeiling, 1)
        watcher.queue.sync {}
        for _ in 0..<4 { clock.runLast(on: watcher.queue) }
        XCTAssertEqual(clock.delays, [1, 1, 1, 1, 1])
    }

    /// After an arm the back-off starts over: missing (1, 2), created (armed, its fire debounced 0.2),
    /// deleted (the delete fires, 0.2; that item re-arms and finds nothing): the next retry is 1 s again.
    func testBackOffStartsOverAfterAnArm() throws {
        let dir = tempDir("fw-reset")
        let file = dir.appendingPathComponent("again.txt")
        let clock = Clock()
        let watcher = FileWatcher(url: file, retryCeiling: 60, schedule: clock.add) {}
        defer { watcher.stop() }
        watcher.queue.sync {}
        clock.runLast(on: watcher.queue)
        XCTAssertEqual(clock.delays, [1, 2])
        try Data("x\n".utf8).write(to: file)
        clock.runLast(on: watcher.queue)   // armed; the appearance fires
        XCTAssertEqual(clock.delays, [1, 2, 0.2])
        XCTAssertEqual(watchedInodes(under: dir).count, 1, "armed on the created file")
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(poll(10) { clock.delays.count == 4 }, "the delete fires within 10 s: \(clock.delays)")
        clock.runLast(on: watcher.queue)   // the delete's debounced item re-arms: nothing there
        XCTAssertEqual(clock.delays, [1, 2, 0.2, 0.2, 1])
    }

    /// `remote` (the viewer's automount or network location): a path never armed gets no look at all.
    func testRemoteNeverArmedIsNotRetried() throws {
        let idle = Clock()
        let missing = FileWatcher(url: tempDir("fw-remote-never").appendingPathComponent("never.txt"),
                                  retryCeiling: 60, remote: true, schedule: idle.add) {}
        defer { missing.stop() }
        missing.queue.sync {}
        XCTAssertEqual(idle.delays, [], "missing from the start: no look")
    }

    /// Remote, armed, deleted, never back: 7 looks (1 ... 60 s, up to the first at the ceiling), then none.
    func testRemoteArmedThenDeletedLooksSevenTimes() throws {
        let dir = tempDir("fw-remote-gone")
        let file = try XCTUnwrap(try files(1, in: dir).first)
        let clock = Clock()
        let watcher = FileWatcher(url: file, retryCeiling: 60, remote: true, schedule: clock.add) {}
        defer { watcher.stop() }
        watcher.queue.sync {}
        XCTAssertEqual(watchedInodes(under: dir).count, 1, "the present file is armed")
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(poll(10) { clock.delays.count == 1 }, "the delete fires within 10 s: \(clock.delays)")
        for _ in 0..<8 { clock.runLast(on: watcher.queue) }   // the re-arm, then each look; the last schedules nothing
        XCTAssertEqual(clock.delays, [0.2, 1, 2, 4, 8, 16, 32, 60])
        clock.runLast(on: watcher.queue)   // performing the look at 60 again: still nothing new
        XCTAssertEqual(clock.delays.count, 8, "the allowance is spent: no further look")
    }

    /// Remote, written again before the third look: armed and fires; a second delete gets all 7 looks again.
    func testRemoteAllowanceIsGivenBackByAnArm() throws {
        let dir = tempDir("fw-remote-back")
        let file = try XCTUnwrap(try files(1, in: dir).first)
        let clock = Clock()
        let watcher = FileWatcher(url: file, retryCeiling: 60, remote: true, schedule: clock.add) {}
        defer { watcher.stop() }
        watcher.queue.sync {}
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(poll(10) { clock.delays.count == 1 }, "the delete fires within 10 s: \(clock.delays)")
        clock.runLast(on: watcher.queue)   // re-arm: gone, look 1 s
        clock.runLast(on: watcher.queue)   // look at 1 s: gone, look 2 s
        XCTAssertEqual(clock.delays, [0.2, 1, 2])
        try Data("again\n".utf8).write(to: file)
        clock.runLast(on: watcher.queue)   // the look at 2 s arms; the appearance fires
        XCTAssertEqual(clock.delays, [0.2, 1, 2, 0.2])
        XCTAssertEqual(watchedInodes(under: dir).count, 1, "armed again")
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(poll(10) { clock.delays.count == 5 }, "the second delete fires: \(clock.delays)")
        for _ in 0..<8 { clock.runLast(on: watcher.queue) }
        XCTAssertEqual(Array(clock.delays.dropFirst(4)), [0.2, 1, 2, 4, 8, 16, 32, 60], "the full 7 looks again")
    }

    /// After a failed open for any reason the next successful arm fires once: the watcher saw nothing
    /// meanwhile. A file behind a folder with no search permission (EACCES) is retried; once the folder is
    /// opened up the arm fires (delays [1, 0.2]). The folder is the row's own, restored in a defer.
    func testArmAfterAFailedOpenFires() throws {
        let dir = tempDir("fw-eacces")
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        let file = locked.appendingPathComponent("f.txt")
        try Data("x\n".utf8).write(to: file)
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { chmod(locked.path, 0o700) }
        let clock = Clock()
        let watcher = FileWatcher(url: file, retryCeiling: 60, schedule: clock.add) {}
        defer { watcher.stop() }
        watcher.queue.sync {}
        XCTAssertEqual(clock.delays, [1], "the EACCES arm is retried")
        XCTAssertEqual(chmod(locked.path, 0o700), 0)
        clock.runLast(on: watcher.queue)
        XCTAssertEqual(watchedInodes(under: dir).count, 1, "armed once reachable")
        XCTAssertEqual(clock.delays, [1, 0.2], "fires: a change made meanwhile must not be lost")
    }

    /// R896-1 (1): the automount and network rule on a made-up mount table (no real /Volumes, /net or
    /// /System/Volumes path is read). The longest mount point containing the path decides.
    func testAutomountAndNetworkLocations() {
        let local = UInt32(MNT_LOCAL)
        let mounts = [FileWatcher.Mount(on: "/", type: "apfs", flags: local),
                      FileWatcher.Mount(on: "/System/Volumes/Data", type: "apfs", flags: local),
                      FileWatcher.Mount(on: "/net", type: "autofs", flags: local),
                      FileWatcher.Mount(on: "/Volumes/Share", type: "smbfs", flags: 0),
                      FileWatcher.Mount(on: "/Volumes/Auto", type: "apfs", flags: local | UInt32(MNT_AUTOMOUNTED))]
        func remote(_ p: String) -> Bool { FileWatcher.onAutomountOrNetwork(p, mounts: mounts) }
        XCTAssertFalse(remote("/Users/example/notes.md"))
        XCTAssertFalse(remote("/System/Volumes/Data/Users/example/notes.md"))
        XCTAssertTrue(remote("/net/host/notes.md"), "autofs")
        XCTAssertTrue(remote("/Volumes/Share/notes.md"), "not MNT_LOCAL")
        XCTAssertTrue(remote("/Volumes/Share"), "the mount point itself")
        XCTAssertFalse(remote("/Volumes/Shared/notes.md"), "a whole component, not a prefix")
        XCTAssertTrue(remote("/NET/host/notes.md"), "the system volume ignores case")
        XCTAssertTrue(remote("/Volumes/Auto/notes.md"), "MNT_AUTOMOUNTED")
        XCTAssertFalse(FileWatcher.onAutomountOrNetwork("/Users/example/notes.md", mounts: []))
    }

    /// The live mount table (getfsstat, MNT_NOWAIT: no path is looked up) decodes and holds the root;
    /// the row's own tempDir() is local.
    func testLiveMountTableHasTheRoot() {
        XCTAssertTrue(FileWatcher.mountTable().contains { $0.on == "/" }, "\(FileWatcher.mountTable().map(\.on))")
        XCTAssertFalse(FileWatcher.onAutomountOrNetwork(tempDir("fw-mounts").path))
    }
}

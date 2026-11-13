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
}

import AppKit
import Darwin
import XCTest
@testable import ProsperApp

/// #1147: a Text Viewer window on a path that is not there yet fills in when the file is created,
/// and one whose file is deleted and created again shows the new file. A folder and a FIFO stay
/// unwatched. Hosted as TextViewerWindowTests does: windows built through the `build` seam with no
/// autosave, `present` and `dismissed` are recorders (never shown, ordered or made key), the
/// actions are fakes that open nothing, and every window is closed in a defer. Files are fakes in
/// the row's own tempDir(). Every wait polls a condition on the main run loop to a stated ceiling;
/// the watcher fires on its own queue and calls the window's closure on the main queue.
@MainActor
final class TextViewerMissingFileTests: XCTestCase {

    private var presented: [NSWindow] = []

    private func registry() -> TextViewerWindows {
        let w = TextViewerWindows()
        w.build = { TextViewerWindows.makeWindow($0, autosave: nil) }
        w.present = { [unowned self] in self.presented.append($0) }
        w.dismissed = { _ in }
        w.actions = {
            TextViewerActions(defaultApp: { _ in nil }, openWith: { _, _ in }, reveal: { _ in },
                              openURL: { _ in }, view: { _ in })
        }
        w.imageLoader = { _, _, _ in nil }
        return w
    }

    /// Polls `done` on the main run loop until it holds or 10 s pass.
    private func waitUntil(_ what: String, _ done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while !done(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(done(), "not within 10 s: \(what)", file: file, line: line)
    }

    private func closeAll(_ w: TextViewerWindows) {
        for e in w.entries { e.window.close() }
    }

    /// The window opens on a missing .txt ("not there"), is watched, and shows the text once the
    /// file is created. Ceilings: the first load 10 s; the text 10 s (the watcher's 1 s retry, its
    /// 0.2 s debounce, then the off-main load).
    func testWindowOnAMissingFileFillsInWhenCreated() throws {
        let dir = tempDir("tv-missing")
        let url = dir.appendingPathComponent("later.txt")
        let w = registry()
        defer { closeAll(w) }
        w.open(url)
        let entry = try XCTUnwrap(w.entries.first)
        waitUntil("the first load", { entry.model.state != nil })
        XCTAssertTrue(entry.model.state == .failure(.missing), "a missing path shows the refusal first")
        XCTAssertTrue(entry.watcher != nil, "a missing path is watched")
        XCTAssertEqual(entry.watcher?.absent, true, "made with absent: a file created before its first arm fires")
        try Data("hello\n".utf8).write(to: url)
        waitUntil("the created file shown", { entry.model.document?.text == "hello\n" })
        XCTAssertEqual(entry.model.output?.text.string, "hello\n", "rendered too (plain text keeps its newline)")
        XCTAssertFalse(presented.contains { $0.isVisible }, "never on screen")
    }

    /// A shown file deleted, then created again: the window shows "not there", then the new text.
    /// Ceilings: each step 10 s. The watcher re-arms in the delete's debounced item before it queues
    /// the reload, so the create below comes after that look and fires on its own.
    func testDeletedAndCreatedAgainShowsTheNewFile() throws {
        let dir = tempDir("tv-recreate")
        let url = dir.appendingPathComponent("again.txt")
        try Data("one\n".utf8).write(to: url)
        let w = registry()
        defer { closeAll(w) }
        w.open(url)
        let entry = try XCTUnwrap(w.entries.first)
        waitUntil("the first load", { entry.model.document?.text == "one\n" })
        waitUntil("watched", { entry.watcher != nil })
        XCTAssertEqual(entry.watcher?.absent, false, "a shown file's watcher is not made absent")
        try FileManager.default.removeItem(at: url)
        waitUntil("the delete shown", { entry.model.state == .failure(.missing) })
        try Data("two\n".utf8).write(to: url)
        waitUntil("the created file shown", { entry.model.document?.text == "two\n" })
    }

    /// A folder and a FIFO (.notRegular) get a window and no watcher. The FIFO is in the row's
    /// tempDir(); a watcher's open of it would not block (O_NONBLOCK, FileWatcherTests'
    /// testArmOnAFIFODoesNotBlock), and a writer-side open in the defer frees one that did.
    func testFolderAndFIFOAreNotWatched() throws {
        let dir = tempDir("tv-notregular")
        let folder = dir.appendingPathComponent("folder.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let fifo = dir.appendingPathComponent("pipe.txt")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        defer {
            let fd = open(fifo.path, O_RDWR | O_NONBLOCK)
            if fd >= 0 { close(fd) }
        }
        let w = registry()
        defer { closeAll(w) }
        w.open(folder)
        w.open(fifo)
        XCTAssertEqual(w.entries.count, 2)
        waitUntil("both loaded", { w.entries.allSatisfy { $0.model.state != nil } })
        XCTAssertTrue(w.entries.allSatisfy { $0.model.state == .failure(.notRegular) }, "both refused as not regular")
        XCTAssertTrue(w.entries.allSatisfy { $0.watcher == nil }, "a folder and a FIFO are not watched")
    }

    /// A path missing at open is watched; when a folder, or a FIFO, appears there the window shows
    /// the not-regular refusal within 10 s. Nothing hangs: the refusal can only come from the
    /// watcher's fire, which runs after its open of the new entry returned (O_EVTONLY|O_NONBLOCK,
    /// the open testArmOnAFIFODoesNotBlock pins), and the reload's own open is O_NONBLOCK. No sync
    /// on the watcher's queue here, so a blocked open would fail the ceiling, never wedge the row;
    /// the defer opens the FIFO's writer side, which frees any open still waiting.
    func testMissingPathThatBecomesAFolderOrAFIFOShowsTheRefusal() throws {
        let dir = tempDir("tv-becomes")
        let folder = dir.appendingPathComponent("later-folder.txt")
        let fifo = dir.appendingPathComponent("later-pipe.txt")
        defer {
            let fd = open(fifo.path, O_RDWR | O_NONBLOCK)
            if fd >= 0 { close(fd) }
        }
        let w = registry()
        defer { closeAll(w) }
        w.open(folder)
        w.open(fifo)
        XCTAssertEqual(w.entries.count, 2)
        waitUntil("both loaded", { w.entries.allSatisfy { $0.model.state != nil } })
        XCTAssertTrue(w.entries.allSatisfy { $0.model.state == .failure(.missing) && $0.watcher != nil },
                      "both missing at open and watched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        waitUntil("both refused as not regular", { w.entries.allSatisfy { $0.model.state == .failure(.notRegular) } })
    }
}

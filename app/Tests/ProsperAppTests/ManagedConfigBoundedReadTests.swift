import Foundation
import XCTest
@testable import ProsperApp

/// #1290: the Agent Kit seed source and the `.prosper-kit` owner marker are read through BoundedFileRead: exactly the
/// cap is read, one byte over is refused the way a missing file is, and a FIFO is refused without blocking.
/// Every file is in tempDir().
final class ManagedConfigBoundedReadTests: XCTestCase {
    private final class Outcome: @unchecked Sendable { var refused = false }

    private func owner(_ ext: URL) -> ManagedConfigOwner {
        ManagedConfigOwner(id: "kit-a", version: "1", kitSlug: "kit-a", extensionDir: ext)
    }

    private func seedResult(_ ext: URL) -> Result<String, ManagedConfigRefusalReason> {
        ManagedConfigPaths.readSource("ext:local.md", owner: owner(ext))
    }

    /// A kit dir whose marker is `owner` padded with spaces to exactly `size` bytes.
    private func kitDir(markerBytes size: Int) throws -> URL {
        let dir = tempDir()
        let text = "kit-a" + String(repeating: " ", count: size - "kit-a".utf8.count)
        try Data(text.utf8).write(to: dir.appendingPathComponent(ManagedConfigPaths.kitMarkerFile))
        return dir
    }

    /// Runs `read` on a FIFO named `name` in `dir` on a background queue and waits at most 1.5 s. A read that blocks
    /// fails the row; the stuck open is then released by a non-blocking writer open, so the run never hangs.
    private func assertFIFORefusedWithoutBlocking(_ dir: URL, _ name: String, _ read: @escaping @Sendable () -> Bool,
                                                  file: StaticString = #filePath, line: UInt = #line) {
        let path = dir.appendingPathComponent(name).path
        XCTAssertEqual(mkfifo(path, 0o600), 0, "mkfifo \(name)", file: file, line: line)
        defer { unlink(path) }
        let outcome = Outcome(), done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            outcome.refused = read()
            done.signal()
        }
        guard done.wait(timeout: .now() + 1.5) == .success else {
            XCTFail("\(name): the read blocked on a FIFO", file: file, line: line)
            let writer = open(path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            _ = done.wait(timeout: .now() + 1)
            return
        }
        XCTAssertTrue(outcome.refused, "\(name) was not refused", file: file, line: line)
    }

    func testASeedAtTheCapIsReadAndOneByteOverIsRefused() throws {
        let ext = tempDir()
        let cap = BoundedFileRead.kitSeedMaxBytes
        XCTAssertEqual(cap, 1 << 20, "the documented seed cap")
        try Data(String(repeating: "a", count: cap).utf8).write(to: ext.appendingPathComponent("local.md"))
        guard case .success(let text) = seedResult(ext) else { return XCTFail("a seed at the cap was refused") }
        XCTAssertEqual(text.utf8.count, cap)
        try Data(String(repeating: "a", count: cap + 1).utf8).write(to: ext.appendingPathComponent("local.md"))
        XCTAssertTrue(seedResult(ext) == .failure(.invalidPiece("seed source is missing or not UTF-8 text")))
    }

    func testAFIFONamedLikeTheSeedIsRefusedWithoutBlocking() {
        let ext = tempDir()
        let o = owner(ext)
        assertFIFORefusedWithoutBlocking(ext, "local.md") {
            ManagedConfigPaths.readSource("ext:local.md", owner: o) == .failure(.invalidPiece("seed source is missing or not UTF-8 text"))
        }
    }

    func testAMarkerAtTheCapIsOursAndOneByteOverIsForeign() throws {
        let cap = BoundedFileRead.kitMarkerMaxBytes
        XCTAssertEqual(cap, 1 << 10, "the documented marker cap")
        XCTAssertTrue(ManagedConfigPaths.ownership(of: try kitDir(markerBytes: cap), owner: "kit-a") == .ours)
        XCTAssertTrue(ManagedConfigPaths.ownership(of: try kitDir(markerBytes: cap + 1), owner: "kit-a") == .foreign)
    }

    func testAFIFONamedLikeTheMarkerIsForeignWithoutBlocking() {
        let dir = tempDir()
        assertFIFORefusedWithoutBlocking(dir, ManagedConfigPaths.kitMarkerFile) {
            ManagedConfigPaths.ownership(of: dir, owner: "kit-a") == .foreign
        }
    }
}

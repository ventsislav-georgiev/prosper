import XCTest
@testable import ProsperApp

/// #1410: XrayPanels.runBounded / DchCommand.runCapturingBoth's `stdin`: the bytes reach the child through a pipe that
/// is closed (the child sees EOF); nil keeps today's child, which inherits this process's stdin. /bin/sh, /bin/cat and
/// /usr/bin/stat only: no dch, no window, no key posted.
final class XrayStdinTests: XCTestCase {
    /// Red without the write (empty out) or without the close (cat never ends: -1 at the 5 s bound).
    func testStdinBytesReachTheChildAndEnd() {
        for bytes in [Data("login test\n".utf8), Data(repeating: 0x61, count: Int(PIPE_BUF))] {
            let r = XrayPanels.runBounded(XrayChild(), "/bin/sh", ["-c", "exec /bin/cat"], [:], timeout: 5, stdin: bytes)
            XCTAssertEqual(r.status, 0, "\(bytes.count) bytes")
            XCTAssertEqual(r.out, bytes, "\(bytes.count) bytes")
        }
    }

    /// Red without the PIPE_BUF check: a larger write could block before the spawn; nothing runs (no pid, -1).
    func testOverPipeBufRunsNothing() {
        var pids = 0
        let r = DchCommand.runCapturingBoth(args: ["-c", "exec /bin/cat"], env: [:], path: "/bin/sh", onPid: { _ in pids += 1 },
                                            stdin: Data(repeating: 0x61, count: Int(PIPE_BUF) + 1))
        XCTAssertEqual(r.status, -1)
        XCTAssertEqual(pids, 0, "nothing spawned")
    }

    /// An existing caller (stdin nil) gets no pipe: two such children share one fd 0 (this process's, inherited), while
    /// a child given bytes has its own pipe. Red if nil ever builds a pipe (two fresh pipes, two inodes).
    func testNilStdinInheritsOursAndBytesDoNot() {
        func inode(_ stdin: Data?) -> String {
            let r = XrayPanels.runBounded(XrayChild(), "/bin/sh", ["-c", "exec /usr/bin/stat -L -f '%i' /dev/stdin"], [:],
                                          timeout: 5, stdin: stdin)
            XCTAssertEqual(r.status, 0)
            return String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let plain = (inode(nil), inode(nil)), piped = inode(Data("x\n".utf8))
        XCTAssertFalse(plain.0.isEmpty)
        XCTAssertEqual(plain.0, plain.1, "both inherit the same stdin")
        XCTAssertNotEqual(piped, plain.0, "bytes: a pipe of its own (ours stays open, so its inode is not reused)")
    }

    /// dch 1.83.0 reads "-" until EOF before it looks the session up: a child that reads its stdin to the end (as dch
    /// does) and writes it to a file finishes, and the file holds exactly the bytes. Red without the close (-1 at 5 s).
    func testAChildReadingToEOFFinishes() throws {
        let dir = tempDir("xray-stdin")
        let r = XrayPanels.runBounded(XrayChild(), "/bin/sh", ["-c", "/bin/cat > \"$D/stdin\""], ["D": dir.path], timeout: 5,
                                      stdin: Data("#12\n".utf8))
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("stdin")), Data("#12\n".utf8))
    }
}

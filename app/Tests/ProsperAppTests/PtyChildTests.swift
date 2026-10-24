import XCTest
@testable import ProsperApp

/// #517: Prosper.app runs with cwd "/", so a phone-created session started its shell
/// there. PtyChild chdirs the child to `cwd` (default: home) before exec, and falls
/// back to "/" when that dir is gone so a session always starts.
final class PtyChildTests: XCTestCase {

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: [UInt8] = []
        func append(_ b: [UInt8]) { lock.withLock { bytes += b } }
        var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
    }

    /// Runs /bin/pwd in a PtyChild and returns its output line once the child is reaped.
    private func pwd(cwd: String?) throws -> String {
        let out = Output()
        let exited = expectation(description: "pwd exited")
        var code: Int32 = -1
        let onOutput: ([UInt8]) -> Void = { out.append($0) }
        let onExit: (Int32) -> Void = { code = $0; exited.fulfill() }
        // No PWD in env: /bin/pwd then reports the physical cwd.
        let env = ["PATH": "/usr/bin:/bin"]
        let child = if let cwd {
            try PtyChild(exe: "/bin/pwd", args: [], env: env, cols: 80, rows: 24, cwd: cwd,
                         onOutput: onOutput, onExit: onExit)
        } else {
            try PtyChild(exe: "/bin/pwd", args: [], env: env, cols: 80, rows: 24,
                         onOutput: onOutput, onExit: onExit)
        }
        child.run()
        wait(for: [exited], timeout: 15)
        XCTAssertEqual(code, 0, "pwd did not exec cleanly: \(out.text)")
        return out.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// /var -> /private/var: compare physical paths on both sides.
    private func real(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    func testExplicitDirIsTheChildsCwd() throws {
        let dir = tempDir().path
        XCTAssertEqual(try pwd(cwd: dir), real(dir))
    }

    func testDefaultCwdIsHome() throws {
        XCTAssertEqual(try pwd(cwd: nil), real(NSHomeDirectory()))
    }

    /// The fallback must land in "/", not the test runner's own cwd.
    func testMissingDirFallsBackToRoot() throws {
        XCTAssertNotEqual(FileManager.default.currentDirectoryPath, "/",
                          "runner cwd is / — this test could not tell the fallback from no chdir")
        let missing = tempDir().appendingPathComponent("gone").path
        XCTAssertEqual(try pwd(cwd: missing), "/")
    }

    /// #522, a scan by necessity: a Swift String bridged to a C string in the forked
    /// child behaves the same when it happens not to deadlock, so no run can catch it.
    /// The child block's code (comments stripped) holds no string literal and never
    /// names the Swift exe; its "/" fallback and execve path are pre-fork C strings.
    func testForkedChildBridgesNoSwiftString() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Server/PtyChild.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "if child == 0 {"))
        let end = try XCTUnwrap(source.range(of: "_exit(127)", range: start.upperBound..<source.endIndex))
        let code = source[start.upperBound..<end.lowerBound].split(separator: "\n")
            .map { $0.components(separatedBy: "//")[0] }
        XCTAssertTrue(code.contains { $0.contains("execve(") }, "child block not found")
        for line in code {
            XCTAssertFalse(line.contains("\""), "string literal in the forked child: \(line)")
            XCTAssertNil(line.range(of: #"\bexe\b"#, options: .regularExpression), "Swift exe bridged in the child: \(line)")
        }
    }
}

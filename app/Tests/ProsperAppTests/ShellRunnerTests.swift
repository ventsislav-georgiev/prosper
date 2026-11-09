import XCTest
@testable import ProsperApp

/// #833: `host.shell.run` goes through `ExtensionHost.awaitSync` → `ShellRunner.run`. A timeout
/// must take down zsh and everything it started, output is capped, and the continuation
/// resumes exactly once however a cancel races the exit. Runs `zsh -c` (never a login shell
/// under XCTest) and signals only pids the test's own commands recorded.
final class ShellRunnerTests: XCTestCase {
    /// Polls `kill(pid, 0)` until ESRCH or the timeout.
    private func waitGone(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            if Date() >= deadline { return false }
            usleep(10_000)
        }
    }

    func testTimeoutKillsTheShellAndItsBackgroundChild() throws {
        let file = tempDir().appendingPathComponent("pids").path
        let cmd = "echo $$ > '\(file)'; /bin/sleep 30 & echo $! >> '\(file)'; wait"
        XCTAssertNil(ExtensionHost.awaitSync(timeout: 1) { await ShellRunner.run(cmd) })
        let pids = try String(contentsOfFile: file, encoding: .utf8)
            .split(separator: "\n").compactMap { pid_t($0) }.filter { $0 > 1 }
        XCTAssertEqual(pids.count, 2, "expected the zsh pid and the sleep pid")
        for pid in pids where !waitGone(pid, timeout: 2) {
            XCTFail("pid \(pid) outlived the timeout by 2 s")
            kill(pid, SIGKILL)   // our own recorded pid: don't leak it past the failure
        }
    }

    func testFloodIsCappedWithMarkerAndDoesNotHang() throws {
        let out = try XCTUnwrap(ExtensionHost.awaitSync(timeout: 20) {
            await ShellRunner.run("/usr/bin/yes | /usr/bin/head -c 5000000")
        }, "a 5 MB flood must not hang the runner")
        XCTAssertTrue(out.hasSuffix("\n" + ShellRunner.truncationMarker))
        XCTAssertLessThanOrEqual(out.utf8.count, ShellRunner.outputCap + ShellRunner.truncationMarker.utf8.count + 1)
        XCTAssertGreaterThan(out.utf8.count, ShellRunner.outputCap - 2)
    }

    func testNormalCommandOutputIsUnchanged() async {
        let out = await ShellRunner.run("  echo hello; echo err 1>&2  ")
        XCTAssertEqual(out, "hello\nerr")
        let empty = await ShellRunner.run("   ")
        XCTAssertEqual(empty, "")
        let quiet = await ShellRunner.run("true")
        XCTAssertEqual(quiet, "")
    }

    func testUnderCapOutputHasNoMarker() async {
        let out = await ShellRunner.run("/usr/bin/yes | /usr/bin/head -c 100000")
        XCTAssertFalse(out.contains(ShellRunner.truncationMarker))
        XCTAssertEqual(out.utf8.count, 99_999)   // 50 000 "y\n" lines, last newline trimmed
    }

    /// A cancel that lands before the spawn (pid still 0, nothing to kill) must stop the
    /// spawn, not let the command run to completion unkilled.
    func testCancelBeforeSpawnNeverRunsTheCommand() async throws {
        let file = tempDir().appendingPathComponent("ran").path
        let task = Task { () -> String in
            withUnsafeCurrentTask { $0?.cancel() }   // already cancelled: onCancel runs before execute
            return await ShellRunner.run("/usr/bin/touch '\(file)'")
        }
        let out = await task.value
        XCTAssertEqual(out, "")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file), "the command ran despite the cancel")
    }

    /// A double resume traps the test process; a leaked continuation shows as a nil here.
    func testCancelRacingExitResumesExactlyOnce() {
        for i in 0..<60 {
            let delay = UInt64(i % 12) * 1_000_000   // 0-11 ms, across spawn, output and exit
            let out = ExtensionHost.awaitSync(timeout: 5) { () -> String in
                let task = Task { await ShellRunner.run("echo \(i)") }
                try? await Task.sleep(nanoseconds: delay)
                task.cancel()
                return await task.value
            }
            guard let out else { return XCTFail("run \(i) never resumed") }
            XCTAssertTrue(out == "" || out == "\(i)", "run \(i): \(out)")
        }
    }
}

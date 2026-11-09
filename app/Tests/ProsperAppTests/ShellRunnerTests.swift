import XCTest
import LuaRuntime
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
            _ = killIfReal(pid, group: false)   // our own recorded pid: don't leak it past the failure
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

    func testExactlyCapBytesHaveNoMarker() async {
        let out = await ShellRunner.run("/usr/bin/head -c \(ShellRunner.outputCap) /dev/zero | /usr/bin/tr '\\0' y")
        XCTAssertEqual(out.utf8.count, ShellRunner.outputCap)
        XCTAssertFalse(out.contains(ShellRunner.truncationMarker))
    }

    /// QA #671 INFO-3: invalid UTF-8 (a cap cut inside a sequence, or a stray byte) shows
    /// U+FFFD instead of blanking the whole output.
    func testSplitOrInvalidUTF8GivesReplacementNotBlank() async {
        let split = await ShellRunner.run(
            "/usr/bin/head -c \(ShellRunner.outputCap - 1) /dev/zero | /usr/bin/tr '\\0' y; printf '\\303\\251'")
        XCTAssertTrue(split.hasSuffix("y\u{FFFD}\n" + ShellRunner.truncationMarker))
        let stray = await ShellRunner.run("printf 'ok\\377'")
        XCTAssertEqual(stray, "ok\u{FFFD}")
    }

    // MARK: host.shell.run through the Lua bridge and the live services (QA #671 F1/F2)

    /// Runs `body` (Lua defining `t()`) on a fresh VM with the live host services, off main
    /// like the extension lane, and returns t()'s first result.
    private func hostShell(_ body: String, callTimeout: TimeInterval) throws -> String? {
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: "com.test.shell", services: LiveExtensionHostServices.shared,
                          callTimeout: callTimeout).install(into: lua)
        try lua.run(body)
        nonisolated(unsafe) var result: Result<String?, Error> = .success(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result = Result { try lua.callGlobal("t") }
            done.signal()
        }
        guard done.wait(timeout: .now() + callTimeout + 30) == .success else {
            XCTFail("host.shell.run did not return"); return nil
        }
        return try result.get()
    }

    /// F1: keep_running hands control back at the timeout and leaves the command running.
    func testKeepRunningOutlivesTheTimeoutUnkilled() throws {
        let file = tempDir().appendingPathComponent("pid").path
        let out = try hostShell("""
            function t()
                local s = host.shell.run([[echo $$ > '\(file)'; exec /bin/sleep 30]], { keep_running = true })
                return s
            end
            """, callTimeout: 1)
        XCTAssertEqual(out, "", "the timeout returns control with empty output")
        let pid = try XCTUnwrap(parsePid(try? String(contentsOfFile: file, encoding: .utf8)))
        defer { _ = killIfReal(pid, group: false) }   // our own recorded pid
        usleep(2_500_000)   // past killGroup's 1 s grace, had a kill been sent
        XCTAssertEqual(kill(pid, 0), 0, "keep_running command \(pid) was killed")
    }

    /// F2: a >5 MB JSON file read through host.shell.run decodes; nothing marks the text.
    func testHostShellReadsLargeJSONIntact() throws {
        let file = tempDir().appendingPathComponent("big.json")
        let items = (0..<70_000).map { #"{"id":\#($0),"url":"https://example.com/\#($0)","title":"bookmark number \#($0)"}"# }
        try Data(("{\"items\":[" + items.joined(separator: ",") + "]}").utf8).write(to: file)
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0, 5_000_000)
        let out = try hostShell("""
            function t()
                local s, truncated = host.shell.run([[cat '\(file.path)']])
                local j = host.json.decode(s)
                return tostring(truncated) .. ":" .. tostring(j and #j.items)
            end
            """, callTimeout: 20)
        XCTAssertEqual(out, "nil:70000")
    }

    /// F2: past the 64 MiB host cap the text is cut, unmarked, and the second return is true.
    func testHostShellCapIsReportedAsSecondReturn() throws {
        let out = try hostShell("""
            function t()
                local s, truncated = host.shell.run("/usr/bin/yes | /usr/bin/head -c 70000000")
                return tostring(truncated) .. ":" .. #s .. ":" .. tostring(s:find("truncated", 1, true))
            end
            """, callTimeout: 30)
        // 64 MiB of "y\n" ends on a newline, which the trim drops.
        XCTAssertEqual(out, "true:\((64 << 20) - 1):nil")   // pinned: 64 MiB, not the constant
    }
}

import XCTest
import LuaRuntime
@testable import ProsperApp

/// No-op host services: host.process.run does not go through them.
private final class ProcRunServices: ExtensionHostServices, @unchecked Sendable {
    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
    func llmChat(_ prompt: String) async -> String { "" }
    func shellRun(_ command: String) async -> String { "" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
    func currentEpochSeconds() -> Double { 0 }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func prefGet(extensionID: String, key: String) -> String? { nil }
    func prefSet(extensionID: String, key: String, value: String) {}
    func notify(title: String, body: String) {}
    func listDirectories(_ path: String) -> [String] { [] }
}

/// #1563 (v2.1 13.6): host.process.run, system tier. Spawns only /bin/echo and /bin/sh -c with fixed literals (as
/// #833's ShellRunnerTests do); every pid a row reads from its own child is killed by that row's defer.
final class ProcessRunTests: XCTestCase {

    /// A VM with the host installed for an extension whose directory is `dir`; `run` is a Lua expression for opts.
    private func lua(_ dir: URL, privileged: Bool = true, trusted: Bool = true) throws -> LuaRuntime {
        let rt = try LuaRuntime()
        try ExtensionHost(extensionID: "com.test.procrun", services: ProcRunServices(), privileged: privileged,
                          trusted: trusted,
                          configOwner: ManagedConfigOwner(id: "com.test.procrun", version: "1.0.0", extensionDir: dir))
            .install(into: rt)
        return rt
    }

    private func luaRun(_ rt: LuaRuntime, _ opts: String) throws -> [String: Any] {
        try rt.run("function probe() return host.json.encode(host.process.run(\(opts))) end")
        let json = try XCTUnwrap(try rt.callGlobal("probe"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// Lua's argv reaches the child as it is: no shell sees it, so a "; touch", "$(id)" or backticks stay text.
    func testArgvIsPassedLiterally() throws {
        let dir = tempDir()
        let sentinel = dir.appendingPathComponent("sentinel").path
        let rt = try lua(dir)
        let args = ["; /usr/bin/touch \(sentinel)", "$(id)", "`id`", "a b", "'q'"]
        let lit = args.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\")
                                    .replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let r = try luaRun(rt, "{ argv = { \"/bin/echo\", \(lit.joined(separator: ", ")) } }")
        XCTAssertEqual(r["stdout"] as? String, args.joined(separator: " ") + "\n")
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["status"] as? Int, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel), "a shell ran the argument")
    }

    /// argv[1] must be an absolute path to an existing regular executable: relative, missing and directory are
    /// refused and nothing runs. A wrong opts shape raises.
    func testRelativeMissingAndDirectoryArgvAreRefused() async throws {
        let dir = tempDir()
        for (path, why) in [("bin/echo", "not an absolute path"), ("echo", "not an absolute path"),
                            (dir.appendingPathComponent("nope").path, "does not exist"),
                            (dir.path, "not a regular file"), ("", "missing")] {
            let r = await ProcessRun.run(argv: [path, "x"], cwd: dir)
            XCTAssertFalse(r.ok, path)
            XCTAssertTrue(r.status == nil, "\(path) ran")
            XCTAssertTrue(r.error?.contains(why) == true, "\(path): \(r.error ?? "nil")")
        }
        let empty = await ProcessRun.run(argv: [], cwd: dir)
        XCTAssertTrue(empty.error?.contains("missing") == true)
        let noDir = await ProcessRun.run(argv: ["/bin/echo"], cwd: nil)
        XCTAssertTrue(noDir.error?.contains("no directory") == true)
        let rt = try lua(dir)
        let r = try luaRun(rt, "{ argv = { \"bin/echo\" } }")
        XCTAssertEqual(r["ok"] as? Bool, false)
        XCTAssertTrue((r["error"] as? String)?.contains("not an absolute path") == true)
        XCTAssertThrowsError(try luaRun(rt, "{ argv = { \"/bin/echo\", 1 } }"), "a number argv entry")
        XCTAssertThrowsError(try luaRun(rt, "{ argv = { \"/bin/echo\" }, shell = true }"), "an unknown option")
        XCTAssertThrowsError(try luaRun(rt, "{ argv = { \"/bin/echo\", \"a\\0b\" } }"), "a NUL byte")
    }

    /// A refusal names argv[1] cleaned for display: a control or bidi character in it does not reach the text.
    func testRefusalTextIsCleaned() async throws {
        let r = await ProcessRun.run(argv: ["rel\u{202E}\u{1B}[31mx\n"], cwd: tempDir())
        let why = try XCTUnwrap(r.error)
        XCTAssertFalse(why.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\u{1B}" || $0 == "\n" }, why)
    }

    /// A timeout ends the whole group (the shell and its background child): ESRCH within 500 ms of the return.
    func testTimeoutKillsTheGroup() async throws {
        let dir = tempDir()
        let r = await ProcessRun.run(argv: ["/bin/sh", "-c", "echo $$; /bin/sleep 30 & wait"], cwd: dir, timeout: 0.5)
        let pgid = try XCTUnwrap(parsePid(r.stdout.split(separator: "\n").first.map(String.init)))
        defer { _ = killIfReal(pgid) }   // our own child's group
        XCTAssertTrue(r.timedOut)
        XCTAssertFalse(r.ok)
        let gone = await groupGone(pgid, within: 0.5)
        XCTAssertTrue(gone, "the group outlived the timeout")
        // escalate unregisters the group once its poll (50 ms) sees it empty
        var registered = true
        for _ in 0..<50 where registered {
            registered = CodexHarness.livePGIDs.withLock { $0[pgid] != nil }
            if registered { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertFalse(registered, "the killed group is still registered")
    }

    /// A dropped request (the calling task cancelled) ends the group the same way.
    func testDroppedRequestKillsTheGroup() async throws {
        let dir = tempDir()
        let task = Task { await ProcessRun.run(argv: ["/bin/sh", "-c", "echo $$; exec /bin/sleep 30"], cwd: dir,
                                               timeout: 10) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let r = await task.value
        let pgid = try XCTUnwrap(parsePid(r.stdout.split(separator: "\n").first.map(String.init)))
        defer { _ = killIfReal(pgid) }
        XCTAssertFalse(r.timedOut)
        XCTAssertFalse(r.ok)
        let gone = await groupGone(pgid, within: 0.5)
        XCTAssertTrue(gone, "the group outlived the dropped request")
    }

    /// 10 MB on each stream: each is cut at the cap, both are drained (the writers finish: exit 0, no timeout).
    func testTenMegabyteFloodIsCapped() async {
        let r = await ProcessRun.run(argv: ["/bin/sh", "-c",
                                            "/usr/bin/yes | /usr/bin/head -c 10485760; /usr/bin/yes e | /usr/bin/head -c 10485760 1>&2"],
                                     cwd: tempDir(), timeout: 10, maxBytes: 50 << 20)
        XCTAssertEqual(r.stdout.utf8.count, ProcessRun.maxBytes, "the cap is clamped to 1 MiB")
        XCTAssertEqual(r.stderr.utf8.count, ProcessRun.maxBytes)
        XCTAssertTrue(r.truncated)
        XCTAssertFalse(r.timedOut, "a stream was not drained")
        XCTAssertEqual(r.status, 0)
        let small = await ProcessRun.run(argv: ["/bin/sh", "-c", "/usr/bin/yes | /usr/bin/head -c 1000"],
                                         cwd: tempDir(), maxBytes: 100)
        XCTAssertEqual(small.stdout.utf8.count, 100)
        XCTAssertTrue(small.truncated)
    }

    /// Below the system tier host.process.run refuses and runs nothing, trusted or not.
    func testNonSystemExtensionIsRefused() throws {
        let dir = tempDir()
        for trusted in [true, false] {
            let r = try luaRun(try lua(dir, privileged: false, trusted: trusted), "{ argv = { \"/bin/echo\", \"ran\" } }")
            XCTAssertEqual(r["ok"] as? Bool, false)
            XCTAssertEqual(r["stdout"] as? String, "", "a non-system extension ran a process")
            XCTAssertTrue((r["error"] as? String)?.contains("restricted to system extensions") == true)
        }
    }

    /// The child gets PATH, HOME and LANG only (not ours), stdin at /dev/null, and the extension dir as cwd.
    func testEnvIsNotInherited() async throws {
        setenv("PROSPER_PROC_RUN_CANARY", "leak", 1)
        defer { unsetenv("PROSPER_PROC_RUN_CANARY") }
        let dir = tempDir()
        let r = await ProcessRun.run(argv: ["/bin/sh", "-c",
                                            "echo \"[$PROSPER_PROC_RUN_CANARY]|$PATH|$LANG|$HOME\"; read x; echo \"read=$?\"; pwd -P"],
                                     cwd: dir)
        let lines = r.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "[]|/usr/bin:/bin:/usr/sbin:/sbin|en_US.UTF-8|\(NSHomeDirectory())")
        XCTAssertTrue(lines.contains("read=1"), "stdin is not at EOF: \(lines)")
        XCTAssertEqual(lines.last, dir.resolvingSymlinksInPath().path)
        XCTAssertEqual(r.status, 0)
    }

    /// At most two run at once for the app; a live group is registered for the quit drain.
    func testAtMostTwoRunAtOnceAndGroupsAreRegistered() async throws {
        let dir = tempDir()
        let tasks = (0..<2).map { _ in
            Task { await ProcessRun.run(argv: ["/bin/sh", "-c", "echo $$; exec /bin/sleep 30"], cwd: dir, timeout: 5) }
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let third = await ProcessRun.run(argv: ["/bin/echo", "x"], cwd: dir)
        let registered = CodexHarness.livePGIDs.withLock { $0.count }
        tasks.forEach { $0.cancel() }
        var pgids: [pid_t] = []
        for t in tasks { if let p = parsePid((await t.value).stdout.split(separator: "\n").first.map(String.init)) { pgids.append(p) } }
        defer { pgids.forEach { _ = killIfReal($0) } }
        XCTAssertTrue(third.error?.contains("already running") == true, third.error ?? "the third ran")
        XCTAssertGreaterThanOrEqual(registered, 2, "the live groups are not registered for quit")
        XCTAssertEqual(pgids.count, 2)
        let after = await ProcessRun.run(argv: ["/bin/echo", "x"], cwd: dir)
        XCTAssertEqual(after.stdout, "x\n", "a slot was not given back")
    }

    private func groupGone(_ pgid: pid_t, within limit: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if kill(-pgid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return kill(-pgid, 0) == -1 && errno == ESRCH
    }
}

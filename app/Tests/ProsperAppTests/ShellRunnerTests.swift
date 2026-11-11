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

    /// Runs `body` (Lua defining `t()`) on a fresh VM with the live host services (or
    /// `services`), off main like the extension lane, and returns t()'s first result.
    private func hostShell(_ body: String, callTimeout: TimeInterval,
                           services: ExtensionHostServices = LiveExtensionHostServices.shared,
                           extensionID: String = "com.test.shell") throws -> String? {
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: extensionID, services: services,
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
        var pid: pid_t?
        defer { if let pid { _ = killIfReal(pid, group: false) } }   // our own recorded pid, armed before the read
        let recorded = try XCTUnwrap(parsePid(try? String(contentsOfFile: file, encoding: .utf8)))
        pid = recorded
        usleep(2_500_000)   // past killGroup's 1 s grace, had a kill been sent
        XCTAssertEqual(kill(recorded, 0), 0, "keep_running command \(recorded) was killed")
    }

    /// QA #671 r2: without opts the bridge timeout kills zsh and its background child.
    func testDefaultOptsTimeoutKillsTheProcessGroup() throws {
        let file = tempDir().appendingPathComponent("pids").path
        var live: [pid_t] = []
        defer { live.forEach { _ = killIfReal($0, group: false) } }   // armed before the pid file is read
        let out = try hostShell("""
            function t()
                return host.shell.run([[echo $$ > '\(file)'; /bin/sleep 30 & echo $! >> '\(file)'; wait]])
            end
            """, callTimeout: 1)
        XCTAssertEqual(out, "", "the timeout returns empty output")
        live = (try? String(contentsOfFile: file, encoding: .utf8))?
            .split(separator: "\n").compactMap { parsePid(String($0)) } ?? []
        XCTAssertEqual(live.count, 2, "expected the zsh pid and the sleep pid")
        live.removeAll { waitGone($0, timeout: 2) }
        XCTAssertEqual(live, [], "these pids outlived the default-opts timeout by 2 s")
    }

    /// QA #671 r2: an uncapped call returns exactly one value, so `f(host.shell.run(x))` sees one arg.
    func testUncappedCallReturnsExactlyOneValue() throws {
        let out = try hostShell("""
            function t() return tostring(select('#', host.shell.run("echo hi"))) end
            """, callTimeout: 10)
        XCTAssertEqual(out, "1")
    }

    /// QA #671 r2 R2: a bad opts raises a Lua error naming the key; nil and a boolean pass.
    func testBadOptsRaiseNamingTheKey() throws {
        let out = try hostShell("""
            local function e(o)
                local ok, err = pcall(host.shell.run, "true", o)
                return ok and "ok" or tostring(err)
            end
            function t()
                return table.concat({ e("yes"), e({ keep_runing = true }), e({ keep_running = 1 }),
                                      e({ keep_running = false }), e(nil) }, "|")
            end
            """, callTimeout: 10)
        XCTAssertEqual(out, "host.shell.run: opts must be a table, got string"
                       + "|host.shell.run: unknown option 'keep_runing'"
                       + "|host.shell.run: keep_running must be a boolean, got number|ok|ok")
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
        try requireHeavyTests()   // 70 MB through zsh, a pipe and the Lua bridge (#710)
        let out = try hostShell("""
            function t()
                local s, truncated = host.shell.run("/usr/bin/yes | /usr/bin/head -c 70000000")
                return tostring(truncated) .. ":" .. #s .. ":" .. tostring(s:find("truncated", 1, true))
            end
            """, callTimeout: 30)
        // 64 MiB of "y\n" ends on a newline, which the trim drops.
        XCTAssertEqual(out, "true:\((64 << 20) - 1):nil")   // pinned: 64 MiB, not the constant
    }

    // MARK: appupdates upgrade at the host timeout (QA #671 r2 R3)

    /// Runs appupdates_upgrade with a canned brew whose upgrade takes `upgradeSeconds`
    /// against a 0.5 s host timeout; returns the notification bodies.
    private func appupdatesUpgrade(upgradeSeconds: Double, outdatedAfter: Int) throws -> [String] {
        let lua = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/Resources/extensions/appupdates/init.lua")
        let fake = BrewFakeServices(upgradeSeconds: upgradeSeconds, outdatedAfter: outdatedAfter)
        _ = try hostShell(try String(contentsOf: lua, encoding: .utf8) + """

            function t() appupdates_upgrade() return "ok" end
            """, callTimeout: 0.5, services: fake, extensionID: "com.prosper.appupdates")
        return fake.notifications
    }

    func testAppUpdatesUpgradeStillRunningSaysSo() throws {
        XCTAssertEqual(try appupdatesUpgrade(upgradeSeconds: 2, outdatedAfter: 1),
                       ["brew upgrade is still running in the background"])
    }

    func testAppUpdatesUpgradeFinishedCountsUpgrades() throws {
        XCTAssertEqual(try appupdatesUpgrade(upgradeSeconds: 0, outdatedAfter: 0), ["1 package upgraded"])
        XCTAssertEqual(try appupdatesUpgrade(upgradeSeconds: 0, outdatedAfter: 1), ["Nothing was upgraded"])
    }
}

/// A Mac with one outdated brew formula: `brew upgrade` takes `upgradeSeconds` and prints
/// nothing itself, like a real no-op upgrade; only a trailing `; echo $?` adds the status.
/// Then `outdatedAfter` remain.
private final class BrewFakeServices: ExtensionHostServices, @unchecked Sendable {
    let upgradeSeconds: Double
    let outdatedAfter: Int
    private let lock = NSLock()
    private var prefs = ["cache": #"{"brew":[{"name":"jq","from":"1.6","to":"1.7"}],"macos":[]}"#]
    private var bodies: [String] = []
    var notifications: [String] { lock.lock(); defer { lock.unlock() }; return bodies }

    init(upgradeSeconds: Double, outdatedAfter: Int) {
        self.upgradeSeconds = upgradeSeconds
        self.outdatedAfter = outdatedAfter
    }

    func shellRun(_ command: String) async -> String {
        if command.contains(" upgrade ") {
            try? await Task.sleep(nanoseconds: UInt64(upgradeSeconds * 1_000_000_000))
            return command.hasSuffix("; echo $?") ? "0" : ""
        }
        guard command.contains(" outdated ") else { return "" }
        let formulae = Array(repeating: #"{"name":"jq","installed_versions":["1.6"],"current_version":"1.7"}"#,
                             count: outdatedAfter).joined(separator: ",")
        return #"{"formulae":[\#(formulae)],"casks":[]}"#
    }
    func fsExists(_ path: String) -> Bool { path == "/opt/homebrew/bin/brew" }
    func notify(title: String, body: String) { lock.lock(); bodies.append(body); lock.unlock() }
    func prefGet(extensionID: String, key: String) -> String? { lock.lock(); defer { lock.unlock() }; return prefs[key] }
    func prefSet(extensionID: String, key: String, value: String) { lock.lock(); prefs[key] = value; lock.unlock() }
    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
    func llmChat(_ prompt: String) async -> String { "" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
    func currentEpochSeconds() -> Double { 1_700_000_000 }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func listDirectories(_ path: String) -> [String] { [] }
}

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
                                      e({ keep_running = false }), e(nil), e(false), e(true), e(1) }, "|")
            end
            """, callTimeout: 10)
        XCTAssertEqual(out, "host.shell.run: opts must be a table, got string"
                       + "|host.shell.run: unknown option 'keep_runing'"
                       + "|host.shell.run: keep_running must be a boolean, got number|ok|ok|ok"
                       + "|host.shell.run: opts must be a table, got boolean"
                       + "|host.shell.run: opts must be a table, got number")
    }

    /// QA #714 INFO-1: `false` opts (from `cond and { keep_running = true }`) is no opts:
    /// one return value, and the timeout kills zsh and its background child.
    func testFalseOptsIsNoOptsAndKillsAtTheTimeout() throws {
        let file = tempDir().appendingPathComponent("pids").path
        var live: [pid_t] = []
        defer { live.forEach { _ = killIfReal($0, group: false) } }   // armed before the pid file is read
        let out = try hostShell("""
            function t()
                local r = table.pack(host.shell.run([[echo $$ > '\(file)'; /bin/sleep 30 & echo $! >> '\(file)'; wait]], false))
                return r.n .. ":" .. r[1]
            end
            """, callTimeout: 1)
        XCTAssertEqual(out, "1:", "one empty return at the timeout")
        live = (try? String(contentsOfFile: file, encoding: .utf8))?
            .split(separator: "\n").compactMap { parsePid(String($0)) } ?? []
        XCTAssertEqual(live.count, 2, "expected the zsh pid and the sleep pid")
        live.removeAll { waitGone($0, timeout: 2) }
        XCTAssertEqual(live, [], "these pids outlived the false-opts timeout by 2 s")
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

    /// Calls `call` (Lua) on the shipped appupdates init.lua with `fake` as the host,
    /// against a 0.5 s host timeout.
    private func appupdates(_ fake: BrewFakeServices, _ call: String = "appupdates_upgrade()") throws {
        let lua = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/Resources/extensions/appupdates/init.lua")
        _ = try hostShell(try String(contentsOf: lua, encoding: .utf8) + """

            function t() \(call) return "ok" end
            """, callTimeout: 0.5, services: fake, extensionID: "com.prosper.appupdates")
    }

    /// Runs appupdates_upgrade with a canned brew whose upgrade takes `upgradeSeconds`;
    /// returns the notification bodies.
    private func appupdatesUpgrade(upgradeSeconds: Double, outdatedAfter: Int) throws -> [String] {
        let fake = BrewFakeServices(upgradeSeconds: upgradeSeconds, outdatedAfter: outdatedAfter)
        try appupdates(fake)
        return fake.notifications
    }

    /// A backgrounded upgrade also arms the 60 s watch and records what it watches (QA #714 INFO-5).
    func testAppUpdatesUpgradeStillRunningSaysSo() throws {
        let fake = BrewFakeServices(upgradeSeconds: 2, outdatedAfter: 1)
        try appupdates(fake)
        XCTAssertEqual(fake.notifications, ["brew upgrade is still running in the background"])
        XCTAssertEqual(fake.timers["appupdates.upgrade_poll"], "60.0:on_upgrade_poll")
        let pending = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data((fake.pref("upgrade_pending") ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(pending["before"] as? Double, 1)
        XCTAssertEqual(pending["at"] as? Double, 1_700_000_000)
        XCTAssertEqual(pending["file"] as? String, "/fake-tmp/prosper-appupdates-1700000000000/status")
        // QA #730 INFO-1: the status file sits in a 0700 dir the same line creates before brew runs.
        // #1011: brew writes into that file, not the pipe; the file gets the status and is printed,
        // and when it cannot be, the bare status is (`|| echo $s`).
        let d = "'/fake-tmp/prosper-appupdates-1700000000000'"
        let part = "'/fake-tmp/prosper-appupdates-1700000000000/status.part'"
        let file = "'/fake-tmp/prosper-appupdates-1700000000000/status'"
        XCTAssertEqual(fake.upgradeCommand, "/bin/mkdir -m 700 \(d) 2>&1 || { echo 'brew upgrade did not start'; exit; }; "
            + "/opt/homebrew/bin/brew upgrade > \(part) 2>&1; s=$?; [ ! -L \(d) ] && [ -O \(d) ] && "
            + "{ echo $s >> \(part) && /bin/mv -f \(part) \(file) && /bin/cat \(file); } || echo $s")
        XCTAssertEqual(fake.cleanups, [], "the watch owns the file now")
    }

    func testAppUpdatesUpgradeFinishedCountsUpgrades() throws {
        XCTAssertEqual(try appupdatesUpgrade(upgradeSeconds: 0, outdatedAfter: 0), ["1 package upgraded"])
        XCTAssertEqual(try appupdatesUpgrade(upgradeSeconds: 0, outdatedAfter: 1), ["Nothing was upgraded"])
    }

    /// QA #730 INFO-3: the synchronous path removes the status file and its dir, guarded.
    func testSyncUpgradeRemovesTheStatusFile() throws {
        let fake = BrewFakeServices(upgradeSeconds: 0, outdatedAfter: 0)
        try appupdates(fake)
        let d = "'/fake-tmp/prosper-appupdates-1700000000000'"
        XCTAssertEqual(fake.cleanups, ["[ ! -L \(d) ] && [ -O \(d) ] && { /bin/rm -f "
            + "'/fake-tmp/prosper-appupdates-1700000000000/status' '/fake-tmp/prosper-appupdates-1700000000000/status.part'; "
            + "/bin/rmdir \(d); }"])
    }

    private let brewOutdated = "/opt/homebrew/bin/brew outdated --json=v2 2>/dev/null"

    /// #1011 (QA #730 INFO-4): the count is taken against `brew outdated` read right before the
    /// upgrade, not the cache. The cache holds 1 (jq), brew says 2 before and 1 after: 1 upgraded
    /// (the cache would say none, and so would a read after the upgrade).
    func testAppUpdatesCountsAgainstTheListReadBeforeTheUpgrade() throws {
        let fake = BrewFakeServices(upgradeSeconds: 0, outdatedBefore: 2, outdatedAfter: 1)
        try appupdates(fake)
        XCTAssertEqual(fake.notifications, ["1 package upgraded"])
        XCTAssertEqual(fake.commands, [brewOutdated, brewOutdated], "one read before the upgrade, one after")
    }

    /// #1011: no answer from the read before the upgrade claims no count, in the foreground and
    /// through the watch; the re-check after it still refreshes the list.
    func testAppUpdatesNoAnswerBeforeTheUpgradeClaimsNoCount() throws {
        for reply in ["", "error: spawn failed"] {
            let fake = BrewFakeServices(upgradeSeconds: 0, outdatedAfter: 0, outdatedBeforeReply: reply)
            try appupdates(fake)
            XCTAssertEqual(fake.notifications, ["brew upgrade finished"], reply)
            XCTAssertEqual(fake.cachedBrew, [], reply)
        }
        let fake = BrewFakeServices(upgradeSeconds: 2, outdatedAfter: 0, outdatedBeforeReply: "")
        try appupdates(fake)
        let pending = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data((fake.pref("upgrade_pending") ?? "").utf8)) as? [String: Any])
        XCTAssertTrue(pending["before"] == nil, "\(pending)")
        fake.statusFileExists = true
        try appupdates(fake, "on_upgrade_poll()")
        XCTAssertEqual(fake.notifications, ["brew upgrade is still running in the background", "brew upgrade finished"])
    }

    /// #1011 r2: when the status file cannot be printed (the folder is no longer ours after brew)
    /// the shell prints the bare status, and a foreground run ends there: failed or counted, with
    /// no watch record and no timer, its folder removed.
    func testForegroundBareStatusEndsTheUpgrade() throws {
        let failed = BrewFakeServices(upgradeSeconds: 0, outdatedAfter: 1, upgradeStatus: 1, folderLost: true)
        try appupdates(failed)
        XCTAssertEqual(failed.notifications, ["brew upgrade failed (exit 1)"])
        let counted = BrewFakeServices(upgradeSeconds: 0, outdatedAfter: 0, folderLost: true)
        try appupdates(counted)
        XCTAssertEqual(counted.notifications, ["1 package upgraded"])
        for fake in [failed, counted] {
            XCTAssertNil(fake.pref("upgrade_pending"))
            XCTAssertNil(fake.timers["appupdates.upgrade_poll"])
            XCTAssertEqual(fake.cleanups.count, 1)
        }
    }

    /// QA #730 F1: brew exits non-zero when some packages fail and the rest upgrade. The list
    /// is re-derived and saved, and one notice says the failure, its status and the count.
    func testAppUpdatesPartialFailureRefreshesAndCounts() throws {
        let fake = BrewFakeServices(upgradeSeconds: 0, outdatedAfter: 0, upgradeStatus: 1)
        try appupdates(fake)
        XCTAssertEqual(fake.notifications, ["brew upgrade failed for some packages (exit 1); 1 package upgraded"])
        XCTAssertEqual(fake.cachedBrew, [])
        XCTAssertNil(fake.timers["appupdates.upgrade_poll"])
    }

    /// Nothing upgraded: a plain failure with the status; the (re-read, unchanged) list stays.
    func testAppUpdatesTotalFailureKeepsTheListAndSaysFailed() throws {
        let fake = BrewFakeServices(upgradeSeconds: 0, outdatedAfter: 1, upgradeStatus: 1)
        try appupdates(fake)
        XCTAssertEqual(fake.notifications, ["brew upgrade failed (exit 1)"])
        XCTAssertEqual(fake.cachedBrew, ["jq"])
        XCTAssertTrue(fake.commands.contains { $0.contains(" outdated ") }, "\(fake.commands)")
    }

    /// A failed upgrade whose re-check gets no answer: the cached list stays, no count, and the
    /// notice says the list is stale (#1011, QA #730 r2 INFO-3).
    func testAppUpdatesFailureWithNoAnswerKeepsTheList() throws {
        let fake = BrewFakeServices(upgradeSeconds: 0, outdatedAfter: 0, upgradeStatus: 1, outdatedReply: "")
        let before = fake.pref("cache")
        try appupdates(fake)
        XCTAssertEqual(fake.notifications, ["brew upgrade failed (exit 1); the list could not be refreshed"])
        XCTAssertEqual(fake.pref("cache"), before)
    }

    /// QA #714 INFO-2 / #730 F1: Homebrew's lock refusal while our own backgrounded upgrade is
    /// watched, its record written after this call began (a record there at the start refuses
    /// before brew runs): no `brew outdated` after the refusal (only the read before the upgrade),
    /// the cache untouched, no count, and the first upgrade's watch and its pref survive the refused call.
    func testAppUpdatesLockRefusalDuringOurWatchKeepsCacheAndWatch() throws {
        let fake = BrewFakeServices(upgradeSeconds: 0, outdatedAfter: 0, upgradeStatus: 1, locked: true)
        let pending = #"{"file":"/fake-tmp/prosper-appupdates-1/status","at":1700000000,"before":1}"#
        fake.pendingWrittenByUpgrade = pending
        fake.timerSchedule(extensionID: "", id: "appupdates.upgrade_poll", every: true, seconds: 60, handler: "on_upgrade_poll")
        let before = fake.pref("cache")
        try appupdates(fake)
        XCTAssertEqual(fake.notifications, ["brew upgrade refused: an upgrade Prosper started is still running"])
        XCTAssertEqual(fake.pref("cache"), before)
        XCTAssertEqual(fake.commands, [brewOutdated], "only the read before the upgrade: no re-check, no softwareupdate")
        XCTAssertEqual(fake.cleanups.count, 1, "the refused call removes only its own status file")
        XCTAssertEqual(fake.timers["appupdates.upgrade_poll"], "60.0:on_upgrade_poll")
        XCTAssertEqual(fake.pref("upgrade_pending"), pending)
    }

    /// QA #730 r2 F1: Upgrade goes to the background, then Upgrade again while it runs: refused
    /// by name, no second mkdir or brew, the record and the watch exactly as the first left them.
    func testSecondUpgradeWhileOursRunsIsRefused() throws {
        let fake = BrewFakeServices(upgradeSeconds: 2, outdatedAfter: 0)
        try appupdates(fake)
        let pending = fake.pref("upgrade_pending")
        fake.now += 90
        try appupdates(fake)
        XCTAssertEqual(fake.notifications, ["brew upgrade is still running in the background",
                                            "brew upgrade refused: an upgrade Prosper started is still running"])
        XCTAssertEqual(fake.upgradeRuns, 1, "no second mkdir + brew upgrade line")
        XCTAssertEqual(fake.commands, [brewOutdated], "only the first call's read before its upgrade")
        XCTAssertEqual(fake.cleanups, [])
        XCTAssertEqual(fake.pref("upgrade_pending"), pending)
        XCTAssertEqual(fake.timers, ["appupdates.upgrade_poll": "60.0:on_upgrade_poll"])
    }

    /// The first upgrade's status file is there when Upgrade is pressed again (before the 60 s
    /// tick): its result is reported and its file removed, then the second upgrade starts.
    func testSecondUpgradeFinishesTheEndedOneFirst() throws {
        let fake = BrewFakeServices(upgradeSeconds: 2, outdatedAfter: 0)
        try appupdates(fake)
        fake.statusFileExists = true
        fake.now += 40
        try appupdates(fake)
        XCTAssertEqual(fake.notifications, ["brew upgrade is still running in the background", "1 package upgraded",
                                            "brew upgrade is still running in the background"])
        // The first call's read before its upgrade; then the ended one read and removed, its
        // re-check, and the second call's read before its upgrade.
        let d = "'/fake-tmp/prosper-appupdates-1700000000000'"
        XCTAssertEqual(fake.commands, [brewOutdated,
            "/bin/cat '/fake-tmp/prosper-appupdates-1700000000000/status'; [ ! -L \(d) ] && [ -O \(d) ] && "
            + "{ /bin/rm -f '/fake-tmp/prosper-appupdates-1700000000000/status' "
            + "'/fake-tmp/prosper-appupdates-1700000000000/status.part'; /bin/rmdir \(d); }",
            brewOutdated, brewOutdated])
        XCTAssertEqual(fake.upgradeRuns, 2)
        XCTAssertTrue(fake.upgradeCommand?.hasPrefix("/bin/mkdir -m 700 '/fake-tmp/prosper-appupdates-1700000040000'") == true,
                      fake.upgradeCommand ?? "nil")
        let pending = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data((fake.pref("upgrade_pending") ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(pending["file"] as? String, "/fake-tmp/prosper-appupdates-1700000040000/status")
    }

    /// F1b: a lock nobody of ours holds (brew in Terminal), possibly hit after this run upgraded
    /// earlier packages: the list is re-read and saved; the notice names the lock and the count.
    func testAppUpdatesForeignLockRefreshesAndCounts() throws {
        let fake = BrewFakeServices(upgradeSeconds: 0, outdatedAfter: 0, upgradeStatus: 1, locked: true)
        try appupdates(fake)
        XCTAssertEqual(fake.notifications,
                       ["brew upgrade stopped: another Homebrew process holds its lock (exit 1); 1 package upgraded"])
        XCTAssertEqual(fake.cachedBrew, [])

        let none = BrewFakeServices(upgradeSeconds: 0, outdatedAfter: 1, upgradeStatus: 1, locked: true)
        try appupdates(none)
        XCTAssertEqual(none.notifications, ["brew upgrade stopped: another Homebrew process holds its lock (exit 1)"])
        XCTAssertEqual(none.cachedBrew, ["jq"])
        XCTAssertTrue(none.commands.contains { $0.contains(" outdated ") }, "\(none.commands)")
    }

    /// QA #714 INFO-3: "" (timeout) and a spawn error from `brew outdated` are no answer, not
    /// "nothing outdated": the cached brew list stays and no count is claimed.
    func testAppUpdatesNoAnswerFromBrewKeepsTheList() throws {
        for reply in ["", "error: spawn failed"] {
            let fake = BrewFakeServices(upgradeSeconds: 0, outdatedAfter: 0, outdatedReply: reply)
            let before = fake.pref("cache")
            try appupdates(fake)
            XCTAssertEqual(fake.notifications, ["brew upgrade finished; the list could not be refreshed"], reply)
            XCTAssertEqual(fake.pref("cache"), before, reply)
            try appupdates(fake, "appupdates_refresh()")
            XCTAssertEqual(fake.cachedBrew, ["jq"], reply)
        }
        // brew's own empty answer does empty the list.
        let fake = BrewFakeServices(upgradeSeconds: 0, outdatedBefore: 0, outdatedAfter: 0)
        try appupdates(fake, "appupdates_refresh()")
        XCTAssertEqual(fake.cachedBrew, [])
    }

    // MARK: the backgrounded-upgrade watch (QA #714 INFO-5)

    /// A fake whose earlier upgrade went to the background at `fake.now` with 1 package outdated
    /// (that upgrade already ran, so brew's list is `outdatedAfter`).
    private func watching(statusFile: Bool, outdatedAfter: Int = 0, upgradeStatus: Int = 0) -> BrewFakeServices {
        let fake = BrewFakeServices(upgradeSeconds: 0, outdatedBefore: outdatedAfter, outdatedAfter: outdatedAfter,
                                    upgradeStatus: upgradeStatus, statusFileExists: statusFile)
        fake.prefSet(extensionID: "", key: "upgrade_pending",
                     value: #"{"file":"/fake-tmp/prosper-appupdates-1/status","at":1700000000,"before":1}"#)
        fake.timerSchedule(extensionID: "", id: "appupdates.upgrade_poll", every: true, seconds: 60, handler: "on_upgrade_poll")
        return fake
    }

    func testUpgradeWatchStaysWhileBrewRuns() throws {
        let fake = watching(statusFile: false)
        fake.now += 3600
        try appupdates(fake, "on_upgrade_poll()")
        XCTAssertEqual(fake.notifications, [])
        XCTAssertEqual(fake.commands, [], "no refresh while brew runs")
        XCTAssertNotNil(fake.timers["appupdates.upgrade_poll"], "the watch stays")
        XCTAssertNotEqual(fake.pref("upgrade_pending"), "")
    }

    func testUpgradeWatchRefreshesNotifiesAndEndsWhenBrewEnds() throws {
        let fake = watching(statusFile: true)
        try appupdates(fake, "on_upgrade_poll()")
        XCTAssertEqual(fake.notifications, ["1 package upgraded"])
        XCTAssertEqual(fake.cachedBrew, [])
        XCTAssertNil(fake.timers["appupdates.upgrade_poll"], "the watch cancels itself")
        XCTAssertEqual(fake.pref("upgrade_pending"), "")
        // QA #730 INFO-3: the same line reads and removes the status file and its dir.
        let d = "'/fake-tmp/prosper-appupdates-1'"
        XCTAssertEqual(fake.commands.first, "/bin/cat '/fake-tmp/prosper-appupdates-1/status'; [ ! -L \(d) ] && [ -O \(d) ] && "
            + "{ /bin/rm -f '/fake-tmp/prosper-appupdates-1/status' '/fake-tmp/prosper-appupdates-1/status.part'; /bin/rmdir \(d); }")
    }

    /// #1011: a record whose `at` is this very second is fresh: the poll keeps it and its timer,
    /// and an Upgrade at the same instant is refused and runs nothing.
    func testUpgradeWatchRecordFromThisSecondIsFresh() throws {
        let fake = watching(statusFile: false)   // its at == fake.now
        let record = fake.pref("upgrade_pending")
        try appupdates(fake, "on_upgrade_poll()")
        XCTAssertEqual(fake.timers["appupdates.upgrade_poll"], "60.0:on_upgrade_poll")
        XCTAssertEqual(fake.pref("upgrade_pending"), record)
        try appupdates(fake)
        XCTAssertEqual(fake.notifications, ["brew upgrade refused: an upgrade Prosper started is still running"])
        XCTAssertEqual(fake.upgradeRuns, 0)
        XCTAssertEqual(fake.commands, [])
        XCTAssertEqual(fake.cleanups, [])
        XCTAssertEqual(fake.pref("upgrade_pending"), record)
    }

    /// QA #730 F1 through the watch: a non-zero status refreshes and reports both.
    func testUpgradeWatchPartialFailureRefreshesAndCounts() throws {
        let fake = watching(statusFile: true, upgradeStatus: 1)
        try appupdates(fake, "on_upgrade_poll()")
        XCTAssertEqual(fake.notifications, ["brew upgrade failed for some packages (exit 1); 1 package upgraded"])
        XCTAssertEqual(fake.cachedBrew, [])
        XCTAssertNil(fake.timers["appupdates.upgrade_poll"])
    }

    func testUpgradeWatchGivesUpSilentlyAtTheCap() throws {
        let fake = watching(statusFile: false)
        fake.now += 2 * 3600
        try appupdates(fake, "on_upgrade_poll()")
        XCTAssertEqual(fake.notifications, [])
        XCTAssertEqual(fake.commands, [])
        XCTAssertNil(fake.timers["appupdates.upgrade_poll"], "the watch ends at the cap")
        XCTAssertEqual(fake.pref("upgrade_pending"), "")
        XCTAssertEqual(fake.cleanups, [Self.watchedCleanup], "#1011: its folder goes too")
    }

    /// The cleanup of the folder `watching` records, verbatim.
    private static let watchedCleanup = "[ ! -L '/fake-tmp/prosper-appupdates-1' ] && [ -O '/fake-tmp/prosper-appupdates-1' ] && "
        + "{ /bin/rm -f '/fake-tmp/prosper-appupdates-1/status' '/fake-tmp/prosper-appupdates-1/status.part'; "
        + "/bin/rmdir '/fake-tmp/prosper-appupdates-1'; }"

    // MARK: QA #714 r4 pins

    /// An unreadable status (empty status file, garbage last line) is a failed upgrade, on
    /// the watch path and the synchronous path: "(exit ?)", never success; like any non-lock
    /// failure the list is re-derived (QA #730 F1).
    func testUnreadableUpgradeStatusCountsAsFailed() throws {
        let watch = BrewFakeServices(upgradeSeconds: 0, outdatedAfter: 1, statusFileExists: true, statusText: "")
        watch.prefSet(extensionID: "", key: "upgrade_pending",
                      value: #"{"file":"/fake-tmp/prosper-appupdates-1/status","at":1700000000,"before":1}"#)
        try appupdates(watch, "on_upgrade_poll()")
        XCTAssertEqual(watch.notifications, ["brew upgrade failed (exit ?)"])
        XCTAssertEqual(watch.cachedBrew, ["jq"])

        let sync = BrewFakeServices(upgradeSeconds: 0, outdatedAfter: 0, statusText: "Upgrading jq\ndone")
        try appupdates(sync)
        XCTAssertEqual(sync.notifications, ["brew upgrade failed for some packages (exit ?); 1 package upgraded"])
        XCTAssertEqual(sync.cachedBrew, [])
    }

    /// A relaunch drops a pending watch: after on_launch the pref is cleared, the watch timer
    /// is cancelled, and a tick that still arrives (status file present) does nothing.
    func testLaunchDropsAPendingUpgradeWatch() throws {
        let fake = watching(statusFile: true)
        try appupdates(fake, "on_launch()")
        XCTAssertEqual(fake.pref("upgrade_pending"), "")
        XCTAssertNil(fake.timers["appupdates.upgrade_poll"])
        XCTAssertEqual(fake.cleanups, [Self.watchedCleanup], "#1011: its folder goes too")
        try appupdates(fake, "on_upgrade_poll()")
        XCTAssertEqual(fake.notifications, [])
        XCTAssertEqual(fake.commands, [])
    }

    /// The softwareupdate twin of testAppUpdatesNoAnswerFromBrewKeepsTheList.
    func testAppUpdatesNoAnswerFromSoftwareUpdateKeepsTheList() throws {
        let cache = #"{"brew":[],"macos":["Safari 18.1"]}"#
        for reply in ["", "error: spawn failed"] {
            let fake = BrewFakeServices(upgradeSeconds: 0, outdatedAfter: 0, suReply: reply)
            fake.prefSet(extensionID: "", key: "cache", value: cache)
            try appupdates(fake, "appupdates_refresh()")
            XCTAssertEqual(fake.cachedMacos, ["Safari 18.1"], reply)
        }
        let fake = BrewFakeServices(upgradeSeconds: 0, outdatedAfter: 0,
                                    suReply: "Software Update Tool\n\nFinding available software\nNo new software available.")
        fake.prefSet(extensionID: "", key: "cache", value: cache)
        try appupdates(fake, "appupdates_refresh()")
        XCTAssertEqual(fake.cachedMacos, [])
    }
}

/// A Mac with `outdatedBefore` (one) outdated brew formulae: `brew upgrade` takes `upgradeSeconds`,
/// prints a package error when `upgradeStatus` is not 0 (Homebrew's lock refusal when `locked`)
/// into the status file, which the shell then prints with the status line appended; when the
/// folder is no longer ours after brew (`folderLost`) only the closing `|| echo $s` prints, the
/// bare status. Once the upgrade ran, `outdatedAfter` remain. `outdatedReply` comes back verbatim
/// for every `brew outdated`, `outdatedBeforeReply` for those before the upgrade.
/// Nothing here touches a real file, process or timer.
private final class BrewFakeServices: ExtensionHostServices, @unchecked Sendable {
    let upgradeSeconds: Double
    let outdatedBefore: Int
    let outdatedAfter: Int
    let upgradeStatus: Int
    let locked: Bool
    let outdatedReply: String?
    let outdatedBeforeReply: String?
    let folderLost: Bool
    private var fileThere: Bool
    var statusFileExists: Bool {
        get { lock.lock(); defer { lock.unlock() }; return fileThere }
        set { lock.lock(); fileThere = newValue; lock.unlock() }
    }
    /// When set, the `brew upgrade` call writes it as the pending record (a record that came
    /// after appupdates_upgrade began).
    var pendingWrittenByUpgrade: String?
    /// When set, the upgrade's whole output and the status file's text (no trailing number).
    let statusText: String?
    let suReply: String
    private let lock = NSLock()
    private var prefs = ["cache": #"{"brew":[{"name":"jq","from":"1.6","to":"1.7"}],"macos":[]}"#]
    private var bodies: [String] = []
    private var ran: [String] = []
    private var cleaned: [String] = []
    private var upgradeLine: String?
    private var upgradeCount = 0
    private var armed: [String: String] = [:]
    private var clock: Double = 1_700_000_000
    var notifications: [String] { lock.lock(); defer { lock.unlock() }; return bodies }
    /// Every shell command except the upgrade itself and the bare folder cleanups.
    var commands: [String] { lock.lock(); defer { lock.unlock() }; return ran }
    /// The bare folder cleanups (synchronous path, the watch's cap, a relaunch), verbatim.
    var cleanups: [String] { lock.lock(); defer { lock.unlock() }; return cleaned }
    /// The last `brew upgrade` shell line, verbatim.
    var upgradeCommand: String? { lock.lock(); defer { lock.unlock() }; return upgradeLine }
    /// How many `brew upgrade` lines ran.
    var upgradeRuns: Int { lock.lock(); defer { lock.unlock() }; return upgradeCount }
    /// Live timers: id -> "<seconds>:<handler>".
    var timers: [String: String] { lock.lock(); defer { lock.unlock() }; return armed }
    var now: Double {
        get { lock.lock(); defer { lock.unlock() }; return clock }
        set { lock.lock(); clock = newValue; lock.unlock() }
    }
    func pref(_ key: String) -> String? { prefGet(extensionID: "", key: key) }
    /// Package names in the cached brew list; an empty Lua table may encode as `{}`.
    var cachedBrew: [String]? {
        guard let doc = try? JSONSerialization.jsonObject(with: Data((pref("cache") ?? "").utf8)) as? [String: Any]
        else { return nil }
        if let d = doc["brew"] as? [String: Any], d.isEmpty { return [] }
        return (doc["brew"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
    }
    /// The cached macOS update titles.
    var cachedMacos: [String]? {
        guard let doc = try? JSONSerialization.jsonObject(with: Data((pref("cache") ?? "").utf8)) as? [String: Any]
        else { return nil }
        if let d = doc["macos"] as? [String: Any], d.isEmpty { return [] }
        return doc["macos"] as? [String]
    }

    init(upgradeSeconds: Double, outdatedBefore: Int = 1, outdatedAfter: Int, upgradeStatus: Int = 0, locked: Bool = false,
         outdatedReply: String? = nil, outdatedBeforeReply: String? = nil, folderLost: Bool = false,
         statusFileExists: Bool = false, statusText: String? = nil, suReply: String = "") {
        self.statusText = statusText
        self.suReply = suReply
        self.upgradeSeconds = upgradeSeconds
        self.outdatedBefore = outdatedBefore
        self.outdatedAfter = outdatedAfter
        self.upgradeStatus = upgradeStatus
        self.locked = locked
        self.outdatedReply = outdatedReply
        self.outdatedBeforeReply = outdatedBeforeReply
        self.folderLost = folderLost
        self.fileThere = statusFileExists
    }

    func shellRun(_ command: String) async -> String {
        if command.contains(" upgrade ") {
            noteUpgrade(command)
            if let pendingWrittenByUpgrade { prefSet(extensionID: "", key: "upgrade_pending", value: pendingWrittenByUpgrade) }
            try? await Task.sleep(nanoseconds: UInt64(upgradeSeconds * 1_000_000_000))
            // What the shell prints: only the fallback's bare status once the folder is not ours,
            // else the status file, when the line appends the status to it.
            if folderLost { return command.hasSuffix(" || echo $s") ? "\(upgradeStatus)" : "" }
            guard command.contains("{ echo $s >> ") else { return "" }
            if let statusText { return statusText }
            if upgradeStatus == 0 { return "0" }
            // Homebrew's text, read in Library/Homebrew/exceptions.rb (OperationInProgressError).
            return locked
                ? "Error: A `brew upgrade` process has already locked /opt/homebrew/var/homebrew/locks/jq.formula.lock.\n"
                    + "Please wait for it to finish or terminate it to continue.\n\(upgradeStatus)"
                : "Error: jq: post-install step failed\n\(upgradeStatus)"
        }
        if command.hasPrefix("[ ! -L ") { noteCleanup(command); return "" }
        record(command)
        if command.hasPrefix("/bin/cat ") { return statusFileExists ? (statusText ?? "\(upgradeStatus)") : "" }
        if command.hasPrefix("softwareupdate ") { return suReply }
        guard command.contains(" outdated ") else { return "" }
        let before = upgradeRuns == 0
        if before, let outdatedBeforeReply { return outdatedBeforeReply }
        if let outdatedReply { return outdatedReply }
        let formulae = Array(repeating: #"{"name":"jq","installed_versions":["1.6"],"current_version":"1.7"}"#,
                             count: before ? outdatedBefore : outdatedAfter).joined(separator: ",")
        return #"{"formulae":[\#(formulae)],"casks":[]}"#
    }
    private func record(_ command: String) { lock.lock(); ran.append(command); lock.unlock() }
    private func noteUpgrade(_ command: String) { lock.lock(); upgradeLine = command; upgradeCount += 1; lock.unlock() }
    private func noteCleanup(_ command: String) { lock.lock(); cleaned.append(command); lock.unlock() }
    func fsExists(_ path: String) -> Bool {
        path == "/opt/homebrew/bin/brew" || (statusFileExists && path.hasPrefix("/fake-tmp/prosper-appupdates-"))
    }
    func envGet(_ name: String) -> String? { name == "TMPDIR" ? "/fake-tmp/" : nil }
    func timerSchedule(extensionID: String, id: String, every: Bool, seconds: Double, handler: String) {
        lock.lock(); armed[id] = "\(seconds):\(handler)"; lock.unlock()
    }
    func timerCancel(extensionID: String, id: String) { lock.lock(); armed[id] = nil; lock.unlock() }
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
    func currentEpochSeconds() -> Double { now }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func listDirectories(_ path: String) -> [String] { [] }
}

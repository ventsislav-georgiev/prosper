import XCTest
import os
@testable import ProsperApp

/// #290: BunHarness tears its plugin host down with `CodexHarness.killGroup`, so a
/// SIGTERM-ignoring grandchild must still go. #327: the blocking quit-path variant,
/// the guard predicate, and BunHarness's two call sites.
final class ProcessGroupKillTests: XCTestCase {
    /// Stops a recorder row before it touches anything when the fake pgid is not above PID_MAX
    /// (continueAfterFailure is on, so an assert alone would not) (#380).
    private func requireFakePGID() throws {
        guard Self.fakePGID > 99_999 else {
            XCTFail("fake pgids must exceed PID_MAX so a real signal can never land")
            throw XCTSkip("fake pgid not above PID_MAX")
        }
    }

    /// A /bin/sh group leader that backgrounds `sleep 611` and prints its pid.
    private func spawnGroup(_ script: String) throws -> (proc: Process, leader: pid_t, child: pid_t) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        let out = Pipe()
        proc.standardOutput = out
        try proc.run()
        let leader = proc.processIdentifier
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        guard let child = parsePid(line) else {
            killIfReal(leader)
            throw XCTSkip("no child pid from the stand-in: \(line)")
        }
        return (proc, leader, child)
    }

    /// Polls `kill(pid, 0)` every 10 ms until ESRCH or the timeout. The group probe in
    /// escalate skips zombies, so killGroup can return before launchd reaps an orphan,
    /// and `kill(pid, 0)` on a not-yet-reaped zombie still answers 0 (#375).
    private func waitGone(_ pid: pid_t, timeout: TimeInterval = 1) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            if Date() >= deadline { return false }
            usleep(10_000)
        }
    }

    /// Fake pgid for the recorder rows: above PID_MAX (99999 on macOS), so no real group
    /// can ever carry it, whatever the state of the `sendSignal` seam (a detached escalate
    /// outliving the swap, or a row failing before the defer restores it) (#375).
    private static let fakePGID: pid_t = 424242

    private let ignoringTerm = #"trap "" TERM; sleep 611 & echo $!; wait"#

    func testKillGroupTakesDownASigtermIgnoringChild() async throws {
        let (proc, leader, child) = try spawnGroup(ignoringTerm)
        defer { killIfReal(leader); proc.waitUntilExit() }   // no leak if an assert below throws
        XCTAssertEqual(getpgid(leader), leader, "Process must spawn the child as its own group leader")
        XCTAssertEqual(getpgid(child), leader)

        CodexHarness.killGroup(leader)
        if !waitGone(child, timeout: 8) {   // 3 s grace + SIGKILL + reap
            killIfReal(leader)   // don't leak it past a failing test
            XCTFail("the SIGTERM-ignoring child \(child) outlived killGroup")
        }
    }

    /// The quit path: SIGKILL has landed by the time the call returns, within grace + 1 s.
    func testBlockingKillGroupReturnsWithTheGroupGone() throws {
        let (proc, leader, child) = try spawnGroup(ignoringTerm)
        defer { killIfReal(leader); proc.waitUntilExit() }
        XCTAssertEqual(getpgid(leader), leader)
        let done = expectation(description: "blocking killGroup returned")
        DispatchQueue.global().async {   // off-thread so a never-ending wait fails instead of hanging
            CodexHarness.killGroup(leader, grace: 1, blocking: true)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(waitGone(child), "the SIGTERM-ignoring child \(child) outlived blocking killGroup")
    }

    /// The guard as a pure predicate: never call killGroup with these, a regressed guard
    /// would signal the whole login session or the xctest tree (#327).
    func testMayKillGroupRefusesOursAndTheSpecialPgids() throws {
        for pgid in [0, 1, -1, getpgrp()] as [pid_t] {
            XCTAssertFalse(CodexHarness.mayKillGroup(pgid), "pgid \(pgid)")
        }
        let (proc, leader, _) = try spawnGroup("sleep 611 & echo $!; wait")
        defer { killIfReal(leader); proc.waitUntilExit() }
        XCTAssertEqual(getpgid(leader), leader)
        XCTAssertTrue(CodexHarness.mayKillGroup(leader))
    }

    /// Swaps `CodexHarness.sendSignal` for a recorder that never forwards: every probe
    /// answers -1 (group gone), so escalate stops at once and nothing real is signalled.
    /// Guards the fake pgid first, so every recorder row is covered without a scan (#386).
    /// `answer` 0 makes every probe say the group is still alive.
    private func recordingSignals(answer: Int32 = -1, _ body: () -> Void) throws -> [(pid: pid_t, sig: Int32)] {
        try requireFakePGID()
        let log = OSAllocatedUnfairLock(initialState: [(pid: pid_t, sig: Int32)]())
        let saved = CodexHarness.sendSignal
        CodexHarness.sendSignal = { pid, sig in log.withLock { $0.append((pid, sig)) }; return answer }
        defer { CodexHarness.sendSignal = saved }
        body()
        return log.withLock { $0 }
    }

    /// killGroup gates on mayKillGroup before its first signal: a rejected pgid sends
    /// nothing, an accepted one leads with SIGTERM to the group (#361).
    func testKillGroupSendsNothingForRejectedPgidsAndSigtermFirstOtherwise() throws {
        let rejected: [pid_t] = [1, getpgrp()]
        let sent = try recordingSignals {
            for pgid in rejected { CodexHarness.killGroup(pgid, grace: 0.1, blocking: true) }
        }
        // Filter: a detached escalate from an earlier test may land in the window.
        XCTAssertEqual(sent.filter { rejected.contains(-$0.pid) }.map(\.sig), [], "signalled a rejected pgid")

        let accepted = try recordingSignals { CodexHarness.killGroup(Self.fakePGID, grace: 0.1, blocking: true) }
            .filter { $0.pid == -Self.fakePGID }
        XCTAssertEqual(accepted.first?.sig, SIGTERM)
        XCTAssertFalse(accepted.contains { $0.sig == SIGKILL }, "probe said gone; no SIGKILL")
    }

    /// Registers `leader` with `start` and runs the quit drain under the recorder; returns
    /// what it sent to that group. The drain's probe is real, its signals are recorded only.
    private func drainRecording(_ leader: pid_t, start: UInt64) throws -> [Int32] {
        try recordingSignals {
            CodexHarness.livePGIDs.withLock { $0[leader] = start }
            CodexHarness.killLiveGroupsBlocking(grace: 0.1)
        }.filter { $0.pid == -leader }.map(\.sig)
    }

    /// The quit path's registry: a live group passes the probe, gets a group SIGTERM and
    /// the registry is drained (#361, #387).
    func testKillLiveGroupsBlockingSignalsAndDrainsTheRegistry() throws {
        let (proc, leader, _) = try spawnGroup("sleep 611 & echo $!; wait")
        defer { killIfReal(leader); proc.waitUntilExit() }
        let start = try XCTUnwrap(CodexHarness.startTime(leader))
        XCTAssertEqual(try drainRecording(leader, start: start).first, SIGTERM)
        XCTAssertTrue(CodexHarness.livePGIDs.withLock { $0.isEmpty })
    }

    /// #387: an entry whose group is gone (a harness released without shutdown) is dropped
    /// by the probe without a signal.
    func testKillLiveGroupsBlockingSkipsADeadGroup() throws {
        let (proc, leader, child) = try spawnGroup("sleep 611 & echo $!; wait")
        let start = CodexHarness.startTime(leader)   // read before the kill, unwrapped after it
        killIfReal(leader)
        proc.waitUntilExit()
        XCTAssertTrue(waitGone(child), "the stand-in child \(child) outlived its SIGKILL")
        XCTAssertEqual(try drainRecording(leader, start: try XCTUnwrap(start)), [], "signalled a dead group")
        XCTAssertTrue(CodexHarness.livePGIDs.withLock { $0.isEmpty })
    }

    /// #387: a live leader whose start time differs from the registered one is a reused pid.
    func testKillLiveGroupsBlockingSkipsAReusedPgid() throws {
        let (proc, leader, _) = try spawnGroup("sleep 611 & echo $!; wait")
        defer { killIfReal(leader); proc.waitUntilExit() }
        let start = try XCTUnwrap(CodexHarness.startTime(leader))
        XCTAssertEqual(try drainRecording(leader, start: start &+ 1), [], "signalled a reused pgid")
    }

    /// #387: a group that outlives its SIGKILL stays registered so a later quit retries it.
    func testEscalateKeepsAGroupThatOutlivesSigkillRegistered() throws {
        defer { CodexHarness.livePGIDs.withLock { _ = $0.removeValue(forKey: Self.fakePGID) } }
        let sent = try recordingSignals(answer: 0) {   // every probe: still alive
            CodexHarness.livePGIDs.withLock { $0[Self.fakePGID] = 0 }
            CodexHarness.killGroup(Self.fakePGID, grace: 0.1, blocking: true)
        }
        XCTAssertTrue(sent.contains { $0.pid == -Self.fakePGID && $0.sig == SIGKILL }, "\(sent)")
        XCTAssertTrue(CodexHarness.livePGIDs.withLock { $0[Self.fakePGID] != nil }, "a surviving group left the registry")
    }

    /// QA #186: the drain kills inline, so a TERM-ignoring group is gone when it returns
    /// (a detached SIGKILL would lose to atexit's _exit).
    func testKillLiveGroupsBlockingReturnsWithTheGroupGone() throws {
        guard CodexHarness.livePGIDs.withLock({ $0.isEmpty }) else {
            return XCTFail("registry not empty; the real drain would signal groups this row did not start")
        }
        let (proc, leader, child) = try spawnGroup(ignoringTerm)
        defer { killIfReal(leader); proc.waitUntilExit() }
        let start = try XCTUnwrap(CodexHarness.startTime(leader))
        CodexHarness.livePGIDs.withLock { $0[leader] = start }
        let done = expectation(description: "killLiveGroupsBlocking returned")
        DispatchQueue.global().async {   // off-thread so a never-ending wait fails instead of hanging
            CodexHarness.killLiveGroupsBlocking(grace: 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertTrue(waitGone(child, timeout: 0.3), "the SIGTERM-ignoring child \(child) outlived the drain")
    }

    /// Polls the registry until `pgid` leaves it or the timeout: escalate unregisters a
    /// group at its end, off the caller's thread (#377).
    private func waitUnregistered(_ pgid: pid_t, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while CodexHarness.livePGIDs.withLock({ $0[pgid] != nil }) {
            if Date() >= deadline { return false }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// The registry tracks a real start/shutdown: a silent stand-in codex (never answers
    /// `initialize`) is registered once spawned and gone from the registry once shutdown's
    /// escalate ends.
    func testStartRegistersTheCodexGroupAndShutdownUnregistersIt() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosper-tests/pgkill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("codex"), pidFile = dir.appendingPathComponent("pid")
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 611\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let harness = CodexHarness(executableURL: exe, codexHome: dir.appendingPathComponent("home"),
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "t")
        let starting = Task { try await harness.start() }
        let deadline = Date().addingTimeInterval(5)
        var pid: pid_t?
        func registered() -> Bool { pid.map { p in CodexHarness.livePGIDs.withLock { $0[p] != nil } } ?? false }
        while !registered(), Date() < deadline {   // the child may write its pid before run() returns
            pid = parsePid(try? String(contentsOf: pidFile, encoding: .utf8))
            if !registered() { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let leader = try XCTUnwrap(pid, "stand-in codex never started")
        defer { killIfReal(leader) }   // no leak if an assert below throws
        XCTAssertEqual(getpgid(leader), leader)
        XCTAssertTrue(CodexHarness.livePGIDs.withLock { $0[leader] != nil }, "start did not register the group")
        // QA #212: start stores the leader's real start time; a 0 would make the quit drain skip it (#401).
        let registeredStart = CodexHarness.livePGIDs.withLock { $0[leader] }
        XCTAssertEqual(registeredStart, CodexHarness.startTime(leader))
        XCTAssertNotEqual(registeredStart ?? 0, 0, "start registered start time 0: the quit drain would skip a live codex")

        await harness.shutdown()
        _ = try? await starting.value
        let gone = try await waitUnregistered(leader, timeout: 5)
        XCTAssertTrue(gone, "shutdown left the group registered")
    }

    /// #377: a codex that exits on its own leaves a SIGTERM-ignoring child; the group stays
    /// registered through handleTermination's 3 s grace (so a quit then still kills it
    /// inline) and leaves the registry once the escalate has SIGKILLed the child.
    func testHandleTerminationKeepsTheGroupRegisteredUntilEscalateEnds() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosper-tests/pgkill-exit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = dir.appendingPathComponent("codex")
        let pidFile = dir.appendingPathComponent("pid"), childFile = dir.appendingPathComponent("child")
        try """
            #!/bin/sh
            trap "" TERM
            /bin/sleep 611 &
            echo $! > '\(childFile.path)'
            echo $$ > '\(pidFile.path)'
            /bin/sleep 0.3
            """.write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let harness = CodexHarness(executableURL: exe, codexHome: dir.appendingPathComponent("home"),
                                   llmBaseURL: "http://127.0.0.1:0/v1", llmToken: "t")
        // The exit fails the pending initialize, so start returns once handleTermination ran.
        do { try await harness.start(); XCTFail("start succeeded against an exiting stand-in") } catch {}
        func readPid(_ url: URL) -> pid_t? {
            parsePid(try? String(contentsOf: url, encoding: .utf8))
        }
        // Child first, its defer armed before the leader unwrap can throw. Its group and start
        // time are taken now, while the child is certainly alive; the defer signals it by pid
        // only if both still match, so a reused pid or group id is never hit (#386, #387).
        let child = try XCTUnwrap(readPid(childFile), "stand-in codex never forked its child")
        let childGroup = getpgid(child), childStart = CodexHarness.startTime(child)
        defer {
            if childGroup > 1, childStart != nil, getpgid(child) == childGroup,
               CodexHarness.startTime(child) == childStart { killIfReal(child, group: false) }
        }
        let leader = try XCTUnwrap(readPid(pidFile), "stand-in codex never started")
        XCTAssertEqual(childGroup, leader, "the stand-in child is not in the codex group")

        XCTAssertEqual(kill(child, 0), 0, "the SIGTERM-ignoring child died before the grace ended")
        let start = CodexHarness.livePGIDs.withLock { $0[leader] }
        XCTAssertNotNil(start, "handleTermination unregistered the group before its escalate ended")
        // The leader is gone, its child is not: the drain's probe must still take the group (#387).
        XCTAssertTrue(start.map { CodexHarness.isOurGroup(leader, leaderStart: $0) } ?? false,
                      "the quit drain would skip a codex group whose leader exited")
        XCTAssertTrue(waitGone(child, timeout: 8), "the SIGTERM-ignoring child \(child) outlived handleTermination")
        let gone = try await waitUnregistered(leader, timeout: 2)
        XCTAssertTrue(gone, "the group stayed registered after its escalate ended")
    }

    /// A scan by necessity: applicationWillTerminate can't run in a test (it needs a
    /// launched Prosper). Pins the codex teardown before the atexit `_exit` shortcut.
    func testApplicationWillTerminateKillsCodexGroupsBeforeAtexit() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/AppDelegate.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func applicationWillTerminate("))
        let end = try XCTUnwrap(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = source[start.upperBound..<end.lowerBound]
        let call = try XCTUnwrap(body.range(of: "CodexHarness.killLiveGroupsBlocking("), "quit path never kills codex")
        let exit = try XCTUnwrap(body.range(of: "atexit { _exit"))
        XCTAssertLessThan(call.lowerBound, exit.lowerBound, "codex teardown must run before atexit { _exit(0) }")
    }

    /// BunHarness.stopHost (the process half of shutdown, minus the socket unlink) leaves
    /// no live group behind when it returns.
    @MainActor func testBunHarnessStopHostKillsTheHostGroup() throws {
        let harness = BunHarness()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", ignoringTerm]
        let out = Pipe()
        proc.standardOutput = out
        try harness.launch(proc)
        let leader = proc.processIdentifier
        defer { killIfReal(leader); proc.waitUntilExit() }
        let child = try XCTUnwrap(parsePid(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)))
        XCTAssertEqual(getpgid(leader), leader)

        harness.stopHost()
        XCTAssertTrue(waitGone(child), "the host's SIGTERM-ignoring child \(child) outlived stopHost")
    }

    /// A host that exits on its own: the terminationHandler takes its children down.
    @MainActor func testBunHarnessHostExitKillsItsChildren() async throws {
        let harness = BunHarness()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 611 & echo $!; sleep 0.3"]
        let out = Pipe()
        proc.standardOutput = out
        try harness.launch(proc)
        let leader = proc.processIdentifier
        defer { killIfReal(leader) }
        let child = try XCTUnwrap(parsePid(String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)))

        XCTAssertTrue(waitGone(child, timeout: 5), "the host's child \(child) outlived the host")
        withExtendedLifetime(harness) {}
    }

    /// #380, #386: cleanup never signals 0, 1, -1, our group or our pid; pid parsing rejects the first three.
    func testKillIfRealSkipsSpecialPidsAndParsePidRejectsThem() {
        var sent: [pid_t] = []
        for pid in [-1, 0, 1] as [pid_t] { killIfReal(pid, using: { p, _ in sent.append(p); return 0 }) }
        XCTAssertEqual(sent, [], "signalled a special pid")
        killIfReal(424242, using: { p, _ in sent.append(p); return 0 })
        killIfReal(424242, group: false, using: { p, _ in sent.append(p); return 0 })
        XCTAssertEqual(sent, [-424242, 424242])
        sent = []
        killIfReal(getpgrp(), using: { p, _ in sent.append(p); return 0 })
        killIfReal(getpid(), group: false, using: { p, _ in sent.append(p); return 0 })
        XCTAssertEqual(sent, [], "signalled our own group or pid")
        killIfReal(424242, using: { p, _ in sent.append(p); return 0 })   // above PID_MAX: one call, never forwarded to kill (the closure records it)
        XCTAssertEqual(sent, [-424242])
        for text in ["0", "1", "-1", "x", ""] { XCTAssertNil(parsePid(text), text) }
        XCTAssertEqual(parsePid(" 4242\n"), 4242)
    }
}
